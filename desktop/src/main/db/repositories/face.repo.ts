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

  reuseObservationsForAssetFile(
    sessionId: string,
    photoId: string,
    sourceFileSize: number,
    sourceFileMtimeMs: number,
    analysisSignature: string,
  ): { reused: boolean; faceCount: number } {
    const source = this.db.prepare(`
      SELECT source_state.photo_id
      FROM photos target
      JOIN photos source_photo
        ON source_photo.asset_file_id = target.asset_file_id
       AND source_photo.id <> target.id
      JOIN face_analysis_state source_state
        ON source_state.photo_id = source_photo.id
       AND source_state.session_id = source_photo.session_id
      WHERE target.id = ?
        AND target.session_id = ?
        AND target.asset_file_id IS NOT NULL
        AND source_state.source_file_size = ?
        AND ABS(source_state.source_file_mtime_ms - ?) < 1
        AND source_state.analysis_signature = ?
      ORDER BY source_state.updated_at DESC
      LIMIT 1
    `).get(
      photoId,
      sessionId,
      sourceFileSize,
      sourceFileMtimeMs,
      analysisSignature,
    ) as { photo_id: string } | undefined
    if (!source) return { reused: false, faceCount: 0 }

    let faceCount = 0
    this.db.transaction(() => {
      this.db.prepare(
        'DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?',
      ).run(sessionId, photoId)
      const copied = this.db.prepare(`
        INSERT INTO face_observations (
          photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
          source_file_size, source_file_mtime_ms, analysis_signature, created_at
        )
        SELECT ?, ?, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
               source_file_size, source_file_mtime_ms, analysis_signature, ?
        FROM face_observations
        WHERE photo_id = ?
          AND session_id = (SELECT session_id FROM photos WHERE id = ?)
      `).run(
        photoId,
        sessionId,
        new Date().toISOString(),
        source.photo_id,
        source.photo_id,
      )
      faceCount = copied.changes
      this.upsertAnalysisState(
        sessionId,
        photoId,
        sourceFileSize,
        sourceFileMtimeMs,
        analysisSignature,
      )
    })()
    return { reused: true, faceCount }
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
    if (!includeMembers) return clusters
    for (const cluster of clusters) {
      cluster.members = this.db.prepare('SELECT fm.id, fm.cluster_id, fm.session_id, fm.photo_id, p.filepath as photo_path, fm.bbox, fm.confidence, fm.observation_id FROM face_cluster_members fm JOIN photos p ON fm.photo_id = p.id WHERE fm.cluster_id = ?').all(cluster.id) as FaceClusterMemberRow[]
      const binding = this.db.prepare('SELECT * FROM role_bindings WHERE cluster_id = ?').get(cluster.id) as { cluster_id: number; session_id: string; role_name: string; keywords: string } | undefined
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
