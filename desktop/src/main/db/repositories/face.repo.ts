import { Database } from '../database'
import * as path from 'path'
import * as fs from 'fs'
import { app } from 'electron'
import { FACE_THUMB_DIR } from '@gather/shared'
import type { SettingsService } from '../../services/settings/settings.service'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

export interface FaceObservationInput {
  photoId: string
  bboxX: number
  bboxY: number
  bboxW: number
  bboxH: number
  embedding: number[]
  confidence: number
  sourceFileSize?: number
  sourceFileMtimeMs?: number
  analysisSignature?: string
}

export interface FaceObservationRow {
  id: number
  photo_id: string
  session_id: string
  bbox_x: number
  bbox_y: number
  bbox_w: number
  bbox_h: number
  embedding: Buffer
  confidence: number
  source_file_size: number
  source_file_mtime_ms: number
  analysis_signature: string
}

export interface FaceClusterInput {
  label: string
  members: {
    photoId: string
    photoPath: string
    bbox: number[]
    confidence: number
    observationId: number | null
  }[]
}

export interface FaceClusterRow {
  id: number
  session_id: string
  label: string
  member_count: number
  status: string
  thumbnail_base64: string
  thumbnail_path: string
  members?: FaceClusterMemberRow[]
  binding?: { clusterId: string; roleName: string; keywords: string[] }
}

export interface FaceClusterMemberRow {
  id: number
  cluster_id: number
  session_id: string
  photo_id: string
  photo_path: string
  bbox: string
  confidence: number
  observation_id: number | null
}

function parseBbox(raw: string): number[] {
  try {
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed as number[] : []
  } catch {
    return []
  }
}

@injectable()
export class FaceRepository {
  constructor(
    @inject(DI_TOKENS.DB) private db: Database,
    @inject(DI_TOKENS.SETTINGS_SERVICE) private settings: SettingsService,
  ) {}

