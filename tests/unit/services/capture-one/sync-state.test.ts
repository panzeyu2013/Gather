import { describe, expect, it } from 'vitest'
import {
  aggregateSessionState,
  CaptureOneSessionState,
  countOutboxStatuses,
} from '../../../../desktop/src/main/services/capture-one/sync-state'

const CONFLICT = CaptureOneSessionState.Conflict
const FAILED = CaptureOneSessionState.Failed
const SYNCING = CaptureOneSessionState.Syncing
const C1_READ = CaptureOneSessionState.C1Read
const SAFE_TO_CLEANUP = CaptureOneSessionState.SafeToCleanup
const SYNCED = CaptureOneSessionState.Synced

function counts(overrides: Record<string, number>): Record<string, number> {
  return overrides
}

describe('aggregateSessionState — session-level aggregation priority (doc 2.3.2)', () => {
  it('conflict outranks every other status', () => {
    expect(aggregateSessionState({
      counts: counts({ conflict: 1, failed: 3, pending: 2, writing: 1, written: 4, synced: 5 }),
      reloadAckedAt: '2026-08-08T10:00:00.000Z',
    })).toBe(CONFLICT)
  })

  it('failed outranks pending/writing/synced but loses to conflict', () => {
    expect(aggregateSessionState({
      counts: counts({ failed: 2, pending: 1, writing: 3, written: 1, synced: 2 }),
      reloadAckedAt: null,
    })).toBe(FAILED)
    expect(aggregateSessionState({
      counts: counts({ conflict: 1, failed: 2 }),
      reloadAckedAt: null,
    })).toBe(CONFLICT)
  })

  it('pending or writing rows mean the session is still syncing', () => {
    expect(aggregateSessionState({
      counts: counts({ pending: 1 }),
      reloadAckedAt: null,
    })).toBe(SYNCING)
    expect(aggregateSessionState({
      counts: counts({ writing: 1, written: 2 }),
      reloadAckedAt: null,
    })).toBe(SYNCING)
  })

  it('all synced without a reload ack is c1Read, with a reload ack is safeToCleanup', () => {
    expect(aggregateSessionState({
      counts: counts({ synced: 3 }),
      reloadAckedAt: null,
    })).toBe(C1_READ)
    expect(aggregateSessionState({
      counts: counts({ synced: 3 }),
      reloadAckedAt: '2026-08-08T10:00:00.000Z',
    })).toBe(SAFE_TO_CLEANUP)
  })

  it('written rows are c1Read even when a reload ack exists (sync not confirmed yet)', () => {
    expect(aggregateSessionState({
      counts: counts({ written: 2 }),
      reloadAckedAt: '2026-08-08T10:00:00.000Z',
    })).toBe(C1_READ)
    expect(aggregateSessionState({
      counts: counts({ written: 2, synced: 1 }),
      reloadAckedAt: '2026-08-08T10:00:00.000Z',
    })).toBe(C1_READ)
  })

  it('an empty outbox is the terminal synced state', () => {
    expect(aggregateSessionState({
      counts: counts({}),
      reloadAckedAt: null,
    })).toBe(SYNCED)
  })

  it('unrecognized statuses are conservative: never safeToCleanup, never synced', () => {
    expect(aggregateSessionState({
      counts: counts({ mystery: 1 }),
      reloadAckedAt: '2026-08-08T10:00:00.000Z',
    })).toBe(C1_READ)
  })

  it('clean/cleaned rows are terminal rows, gated by the reload ack', () => {
    expect(aggregateSessionState({
      counts: counts({ clean: 1 }),
      reloadAckedAt: null,
    })).toBe(C1_READ)
    expect(aggregateSessionState({
      counts: counts({ cleaned: 2, synced: 1 }),
      reloadAckedAt: '2026-08-08T10:00:00.000Z',
    })).toBe(SAFE_TO_CLEANUP)
  })

  it('countOutboxStatuses reduces rows deterministically', () => {
    expect(countOutboxStatuses([
      { status: 'pending' },
      { status: 'synced' },
      { status: 'pending' },
      { status: 'conflict' },
    ])).toEqual({ pending: 2, synced: 1, conflict: 1 })
  })
})
