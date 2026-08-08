import { describe, expect, it } from 'vitest'
import {
  C1_SYNC_STATES,
} from '../../../desktop/src/renderer/api/captureOne'
import {
  deriveSyncControlHints,
  deriveSyncControls,
  syncStatusCopy,
} from '../../../desktop/src/renderer/utils/c1-sync-controls'
import {
  CaptureOneSessionState,
} from '../../../desktop/src/main/services/capture-one/sync-state'
import type { TypedTFunction } from '../../../desktop/src/renderer/locales'

/** zh-CN copy snapshot so the pure helpers stay regression-testable. */
const zh: TypedTFunction = ((key: any, options?: any) => {
  const map: Record<string, string> = {
    'c1sync.syncing': '同步中：Gather 正在写入 XMP…',
    'c1sync.c1Read': 'Gather 已写入，等待 C1 读取',
    'c1.status.safeToCleanup': 'C1 已读取，可安全清理',
    'c1.status.synced': '已同步',
    'c1sync.failed': '有写入失败项，请先重试',
    'c1sync.conflict': '存在 XMP 冲突，请先裁决',
    'c1.status.disconnected': '未连接 Capture One',
    'c1sync.connected': '已连接 Capture One，暂无写入',
    'c1sync.loading': '同步状态加载中…',
    'c1sync.hint.loadSynced': '已完成同步，无需再次加载元数据',
    'c1sync.hint.loadFailed': '存在写入失败项，请先重试',
    'c1sync.hint.loadConflict': '存在 XMP 冲突，请先裁决',
    'c1sync.hint.loadNone': '没有可加载的已写入元数据',
    'c1sync.hint.confirmSynced': '已完成同步',
    'c1sync.hint.confirmNotAcked': '请先在 Capture One 中加载元数据，再确认同步',
    'c1sync.hint.confirmPending': '请先等待写入完成或处理失败项',
    'c1sync.hint.cleanupSynced': '已完成清理',
    'c1sync.hint.cleanupSteps': '请先加载元数据并确认同步，再执行清理',
  }
  const keyName = typeof key === 'string' ? key : key[0]
  return map[keyName] ?? keyName
}) as TypedTFunction

describe('C1_SYNC_STATES mirrors the main-process enum (contract parity)', () => {
  it('renderer state union covers every CaptureOneSessionState value', () => {
    expect(new Set(C1_SYNC_STATES))
      .toEqual(new Set(Object.values(CaptureOneSessionState)))
  })
})

describe('deriveSyncControls — button availability driven by the state machine (doc 2.3.5)', () => {
  it('syncing: load enabled, confirm/cleanup disabled', () => {
    expect(deriveSyncControls({ syncState: 'syncing', hasWritten: true, acked: false }))
      .toEqual({ canLoadMetadata: true, canConfirmSync: false, canCleanup: false })
  })

  it('c1Read without ack: only load enabled', () => {
    expect(deriveSyncControls({ syncState: 'c1Read', hasWritten: true, acked: false }))
      .toEqual({ canLoadMetadata: true, canConfirmSync: false, canCleanup: false })
  })

  it('c1Read with ack and written rows: load + confirm enabled, cleanup disabled', () => {
    expect(deriveSyncControls({ syncState: 'c1Read', hasWritten: true, acked: true }))
      .toEqual({ canLoadMetadata: true, canConfirmSync: true, canCleanup: false })
  })

  it('c1Read with ack but no written rows: confirm stays disabled (nothing to confirm)', () => {
    expect(deriveSyncControls({ syncState: 'c1Read', hasWritten: false, acked: true }))
      .toEqual({ canLoadMetadata: true, canConfirmSync: false, canCleanup: false })
  })

  it('safeToCleanup: all three enabled', () => {
    expect(deriveSyncControls({ syncState: 'safeToCleanup', hasWritten: false, acked: true }))
      .toEqual({ canLoadMetadata: true, canConfirmSync: true, canCleanup: true })
  })

  it('synced: all disabled', () => {
    expect(deriveSyncControls({ syncState: 'synced', hasWritten: false, acked: true }))
      .toEqual({ canLoadMetadata: false, canConfirmSync: false, canCleanup: false })
  })

  it('failed/conflict: all disabled', () => {
    for (const state of ['failed', 'conflict'] as const) {
      expect(deriveSyncControls({ syncState: state, hasWritten: true, acked: true }))
        .toEqual({ canLoadMetadata: false, canConfirmSync: false, canCleanup: false })
    }
  })

  it('unknown state (view not loaded yet): all disabled conservatively', () => {
    expect(deriveSyncControls({ syncState: null, hasWritten: false, acked: false }))
      .toEqual({ canLoadMetadata: false, canConfirmSync: false, canCleanup: false })
  })
})

describe('syncStatusCopy — status copy next to buttons (doc 2.3.5)', () => {
  it('maps every state to Chinese copy via the translator', () => {
    expect(syncStatusCopy('syncing', zh)).toBe('同步中：Gather 正在写入 XMP…')
    expect(syncStatusCopy('c1Read', zh)).toBe('Gather 已写入，等待 C1 读取')
    expect(syncStatusCopy('safeToCleanup', zh)).toBe('C1 已读取，可安全清理')
    expect(syncStatusCopy('synced', zh)).toBe('已同步')
    expect(syncStatusCopy('failed', zh)).toBe('有写入失败项，请先重试')
    expect(syncStatusCopy('conflict', zh)).toBe('存在 XMP 冲突，请先裁决')
    expect(syncStatusCopy('disconnected', zh)).toBe('未连接 Capture One')
    expect(syncStatusCopy('connected', zh)).toBe('已连接 Capture One，暂无写入')
    expect(syncStatusCopy(null, zh)).toBe('同步状态加载中…')
  })
})

describe('deriveSyncControlHints — disabled buttons explain why', () => {
  it('returns null hints for enabled buttons', () => {
    const controls = deriveSyncControls({ syncState: 'c1Read', hasWritten: true, acked: true })
    const hints = deriveSyncControlHints('c1Read', controls, true, zh)
    expect(hints.loadHint).toBeNull()
    expect(hints.confirmHint).toBeNull()
    expect(hints.cleanupHint).toContain('确认同步')
  })

  it('confirm disabled without ack points at Load Metadata', () => {
    const controls = deriveSyncControls({ syncState: 'c1Read', hasWritten: true, acked: false })
    const hints = deriveSyncControlHints('c1Read', controls, false, zh)
    expect(hints.confirmHint).toContain('加载元数据')
  })

  it('cleanup disabled outside safeToCleanup explains the required steps', () => {
    const controls = deriveSyncControls({ syncState: 'c1Read', hasWritten: true, acked: true })
    const hints = deriveSyncControlHints('c1Read', controls, true, zh)
    expect(hints.cleanupHint).toContain('加载元数据并确认同步')
  })

  it('load disabled in synced/failed/conflict states explains why', () => {
    const synced = deriveSyncControls({ syncState: 'synced', hasWritten: false, acked: true })
    expect(deriveSyncControlHints('synced', synced, true, zh).loadHint).toContain('已完成同步')
    const failed = deriveSyncControls({ syncState: 'failed', hasWritten: true, acked: false })
    expect(deriveSyncControlHints('failed', failed, false, zh).loadHint).toContain('重试')
    const conflict = deriveSyncControls({ syncState: 'conflict', hasWritten: true, acked: false })
    expect(deriveSyncControlHints('conflict', conflict, false, zh).loadHint).toContain('裁决')
  })
})
