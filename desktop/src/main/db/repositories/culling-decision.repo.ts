import { Database } from '../database'
import { ICullingDecisionRepository } from './interfaces'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

export interface CullingDecisionRow {
  id: number
  session_id: string
  photo_id: string
  group_id: string
  decision: string
  updated_at: string
  created_at: string
}

@injectable()
export class CullingDecisionRepository implements ICullingDecisionRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  getDecisions(sessionId: string): { photo_id: string; decision: string }[] {
    return this.db
      .prepare('SELECT photo_id, decision FROM culling_decisions WHERE session_id = ?')
      .all(sessionId) as { photo_id: string; decision: string }[]
  }

  getDecisionsFull(sessionId: string): CullingDecisionRow[] {
    return this.db
      .prepare('SELECT * FROM culling_decisions WHERE session_id = ?')
      .all(sessionId) as CullingDecisionRow[]
  }

  getBySession(sessionId: string): CullingDecisionRow[] {
    return this.getDecisionsFull(sessionId)
  }

  getDecision(sessionId: string, photoId: string): CullingDecisionRow | undefined {
    return this.db
      .prepare('SELECT * FROM culling_decisions WHERE session_id = ? AND photo_id = ?')
      .get(sessionId, photoId) as CullingDecisionRow | undefined
  }

  upsert(sessionId: string, photoId: string, groupId: string, decision: string): void {
    const now = new Date().toISOString()
    const existing = this.getDecision(sessionId, photoId)
    if (existing) {
      this.db.prepare(
        'UPDATE culling_decisions SET group_id = ?, decision = ?, updated_at = ? WHERE session_id = ? AND photo_id = ?',
      ).run(groupId, decision, now, sessionId, photoId)
    } else {
      this.db.prepare(
        'INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, updated_at, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      ).run(sessionId, photoId, groupId, decision, now, now)
    }
  }

  getDecisionCounts(sessionId: string): { decision: string; cnt: number }[] {
    return this.db
      .prepare('SELECT decision, COUNT(*) as cnt FROM culling_decisions WHERE session_id = ? GROUP BY decision')
      .all(sessionId) as { decision: string; cnt: number }[]
  }

  deleteBySession(sessionId: string): void {
    this.db.prepare('DELETE FROM culling_decisions WHERE session_id = ?').run(sessionId)
  }

  deleteBySessionAndGroup(sessionId: string, groupId: string): void {
    this.db.prepare('DELETE FROM culling_decisions WHERE session_id = ? AND group_id = ?').run(sessionId, groupId)
  }

  batchRestoreDecisions(decisions: Array<{ session_id: string; photo_id: string; decision: string }>): void {
    const restoreTransaction = this.db.transaction(() => {
      for (const d of decisions) {
        this.db.prepare('UPDATE culling_decisions SET decision = ? WHERE session_id = ? AND photo_id = ?')
          .run(d.decision, d.session_id, d.photo_id)
      }
    })
    restoreTransaction()
  }
}
