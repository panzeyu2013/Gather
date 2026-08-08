import crypto from 'node:crypto'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { Database } from '../database'
import type { AnalysisJobData, AnalysisJobStatus, AnalysisJobType, JobCreateParams, JobProgressUpdate } from '@gather/shared'

interface JobRow {
  id: string; type: AnalysisJobType; scope_type: string; scope_id: string; dedupe_key: string
  status: AnalysisJobStatus; priority: number; progress_current: number; progress_total: number
  progress_message: string; input_fingerprint: string; model_id: string; model_version: string
  checkpoint_json: string; attempt_count: number; lease_owner: string; heartbeat_at: string
  error_code: string; error_message: string; created_at: string; started_at: string
  finished_at: string; updated_at: string
}

function toData(row: JobRow): AnalysisJobData {
  let checkpoint: Record<string, unknown> = {}
  try { checkpoint = JSON.parse(row.checkpoint_json) as Record<string, unknown> } catch { /* keep empty */ }
  return {
    id: row.id, type: row.type, scopeType: row.scope_type, scopeId: row.scope_id,
    dedupeKey: row.dedupe_key, status: row.status, priority: row.priority,
    progressCurrent: row.progress_current, progressTotal: row.progress_total,
    progressMessage: row.progress_message, inputFingerprint: row.input_fingerprint,
    modelId: row.model_id, modelVersion: row.model_version, checkpoint,
    attemptCount: row.attempt_count, leaseOwner: row.lease_owner, heartbeatAt: row.heartbeat_at,
    errorCode: row.error_code, errorMessage: row.error_message, createdAt: row.created_at,
    startedAt: row.started_at, finishedAt: row.finished_at, updatedAt: row.updated_at,
  }
}

