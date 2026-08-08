import crypto from 'node:crypto'
import path from 'node:path'
import { existsSync, statSync } from 'node:fs'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { Database } from '../database'
import { getXmpSidecarPath } from '../../services/xmp/xmp-sidecar-writer'
import type { PhotoRow } from './photo.repo'
import type { AssetLinkCandidateData, AssetVolumeData } from '@gather/shared'

function now(): string {
  return new Date().toISOString()
}

function mediaType(extension: string): string {
  if (['.jpg', '.jpeg', '.heic', '.heif', '.png', '.webp'].includes(extension)) return 'image'
  if (['.nef', '.arw', '.cr2', '.cr3', '.dng', '.raf', '.orf', '.rw2', '.pef', '.srw'].includes(extension)) return 'raw'
  if (['.tif', '.tiff', '.psd'].includes(extension)) return 'image'
  return 'unknown'
}

function memberRole(extension: string): string {
  if (mediaType(extension) === 'raw') return 'raw'
  if (['.jpg', '.jpeg', '.heic', '.heif'].includes(extension)) return 'camera_jpeg'
  if (['.tif', '.tiff'].includes(extension)) return 'rendered_tiff'
  return 'unknown'
}

@injectable()
export class AssetRepository {
  private metadataRelocationSink: ((xmpPath: string) => void) | null = null

  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  setMetadataRelocationSink(sink: (xmpPath: string) => void): void {
    this.metadataRelocationSink = sink
  }

  private relocateMetadataState(
    oldPhotoPath: string,
    newPhotoPath: string,
    timestamp: string,
  ): string | null {
    const oldXmp = getXmpSidecarPath(oldPhotoPath)
    const newXmp = getXmpSidecarPath(newPhotoPath)
    if (oldXmp === newXmp) return null
    const oldOutbox = this.db.prepare(
      'SELECT status FROM metadata_outbox WHERE xmp_path = ?',
    ).get(oldXmp) as { status: string } | undefined
    if (oldOutbox?.status === 'writing') {
      throw new Error('ASSET_RELINK_XMP_BUSY')
    }
    if (oldOutbox) {
      const targetExists = this.db.prepare(
        'SELECT 1 FROM metadata_outbox WHERE xmp_path = ?',
      ).get(newXmp)
      if (targetExists) {
        throw new Error('ASSET_RELINK_OUTBOX_CONFLICT')
      }
      this.db.prepare(`
        INSERT INTO metadata_outbox (
          xmp_path, owner_session_id, created_by_session_id, photo_path,
          patch_json, dirty_fields, revision, persisted_revision,
          base_fingerprint, base_values_json, backup_path, status,
          attempt_count, error_message, updated_at
        )
        SELECT ?, owner_session_id, created_by_session_id, ?,
          patch_json, dirty_fields, revision, persisted_revision,
          base_fingerprint, base_values_json, backup_path,
          CASE WHEN status IN ('pending', 'failed') THEN 'pending' ELSE status END,
          CASE WHEN status IN ('pending', 'failed') THEN 0 ELSE attempt_count END,
          CASE WHEN status IN ('pending', 'failed') THEN '' ELSE error_message END,
          ?
        FROM metadata_outbox WHERE xmp_path = ?
      `).run(newXmp, newPhotoPath, timestamp, oldXmp)
      this.db.prepare(`
        INSERT INTO metadata_outbox_sessions
          (xmp_path, session_id, confirmed_at, linked_at)
        SELECT ?, session_id, confirmed_at, linked_at
        FROM metadata_outbox_sessions WHERE xmp_path = ?
      `).run(newXmp, oldXmp)
      this.db.prepare(
        'UPDATE writeback_items SET photo_path = ?, xmp_path = ? WHERE xmp_path = ?',
      ).run(newPhotoPath, newXmp, oldXmp)
      this.db.prepare(`
        INSERT INTO metadata_keyword_origins (
          xmp_path, source, keyword, active, created_at, updated_at
        )
        SELECT ?, source, keyword, active, created_at, ?
        FROM metadata_keyword_origins WHERE xmp_path = ?
        ON CONFLICT(xmp_path, source, keyword) DO UPDATE SET
          active = MAX(active, excluded.active),
          updated_at = excluded.updated_at
      `).run(newXmp, timestamp, oldXmp)
      this.db.prepare('DELETE FROM metadata_keyword_origins WHERE xmp_path = ?')
        .run(oldXmp)
      this.db.prepare('DELETE FROM metadata_outbox WHERE xmp_path = ?')
        .run(oldXmp)
    } else {
      this.db.prepare(
        'UPDATE writeback_items SET photo_path = ?, xmp_path = ? WHERE xmp_path = ?',
      ).run(newPhotoPath, newXmp, oldXmp)
      this.db.prepare(`
        INSERT INTO metadata_keyword_origins (
          xmp_path, source, keyword, active, created_at, updated_at
        )
        SELECT ?, source, keyword, active, created_at, ?
        FROM metadata_keyword_origins WHERE xmp_path = ?
        ON CONFLICT(xmp_path, source, keyword) DO UPDATE SET
          active = MAX(active, excluded.active),
          updated_at = excluded.updated_at
      `).run(newXmp, timestamp, oldXmp)
      this.db.prepare('DELETE FROM metadata_keyword_origins WHERE xmp_path = ?')
        .run(oldXmp)
    }
    return oldOutbox ? newXmp : null
  }

