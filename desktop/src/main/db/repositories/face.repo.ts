import { getDatabase } from '../database'
import { IFaceRepository } from './interfaces'

export interface FaceObservationInput {
  photoId: string
  bboxX: number
  bboxY: number
  bboxW: number
  bboxH: number
  embedding: number[]
  confidence: number
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

export class FaceRepository implements IFaceRepository {
  saveObservations(sessionId: string, observations: FaceObservationInput[]): number[] {
    const db = getDatabase()
    const ids: number[] = []
    const stmt = db.prepare(
      'INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    )
    const insertMany = db.transaction(() => {
      for (const obs of observations) {
        const embBuffer = Buffer.from(new Float32Array(obs.embedding).buffer)
        const result = stmt.run(obs.photoId, sessionId, obs.bboxX, obs.bboxY, obs.bboxW, obs.bboxH, embBuffer, obs.confidence)
        ids.push(Number(result.lastInsertRowid))
      }
    })
    insertMany()
    return ids
  }

  getObservations(sessionId: string): FaceObservationRow[] {
    const db = getDatabase()
    return db.prepare('SELECT * FROM face_observations WHERE session_id = ? ORDER BY id').all(sessionId) as FaceObservationRow[]
  }

  updateEmbedding(observationId: number, embedding: number[]): void {
    const db = getDatabase()
    const embBuffer = Buffer.from(new Float32Array(embedding).buffer)
    db.prepare('UPDATE face_observations SET embedding = ? WHERE id = ?').run(embBuffer, observationId)
  }

  deleteObservationsBySession(sessionId: string): void {
    const db = getDatabase()
    db.prepare('DELETE FROM face_observations WHERE session_id = ?').run(sessionId)
  }

  updateClusterThumbnail(clusterId: number, base64: string): void {
    const db = getDatabase()
    db.prepare('UPDATE face_clusters SET thumbnail_base64 = ? WHERE id = ?').run(base64, clusterId)
  }

  saveClusters(sessionId: string, clusters: FaceClusterInput[]): number[] {
    const db = getDatabase()
    const ids: number[] = []
    const insertCluster = db.prepare("INSERT INTO face_clusters (session_id, label, member_count, status, thumbnail_base64) VALUES (?, ?, ?, 'unbound', '')")
    const insertMember = db.prepare('INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence, observation_id) VALUES (?, ?, ?, ?, ?, ?)')
    const insertMany = db.transaction(() => {
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
    const db = getDatabase()
    const clusters = db.prepare('SELECT * FROM face_clusters WHERE session_id = ? ORDER BY id').all(sessionId) as FaceClusterRow[]
    if (!includeMembers) return clusters
    for (const cluster of clusters) {
      cluster.members = db.prepare('SELECT fm.id, fm.cluster_id, fm.session_id, fm.photo_id, p.filepath as photo_path, fm.bbox, fm.confidence, fm.observation_id FROM face_cluster_members fm JOIN photos p ON fm.photo_id = p.id WHERE fm.cluster_id = ?').all(cluster.id) as FaceClusterMemberRow[]
      const binding = db.prepare('SELECT * FROM role_bindings WHERE cluster_id = ?').get(cluster.id) as { cluster_id: number; session_id: string; role_name: string; keywords: string } | undefined
      if (binding) {
        cluster.binding = { clusterId: String(binding.cluster_id), roleName: binding.role_name, keywords: JSON.parse(binding.keywords) }
      }
    }
    return clusters
  }

  updateBinding(clusterId: number, roleName: string, keywords: string[]): void {
    const db = getDatabase()
    const existing = db.prepare('SELECT id FROM role_bindings WHERE cluster_id = ?').get(clusterId)
    if (existing) {
      db.prepare('UPDATE role_bindings SET role_name = ?, keywords = ? WHERE cluster_id = ?').run(roleName, JSON.stringify(keywords), clusterId)
    } else {
      const cluster = db.prepare('SELECT session_id FROM face_clusters WHERE id = ?').get(clusterId) as { session_id: string }
      db.prepare('INSERT INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)').run(clusterId, cluster.session_id, roleName, JSON.stringify(keywords))
    }
    db.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?").run(clusterId)
  }

  deleteBinding(clusterId: number): void {
    const db = getDatabase()
    db.prepare('DELETE FROM role_bindings WHERE cluster_id = ?').run(clusterId)
    db.prepare("UPDATE face_clusters SET status = 'unbound' WHERE id = ?").run(clusterId)
  }

  mergeClusters(sourceId: number, targetId: number): void {
    const db = getDatabase()
    const merge = db.transaction(() => {
      const sourceMembers = db.prepare('SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?').get(sourceId) as { count: number }
      db.prepare('UPDATE face_cluster_members SET cluster_id = ? WHERE cluster_id = ?').run(targetId, sourceId)
      db.prepare('UPDATE face_clusters SET member_count = member_count + ? WHERE id = ?').run(sourceMembers.count, targetId)
      db.prepare('DELETE FROM role_bindings WHERE cluster_id = ?').run(sourceId)
      db.prepare('DELETE FROM face_clusters WHERE id = ?').run(sourceId)
    })
    merge()
  }

  deleteClustersBySession(sessionId: string): void {
    const db = getDatabase()
    const del = db.transaction(() => {
      db.prepare('DELETE FROM face_cluster_members WHERE session_id = ?').run(sessionId)
      db.prepare('DELETE FROM role_bindings WHERE session_id = ?').run(sessionId)
      db.prepare('DELETE FROM face_clusters WHERE session_id = ?').run(sessionId)
    })
    del()
  }

  removeMemberFromCluster(clusterId: number, photoId: string): void {
    const db = getDatabase()
    const delMember = db.transaction(() => {
      db.prepare('DELETE FROM face_cluster_members WHERE cluster_id = ? AND photo_id = ?').run(clusterId, photoId)
      const remaining = db.prepare('SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?').get(clusterId) as { count: number }
      if (remaining.count === 0) {
        db.prepare('DELETE FROM role_bindings WHERE cluster_id = ?').run(clusterId)
        db.prepare('DELETE FROM face_clusters WHERE id = ?').run(clusterId)
      } else {
        db.prepare('UPDATE face_clusters SET member_count = ? WHERE id = ?').run(remaining.count, clusterId)
      }
    })
    delMember()
  }
}