  saveObservations(sessionId: string, observations: FaceObservationInput[]): number[] {
    const ids: number[] = []
    const stmt = this.db.prepare(
      `INSERT INTO face_observations
       (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
        source_file_size, source_file_mtime_ms, analysis_signature)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    const insertMany = this.db.transaction(() => {
      for (const obs of observations) {
        const embBuffer = Buffer.from(new Float32Array(obs.embedding).buffer)
        const result = stmt.run(
          obs.photoId,
          sessionId,
          obs.bboxX,
          obs.bboxY,
          obs.bboxW,
          obs.bboxH,
          embBuffer,
          obs.confidence,
          obs.sourceFileSize ?? 0,
          obs.sourceFileMtimeMs ?? 0,
          obs.analysisSignature ?? '',
        )
        ids.push(Number(result.lastInsertRowid))
      }
    })
    insertMany()
    return ids
  }

  getObservations(sessionId: string): FaceObservationRow[] {
    return this.db.prepare('SELECT * FROM face_observations WHERE session_id = ? ORDER BY id').all(sessionId) as FaceObservationRow[]
  }

  getAnalysisStates(sessionId: string): Map<string, {
    sourceFileSize: number
    sourceFileMtimeMs: number
    analysisSignature: string
  }> {
    const rows = this.db.prepare(
      `SELECT photo_id, source_file_size, source_file_mtime_ms, analysis_signature
       FROM face_analysis_state WHERE session_id = ?`,
    ).all(sessionId) as Array<{
      photo_id: string
      source_file_size: number
      source_file_mtime_ms: number
      analysis_signature: string
    }>
    return new Map(rows.map(row => [row.photo_id, {
      sourceFileSize: row.source_file_size,
      sourceFileMtimeMs: row.source_file_mtime_ms,
      analysisSignature: row.analysis_signature,
    }]))
  }

  /**
   * Reuse observations from another photo that shares the same asset file and
   * was already analyzed with an identical file state (size/mtime) and
   * signature. Batch form: the service passes every photo that needs analysis
   * in one call, all candidate sources are loaded with a single IN query, and
   * each target with a matching source gets the observations copied over.
   * Returns a map keyed by target photo id; targets without a reusable source
   * are absent from it. Same matching semantics as the per-photo form (newest
   * matching source wins, the source's state session is its own session).
   */
  reuseObservationsForAssetFile(
    sessionId: string,
    photoId: string,
    sourceFileSize: number,
    sourceFileMtimeMs: number,
    analysisSignature: string,
  ): { reused: boolean; faceCount: number }
  reuseObservationsForAssetFile(
    sessionId: string,
    targets: Array<{
      photoId: string
      assetFileId: string | null
      sourceFileSize: number
      sourceFileMtimeMs: number
    }>,
    analysisSignature: string,
  ): Record<string, { reused: boolean; faceCount: number }>
  reuseObservationsForAssetFile(
    sessionId: string,
    photoIdOrTargets: string | Array<{
      photoId: string
      assetFileId: string | null
      sourceFileSize: number
      sourceFileMtimeMs: number
    }>,
    sourceFileSizeOrSignature: number | string,
    sourceFileMtimeMs?: number,
    analysisSignature?: string,
  ): { reused: boolean; faceCount: number } | Record<string, { reused: boolean; faceCount: number }> {
    // Per-photo compatibility form: resolve the target's asset file first,
    // then delegate to the batch path below.
    if (typeof photoIdOrTargets === 'string') {
      const photoId = photoIdOrTargets
      const row = this.db.prepare(
        'SELECT asset_file_id FROM photos WHERE id = ? AND session_id = ?',
      ).get(photoId, sessionId) as { asset_file_id: string | null } | undefined
      const results = this.reuseObservationsForAssetFile(sessionId, [{
        photoId,
        assetFileId: row?.asset_file_id ?? null,
        sourceFileSize: sourceFileSizeOrSignature as number,
        sourceFileMtimeMs: sourceFileMtimeMs as number,
      }], analysisSignature as string)
      return results[photoId] ?? { reused: false, faceCount: 0 }
    }

    const targets = photoIdOrTargets
    // Batch form passes the signature as the third argument.
    const signature = sourceFileSizeOrSignature as string
    const results: Record<string, { reused: boolean; faceCount: number }> = {}
    const assetFileIds = [...new Set(
      targets
        .map(target => target.assetFileId)
        .filter((id): id is string => id !== null),
    )]
    if (assetFileIds.length === 0) return results
    // ORDER BY s.updated_at DESC ranks every candidate; per target the first
    // row that matches its file state is the source the per-photo query
    // (ORDER BY updated_at DESC LIMIT 1) would have picked.
    const sourcesByAssetFile = new Map<string, Array<{
      photoId: string
      sourceFileSize: number
      sourceFileMtimeMs: number
      analysisSignature: string
    }>>()
    for (let index = 0; index < assetFileIds.length; index += 800) {
      const chunk = assetFileIds.slice(index, index + 800)
      const placeholders = chunk.map(() => '?').join(', ')
      const rows = this.db.prepare(`
        SELECT p.asset_file_id, s.photo_id, s.source_file_size,
               s.source_file_mtime_ms, s.analysis_signature
        FROM photos p
        JOIN face_analysis_state s ON s.photo_id = p.id AND s.session_id = p.session_id
        WHERE p.asset_file_id IN (${placeholders})
        ORDER BY s.updated_at DESC
      `).all(...chunk) as Array<{
        asset_file_id: string
        photo_id: string
        source_file_size: number
        source_file_mtime_ms: number
        analysis_signature: string
      }>
      for (const row of rows) {
        const list = sourcesByAssetFile.get(row.asset_file_id) ?? []
        list.push({
          photoId: row.photo_id,
          sourceFileSize: row.source_file_size,
          sourceFileMtimeMs: row.source_file_mtime_ms,
          analysisSignature: row.analysis_signature,
        })
        sourcesByAssetFile.set(row.asset_file_id, list)
      }
    }
    const deleteStmt = this.db.prepare(
      'DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?',
    )
    const copyStmt = this.db.prepare(`
      INSERT INTO face_observations (
        photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
        source_file_size, source_file_mtime_ms, analysis_signature, created_at
      )
      SELECT ?, ?, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
             source_file_size, source_file_mtime_ms, analysis_signature, ?
      FROM face_observations
      WHERE photo_id = ?
        AND session_id = (SELECT session_id FROM photos WHERE id = ?)
    `)
    for (const target of targets) {
      if (!target.assetFileId) continue
      const source = (sourcesByAssetFile.get(target.assetFileId) ?? []).find(candidate =>
        candidate.photoId !== target.photoId &&
        candidate.sourceFileSize === target.sourceFileSize &&
        Math.abs(candidate.sourceFileMtimeMs - target.sourceFileMtimeMs) < 1 &&
        candidate.analysisSignature === signature,
      )
      if (!source) continue
      let faceCount = 0
      this.db.transaction(() => {
        deleteStmt.run(sessionId, target.photoId)
        const copied = copyStmt.run(
          target.photoId,
          sessionId,
          new Date().toISOString(),
          source.photoId,
          source.photoId,
        )
        faceCount = copied.changes
        this.upsertAnalysisState(
          sessionId,
          target.photoId,
          target.sourceFileSize,
          target.sourceFileMtimeMs,
          signature,
        )
      })()
      results[target.photoId] = { reused: true, faceCount }
    }
    return results
  }

  upsertAnalysisState(
    sessionId: string,
    photoId: string,
    sourceFileSize: number,
    sourceFileMtimeMs: number,
    analysisSignature: string,
  ): void {
    this.db.prepare(
      `INSERT INTO face_analysis_state
       (photo_id, session_id, source_file_size, source_file_mtime_ms, analysis_signature, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(photo_id) DO UPDATE SET
         session_id = excluded.session_id,
         source_file_size = excluded.source_file_size,
         source_file_mtime_ms = excluded.source_file_mtime_ms,
         analysis_signature = excluded.analysis_signature,
         updated_at = excluded.updated_at`,
    ).run(
      photoId,
      sessionId,
      sourceFileSize,
      sourceFileMtimeMs,
      analysisSignature,
      new Date().toISOString(),
    )
  }

  getClusterSignature(sessionId: string): string | null {
    const row = this.db.prepare(
      'SELECT cluster_signature FROM face_cluster_state WHERE session_id = ?',
    ).get(sessionId) as { cluster_signature: string } | undefined
    return row?.cluster_signature ?? null
  }

  upsertClusterSignature(sessionId: string, signature: string): void {
    this.db.prepare(`
      INSERT INTO face_cluster_state (session_id, cluster_signature, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET
        cluster_signature = excluded.cluster_signature,
        updated_at = excluded.updated_at
    `).run(sessionId, signature, new Date().toISOString())
  }

  updateEmbedding(observationId: number, embedding: number[]): void {
    const embBuffer = Buffer.from(new Float32Array(embedding).buffer)
    this.db.prepare('UPDATE face_observations SET embedding = ? WHERE id = ?').run(embBuffer, observationId)
  }

  deleteObservationsBySession(sessionId: string): void {
    this.db.transaction(() => {
      this.db.prepare('DELETE FROM face_observations WHERE session_id = ?').run(sessionId)
      this.db.prepare('DELETE FROM face_analysis_state WHERE session_id = ?').run(sessionId)
      this.db.prepare('DELETE FROM face_cluster_state WHERE session_id = ?').run(sessionId)
    })()
  }

  deleteObservationsByPhoto(sessionId: string, photoId: string): void {
    this.db.prepare(
      'DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?',
    ).run(sessionId, photoId)
  }

  deleteAnalysisStateByPhoto(sessionId: string, photoId: string): void {
    this.db.prepare(
      'DELETE FROM face_analysis_state WHERE session_id = ? AND photo_id = ?',
    ).run(sessionId, photoId)
  }

  /**
   * Atomically replace a photo's face observations. Old observations are only
   * removed once the new ones are committed, so a failed run never destroys
   * previously valid detections for a photo.
   */
  replaceObservationsByPhoto(
    sessionId: string,
    photoId: string,
    observations: FaceObservationInput[],
  ): number[] {
    const ids: number[] = []
    const deleteStmt = this.db.prepare(
      'DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?',
    )
    const insertStmt = this.db.prepare(
      `INSERT INTO face_observations
       (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
        source_file_size, source_file_mtime_ms, analysis_signature)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    const replace = this.db.transaction(() => {
      deleteStmt.run(sessionId, photoId)
      for (const obs of observations) {
        const embBuffer = Buffer.from(new Float32Array(obs.embedding).buffer)
        const result = insertStmt.run(
          obs.photoId,
          sessionId,
          obs.bboxX,
          obs.bboxY,
          obs.bboxW,
          obs.bboxH,
          embBuffer,
          obs.confidence,
          obs.sourceFileSize ?? 0,
          obs.sourceFileMtimeMs ?? 0,
          obs.analysisSignature ?? '',
        )
        ids.push(Number(result.lastInsertRowid))
      }
    })
    replace()
    return ids
  }

  getFaceThumbDir(): string {
    const dir = this.resolveFaceThumbDir()
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
    return dir
  }

  private resolveFaceThumbDir(): string {
    const customDir = this.settings.get('face_thumbnail_dir') ?? ''
    return customDir || path.join(app.getPath('userData'), FACE_THUMB_DIR)
  }

  private deleteThumbnailFile(thumbnailPath: string): void {
    if (!thumbnailPath) return
    const fullPath = path.join(this.resolveFaceThumbDir(), thumbnailPath)
    try { fs.unlinkSync(fullPath) } catch { /* file may not exist */ }
  }

  updateClusterThumbnail(clusterId: number, thumbnailPath: string): void {
    this.db.prepare('UPDATE face_clusters SET thumbnail_path = ? WHERE id = ?').run(thumbnailPath, clusterId)
  }

  saveClusters(sessionId: string, clusters: FaceClusterInput[]): number[] {
    const ids: number[] = []
    const insertCluster = this.db.prepare("INSERT INTO face_clusters (session_id, label, member_count, status, thumbnail_base64, thumbnail_path) VALUES (?, ?, ?, 'unbound', '', '')")
    const insertMember = this.db.prepare('INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence, observation_id) VALUES (?, ?, ?, ?, ?, ?)')
    const insertMany = this.db.transaction(() => {
      for (const cluster of clusters) {
        const result = insertCluster.run(sessionId, cluster.label, cluster.members.length)
        const clusterId = Number(result.lastInsertRowid)
        ids.push(clusterId)
        for (const member of cluster.members) {
          insertMember.run(clusterId, sessionId, member.photoId, JSON.stringify(member.bbox), member.confidence, member.observationId)
        }
      }
    })
    insertMany()
    return ids
  }

  getClusters(sessionId: string, includeMembers = false): FaceClusterRow[] {
    const clusters = this.db.prepare('SELECT * FROM face_clusters WHERE session_id = ? AND member_count > 0 ORDER BY id').all(sessionId) as FaceClusterRow[]
    if (!includeMembers || clusters.length === 0) return clusters
    // Batch members and role bindings with two IN queries instead of the
    // previous N+1 (two queries per cluster). Statements are prepared once
    // outside the loop; the IN arity varies per chunk, mirroring photo.repo's
    // keyset page queries. fm.id (INTEGER PRIMARY KEY = rowid) keeps the same
    // natural member order the per-cluster query used.
    const clusterIds = clusters.map(cluster => cluster.id)
    const membersByCluster = new Map<number, FaceClusterMemberRow[]>()
    for (let index = 0; index < clusterIds.length; index += 800) {
      const chunk = clusterIds.slice(index, index + 800)
      const placeholders = chunk.map(() => '?').join(', ')
      const rows = this.db.prepare(`
        SELECT fm.id, fm.cluster_id, fm.session_id, fm.photo_id,
               p.filepath as photo_path, fm.bbox, fm.confidence, fm.observation_id
        FROM face_cluster_members fm
        JOIN photos p ON fm.photo_id = p.id
        WHERE fm.cluster_id IN (${placeholders})
        ORDER BY fm.id
      `).all(...chunk) as FaceClusterMemberRow[]
      for (const row of rows) {
        const list = membersByCluster.get(row.cluster_id) ?? []
        list.push(row)
        membersByCluster.set(row.cluster_id, list)
      }
    }
    const bindingByCluster = new Map<number, { cluster_id: number; session_id: string; role_name: string; keywords: string }>()
    for (let index = 0; index < clusterIds.length; index += 800) {
      const chunk = clusterIds.slice(index, index + 800)
      const placeholders = chunk.map(() => '?').join(', ')
      const rows = this.db.prepare(
        `SELECT * FROM role_bindings WHERE cluster_id IN (${placeholders})`,
      ).all(...chunk) as Array<{ cluster_id: number; session_id: string; role_name: string; keywords: string }>
      for (const row of rows) bindingByCluster.set(row.cluster_id, row)
    }
    for (const cluster of clusters) {
      cluster.members = membersByCluster.get(cluster.id) ?? []
      const binding = bindingByCluster.get(cluster.id)
      if (binding) {
        cluster.binding = { clusterId: String(binding.cluster_id), roleName: binding.role_name, keywords: JSON.parse(binding.keywords) }
      }
    }
    return clusters
  }

  getClusterThumbnailPath(clusterId: number): string {
    const row = this.db.prepare('SELECT thumbnail_path FROM face_clusters WHERE id = ?').get(clusterId) as { thumbnail_path: string } | undefined
    return row?.thumbnail_path ?? ''
  }

  getClusterSessionId(clusterId: number): string | null {
    const row = this.db.prepare('SELECT session_id FROM face_clusters WHERE id = ?').get(clusterId) as { session_id: string } | undefined
    return row?.session_id ?? null
  }

  getClusterMembers(clusterId: number): Array<{ photoId: string; bbox: number[]; confidence: number }> {
    const rows = this.db.prepare(
      'SELECT photo_id, bbox, confidence FROM face_cluster_members WHERE cluster_id = ?',
    ).all(clusterId) as Array<{ photo_id: string; bbox: string; confidence: number }>
    return rows.map(row => ({
      photoId: row.photo_id,
      bbox: parseBbox(row.bbox),
      confidence: row.confidence,
    }))
  }

  getThumbnailPathsBySession(sessionId: string): string[] {
    const rows = this.db.prepare("SELECT thumbnail_path FROM face_clusters WHERE session_id = ? AND thumbnail_path != '' AND member_count > 0").all(sessionId) as { thumbnail_path: string }[]
    return rows.map(r => r.thumbnail_path)
  }

  updateBinding(clusterId: number, roleName: string, keywords: string[]): void {
    const existing = this.db.prepare('SELECT id FROM role_bindings WHERE cluster_id = ?').get(clusterId)
    if (existing) {
      this.db.prepare('UPDATE role_bindings SET role_name = ?, keywords = ? WHERE cluster_id = ?').run(roleName, JSON.stringify(keywords), clusterId)
    } else {
      const cluster = this.db.prepare('SELECT session_id FROM face_clusters WHERE id = ?').get(clusterId) as { session_id: string }
      this.db.prepare('INSERT INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)').run(clusterId, cluster.session_id, roleName, JSON.stringify(keywords))
    }
    this.db.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?").run(clusterId)
  }

  deleteBinding(clusterId: number): void {
    this.db.prepare('DELETE FROM role_bindings WHERE cluster_id = ?').run(clusterId)
    this.db.prepare("UPDATE face_clusters SET status = 'unbound' WHERE id = ?").run(clusterId)
  }

  restoreBinding(clusterId: number, sessionId: string, roleName: string, keywords: string[]): void {
    const restoreTransaction = this.db.transaction(() => {
      this.db.prepare('INSERT OR REPLACE INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)')
        .run(clusterId, sessionId, roleName, JSON.stringify(keywords))
      this.db.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?").run(clusterId)
    })
    restoreTransaction()
  }

  mergeClusters(sourceId: number, targetId: number): void {
    const sourcePath = this.getClusterThumbnailPath(sourceId)
    const merge = this.db.transaction(() => {
      const sourceMembers = this.db.prepare('SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?').get(sourceId) as { count: number }
      this.db.prepare('UPDATE face_cluster_members SET cluster_id = ? WHERE cluster_id = ?').run(targetId, sourceId)
      this.db.prepare('UPDATE face_clusters SET member_count = member_count + ? WHERE id = ?').run(sourceMembers.count, targetId)
      this.db.prepare('DELETE FROM role_bindings WHERE cluster_id = ?').run(sourceId)
      this.db.prepare('UPDATE face_clusters SET member_count = 0, status = ? WHERE id = ?').run('unbound', sourceId)
    })
    merge()
    this.deleteThumbnailFile(sourcePath)
  }

  restoreMerge(
    sourceId: number,
    targetId: number,
    sessionId: string,
    sourceMemberIds: number[],
    sourceMemberCount: number,
    sourceBinding: { clusterId: string; roleName: string; keywords: string[] } | undefined,
  ): void {
    const restoreTransaction = this.db.transaction(() => {
      for (const memberId of sourceMemberIds) {
        this.db.prepare('UPDATE face_cluster_members SET cluster_id = ? WHERE id = ?').run(sourceId, memberId)
      }

      const targetCount = this.db.prepare('SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?').get(targetId) as { count: number }

      this.db.prepare('UPDATE face_clusters SET member_count = ? WHERE id = ?').run(sourceMemberCount, sourceId)
      this.db.prepare('UPDATE face_clusters SET member_count = ?, status = ? WHERE id = ?').run(
        Math.max(0, targetCount.count),
        'unbound',
        targetId,
      )

      if (sourceBinding) {
        this.db.prepare('INSERT OR REPLACE INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)').run(
          sourceId,
          sessionId,
          sourceBinding.roleName,
          JSON.stringify(sourceBinding.keywords),
        )
        this.db.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?").run(sourceId)
      }
    })
    restoreTransaction()
  }

  deleteClustersBySession(sessionId: string): void {
    const paths = this.getThumbnailPathsBySession(sessionId)
    const del = this.db.transaction(() => {
      this.db.prepare('DELETE FROM face_cluster_members WHERE session_id = ?').run(sessionId)
      this.db.prepare('DELETE FROM role_bindings WHERE session_id = ?').run(sessionId)
      this.db.prepare('DELETE FROM face_clusters WHERE session_id = ?').run(sessionId)
    })
    del()
    for (const p of paths) this.deleteThumbnailFile(p)
  }

  /**
   * Role bindings with the photo ids of their members, used to migrate
   * user-bound roles onto re-clustered clusters by member overlap.
   * Photo ids are stable across re-analysis (observation ids are not: they
   * are re-issued by replaceObservationsByPhoto on every analysis run).
   */
  getBindingsBySession(sessionId: string): Array<{
    clusterId: number
    roleName: string
    keywords: string[]
    memberPhotoIds: string[]
  }> {
    const bindings = this.db.prepare(`
      SELECT rb.cluster_id, rb.role_name, rb.keywords
      FROM role_bindings rb
      WHERE rb.session_id = ?
    `).all(sessionId) as Array<{ cluster_id: number; role_name: string; keywords: string }>
    if (bindings.length === 0) return []
    const memberStmt = this.db.prepare(
      'SELECT DISTINCT photo_id FROM face_cluster_members WHERE cluster_id = ?',
    )
    return bindings.map(binding => ({
      clusterId: binding.cluster_id,
      roleName: binding.role_name,
      keywords: JSON.parse(binding.keywords) as string[],
      memberPhotoIds: (memberStmt.all(binding.cluster_id) as Array<{ photo_id: string }>)
        .map(member => member.photo_id),
    }))
  }

  removeMemberFromCluster(clusterId: number, memberId: number): boolean {
    const memberCount = this.db.prepare(
      'SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?'
    ).get(clusterId) as { count: number }
    const thumbnailPathToDelete = memberCount.count === 1
      ? this.getClusterThumbnailPath(clusterId)
      : ''

    const delMember = this.db.transaction(() => {
      const deleted = this.db.prepare(
        'DELETE FROM face_cluster_members WHERE cluster_id = ? AND id = ?',
      ).run(clusterId, memberId)
      if (deleted.changes === 0) return false
      const remaining = this.db.prepare('SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?').get(clusterId) as { count: number }
      if (remaining.count === 0) {
        this.db.prepare('DELETE FROM role_bindings WHERE cluster_id = ?').run(clusterId)
        this.db.prepare('DELETE FROM face_clusters WHERE id = ?').run(clusterId)
      } else {
        this.db.prepare('UPDATE face_clusters SET member_count = ? WHERE id = ?').run(remaining.count, clusterId)
      }
      return true
    })
    const deleted = delMember()
    if (deleted) this.deleteThumbnailFile(thumbnailPathToDelete)
    return deleted
  }
}
