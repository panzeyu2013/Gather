import { getDatabase } from '../database'
import { ICullingDecisionRepository } from './interfaces'

export interface CullingDecisionRow {
  id: number
  session_id: string
  photo_id: string
  group_id: string
  decision: string
  updated_at: string
  created_at: string
}

export class CullingDecisionRepository implements ICullingDecisionRepository {
  getDecisions(sessionId: string): { photo_id: string; decision: string }[] {
    const db = getDatabase()
    return db
      .prepare('SELECT photo_id, decision FROM culling_decisions WHERE session_id = ?')
      .all(sessionId) as { photo_id: string; decision: string }[]
  }

  getDecisionsFull(sessionId: string): CullingDecisionRow[] {
    const db = getDatabase()
    return db
      .prepare('SELECT * FROM culling_decisions WHERE session_id = ?')
      .all(sessionId) as CullingDecisionRow[]
  }

  getBySession(sessionId: string): CullingDecisionRow[] {
    return this.getDecisionsFull(sessionId)
  }

  getDecision(sessionId: string, photoId: string): CullingDecisionRow | undefined {
    const db = getDatabase()
    return db
      .prepare('SELECT * FROM culling_decisions WHERE session_id = ? AND photo_id = ?')
      .get(sessionId, photoId) as CullingDecisionRow | undefined
  }

  upsert(sessionId: string, photoId: string, groupId: string, decision: string): void {
    const db = getDatabase()
    const now = new Date().toISOString()
    const existing = this.getDecision(sessionId, photoId)
    if (existing) {
      db.prepare(
        'UPDATE culling_decisions SET group_id = ?, decision = ?, updated_at = ? WHERE session_id = ? AND photo_id = ?',
      ).run(groupId, decision, now, sessionId, photoId)
    } else {
      db.prepare(
        'INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, updated_at, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      ).run(sessionId, photoId, groupId, decision, now, now)
    }
  }

  getDecisionCounts(sessionId: string): { decision: string; cnt: number }[] {
    const db = getDatabase()
    return db
      .prepare('SELECT decision, COUNT(*) as cnt FROM culling_decisions WHERE session_id = ? GROUP BY decision')
      .all(sessionId) as { decision: string; cnt: number }[]
  }

  deleteBySession(sessionId: string): void {
    const db = getDatabase()
    db.prepare('DELETE FROM culling_decisions WHERE session_id = ?').run(sessionId)
  }

  deleteBySessionAndGroup(sessionId: string, groupId: string): void {
    const db = getDatabase()
    db.prepare('DELETE FROM culling_decisions WHERE session_id = ? AND group_id = ?').run(sessionId, groupId)
  }
}
