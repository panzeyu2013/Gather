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
  owner_session_id: string | null
  photo_path: string
  patch_json: string
  dirty_fields: string
  source_module: string
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
      SELECT o.*
      FROM metadata_outbox o
      JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
      WHERE os.session_id = ?
      ORDER BY o.updated_at, o.xmp_path
    `).all(sessionId) as MetadataOutboxRow[]
  }

  getSessionIds(xmpPath: string): string[] {
    return (this.db.prepare(`
      SELECT session_id FROM metadata_outbox_sessions
      WHERE xmp_path = ? ORDER BY linked_at, session_id
    `).all(xmpPath) as Array<{ session_id: string }>).map(row => row.session_id)
  }

  /**
   * Whether the session still holds outbox work from a batch writeback workflow
   * other than the given module that is written or synced — i.e. it must be
   * confirmed in Capture One and cleaned up before another module starts.
   *
   * Only batch workflows (face-keyword/similarity/template) participate in the
   * gate: they rewrite whole keyword sets and depend on the confirm→cleanup
   * cycle. Interactive culling rating/label sync and 'manual' edits are
   * continuous and must never block a writeback, so they are excluded.
   */
  hasActiveOtherModule(sessionId: string, module: string): boolean {
    const row = this.db.prepare(`
      SELECT 1
      FROM metadata_outbox o
      JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
      WHERE os.session_id = ?
        AND o.source_module IN ('face-keyword', 'similarity', 'template')
        AND o.source_module != ?
        AND o.status IN ('written', 'synced')
      LIMIT 1
    `).get(sessionId, module)
    return row !== undefined
  }

  getRecoverable(): MetadataOutboxRow[] {
    return this.db.prepare(`
      SELECT *
      FROM metadata_outbox
      WHERE status IN ('pending', 'writing', 'failed')
      ORDER BY updated_at
    `).all() as MetadataOutboxRow[]
  }

  getOrphans(): MetadataOutboxRow[] {
    return this.db.prepare(`
      SELECT o.*
      FROM metadata_outbox o
      WHERE NOT EXISTS (
        SELECT 1 FROM metadata_outbox_sessions os WHERE os.xmp_path = o.xmp_path
      )
      ORDER BY o.updated_at DESC
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
    const sourceModule =
      typeof patch.source === 'string' && patch.source !== '' ? patch.source : 'manual'
    const revision = (existing?.revision ?? 0) + 1
    const now = new Date().toISOString()

    const transaction = this.db.transaction(() => {
      this.db.prepare(`
        INSERT INTO metadata_outbox (
        xmp_path, owner_session_id, created_by_session_id, photo_path, patch_json, dirty_fields,
        source_module, revision, persisted_revision, base_fingerprint, base_values_json,
        backup_path, status, attempt_count, error_message, updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, '', '{}', '', 'pending', 0, '', ?)
      ON CONFLICT(xmp_path) DO UPDATE SET
        photo_path = excluded.photo_path,
        patch_json = excluded.patch_json,
        dirty_fields = excluded.dirty_fields,
        source_module = excluded.source_module,
        revision = excluded.revision,
        status = 'pending',
        attempt_count = 0,
        error_message = '',
        updated_at = excluded.updated_at
      `).run(
        xmpPath,
        sessionId,
        sessionId,
        photoPath,
        JSON.stringify(mergedPatch),
        JSON.stringify(mergedDirty),
        sourceModule,
        revision,
        now,
      )
      this.db.prepare(`
        INSERT INTO metadata_outbox_sessions
          (xmp_path, session_id, confirmed_at, linked_at)
        VALUES (?, ?, '', ?)
        ON CONFLICT(xmp_path, session_id) DO UPDATE SET confirmed_at = ''
      `).run(xmpPath, sessionId, now)
      this.db.prepare(`
        UPDATE metadata_outbox_sessions SET confirmed_at = ''
        WHERE xmp_path = ?
      `).run(xmpPath)
    })
    transaction()
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

  resolveConflict(
    xmpPath: string,
    patch: Record<string, unknown>,
    dirtyFields: string[],
    baselineFingerprint: string,
    baselineValues: Record<string, unknown>,
    acceptRemote: boolean,
  ): void {
    if (acceptRemote) {
      // All local dirty fields were discarded. Keeping a synthetic "written"
      // transaction here would make cleanup delete or restore the external XMP
      // that the user explicitly chose to keep.
      this.delete(xmpPath)
      return
    }
    const now = new Date().toISOString()
    this.db.prepare(`
      UPDATE metadata_outbox
      SET patch_json = ?, dirty_fields = ?, revision = revision + 1,
          persisted_revision = persisted_revision,
          base_fingerprint = ?, base_values_json = ?,
          status = 'pending',
          attempt_count = 0, error_message = '', updated_at = ?
      WHERE xmp_path = ? AND status = 'conflict'
    `).run(
      JSON.stringify(patch),
      JSON.stringify(dirtyFields),
      baselineFingerprint,
      JSON.stringify(baselineValues),
      now,
      xmpPath,
    )
    this.db.prepare(
      'UPDATE metadata_outbox_sessions SET confirmed_at = ? WHERE xmp_path = ?',
    ).run('', xmpPath)
  }

  markSessionSynced(sessionId: string): void {
    const now = new Date().toISOString()
    const transaction = this.db.transaction(() => {
      this.db.prepare(`
        UPDATE metadata_outbox_sessions
        SET confirmed_at = ?
        WHERE session_id = ?
          AND xmp_path IN (
            SELECT xmp_path FROM metadata_outbox WHERE status IN ('written', 'synced')
          )
      `).run(now, sessionId)
      this.db.prepare(`
        UPDATE metadata_outbox
        SET status = 'synced', updated_at = ?
        WHERE status = 'written'
          AND EXISTS (
            SELECT 1 FROM metadata_outbox_sessions os
            WHERE os.xmp_path = metadata_outbox.xmp_path
          )
          AND NOT EXISTS (
            SELECT 1 FROM metadata_outbox_sessions os
            WHERE os.xmp_path = metadata_outbox.xmp_path
              AND os.confirmed_at = ''
          )
      `).run(now)
    })
    transaction()
  }

  delete(xmpPath: string): void {
    this.db.prepare('DELETE FROM metadata_outbox WHERE xmp_path = ?').run(xmpPath)
  }
}
