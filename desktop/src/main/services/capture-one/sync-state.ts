// src/main/services/capture-one/sync-state.ts
// CaptureOneSyncState — 会话级同步状态聚合（设计文档 2.3.2 / 2.3.3）
//
// 机器状态在内存，App 重启后丢失；行状态（metadata_outbox + reload_acked_at）
// 是持久真相源，本模块跨重启从 DB 重推导，不落库机器状态。
// 保守策略：不自动 reload、不自动清理；safeToCleanup 仅在
// reload_acked_at 已写入（即 reloadMetadata() 成功）后才可恢复。

import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { Database } from '../../db/database'
import type { MetadataSyncSummary } from '@gather/shared'

export enum CaptureOneSessionState {
  Disconnected = 'disconnected',
  Connected = 'connected',
  Syncing = 'syncing',
  C1Read = 'c1Read',
  SafeToCleanup = 'safeToCleanup',
  Synced = 'synced',
  Failed = 'failed',
  Conflict = 'conflict',
}

export interface SessionOutboxAggregation {
  /** status → row count over the session's metadata_outbox rows */
  counts: Record<string, number>
  /** sessions.reload_acked_at (ISO) or null when Capture One never confirmed */
  reloadAckedAt: string | null
}

const KNOWN_OUTBOX_STATUSES = new Set([
  'pending',
  'writing',
  'written',
  'failed',
  'conflict',
  'synced',
  'clean',
  'cleaned',
])

/** Pure row reducer: build a status → count map from outbox rows. */
export function countOutboxStatuses(rows: Array<{ status: string }>): Record<string, number> {
  const counts: Record<string, number> = {}
  for (const row of rows) {
    counts[row.status] = (counts[row.status] ?? 0) + 1
  }
  return counts
}

/**
 * 确定性聚合（2.3.2）：conflict > failed > pending/writing > …
 * 纯函数，不依赖 DB，可直接单测。
 */
export function aggregateSessionState(
  aggregation: SessionOutboxAggregation,
): CaptureOneSessionState {
  const { counts, reloadAckedAt } = aggregation
  const conflict = counts.conflict ?? 0
  const failed = counts.failed ?? 0
  const pending = counts.pending ?? 0
  const writing = counts.writing ?? 0
  const written = counts.written ?? 0
  let other = 0
  let total = 0
  for (const [status, count] of Object.entries(counts)) {
    if (!KNOWN_OUTBOX_STATUSES.has(status)) other += count
    total += count
  }

  if (conflict > 0) return CaptureOneSessionState.Conflict
  if (failed > 0) return CaptureOneSessionState.Failed
  if (pending > 0 || writing > 0) return CaptureOneSessionState.Syncing
  // Written rows are "Gather 已写入、C1 尚未 reload" — the c1Read state,
  // regardless of a stale reload ack: the user has not confirmed the sync.
  if (written > 0) return CaptureOneSessionState.C1Read
  // Unknown statuses are handled conservatively: never claim safeToCleanup.
  if (other > 0) return CaptureOneSessionState.C1Read
  if (total === 0) return CaptureOneSessionState.Synced
  // All rows are terminal (synced/clean/cleaned): cleanup is safe only after
  // Capture One confirmed the reload; otherwise C1 may still hold old metadata.
  return reloadAckedAt
    ? CaptureOneSessionState.SafeToCleanup
    : CaptureOneSessionState.C1Read
}

@injectable()
export class CaptureOneSyncState {
  private observedStates = new Map<string, CaptureOneSessionState>()

  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  /**
   * 重启重推导（2.3.3）：从 outbox 行状态 + reload_acked_at 恢复机器状态。
   * 不存在的会话按 disconnected 处理（最保守、无任何同步语义）。
   */
  deriveSessionState(sessionId: string): CaptureOneSessionState {
    const session = this.db.prepare(
      'SELECT reload_acked_at FROM sessions WHERE id = ?',
    ).get(sessionId) as { reload_acked_at: string | null } | undefined
    if (!session) return CaptureOneSessionState.Disconnected

    const rows = this.db.prepare(`
      SELECT o.status
      FROM metadata_outbox o
      JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
      WHERE os.session_id = ?
    `).all(sessionId) as Array<{ status: string }>

    return aggregateSessionState({
      counts: countOutboxStatuses(rows),
      reloadAckedAt: session.reload_acked_at,
    })
  }

  /**
   * P1 事件接线（2.5）：写回协调器每次 emitSummary 后由组合根调用。
   * 从 DB 重推导并记录状态转换（验收：状态机转换全部可观测）。
   * 保守策略不变：本模块不触发任何 reload / cleanup，只做观测。
   */
  observeSummary(summary: MetadataSyncSummary): CaptureOneSessionState {
    return this.reportTransition(summary.sessionId)
  }

  /**
   * reloadMetadata() 成功写入 reload_acked_at 后由组合根调用，
   * 补上协调器事件不覆盖的 ack 转换（ack 不产生 outbox 变更）。
   */
  observeReloadAck(sessionId: string): CaptureOneSessionState {
    return this.reportTransition(sessionId)
  }

  /** 单次全量视图（IPC c1:sync-state）：派生状态 + 持久 ack 标记。 */
  getSessionView(sessionId: string): { state: CaptureOneSessionState; reloadAckedAt: string | null } {
    const session = this.db.prepare(
      'SELECT reload_acked_at FROM sessions WHERE id = ?',
    ).get(sessionId) as { reload_acked_at: string | null } | undefined
    return {
      state: this.deriveSessionState(sessionId),
      reloadAckedAt: session?.reload_acked_at ?? null,
    }
  }

  private reportTransition(sessionId: string): CaptureOneSessionState {
    const next = this.deriveSessionState(sessionId)
    const previous = this.observedStates.get(sessionId)
    this.observedStates.set(sessionId, next)
    if (previous === undefined) {
      console.log(`[capture-one-sync] session ${sessionId} 初始状态: ${next}`)
    } else if (previous !== next) {
      console.log(`[capture-one-sync] session ${sessionId} 状态转换: ${previous} → ${next}`)
    }
    return next
  }
}
