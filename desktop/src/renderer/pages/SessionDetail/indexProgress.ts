import { t as defaultT, type TypedTFunction } from '../../locales'

/** Progress snapshot of the workspace's background `metadata.scan` job.
 * Live `jobs:progress` frames carry no `status`; terminal frames carry the
 * final status, and `jobs.list` rows always carry one. */
export interface IndexJobSnapshot {
  status?: string
  current: number
  total: number
}

export type IndexHeaderCopyKind = 'scanning' | 'count' | 'error'

export interface IndexHeaderCopy {
  kind: IndexHeaderCopyKind
  text: string
  /** 0-100 when a determinate percentage is known, otherwise null. */
  percent: number | null
}

export const TERMINAL_JOB_STATUSES = ['succeeded', 'failed', 'cancelled', 'interrupted']

const ACTIVE_JOB_STATUSES = ['queued', 'running', 'cancelling']

/** 文案规范 (design_improvements.md 3.3.3 / 3.3.4): while the background
 * `metadata.scan` job for a workspace is running/queued, the header shows the
 * live progress ("正在索引 N / M（x%）" or "扫描中…") and never presents a
 * partial count as authoritative. Only after the scan succeeds — when
 * `photoCount` has been backfilled exactly — does the copy switch to the
 * authoritative count ("已索引 N 张照片"), dropping the "≥" prefix that a
 * truncated import keeps until then. */
export function deriveIndexHeaderCopy(
  job: IndexJobSnapshot | null,
  session: { photoCount: number; truncatedImport: boolean },
  translator: TypedTFunction = defaultT,
): IndexHeaderCopy | null {
  if (job) {
    if (job.status === 'succeeded') {
      return { kind: 'count', text: translator('index.indexedCount', { count: session.photoCount }), percent: null }
    }
    if (job.status === 'failed') {
      return { kind: 'error', text: translator('index.failed'), percent: null }
    }
    if (job.status === undefined || ACTIVE_JOB_STATUSES.includes(job.status)) {
      if (job.current > 0 && job.total > 0) {
        const percent = Math.min(100, Math.round((job.current / job.total) * 100))
        return {
          kind: 'scanning',
          text: translator('index.scanningLive', { current: job.current, total: job.total, percent }),
          percent,
        }
      }
      return { kind: 'scanning', text: translator('index.scanningEllipsis'), percent: null }
    }
  }
  // No job, or a cancelled/interrupted terminal frame: the exact count is only
  // authoritative after a successful scan, so a truncated import keeps the
  // "≥" prefix and a workspace with no photos yet shows nothing at all.
  if (session.photoCount === 0) return null
  if (session.truncatedImport) {
    return { kind: 'count', text: translator('index.indexedCountGE', { count: session.photoCount }), percent: null }
  }
  return { kind: 'count', text: translator('index.indexedCount', { count: session.photoCount }), percent: null }
}