  private relocateSidecarBinding(
    oldPhotoPath: string,
    newPhotoPath: string,
    timestamp: string,
  ): void {
    const oldXmp = getXmpSidecarPath(oldPhotoPath)
    const newXmp = getXmpSidecarPath(newPhotoPath)
    const normalizedOld = path.normalize(oldXmp)
    const normalizedNew = path.normalize(newXmp)
    if (normalizedOld === normalizedNew) return
    const oldBinding = this.db.prepare(
      'SELECT id FROM sidecar_bindings WHERE normalized_xmp_path = ?',
    ).get(normalizedOld) as { id: string } | undefined
    if (!oldBinding) return
    const targetBinding = this.db.prepare(
      'SELECT id FROM sidecar_bindings WHERE normalized_xmp_path = ?',
    ).get(normalizedNew) as { id: string } | undefined
    if (!targetBinding) {
      this.db.prepare(`
        UPDATE sidecar_bindings
        SET xmp_path = ?, normalized_xmp_path = ?, updated_at = ?
        WHERE id = ?
      `).run(newXmp, normalizedNew, timestamp, oldBinding.id)
      return
    }

    const oldState = this.db.prepare(`
      SELECT rating, label, keywords, fingerprint
      FROM sidecar_metadata_state WHERE sidecar_binding_id = ?
    `).get(oldBinding.id) as {
      rating: number | null
      label: string | null
      keywords: string
      fingerprint: string
    } | undefined
    const targetState = this.db.prepare(`
      SELECT rating, label, keywords, fingerprint
      FROM sidecar_metadata_state WHERE sidecar_binding_id = ?
    `).get(targetBinding.id) as typeof oldState
    if (oldState && targetState && (
      oldState.rating !== targetState.rating ||
      oldState.label !== targetState.label ||
      oldState.keywords !== targetState.keywords ||
      oldState.fingerprint !== targetState.fingerprint
    )) {
      throw new Error('ASSET_RELINK_XMP_CONFLICT')
    }
    if (oldState && !targetState) {
      this.db.prepare(`
        INSERT INTO sidecar_metadata_state (
          sidecar_binding_id, rating, label, keywords, fingerprint, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
      `).run(
        targetBinding.id,
        oldState.rating,
        oldState.label,
        oldState.keywords,
        oldState.fingerprint,
        timestamp,
      )
    }
    this.db.prepare(`
      INSERT OR IGNORE INTO sidecar_binding_files (sidecar_binding_id, file_id)
      SELECT ?, file_id FROM sidecar_binding_files WHERE sidecar_binding_id = ?
    `).run(targetBinding.id, oldBinding.id)
    this.db.prepare('DELETE FROM sidecar_bindings WHERE id = ?').run(oldBinding.id)
  }

