import { describe, expect, it } from 'vitest'
import {
  deriveCardIndexKind,
  type DashboardScanJob,
} from '../../../desktop/src/renderer/pages/Dashboard/index'

describe('deriveCardIndexKind — Dashboard card index copy decision (3.3.3 / 3.3.4)', () => {
  it('failed terminal scan → failed (索引失败 + 重试, never a count)', () => {
    expect(deriveCardIndexKind({ status: 'failed', current: 100, total: 100 })).toBe('failed')
  })

  it('active scan states → active even with zero progress (queued counts)', () => {
    for (const status of ['queued', 'running', 'cancelling', undefined]) {
      expect(deriveCardIndexKind({ status, current: 0, total: 0 })).toBe('active')
    }
  })

  it('active scan with progress → active', () => {
    expect(deriveCardIndexKind({ status: 'running', current: 25, total: 100 })).toBe('active')
  })

  it('succeeded scan → count (authoritative, ≥ drops for truncated imports)', () => {
    expect(deriveCardIndexKind({ status: 'succeeded', current: 100, total: 100 })).toBe('count')
  })

  it('cancelled / interrupted scans → count (count stays non-authoritative → ≥ kept downstream)', () => {
    expect(deriveCardIndexKind({ status: 'cancelled', current: 10, total: 100 })).toBe('count')
    expect(deriveCardIndexKind({ status: 'interrupted', current: 10, total: 100 })).toBe('count')
  })

  it('no scan row → count', () => {
    expect(deriveCardIndexKind(undefined)).toBe('count')
    expect(deriveCardIndexKind(null as unknown as DashboardScanJob | undefined)).toBe('count')
  })
})
