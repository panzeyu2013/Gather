// Capture One 渲染层 API — 直连 preload 的轻量表面（与 c1:health 同构，
// 不走 gather:command 白名单）。C1SyncStateView 镜像 preload 的契约形状。

import type { C1Health } from '../../preload'

/** 与主进程 CaptureOneSessionState 枚举逐值对应（有校验测试守住镜像）。 */
export const C1_SYNC_STATES = [
  'disconnected',
  'connected',
  'syncing',
  'c1Read',
  'safeToCleanup',
  'synced',
  'failed',
  'conflict',
] as const

export type C1SyncState = (typeof C1_SYNC_STATES)[number]

export interface C1SyncStateView {
  state: C1SyncState
  reloadAckedAt: string | null
  xmp: {
    pending: number
    writing: number
    written: number
    failed: number
    conflict: number
    synced: number
  }
}

export const captureOneApi = {
  health: (): Promise<C1Health> => window.gather.getC1Health(),

  /** 会话级同步状态机视图（design_improvements.md 2.3.5 P1）。
   * preload 契约把 state 声明为 string（镜像主进程枚举、不跨层 import），
   * 此处收窄为已知状态联合；C1_SYNC_STATES 与主进程枚举的逐值一致性
   * 由 tests/unit/renderer/c1-sync-controls.test.ts 校验。 */
  syncState: (sessionId: string): Promise<C1SyncStateView> =>
    window.gather.getC1SyncState(sessionId) as Promise<C1SyncStateView>,
}