  backfillSession(sessionId: string): { migrated: number; offline: number; candidates: number } {
    let migrated = 0
    let offline = 0
    const total = (this.db.prepare(
      'SELECT COUNT(*) AS count FROM photos WHERE session_id = ?',
    ).get(sessionId) as { count: number }).count
    const state = this.db.prepare(`
      SELECT last_photo_rowid FROM asset_backfill_state WHERE session_id = ?
    `).get(sessionId) as { last_photo_rowid: number } | undefined
    let cursor = state?.last_photo_rowid ?? 0
    this.db.prepare(`
      INSERT INTO asset_backfill_state (
        session_id, last_photo_rowid, total_photos, status, updated_at
      ) VALUES (?, ?, ?, 'running', ?)
      ON CONFLICT(session_id) DO UPDATE SET
        total_photos = excluded.total_photos,
        status = 'running',
        updated_at = excluded.updated_at
    `).run(sessionId, cursor, total, now())

    try {
      for (;;) {
        const photos = this.db.prepare(`
          SELECT rowid AS migration_rowid, *
          FROM photos
          WHERE session_id = ? AND rowid > ?
            AND (asset_id IS NULL OR asset_file_id IS NULL)
          ORDER BY rowid
          LIMIT 250
        `).all(sessionId, cursor) as Array<PhotoRow & { migration_rowid: number }>
        if (photos.length === 0 && cursor > 0) {
          const remaining = (this.db.prepare(`
            SELECT COUNT(*) AS count
            FROM photos
            WHERE session_id = ? AND (asset_id IS NULL OR asset_file_id IS NULL)
          `).get(sessionId) as { count: number }).count
          if (remaining > 0) {
            cursor = 0
            continue
          }
        }
        if (photos.length === 0) break
        let batchMigrated = 0
        let batchOffline = 0
        this.db.transaction(() => {
          for (const photo of photos) {
            const result = this.ensurePhoto(sessionId, photo)
            batchMigrated += result.migrated
            batchOffline += result.offline
            cursor = photo.migration_rowid
          }
          this.db.prepare(`
            UPDATE asset_backfill_state
            SET last_photo_rowid = ?, migrated_photos = migrated_photos + ?,
                offline_files = offline_files + ?, updated_at = ?
            WHERE session_id = ?
          `).run(cursor, batchMigrated, batchOffline, now(), sessionId)
        })()
        migrated += batchMigrated
        offline += batchOffline
      }
    } catch (error) {
      this.db.prepare(`
        UPDATE asset_backfill_state SET status = 'failed', updated_at = ?
        WHERE session_id = ?
      `).run(now(), sessionId)
      throw error
    }
    const candidates = this.createRawJpegCandidates(sessionId)
    this.db.prepare(`
      UPDATE asset_backfill_state
      SET candidate_links = candidate_links + ?, status = 'completed', updated_at = ?
      WHERE session_id = ?
    `).run(candidates, now(), sessionId)
    return { migrated, offline, candidates }
  }

  listCandidates(sessionId?: string): AssetLinkCandidateData[] {
    const sessionClause = sessionId
      ? `AND EXISTS (
          SELECT 1
          FROM asset_members am
          JOIN session_assets sa ON sa.asset_id = am.asset_id
          WHERE am.file_id IN (c.left_file_id, c.right_file_id)
            AND sa.session_id = ?
        )`
      : ''
    const rows = this.db.prepare(`
      SELECT c.id, c.left_file_id, c.right_file_id, c.confidence,
        c.evidence_json, c.status, lf.normalized_path AS left_path,
        rf.normalized_path AS right_path
      FROM asset_link_candidates c
      JOIN asset_files lf ON lf.id = c.left_file_id
      JOIN asset_files rf ON rf.id = c.right_file_id
      WHERE c.relation_type = 'raw_jpeg' ${sessionClause}
      ORDER BY
        CASE c.status WHEN 'pending' THEN 0 WHEN 'accepted' THEN 1 ELSE 2 END,
        c.updated_at DESC
    `).all(...(sessionId ? [sessionId] : [])) as Array<{
      id: string
      left_file_id: string
      right_file_id: string
      confidence: number
      evidence_json: string
      status: AssetLinkCandidateData['status']
      left_path: string
      right_path: string
    }>
    return rows.map(row => {
      let evidence: Record<string, unknown> = {}
      try { evidence = JSON.parse(row.evidence_json) as Record<string, unknown> } catch { /* empty */ }
      return {
        id: row.id,
        leftFileId: row.left_file_id,
        rightFileId: row.right_file_id,
        leftPath: row.left_path,
        rightPath: row.right_path,
        confidence: row.confidence,
        status: row.status,
        evidence,
      }
    })
  }

  listVolumes(): AssetVolumeData[] {
    const rows = this.db.prepare(`
      SELECT volume_id, normalized_path, online_status
      FROM asset_files ORDER BY volume_id, normalized_path
    `).all() as Array<{
      volume_id: string
      normalized_path: string
      online_status: string
    }>
    const volumes = new Map<string, AssetVolumeData>()
    for (const row of rows) {
      const root = row.normalized_path.startsWith('/Volumes/')
        ? `/${row.normalized_path.split('/').slice(1, 3).join('/')}`
        : path.parse(row.normalized_path).root
      const volume = volumes.get(row.volume_id) ?? {
        volumeId: row.volume_id,
        roots: [],
        onlineFiles: 0,
        offlineFiles: 0,
      }
      if (!volume.roots.includes(root)) volume.roots.push(root)
      if (row.online_status === 'online') volume.onlineFiles++
      else volume.offlineFiles++
      volumes.set(row.volume_id, volume)
    }
    return [...volumes.values()]
  }

