import { describe, expect, it } from 'vitest'
import { deriveIndexHeaderCopy } from '../../../desktop/src/renderer/pages/SessionDetail/indexProgress'
import type { TypedTFunction } from '../../../desktop/src/renderer/locales'

/** zh-CN copy snapshot so the pure helper stays regression-testable. */
const zh: TypedTFunction = ((key: any, options?: { count?: number; current?: number; total?: number; percent?: number }) => {
  const map: Record<string, (o: any) => string> = {
    'index.indexedCount': (o) => `已索引 ${o.count} 张照片`,
    'index.indexedCountGE': (o) => `已索引 ≥${o.count} 张照片`,
    'index.scanningLive': (o) => `正在索引 ${o.current} / ${o.total}（${o.percent}%）`,
    'index.scanningEllipsis': () => '扫描中…',
    'index.failed': () => '索引失败',
  }
  const keyName = typeof key === 'string' ? key : key[0]
  const fn = map[keyName]
  return fn ? fn(options ?? {}) : keyName
}) as TypedTFunction

const session = (overrides: Partial<{ photoCount: number; truncatedImport: boolean }> = {}) => ({
  photoCount: 0,
  truncatedImport: false,
  ...overrides,
})

describe('deriveIndexHeaderCopy', () => {
  it('shows nothing when there is no job and no photo count yet', () => {
    expect(deriveIndexHeaderCopy(null, session(), zh)).toBeNull()
  })

  it('shows 扫描中… for an active job with no numbers yet', () => {
    expect(deriveIndexHeaderCopy({ status: 'queued', current: 0, total: 0 }, session(), zh)).toEqual({
      kind: 'scanning',
      text: '扫描中…',
      percent: null,
    })
    expect(deriveIndexHeaderCopy({ status: 'running', current: 0, total: 12847 }, session(), zh)).toEqual({
      kind: 'scanning',
      text: '扫描中…',
      percent: null,
    })
  })

  it('shows live progress with percent while the job runs', () => {
    expect(deriveIndexHeaderCopy({ current: 12547, total: 12847 }, session(), zh)).toEqual({
      kind: 'scanning',
      text: '正在索引 12547 / 12847（98%）',
      percent: 98,
    })
  })

  it('rounds the percent', () => {
    expect(deriveIndexHeaderCopy({ current: 1, total: 3 }, session(), zh)?.percent).toBe(33)
  })

  it('clamps the percent at 100', () => {
    expect(deriveIndexHeaderCopy({ current: 5, total: 2 }, session(), zh)?.percent).toBe(100)
  })

  it('shows 索引失败 for a failed job', () => {
    expect(deriveIndexHeaderCopy({ status: 'failed', current: 100, total: 100 }, session(), zh)).toEqual({
      kind: 'error',
      text: '索引失败',
      percent: null,
    })
  })

  it('shows the exact count once the scan succeeded, dropping the ≥ prefix for truncated imports', () => {
    expect(
      deriveIndexHeaderCopy({ status: 'succeeded', current: 12847, total: 12847 }, session({
        photoCount: 12847,
        truncatedImport: true,
      }), zh),
    ).toEqual({ kind: 'count', text: '已索引 12847 张照片', percent: null })
  })

  it('keeps the ≥ prefix while the exact count is unknown for truncated imports', () => {
    expect(deriveIndexHeaderCopy(null, session({ photoCount: 50000, truncatedImport: true }), zh)).toEqual({
      kind: 'count',
      text: '已索引 ≥50000 张照片',
      percent: null,
    })
  })

  it('keeps the ≥ prefix after a cancelled scan (count still non-authoritative)', () => {
    expect(
      deriveIndexHeaderCopy(
        { status: 'cancelled', current: 20000, total: 50000 },
        session({ photoCount: 50000, truncatedImport: true }),
        zh,
      ),
    ).toEqual({ kind: 'count', text: '已索引 ≥50000 张照片', percent: null })
  })

  it('shows the exact count for a non-truncated session without a job', () => {
    expect(deriveIndexHeaderCopy(null, session({ photoCount: 12 }), zh)).toEqual({
      kind: 'count',
      text: '已索引 12 张照片',
      percent: null,
    })
  })
})
