import { getDatabase } from '../database'

export interface SimilarityResultRow {
  id: number
  session_id: string
  groups_json: string
  stats_json: string
  param_threshold: number
  param_min_group_size: number
  created_at: string
}

export class SimilarityResultRepository {
  getLatest(sessionId: string): SimilarityResultRow | undefined {
    const db = getDatabase()
    return db
      .prepare(
        'SELECT * FROM similarity_results WHERE session_id = ? ORDER BY id DESC LIMIT 1',
      )
      .get(sessionId) as SimilarityResultRow | undefined
  }

  insert(
    sessionId: string,
    groupsJson: string,
    statsJson: string,
    threshold: number,
    minGroupSize: number,
  ): void {
    const db = getDatabase()
    db.prepare(
      `INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(sessionId, groupsJson, statsJson, threshold, minGroupSize, new Date().toISOString())
  }
}
