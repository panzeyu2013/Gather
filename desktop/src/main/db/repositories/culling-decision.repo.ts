import { Database } from '../database'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

export interface CullingDecisionRow {
  id: number
  session_id: string
  photo_id: string
  group_id: string
  decision: string
  rating: number
  color_label: string
  decision_source: string
  revision: number
  updated_at: string
  created_at: string
}

@injectable()
export class CullingDecisionRepository {
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
    this.db.prepare(`
      INSERT INTO culling_decisions
        (session_id, photo_id, group_id, decision, updated_at, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id, photo_id) DO UPDATE SET
        group_id = excluded.group_id,
        decision = excluded.decision,
        decision_source = 'manual',
        updated_at = excluded.updated_at
    `).run(sessionId, photoId, groupId, decision, now, now)
  }

  getByPhotoIds(sessionId: string, photoIds: string[]): CullingDecisionRow[] {
    if (photoIds.length === 0) return []
    const rows: CullingDecisionRow[] = []
    // Stay below SQLite's parameter limit while allowing large batches.
    for (let index = 0; index < photoIds.length; index += 800) {
      const chunk = photoIds.slice(index, index + 800)
      const placeholders = chunk.map(() => '?').join(',')
      rows.push(...this.db.prepare(`
        SELECT *
        FROM culling_decisions
        WHERE session_id = ? AND photo_id IN (${placeholders})
      `).all(sessionId, ...chunk) as CullingDecisionRow[])
    }
    return rows
  }

  upsertState(
    sessionId: string,
    photoId: string,
    groupId: string,
    state: {
      decision: string
      rating: number
      colorLabel: string
      revision: number
      source?: string
    },
  ): void {
    const now = new Date().toISOString()
    this.db.prepare(`
      INSERT INTO culling_decisions
        (
          session_id, photo_id, group_id, decision, rating, color_label,
          decision_source, revision, updated_at, created_at
        )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id, photo_id) DO UPDATE SET
        group_id = excluded.group_id,
        decision = excluded.decision,
        rating = excluded.rating,
        color_label = excluded.color_label,
        decision_source = excluded.decision_source,
        revision = excluded.revision,
        updated_at = excluded.updated_at
    `).run(
      sessionId,
      photoId,
      groupId,
      state.decision,
      state.rating,
      state.colorLabel,
      state.source ?? 'manual',
      state.revision,
      now,
      now,
    )
  }

  upsertMany(
    sessionId: string,
    decisions: Array<{ photoId: string; groupId: string; decision: string }>,
  ): void {
    const statement = this.db.prepare(`
      INSERT INTO culling_decisions
        (session_id, photo_id, group_id, decision, updated_at, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id, photo_id) DO UPDATE SET
        group_id = excluded.group_id,
        decision = excluded.decision,
        decision_source = 'manual',
        updated_at = excluded.updated_at
    `)
    const write = this.db.transaction(() => {
      const now = new Date().toISOString()
      for (const item of decisions) {
        statement.run(sessionId, item.photoId, item.groupId, item.decision, now, now)
      }
    })
    write()
  }

  getByResultPrefix(sessionId: string, resultId: number): { photo_id: string; decision: string }[] {
    return this.db.prepare(
      'SELECT photo_id, decision FROM culling_decisions WHERE session_id = ? AND group_id LIKE ?',
    ).all(sessionId, `${resultId}:%`) as { photo_id: string; decision: string }[]
  }

  getCountsByResultPrefix(sessionId: string, resultId: number): { decision: string; cnt: number }[] {
    return this.db.prepare(`
      SELECT decision, COUNT(*) AS cnt
      FROM culling_decisions
      WHERE session_id = ? AND group_id LIKE ?
      GROUP BY decision
    `).all(sessionId, `${resultId}:%`) as { decision: string; cnt: number }[]
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
