import { Database } from '../database'
import { ISimilarityResultRepository } from './interfaces'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

export interface SimilarityResultRow {
  id: number
  session_id: string
  groups_json: string
  stats_json: string
  param_threshold: number
  param_min_group_size: number
  created_at: string
}

@injectable()
export class SimilarityResultRepository implements ISimilarityResultRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  getLatest(sessionId: string): SimilarityResultRow | undefined {
    return this.db
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
    this.db.prepare(
      `INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(sessionId, groupsJson, statsJson, threshold, minGroupSize, new Date().toISOString())
  }
}
