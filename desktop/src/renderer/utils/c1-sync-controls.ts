// Similarity 写回面板按钮状态机映射（design_improvements.md 2.3.5 P1）。
// 纯函数：{syncState, hasWritten, acked} → 三个按钮可用性 + 状态文案 + 禁用提示。
// 状态机语义（2.3.1/2.3.2）：
//   syncing        → Gather 正在写入 XMP（pending/writing 行存在）
//   c1Read         → Gather 已写入、C1 尚未确认读取（written 行存在）
//   safeToCleanup  → 全部行终态（synced/cleaned）+ reload_acked_at 已写入
//   synced         → outbox 无行
// 保守策略：确认同步需 ack（C1 已 load）且存在已写入行；清理仅 safeToCleanup。

import type { C1SyncState } from '../api/captureOne'
import { t as defaultT, type TypedTFunction } from '../locales'

export interface SyncControlInput {
  syncState: C1SyncState | null
  /** metadata_outbox 存在 written 行（Gather 已写入、C1 未确认） */
  hasWritten: boolean
  /** sessions.reload_acked_at 已写入（reloadMetadata() 成功） */
  acked: boolean
}

export interface SyncControls {
  canLoadMetadata: boolean
  canConfirmSync: boolean
  canCleanup: boolean
}

export interface SyncControlHints {
  loadHint: string | null
  confirmHint: string | null
  cleanupHint: string | null
}

export function deriveSyncControls(input: SyncControlInput): SyncControls {
  const { syncState, hasWritten, acked } = input
  if (!syncState) {
    return { canLoadMetadata: false, canConfirmSync: false, canCleanup: false }
  }
  const loadable =
    syncState === 'syncing' || syncState === 'c1Read' || syncState === 'safeToCleanup'
  const confirmable =
    (syncState === 'c1Read' && hasWritten && acked) || syncState === 'safeToCleanup'
  return {
    canLoadMetadata: loadable,
    canConfirmSync: confirmable,
    canCleanup: syncState === 'safeToCleanup',
  }
}

/** 按钮旁状态文案（2.3.5）。 */
export function syncStatusCopy(state: C1SyncState | null, translator: TypedTFunction = defaultT): string {
  switch (state) {
    case 'syncing':
      return translator('c1sync.syncing')
    case 'c1Read':
      return translator('c1sync.c1Read')
    case 'safeToCleanup':
      return translator('c1.status.safeToCleanup')
    case 'synced':
      return translator('c1.status.synced')
    case 'failed':
      return translator('c1sync.failed')
    case 'conflict':
      return translator('c1sync.conflict')
    case 'disconnected':
      return translator('c1.status.disconnected')
    case 'connected':
      return translator('c1sync.connected')
    case null:
      return translator('c1sync.loading')
  }
}

/** 禁用按钮的 title/hint（说明为何不可用），可用时返回 null。 */
export function deriveSyncControlHints(
  state: C1SyncState | null,
  controls: SyncControls,
  acked: boolean,
  translator: TypedTFunction = defaultT,
): SyncControlHints {
  const loadHint = controls.canLoadMetadata
    ? null
    : state === 'synced'
      ? translator('c1sync.hint.loadSynced')
      : state === 'failed'
        ? translator('c1sync.hint.loadFailed')
        : state === 'conflict'
          ? translator('c1sync.hint.loadConflict')
          : translator('c1sync.hint.loadNone')
  const confirmHint = controls.canConfirmSync
    ? null
    : state === 'synced'
      ? translator('c1sync.hint.confirmSynced')
      : !acked
        ? translator('c1sync.hint.confirmNotAcked')
        : translator('c1sync.hint.confirmPending')
  const cleanupHint = controls.canCleanup
    ? null
    : state === 'synced'
      ? translator('c1sync.hint.cleanupSynced')
      : translator('c1sync.hint.cleanupSteps')
  return { loadHint, confirmHint, cleanupHint }
}
