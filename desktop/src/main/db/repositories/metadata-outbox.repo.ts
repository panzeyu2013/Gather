import { Database } from '../database'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

export type MetadataOutboxStatus =
  | 'clean'
  | 'pending'
  | 'writing'
  | 'written'
  | 'failed'
  | 'conflict'
  | 'synced'
  | 'cleaned'

export interface MetadataOutboxRow {
  xmp_path: string
  owner_session_id: string
  photo_path: string
  patch_json: string
  dirty_fields: string
  revision: number
  persisted_revision: number
  base_fingerprint: string
  base_values_json: string
  backup_path: string
  status: MetadataOutboxStatus
  attempt_count: number
  error_message: string
  updated_at: string
}

@injectable()
export class MetadataOutboxRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  get(xmpPath: string): MetadataOutboxRow | null {
    return (this.db.prepare(
      'SELECT * FROM metadata_outbox WHERE xmp_path = ?',
    ).get(xmpPath) as MetadataOutboxRow | undefined) ?? null
  }

  getBySession(sessionId: string): MetadataOutboxRow[] {
    return this.db.prepare(`
      SELECT *
      FROM metadata_outbox
      WHERE owner_session_id = ?
      ORDER BY updated_at, xmp_path
    `).all(sessionId) as MetadataOutboxRow[]
  }

  getRecoverable(): MetadataOutboxRow[] {
    return this.db.prepare(`
      SELECT *
      FROM metadata_outbox
      WHERE status IN ('pending', 'writing', 'failed')
      ORDER BY updated_at
    `).all() as MetadataOutboxRow[]
  }

  mergePatch(
    xmpPath: string,
    sessionId: string,
    photoPath: string,
    patch: Record<string, unknown>,
    dirtyFields: string[],
  ): MetadataOutboxRow {
    const existing = this.get(xmpPath)
    if (
      existing &&
      existing.owner_session_id !== sessionId &&
      !['cleaned', 'clean'].includes(existing.status)
    ) {
      throw new Error(
        `XMP sidecar is already pending in another workspace: ${xmpPath}`,
      )
    }

    let existingPatch: Record<string, unknown> = {}
    let existingDirty: string[] = []
    try {
      const startsNewRevision =
        existing?.persisted_revision === existing?.revision &&
        ['written', 'synced', 'clean', 'cleaned'].includes(existing?.status ?? '')
      existingPatch = existing && !startsNewRevision
        ? JSON.parse(existing.patch_json) as Record<string, unknown>
        : {}
      existingDirty = existing && !startsNewRevision
        ? JSON.parse(existing.dirty_fields) as string[]
        : []
    } catch {
      // Invalid internal rows are overwritten with the new valid patch.
    }
    const mergedPatch = { ...existingPatch, ...patch }
    const mergedDirty = [...new Set([...existingDirty, ...dirtyFields])]
    const revision = (existing?.revision ?? 0) + 1
    const now = new Date().toISOString()

    this.db.prepare(`
      INSERT INTO metadata_outbox (
        xmp_path, owner_session_id, photo_path, patch_json, dirty_fields,
        revision, persisted_revision, base_fingerprint, base_values_json,
        backup_path, status, attempt_count, error_message, updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, 0, '', '{}', '', 'pending', 0, '', ?)
      ON CONFLICT(xmp_path) DO UPDATE SET
        owner_session_id = excluded.owner_session_id,
        photo_path = excluded.photo_path,
        patch_json = excluded.patch_json,
        dirty_fields = excluded.dirty_fields,
        revision = excluded.revision,
        status = 'pending',
        attempt_count = 0,
        error_message = '',
        updated_at = excluded.updated_at
    `).run(
      xmpPath,
      sessionId,
      photoPath,
      JSON.stringify(mergedPatch),
      JSON.stringify(mergedDirty),
      revision,
      now,
    )
    return this.get(xmpPath)!
  }

  claim(xmpPath: string, expectedRevision: number): boolean {
    const result = this.db.prepare(`
      UPDATE metadata_outbox
      SET status = 'writing',
          attempt_count = attempt_count + 1,
          updated_at = ?
      WHERE xmp_path = ?
        AND revision = ?
        AND status IN ('pending', 'failed')
    `).run(new Date().toISOString(), xmpPath, expectedRevision)
    return result.changes === 1
  }

  markWritten(
    xmpPath: string,
    revision: number,
    fingerprint: string,
    baseValues: Record<string, unknown>,
    backupPath: string,
  ): void {
    this.db.prepare(`
      UPDATE metadata_outbox
      SET persisted_revision = ?,
          base_fingerprint = ?,
          base_values_json = ?,
          backup_path = ?,
          status = CASE WHEN revision = ? THEN 'written' ELSE 'pending' END,
          error_message = '',
          updated_at = ?
      WHERE xmp_path = ?
    `).run(
      revision,
      fingerprint,
      JSON.stringify(baseValues),
      backupPath,
      revision,
      new Date().toISOString(),
      xmpPath,
    )
  }

  markStatus(
    xmpPath: string,
    status: MetadataOutboxStatus,
    errorMessage = '',
  ): void {
    this.db.prepare(`
      UPDATE metadata_outbox
      SET status = ?, error_message = ?, updated_at = ?
      WHERE xmp_path = ?
    `).run(status, errorMessage, new Date().toISOString(), xmpPath)
  }

  resetForRetry(xmpPath: string): void {
    this.db.prepare(`
      UPDATE metadata_outbox
      SET status = 'pending',
          attempt_count = 0,
          error_message = '',
          updated_at = ?
      WHERE xmp_path = ? AND status = 'failed'
    `).run(new Date().toISOString(), xmpPath)
  }

  setBackupPath(xmpPath: string, backupPath: string): void {
    this.db.prepare(`
      UPDATE metadata_outbox
      SET backup_path = ?, updated_at = ?
      WHERE xmp_path = ? AND backup_path = ''
    `).run(backupPath, new Date().toISOString(), xmpPath)
  }

  initializeBaseline(
    xmpPath: string,
    baselineFingerprint: string,
    baselineValues: Record<string, unknown>,
  ): void {
    this.db.prepare(`
      UPDATE metadata_outbox
      SET base_fingerprint = ?,
          base_values_json = ?,
          updated_at = ?
      WHERE xmp_path = ? AND base_fingerprint = ''
    `).run(
      baselineFingerprint,
      JSON.stringify(baselineValues),
      new Date().toISOString(),
      xmpPath,
    )
  }

  recoverInterrupted(): void {
    this.db.prepare(`
      UPDATE metadata_outbox
      SET status = 'pending', updated_at = ?
      WHERE status = 'writing'
    `).run(new Date().toISOString())
  }

  purgeOrphans(): void {
    this.db.prepare(`
      DELETE FROM metadata_outbox
      WHERE owner_session_id NOT IN (SELECT id FROM sessions)
    `).run()
  }

  markSessionSynced(sessionId: string): void {
    this.db.prepare(`
      UPDATE metadata_outbox
      SET status = 'synced', updated_at = ?
      WHERE owner_session_id = ? AND status = 'written'
    `).run(new Date().toISOString(), sessionId)
  }

  delete(xmpPath: string): void {
    this.db.prepare('DELETE FROM metadata_outbox WHERE xmp_path = ?').run(xmpPath)
  }
}