  relinkRoot(oldRoot: string, newRoot: string): number {
    const resolvedOld = path.resolve(oldRoot)
    const resolvedNew = path.resolve(newRoot)
    const rows = this.db.prepare(`
      SELECT id, normalized_path FROM asset_files
      WHERE normalized_path = ? OR normalized_path LIKE ? ESCAPE '\\'
    `).all(
      resolvedOld,
      `${resolvedOld.replace(/[\\%_]/g, value => `\\${value}`)}${path.sep}%`,
    ) as Array<{ id: string; normalized_path: string }>
    const changes: Array<{
      id: string
      oldPath: string
      newPath: string
      volumeId: string
      fileIdentity: string
    }> = []
    for (const row of rows) {
      const relativePath = path.relative(resolvedOld, row.normalized_path)
      if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) continue
      const newPath = path.join(resolvedNew, relativePath)
      let volumeId: string
      let fileIdentity: string
      try {
        const info = statSync(newPath)
        if (!info.isFile()) continue
        volumeId = `dev:${info.dev}`
        fileIdentity = String(info.ino)
      } catch {
        continue
      }
      changes.push({
        id: row.id,
        oldPath: row.normalized_path,
        newPath,
        volumeId,
        fileIdentity,
      })
    }
    const timestamp = now()
    const relocatedOutboxPaths: string[] = []
    this.db.transaction(() => {
      const affectedSessions = changes.length > 0
        ? this.db.prepare(`
            SELECT DISTINCT session_id
            FROM photos
            WHERE asset_file_id IN (${changes.map(() => '?').join(',')})
          `).all(...changes.map(change => change.id)) as Array<{ session_id: string }>
        : []
      for (const change of changes) {
        const relocatedOutboxPath = this.relocateMetadataState(
          change.oldPath,
          change.newPath,
          timestamp,
        )
        if (relocatedOutboxPath) relocatedOutboxPaths.push(relocatedOutboxPath)
        this.db.prepare(`
          UPDATE asset_files
          SET volume_id = ?, file_identity = ?, normalized_path = ?, filename = ?,
              online_status = 'online', last_seen_at = ?, updated_at = ?
          WHERE id = ?
        `).run(
          change.volumeId,
          change.fileIdentity,
          change.newPath,
          path.basename(change.newPath),
          timestamp,
          timestamp,
          change.id,
        )
        this.db.prepare(`
          UPDATE photos SET filepath = ?, filename = ?, status = 'pending', updated_at = ?
          WHERE asset_file_id = ?
        `).run(change.newPath, path.basename(change.newPath), timestamp, change.id)
        this.relocateSidecarBinding(change.oldPath, change.newPath, timestamp)
      }
      for (const affected of affectedSessions) {
        const session = this.db.prepare(
          'SELECT source_path FROM sessions WHERE id = ?',
        ).get(affected.session_id) as { source_path: string } | undefined
        if (session?.source_path) {
          const sourcePath = path.resolve(session.source_path)
          const relativeSourcePath = path.relative(resolvedOld, sourcePath)
          if (
            relativeSourcePath === '' ||
            (!relativeSourcePath.startsWith('..') && !path.isAbsolute(relativeSourcePath))
          ) {
            this.db.prepare(
              'UPDATE sessions SET source_path = ?, updated_at = ? WHERE id = ?',
            ).run(
              path.join(resolvedNew, relativeSourcePath),
              timestamp,
              affected.session_id,
            )
          }
        }
        this.db.prepare('DELETE FROM similarity_results WHERE session_id = ?')
          .run(affected.session_id)
        this.db.prepare(
          "DELETE FROM navigation_groups WHERE session_id = ? AND source = 'automatic'",
        ).run(affected.session_id)
        // The relink dropped the session's similarity results, so its stored
        // analysis data is gone while analysis_runs rows stay intact. Bump
        // index_seq in the same transaction (1.4.2) so the last ok run is
        // reported stale instead of the session wrongly staying at stage
        // 'analyzed' with no staleAnalyses.
        this.db.prepare(
          'UPDATE sessions SET index_seq = index_seq + 1, updated_at = ? WHERE id = ?',
        ).run(timestamp, affected.session_id)
      }
    })()
    relocatedOutboxPaths.forEach(xmpPath => this.metadataRelocationSink?.(xmpPath))
    return changes.length
  }

  /**
   * Re-associate a single file after a move/rename only when its content hash
   * identifies exactly one offline file. Ambiguous hashes are deliberately
   * left for manual recovery.
   */
  relinkMovedFile(
    newPath: string,
    checksum: string,
    fileSize: number,
    fileMtimeMs: number,
    fileIdentity = '',
  ): { fileId: string; photoIds: string[] } | null {
    const resolvedPath = path.resolve(newPath)
    let volumeId: string
    try {
      volumeId = `dev:${statSync(resolvedPath).dev}`
    } catch {
      return null
    }
    const identityMatch = fileIdentity
      ? this.db.prepare(`
          SELECT id, normalized_path FROM asset_files
          WHERE volume_id = ? AND file_identity = ? AND normalized_path <> ?
          LIMIT 1
        `).get(volumeId, fileIdentity, resolvedPath) as {
          id: string
          normalized_path: string
        } | undefined
      : undefined
    if (!checksum && !identityMatch) return null
    const checksumMatches = checksum ? (this.db.prepare(`
      SELECT id, normalized_path
      FROM asset_files
      WHERE checksum = ? AND file_size = ? AND normalized_path <> ?
      ORDER BY id
    `).all(checksum, fileSize, path.resolve(newPath)) as Array<{
      id: string
      normalized_path: string
    }>).filter(candidate => !existsSync(candidate.normalized_path)).slice(0, 2) : []
    const match = identityMatch ?? (checksumMatches.length === 1 ? checksumMatches[0] : undefined)
    if (!match) return null
    const photoIds = (this.db.prepare(
      'SELECT id FROM photos WHERE asset_file_id = ? ORDER BY id',
    ).all(match.id) as Array<{ id: string }>).map(row => row.id)
    const timestamp = now()
    let relocatedOutboxPath: string | null = null
    this.db.transaction(() => {
      relocatedOutboxPath = this.relocateMetadataState(
        match.normalized_path,
        resolvedPath,
        timestamp,
      )
      this.db.prepare(`
        UPDATE asset_files
        SET volume_id = ?, file_identity = ?, normalized_path = ?, filename = ?, extension = ?,
            file_size = ?, file_mtime_ms = ?, online_status = 'online',
            last_seen_at = ?, updated_at = ?
        WHERE id = ?
      `).run(
        volumeId,
        fileIdentity,
        resolvedPath,
        path.basename(resolvedPath),
        path.extname(resolvedPath).toLowerCase(),
        fileSize,
        fileMtimeMs,
        timestamp,
        timestamp,
        match.id,
      )
      this.db.prepare(`
        UPDATE photos
        SET filepath = ?, filename = ?, status = 'pending', updated_at = ?
        WHERE asset_file_id = ?
      `).run(resolvedPath, path.basename(resolvedPath), timestamp, match.id)
      this.relocateSidecarBinding(match.normalized_path, resolvedPath, timestamp)
    })()
    if (relocatedOutboxPath) this.metadataRelocationSink?.(relocatedOutboxPath)
    return { fileId: match.id, photoIds }
  }

  acceptCandidate(candidateId: string): void {
    const candidate = this.getCandidate(candidateId)
    if (!candidate) throw new Error('ASSET_LINK_CANDIDATE_NOT_FOUND')
    const accept = this.db.transaction(() => {
      this.mergeFileAssets(candidate.left_file_id, candidate.right_file_id)
      this.db.prepare(`
        UPDATE asset_link_candidates
        SET status = 'accepted', updated_at = ?
        WHERE id = ?
      `).run(now(), candidateId)
    })
    accept()
  }

  rejectCandidate(candidateId: string): void {
    const candidate = this.getCandidate(candidateId)
    if (!candidate) throw new Error('ASSET_LINK_CANDIDATE_NOT_FOUND')
    const reject = this.db.transaction(() => {
      if (candidate.status === 'accepted') {
        this.splitFileAsset(candidate.right_file_id)
      }
      this.db.prepare(`
        UPDATE asset_link_candidates
        SET status = 'rejected', updated_at = ?
        WHERE id = ?
      `).run(now(), candidateId)
    })
    reject()
  }

  /**
   * Promote only fully evidenced, unambiguous RAW/JPEG pairs. Filename
   * similarity alone always remains a manual candidate.
   */
  reconcileRawJpegLinks(sessionId: string): number {
    const candidates = this.db.prepare(`
      SELECT c.id, c.left_file_id, c.right_file_id, c.status,
        lpmc.date_taken AS left_date, rpmc.date_taken AS right_date,
        lpmc.camera_model AS left_camera, rpmc.camera_model AS right_camera,
        (
          SELECT COUNT(*) FROM asset_link_candidates related
          WHERE related.relation_type = 'raw_jpeg' AND related.status = 'pending'
            AND (related.left_file_id = c.left_file_id OR related.right_file_id = c.left_file_id)
        ) AS left_candidate_count,
        (
          SELECT COUNT(*) FROM asset_link_candidates related
          WHERE related.relation_type = 'raw_jpeg' AND related.status = 'pending'
            AND (related.left_file_id = c.right_file_id OR related.right_file_id = c.right_file_id)
        ) AS right_candidate_count
      FROM asset_link_candidates c
      JOIN asset_files lf ON lf.id = c.left_file_id
      JOIN asset_files rf ON rf.id = c.right_file_id
      LEFT JOIN photos lp ON lp.asset_file_id = lf.id AND lp.session_id = ?
      LEFT JOIN photos rp ON rp.asset_file_id = rf.id AND rp.session_id = ?
      LEFT JOIN photo_metadata_cache lpmc ON lpmc.photo_id = lp.id
      LEFT JOIN photo_metadata_cache rpmc ON rpmc.photo_id = rp.id
      WHERE c.relation_type = 'raw_jpeg' AND c.status = 'pending'
      GROUP BY c.id
    `).all(sessionId, sessionId) as Array<{
      id: string
      left_file_id: string
      right_file_id: string
      status: string
      left_date: string | null
      right_date: string | null
      left_camera: string | null
      right_camera: string | null
      left_candidate_count: number
      right_candidate_count: number
    }>
    let merged = 0
    this.db.transaction(() => {
      for (const candidate of candidates) {
        const leftTime = candidate.left_date ? Date.parse(candidate.left_date) : Number.NaN
        const rightTime = candidate.right_date ? Date.parse(candidate.right_date) : Number.NaN
        const leftCamera = candidate.left_camera?.trim()
        const rightCamera = candidate.right_camera?.trim()
        const fullyEvidenced =
          Number.isFinite(leftTime) &&
          Number.isFinite(rightTime) &&
          Math.abs(leftTime - rightTime) <= 2_000 &&
          Boolean(leftCamera && rightCamera) &&
          leftCamera!.localeCompare(rightCamera!, undefined, { sensitivity: 'accent' }) === 0 &&
          candidate.left_candidate_count === 1 &&
          candidate.right_candidate_count === 1
        if (!fullyEvidenced) continue
        this.mergeFileAssets(candidate.left_file_id, candidate.right_file_id)
        this.db.prepare(`
          UPDATE asset_link_candidates
          SET confidence = 1, evidence_json = ?, status = 'accepted', updated_at = ?
          WHERE id = ? AND status = 'pending'
        `).run(
          JSON.stringify({
            sameDirectory: true,
            sameBasename: true,
            captureTimeDeltaMs: Math.abs(leftTime - rightTime),
            cameraModel: leftCamera,
            automatic: true,
            reversible: true,
          }),
          now(),
          candidate.id,
        )
        merged++
      }
      if (merged > 0) {
        this.db.prepare(`
          UPDATE asset_backfill_state
          SET automatic_merges = automatic_merges + ?, updated_at = ?
          WHERE session_id = ?
        `).run(merged, now(), sessionId)
      }
    })()
    return merged
  }

  private getCandidate(candidateId: string): {
    left_file_id: string
    right_file_id: string
    status: string
  } | undefined {
    return this.db.prepare(`
      SELECT left_file_id, right_file_id, status
      FROM asset_link_candidates WHERE id = ?
    `).get(candidateId) as {
      left_file_id: string
      right_file_id: string
      status: string
    } | undefined
  }

  private createRawJpegCandidates(sessionId: string): number {
    const files = this.db.prepare(`
      SELECT DISTINCT af.id, af.filename, af.normalized_path, af.extension
      FROM asset_files af
      JOIN asset_members am ON am.file_id = af.id
      JOIN session_assets sa ON sa.asset_id = am.asset_id
      WHERE sa.session_id = ? AND af.extension IN ('.nef', '.arw', '.cr2', '.cr3', '.dng', '.raf', '.orf', '.rw2', '.pef', '.srw', '.jpg', '.jpeg')
    `).all(sessionId) as Array<{ id: string; filename: string; normalized_path: string; extension: string }>
    let created = 0
    const candidatesByStem = new Map<string, {
      raws: typeof files
      jpegs: typeof files
    }>()
    for (const file of files) {
      const directory = path.dirname(file.normalized_path).toLowerCase()
      const stem = path.basename(file.filename, file.extension).toLowerCase()
      const key = `${directory}\0${stem}`
      const group = candidatesByStem.get(key) ?? { raws: [], jpegs: [] }
      if (mediaType(file.extension) === 'raw') group.raws.push(file)
      else if (['.jpg', '.jpeg'].includes(file.extension)) group.jpegs.push(file)
      candidatesByStem.set(key, group)
    }
    for (const [groupKey, group] of candidatesByStem) {
      for (const raw of group.raws) {
        for (const jpeg of group.jpegs) {
        const exists = this.db.prepare(`
          SELECT id FROM asset_link_candidates
          WHERE (left_file_id = ? AND right_file_id = ?) OR (left_file_id = ? AND right_file_id = ?)
        `).get(raw.id, jpeg.id, jpeg.id, raw.id)
        if (exists) continue
        const timestamp = now()
        const unambiguous = group?.raws.length === 1 && group.jpegs.length === 1
        const candidateId = crypto.randomUUID()
        this.db.prepare(`
          INSERT INTO asset_link_candidates (id, left_file_id, right_file_id, relation_type, confidence, evidence_json, status, created_at, updated_at)
          VALUES (?, ?, ?, 'raw_jpeg', ?, ?, ?, ?, ?)
        `).run(
          candidateId,
          raw.id,
          jpeg.id,
          unambiguous ? 0.85 : 0.7,
          JSON.stringify({
            basename: groupKey.slice(groupKey.lastIndexOf('\0') + 1),
            sameDirectory: true,
            sameSession: true,
            unambiguous,
            requiresManualConfirmation: true,
          }),
          'pending',
          timestamp,
          timestamp,
        )
        created++
        }
      }
    }
    return created
  }

  private mergeFileAssets(primaryFileId: string, secondaryFileId: string): void {
    const primary = this.db.prepare(
      'SELECT asset_id FROM asset_members WHERE file_id = ?',
    ).get(primaryFileId) as { asset_id: string } | undefined
    const secondary = this.db.prepare(
      'SELECT asset_id FROM asset_members WHERE file_id = ?',
    ).get(secondaryFileId) as { asset_id: string } | undefined
    if (!primary || !secondary || primary.asset_id === secondary.asset_id) return

    const timestamp = now()
    const merge = this.db.transaction(() => {
      const secondarySessions = this.db.prepare(
        'SELECT session_id, display_file_id, import_order, added_at FROM session_assets WHERE asset_id = ?',
      ).all(secondary.asset_id) as Array<{
        session_id: string
        display_file_id: string | null
        import_order: number
        added_at: string
      }>
      this.db.prepare('UPDATE asset_members SET asset_id = ?, is_primary = 0, binding_source = ? WHERE asset_id = ?')
        .run(primary.asset_id, 'auto_raw_jpeg', secondary.asset_id)
      for (const membership of secondarySessions) {
        this.db.prepare(`
          INSERT INTO session_assets
            (session_id, asset_id, display_file_id, import_order, added_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(session_id, asset_id) DO UPDATE SET
            import_order = MIN(import_order, excluded.import_order)
        `).run(
          membership.session_id,
          primary.asset_id,
          membership.display_file_id ?? secondaryFileId,
          membership.import_order,
          membership.added_at,
        )
      }
      this.db.prepare('UPDATE photos SET asset_id = ?, updated_at = ? WHERE asset_id = ?')
        .run(primary.asset_id, timestamp, secondary.asset_id)
      this.db.prepare('DELETE FROM session_assets WHERE asset_id = ?').run(secondary.asset_id)
      this.db.prepare('DELETE FROM assets WHERE id = ?').run(secondary.asset_id)
    })
    merge()
  }

  private splitFileAsset(fileId: string): void {
    const membership = this.db.prepare(
      'SELECT asset_id FROM asset_members WHERE file_id = ?',
    ).get(fileId) as { asset_id: string } | undefined
    if (!membership) throw new Error('ASSET_FILE_NOT_LINKED')
    const siblingCount = this.db.prepare(
      'SELECT COUNT(*) AS count FROM asset_members WHERE asset_id = ?',
    ).get(membership.asset_id) as { count: number }
    if (siblingCount.count <= 1) return

    const timestamp = now()
    const assetId = crypto.randomUUID()
    this.db.prepare(
      'INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
    ).run(assetId, '', 'active', timestamp, timestamp)
    this.db.prepare(`
      UPDATE asset_members
      SET asset_id = ?, is_primary = 1, binding_source = 'manual_split'
      WHERE file_id = ?
    `).run(assetId, fileId)

    const sessions = this.db.prepare(`
      SELECT DISTINCT session_id FROM photos WHERE asset_file_id = ?
    `).all(fileId) as Array<{ session_id: string }>
    this.db.prepare('UPDATE photos SET asset_id = ?, updated_at = ? WHERE asset_file_id = ?')
      .run(assetId, timestamp, fileId)
    for (const { session_id: sessionId } of sessions) {
      this.db.prepare(`
        INSERT OR IGNORE INTO session_assets
          (session_id, asset_id, display_file_id, import_order, added_at)
        VALUES (?, ?, ?, 0, ?)
      `).run(sessionId, assetId, fileId, timestamp)
      this.db.prepare(`
        DELETE FROM session_assets
        WHERE session_id = ? AND asset_id = ?
          AND NOT EXISTS (
            SELECT 1 FROM photos
            WHERE session_id = ? AND asset_id = ?
          )
      `).run(sessionId, membership.asset_id, sessionId, membership.asset_id)
    }
  }

  private ensurePhoto(sessionId: string, photo: PhotoRow): { migrated: number; offline: number; candidates: number } {
    const absolute = path.resolve(photo.filepath)
    const normalizedPath = path.normalize(absolute)
    const parsed = path.parse(absolute)
    const extension = parsed.ext.toLowerCase()
    let fileSize = 0
    let mtimeMs = 0
    let deviceId: number | null = null
    let fileIdentity = ''
    let onlineStatus = 'online'
    try {
      const info = statSync(absolute)
      fileSize = info.size
      mtimeMs = info.mtimeMs
      deviceId = info.dev
      fileIdentity = String(info.ino)
    } catch {
      onlineStatus = 'offline'
    }
    const timestamp = now()
    const volumeId = (() => {
      if (deviceId !== null) return `dev:${deviceId}`
      try {
        return `dev:${statSync(parsed.root).dev}`
      } catch {
        return `path:${parsed.root}`
      }
    })()
    let file: { id: string; normalized_path?: string } | undefined = fileIdentity
      ? this.db.prepare(`
          SELECT * FROM asset_files
          WHERE volume_id = ? AND file_identity = ?
          ORDER BY updated_at DESC LIMIT 1
        `).get(volumeId, fileIdentity) as { id: string; normalized_path: string } | undefined
      : undefined
    file ??= this.db.prepare(
      'SELECT * FROM asset_files WHERE normalized_path = ? ORDER BY updated_at DESC LIMIT 1',
    ).get(normalizedPath) as { id: string; normalized_path: string } | undefined
    if (!file) {
      const fileId = crypto.randomUUID()
      this.db.prepare(`
        INSERT INTO asset_files (
          id, volume_id, file_identity, normalized_path, filename, extension, media_type,
          file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        fileId, volumeId, fileIdentity, normalizedPath, path.basename(absolute), extension,
        mediaType(extension), fileSize, mtimeMs, photo.checksum, onlineStatus,
        timestamp, timestamp, timestamp,
      )
      file = { id: fileId }
    } else {
      const previousPath = file.normalized_path
      this.db.prepare(`
        UPDATE asset_files
        SET volume_id = ?, file_identity = CASE WHEN ? != '' THEN ? ELSE file_identity END,
            normalized_path = ?, filename = ?, extension = ?,
            file_size = ?, file_mtime_ms = ?,
            checksum = CASE WHEN ? != '' THEN ? ELSE checksum END, online_status = ?,
            last_seen_at = ?, updated_at = ?
        WHERE id = ?
      `).run(
        volumeId,
        fileIdentity,
        fileIdentity,
        normalizedPath,
        path.basename(absolute),
        extension,
        fileSize,
        mtimeMs,
        photo.checksum,
        photo.checksum,
        onlineStatus,
        timestamp,
        timestamp,
        file.id,
      )
      if (previousPath && previousPath !== normalizedPath && !existsSync(previousPath)) {
        this.db.prepare(`
          UPDATE photos SET filepath = ?, filename = ?, status = 'pending', updated_at = ?
          WHERE asset_file_id = ?
        `).run(normalizedPath, path.basename(normalizedPath), timestamp, file.id)
      }
    }

    let membership = this.db.prepare(
      'SELECT asset_id FROM asset_members WHERE file_id = ?',
    ).get(file.id) as { asset_id: string } | undefined
    if (!membership) {
      const assetId = crypto.randomUUID()
      this.db.prepare(
        'INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
      ).run(assetId, '', onlineStatus === 'online' ? 'active' : 'offline_unverified', timestamp, timestamp)
      this.db.prepare(
        'INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source) VALUES (?, ?, ?, 1, ?)',
      ).run(assetId, file.id, memberRole(extension), 'backfill')
      membership = { asset_id: assetId }
    }

    this.db.prepare(`
      INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(session_id, asset_id) DO UPDATE SET display_file_id = excluded.display_file_id
    `).run(
      sessionId,
      membership.asset_id,
      file.id,
      (photo as PhotoRow & { migration_rowid?: number }).migration_rowid ??
        (this.db.prepare('SELECT rowid FROM photos WHERE id = ?').get(photo.id) as {
          rowid: number
        }).rowid,
      timestamp,
    )
    this.db.prepare(
      "UPDATE assets SET status = ?, updated_at = ? WHERE id = ?",
    ).run(onlineStatus === 'online' ? 'active' : 'offline_unverified', timestamp, membership.asset_id)
    this.db.prepare('UPDATE photos SET asset_id = ?, asset_file_id = ? WHERE id = ?')
      .run(membership.asset_id, file.id, photo.id)

    const sidecarPath = getXmpSidecarPath(absolute)
    const bindingId = crypto.randomUUID()
    this.db.prepare(`
      INSERT INTO sidecar_bindings (id, xmp_path, normalized_xmp_path, binding_rule, created_at, updated_at)
      VALUES (?, ?, ?, 'same_basename', ?, ?)
      ON CONFLICT(normalized_xmp_path) DO UPDATE SET updated_at = excluded.updated_at
    `).run(bindingId, sidecarPath, path.normalize(sidecarPath), timestamp, timestamp)
    const binding = this.db.prepare('SELECT id FROM sidecar_bindings WHERE normalized_xmp_path = ?')
      .get(path.normalize(sidecarPath)) as { id: string }
    this.db.prepare(
      'INSERT OR IGNORE INTO sidecar_binding_files (sidecar_binding_id, file_id) VALUES (?, ?)',
    ).run(binding.id, file.id)

    return { migrated: 1, offline: onlineStatus === 'online' ? 0 : 1, candidates: 0 }
  }
}