@injectable()
export class AnalysisJobRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  create(params: JobCreateParams): AnalysisJobData {
    const now = new Date().toISOString()
    const id = crypto.randomUUID()
    try {
      this.db.prepare(`
        INSERT INTO analysis_jobs (
          id, type, scope_type, scope_id, dedupe_key, status, priority,
          input_fingerprint, model_id, model_version, checkpoint_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?)
      `).run(id, params.type, params.scopeType, params.scopeId, params.dedupeKey,
        params.priority ?? 0, params.inputFingerprint ?? '', params.modelId ?? '',
        params.modelVersion ?? '', JSON.stringify(params.checkpoint ?? {}), now, now)
    } catch (error) {
      if (!(error instanceof Error) || !error.message.includes('UNIQUE')) throw error
      const existing = this.db.prepare(`
        SELECT * FROM analysis_jobs WHERE dedupe_key = ?
          AND status IN ('queued', 'running', 'cancelling')
      `).get(params.dedupeKey) as JobRow | undefined
      if (existing) return toData(existing)
      // The only other row with this dedupe key is in a terminal state
      // (failed/cancelled/succeeded). Re-running the same analysis after a
      // failure or cancel must work from the UI, so reuse the row as an
      // automatic retry instead of surfacing a raw UNIQUE error.
      const terminal = this.db.prepare(`
        SELECT * FROM analysis_jobs WHERE dedupe_key = ?
          AND status IN ('failed', 'cancelled', 'interrupted', 'succeeded')
      `).get(params.dedupeKey) as JobRow | undefined
      if (!terminal) throw error
      this.db.prepare(`
        UPDATE analysis_jobs
        SET status = 'queued', error_code = '', error_message = '', cancel_requested_at = '',
            lease_owner = '', heartbeat_at = '', progress_current = 0,
            progress_total = 0, progress_message = '', finished_at = '', updated_at = ?
        WHERE id = ?
      `).run(new Date().toISOString(), terminal.id)
      return this.get(terminal.id)!
    }
    return this.get(id)!
  }

  get(id: string): AnalysisJobData | null {
    const row = this.db.prepare('SELECT * FROM analysis_jobs WHERE id = ?').get(id) as JobRow | undefined
    return row ? toData(row) : null
  }

  list(status?: AnalysisJobStatus): AnalysisJobData[] {
    const rows = status
      ? this.db.prepare('SELECT * FROM analysis_jobs WHERE status = ? ORDER BY priority DESC, updated_at DESC').all(status) as JobRow[]
      : this.db.prepare('SELECT * FROM analysis_jobs ORDER BY updated_at DESC').all() as JobRow[]
    return rows.map(toData)
  }

  /** Rows of a single job type only, so callers never touch the heavy
   * checkpoint blobs of unrelated job types (e.g. a 50k-id export checkpoint
   * being parsed on every thumbnail preload). */
  listByType(type: AnalysisJobType): AnalysisJobData[] {
    const rows = this.db.prepare('SELECT * FROM analysis_jobs WHERE type = ? ORDER BY updated_at DESC').all(type) as JobRow[]
    return rows.map(toData)
  }

  requestCancel(id: string): boolean {
    return this.db.prepare(`
      UPDATE analysis_jobs
      SET status = CASE WHEN status = 'queued' THEN 'cancelled' ELSE 'cancelling' END,
          cancel_requested_at = ?, updated_at = ?
      WHERE id = ? AND status IN ('queued', 'running')
    `).run(new Date().toISOString(), new Date().toISOString(), id).changes === 1
  }

  retry(id: string): boolean {
    return this.db.prepare(`
      UPDATE analysis_jobs
      SET status = 'queued', error_code = '', error_message = '', cancel_requested_at = '',
          lease_owner = '', heartbeat_at = '', progress_current = 0,
          progress_total = 0, progress_message = '', finished_at = '', updated_at = ?
      WHERE id = ? AND status IN ('failed', 'interrupted', 'cancelled')
    `).run(new Date().toISOString(), id).changes === 1
  }

  recoverStale(leaseTimeoutMs = 30_000): number {
    const cutoff = new Date(Date.now() - leaseTimeoutMs).toISOString()
    return this.db.prepare(`
      UPDATE analysis_jobs
      SET status = 'interrupted', error_code = 'worker_lost',
          error_message = 'Worker heartbeat expired', finished_at = ?, updated_at = ?
      WHERE status IN ('running', 'cancelling')
        AND (heartbeat_at = '' OR heartbeat_at < ?)
    `).run(new Date().toISOString(), new Date().toISOString(), cutoff).changes
  }

  resumeInterrupted(types: AnalysisJobType[]): number {
    if (types.length === 0) return 0
    const placeholders = types.map(() => '?').join(', ')
    const now = new Date().toISOString()
    return this.db.prepare(`
      UPDATE analysis_jobs
      SET status = 'queued', error_code = '', error_message = '',
          cancel_requested_at = '', lease_owner = '', heartbeat_at = '',
          finished_at = '', updated_at = ?
      WHERE status = 'interrupted' AND type IN (${placeholders})
    `).run(now, ...types).changes
  }

  claim(id: string, leaseOwner: string): boolean {
    const now = new Date().toISOString()
    return this.db.prepare(`
      UPDATE analysis_jobs
      SET status = 'running', lease_owner = ?, heartbeat_at = ?, started_at = COALESCE(NULLIF(started_at, ''), ?),
          attempt_count = attempt_count + 1, updated_at = ?
      WHERE id = ? AND status = 'queued'
    `).run(leaseOwner, now, now, now, id).changes === 1
  }

  heartbeat(id: string, leaseOwner: string): boolean {
    return this.db.prepare(`
      UPDATE analysis_jobs SET heartbeat_at = ?, updated_at = ?
      WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
    `).run(new Date().toISOString(), new Date().toISOString(), id, leaseOwner).changes === 1
  }

  updateProgress(id: string, leaseOwner: string, update: JobProgressUpdate): boolean {
    const current = this.get(id)
    if (!current) return false
    const checkpoint = update.checkpoint === undefined ? current.checkpoint : update.checkpoint
    return this.db.prepare(`
      UPDATE analysis_jobs SET progress_current = ?, progress_total = ?, progress_message = ?,
        checkpoint_json = ?, heartbeat_at = ?, updated_at = ?
      WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
    `).run(update.current ?? current.progressCurrent, update.total ?? current.progressTotal,
      update.phase ?? update.message ?? current.progressMessage, JSON.stringify(checkpoint), new Date().toISOString(), new Date().toISOString(), id, leaseOwner).changes === 1
  }

  finish(id: string, leaseOwner: string, status: 'succeeded' | 'failed' | 'cancelled', error?: { code: string; message: string }): boolean {
    const now = new Date().toISOString()
    return this.db.prepare(`
      UPDATE analysis_jobs SET status = ?, error_code = ?, error_message = ?, finished_at = ?, updated_at = ?
      WHERE id = ? AND status IN ('running', 'cancelling') AND lease_owner = ?
    `).run(status, error?.code ?? '', error?.message ?? '', now, now, id, leaseOwner).changes === 1
  }

  interrupt(id: string, leaseOwner: string, message = 'Application stopped during execution'): boolean {
    const now = new Date().toISOString()
    return this.db.prepare(`
      UPDATE analysis_jobs
      SET status = 'interrupted', error_code = 'application_stopped',
          error_message = ?, finished_at = ?, updated_at = ?
      WHERE id = ? AND status = 'running' AND lease_owner = ?
    `).run(message, now, now, id, leaseOwner).changes === 1
  }

  clearCompleted(excludeTypes: readonly string[] = []): number {
    // Terminal rows in every status are cleared so failed/interrupted jobs
    // (which retry() and resumeInterrupted can no longer revive once cleared)
    // do not accumulate forever next to succeeded/cancelled ones.
    // Stage-evidence rows (metadata.scan / export.execute) are excluded by
    // JobService so "clear completed" never regresses workspace status (see
    // job.service.ts CLEAR_COMPLETED_STAGE_EVIDENCE_TYPES).
    const exclusion = excludeTypes.length > 0
      ? ` AND type NOT IN (${excludeTypes.map(() => '?').join(', ')})`
      : ''
    return this.db.prepare(
      `DELETE FROM analysis_jobs WHERE status IN ('succeeded', 'cancelled', 'failed', 'interrupted')${exclusion}`,
    ).run(...excludeTypes).changes
  }
}
