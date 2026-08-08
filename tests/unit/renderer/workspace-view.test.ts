import { describe, expect, it } from 'vitest'
import type { WorkspaceStatus } from '../../../packages/shared/src/protocol/workspace'
import {
  c1QueueCount,
  deriveCapsuleView,
  deriveInboxItems,
  deriveRecommendedNextView,
  deriveStageMarks,
  deriveWorkspaceHeaderCopy,
  jobTypeLabel,
  MAX_FAILED_JOB_ROWS,
} from '../../../desktop/src/renderer/pages/SessionDetail/ControlCenter/workspace-view'
import type { C1SyncStateView } from '../../../desktop/src/renderer/api/captureOne'
import type { TypedTFunction } from '../../../desktop/src/renderer/locales'

/** zh-CN copy snapshot so the pure helpers stay regression-testable. */
const zh: TypedTFunction = ((key: any, options?: Record<string, unknown>) => {
  const map: Record<string, (o: Record<string, unknown>) => string> = {
    'inbox.scanIncomplete.label': () => '索引未完成，照片数量暂不精确',
    'inbox.scanIncomplete.action': () => '查看进度',
    'inbox.xmpConflict.label': (o) => `${o.count} 个 XMP 冲突待裁决`,
    'inbox.xmpConflict.action': () => '逐条裁决',
    'inbox.analysisStale.label': (o) => `${o.names}分析已过期，新增照片未参与分析`,
    'list.separator': () => '、',
    'inbox.analysisKind.similarity': () => '相似度',
    'inbox.analysisKind.face': () => '人脸',
    'inbox.xmpPending.label': (o) => `${o.count} 个 XMP 待写入`,
    'inbox.xmpPending.action': () => '检查',
    'inbox.offlinePhotos.label': (o) => `${o.count} 张照片离线（源文件不可读）`,
    'inbox.jobFailed.label': (o) => `${o.type}任务失败：${o.message}`,
    'inbox.exportPending.label': () => '已挑片但尚未导出',
    'inbox.exportPending.action': () => '去导出',
    'inbox.action.analyze': () => '重新分析',
    'inbox.action.view': () => '查看',
    'inbox.action.retry': () => '重试',
    'inbox.jobType.metadataScan': () => '索引',
    'inbox.jobType.similarityAnalyze': () => '相似度分析',
    'inbox.jobType.fkwAnalyze': () => '人脸分析',
    'inbox.jobType.dupScan': () => '重复扫描',
    'inbox.jobType.exportExecute': () => '导出',
    'inbox.jobType.qualityAnalyze': () => '技术分析',
    'inbox.jobType.navigationAnalyze': () => '导航分析',
    'inbox.jobType.cullingWriteback': () => '挑片写回',
    'inbox.jobType.simWriteback': () => '相似组写回',
    'workspace.stage.imported': () => '已导入',
    'workspace.stage.indexed': () => '已索引',
    'workspace.stage.analyzed': () => '已分析',
    'recommended.done.title': () => '一切正常',
    'recommended.done.detail': () => '工作区状态良好，无待办事项',
    'recommended.reAnalyze.action': () => '重新分析',
    'recommended.scanIncomplete.title': () => '等待索引完成',
    'recommended.scanIncomplete.detail': () => '后台索引正在进行，完成后照片数量将精确显示',
    'recommended.scanIncomplete.action': () => '查看进度',
    'recommended.resolveConflicts.title': () => '裁决 XMP 冲突',
    'recommended.resolveConflicts.detail': () => '冲突会阻塞写回同步，先逐条裁决再继续',
    'recommended.resolveConflicts.action': () => '逐条裁决',
    'recommended.reAnalyze.title': () => '重新分析相似度',
    'recommended.reAnalyze.detail': () => '新增照片未参与分组，重新分析可合并剩余重复项',
    'recommended.retryJobs.title': () => '重试失败任务',
    'recommended.retryJobs.detail': () => '存在失败的后台任务，先重试再继续',
    'recommended.retryJobs.action': () => '重试失败任务',
    'recommended.startCulling.title': () => '开始挑片',
    'recommended.startCulling.detail': () => '工作区已就绪，从挑片开始整理',
    'recommended.startCulling.action': () => '去挑片',
    'recommended.export.title': () => '导出成品',
    'recommended.export.detail': () => '挑片已完成，导出最终成品',
    'recommended.export.action': () => '去导出',
    'controlCenter.indexingLive': (o) => `正在索引 ${o.done} / ${o.total}`,
    'index.scanningEllipsis': () => '扫描中…',
    'index.failed': () => '索引失败',
    'index.indexedCount': (o) => `已索引 ${o.count} 张照片`,
    'index.indexedCountGE': (o) => `已索引 ≥${o.count} 张照片`,
    'gallery.empty': () => '暂无照片',
    'c1.capsule.error.label': () => '状态未知',
    'c1.capsule.error.detail': () => '无法读取 Capture One 同步状态',
    'c1.capsule.checking.label': () => '检测中…',
    'c1.capsule.checking.detail': () => '正在检测 Capture One 同步状态',
    'c1.capsule.synced.label': () => '已同步',
    'c1.capsule.synced.detail': () => 'XMP 写回已全部同步',
    'c1.capsule.safeToCleanup.label': () => '可安全清理',
    'c1.capsule.safeToCleanup.detail': () => 'Capture One 已读取，可安全清理 XMP',
    'c1.capsule.c1Read.label': () => 'Gather 已写入',
    'c1.capsule.c1Read.detail': () => '等待 Capture One 加载元数据',
    'c1.capsule.syncing.label': () => '同步中',
    'c1.capsule.syncing.detail': () => 'Gather 正在写入 XMP',
    'c1.capsule.connected.label': () => '已连接',
    'c1.capsule.connected.detail': () => 'Capture One 已连接，暂无写入',
    'c1.capsule.disconnected.label': () => '连接中断',
    'c1.capsule.disconnected.detail': () => '未检测到 Capture One，请确认已启动',
    'c1.capsule.failed.label': () => '同步失败',
    'c1.capsule.failed.detail': () => '存在写入失败项，请先重试',
    'c1.capsule.conflict.label': () => '存在冲突',
    'c1.capsule.conflict.detail': () => '存在 XMP 冲突，请先裁决',
    'c1.capsule.unknown.label': () => '状态未知',
  }
  const keyName = typeof key === 'string' ? key : key[0]
  const fn = map[keyName]
  return fn ? fn(options ?? {}) : keyName
}) as TypedTFunction

const status = (overrides: Partial<WorkspaceStatus> = {}): WorkspaceStatus => ({
  sessionId: 's1',
  stage: 'analyzed',
  softFlags: { culled: false, exported: false },
  indexing: { total: 0, done: 0, percent: 0, status: 'idle' },
  staleAnalyses: [],
  xmp: { pending: 0, conflict: 0 },
  offlinePhotos: 0,
  failedJobs: [],
  recommendedNext: null,
  generatedAt: '2026-08-08T00:00:00.000Z',
  ...overrides,
})

const syncView = (overrides: Partial<C1SyncStateView> = {}): C1SyncStateView => ({
  state: 'synced',
  reloadAckedAt: null,
  xmp: { pending: 0, writing: 0, written: 0, failed: 0, conflict: 0, synced: 0 },
  ...overrides,
})

describe('deriveInboxItems — priority order + 判定 (design 1.4.3)', () => {
  it('returns nothing when everything is healthy', () => {
    expect(deriveInboxItems(status(), false, zh)).toEqual([])
  })

  it('sorts every kind by the fixed priority list, scan_incomplete on top', () => {
    const items = deriveInboxItems(status({
      stage: 'imported',
      indexing: { total: 100, done: 50, percent: 50, status: 'active' },
      xmp: { pending: 2, conflict: 3 },
      staleAnalyses: [{ kind: 'similarity', lastRunAt: '2026-01-01T00:00:00.000Z' }],
      offlinePhotos: 4,
      failedJobs: [
        { id: 'j1', type: 'similarity.analyze', message: 'timeout' },
        { id: 'j2', type: 'export.execute', message: 'disk full' },
        { id: 'j3', type: 'dup.scan', message: 'oom' },
        { id: 'j4', type: 'metadata.scan', message: 'io' },
      ],
      softFlags: { culled: true, exported: false },
    }), false, zh)

    expect(items.map((i) => i.kind)).toEqual([
      'scan_incomplete',
      'xmp_conflict',
      'analysis_stale',
      'xmp_pending',
      'offline_photos',
      'job_failed',
      'job_failed',
      'job_failed',
      'export_pending',
    ])
    expect(items.filter((i) => i.kind === 'job_failed')).toHaveLength(MAX_FAILED_JOB_ROWS)
  })

  it('scan_incomplete: active indexing job (indexing numbers present)', () => {
    const items = deriveInboxItems(status({
      stage: 'indexed',
      indexing: { total: 100, done: 50, percent: 50, status: 'active' },
    }), false, zh)
    expect(items.map((i) => i.kind)).toEqual(['scan_incomplete'])
    expect(items[0].action).toEqual({ type: 'none' })
  })

  it('scan_incomplete: queued scan with zero progress is still active (1.4.3)', () => {
    const items = deriveInboxItems(status({
      stage: 'imported',
      indexing: { total: 0, done: 0, percent: 0, status: 'active' },
    }), false, zh)
    expect(items.map((i) => i.kind)).toEqual(['scan_incomplete'])
  })

  it('scan_incomplete: failed scan on an imported session (matches recommendedNext)', () => {
    const items = deriveInboxItems(status({
      stage: 'imported',
      indexing: { total: 0, done: 0, percent: 0, status: 'failed' },
      failedJobs: [{ id: 'scan-1', type: 'metadata.scan', message: 'io' }],
    }), false, zh)
    expect(items.map((i) => i.kind)).toEqual(['scan_incomplete', 'job_failed'])
  })

  it('scan_incomplete: stage created (one-hop import window)', () => {
    const items = deriveInboxItems(status({ stage: 'created' }), false, zh)
    expect(items.map((i) => i.kind)).toEqual(['scan_incomplete'])
  })

  it('scan_incomplete: truncated import keeps the item until indexed (1.4.4)', () => {
    expect(deriveInboxItems(status({ stage: 'imported' }), true, zh)[0].kind).toBe('scan_incomplete')
    expect(deriveInboxItems(status({ stage: 'indexed' }), true, zh)).toEqual([])
  })

  it('no scan_incomplete for a settled non-truncated import', () => {
    expect(deriveInboxItems(status({ stage: 'imported' }), false, zh)).toEqual([])
  })

  it('xmp_conflict navigates to the culling page (conflict panel lives there)', () => {
    const items = deriveInboxItems(status({ xmp: { pending: 0, conflict: 2 } }), false, zh)
    expect(items[0]).toMatchObject({
      kind: 'xmp_conflict',
      label: '2 个 XMP 冲突待裁决',
      actionLabel: '逐条裁决',
      action: { type: 'navigate', to: '/sessions/s1/culling' },
    })
  })

  it('analysis_stale: kind names per stale analysis, routes by kind', () => {
    const similarity = deriveInboxItems(
      status({ staleAnalyses: [{ kind: 'similarity', lastRunAt: '' }] }), false, zh,
    )
    expect(similarity[0].label).toContain('相似度分析已过期')
    expect(similarity[0].action).toEqual({ type: 'navigate', to: '/sessions/s1/similarity' })

    const both = deriveInboxItems(status({
      staleAnalyses: [
        { kind: 'similarity', lastRunAt: '' },
        { kind: 'face', lastRunAt: '' },
      ],
    }), false, zh)
    expect(both[0].label).toContain('相似度、人脸分析已过期')
    expect(both[0].action).toEqual({ type: 'navigate', to: '/sessions/s1/similarity' })

    // 仅人脸过期 → 人脸页（route by kind）。
    const faceOnly = deriveInboxItems(
      status({ staleAnalyses: [{ kind: 'face', lastRunAt: '' }] }), false, zh,
    )
    expect(faceOnly[0].action).toEqual({ type: 'navigate', to: '/sessions/s1/face-kw' })
  })

  it('xmp_pending navigates to the culling metadata panel', () => {
    const items = deriveInboxItems(status({ xmp: { pending: 5, conflict: 0 } }), false, zh)
    expect(items[0]).toMatchObject({
      kind: 'xmp_pending',
      actionLabel: '检查',
      action: { type: 'navigate', to: '/sessions/s1/culling' },
    })
  })

  it('offline_photos navigates to the gallery', () => {
    const items = deriveInboxItems(status({ offlinePhotos: 24 }), false, zh)
    expect(items[0]).toMatchObject({
      kind: 'offline_photos',
      label: '24 张照片离线（源文件不可读）',
      action: { type: 'navigate', to: '/sessions/s1/gallery' },
    })
  })

  it('job_failed: retry action carries the job id, label maps job type', () => {
    const items = deriveInboxItems(status({
      failedJobs: [{ id: 'j9', type: 'similarity.analyze', message: 'worker timeout' }],
    }), false, zh)
    expect(items[0]).toMatchObject({
      kind: 'job_failed',
      label: '相似度分析任务失败：worker timeout',
      actionLabel: '重试',
      action: { type: 'retry-job', jobId: 'j9' },
    })
  })

  it('job_failed: unknown job types fall back to the raw type', () => {
    expect(jobTypeLabel('metadata.scan', zh)).toBe('索引')
    expect(jobTypeLabel('mystery.job', zh)).toBe('mystery.job')
  })

  it('export_pending: culled without export', () => {
    const items = deriveInboxItems(status({ softFlags: { culled: true, exported: false } }), false, zh)
    expect(items[0]).toMatchObject({
      kind: 'export_pending',
      actionLabel: '去导出',
      action: { type: 'navigate', to: '/sessions/s1/export' },
    })
    expect(deriveInboxItems(status({ softFlags: { culled: true, exported: true } }), false, zh)).toEqual([])
    expect(deriveInboxItems(status({ softFlags: { culled: false, exported: false } }), false, zh)).toEqual([])
  })
})

describe('deriveStageMarks — three hard stages, soft flags excluded (1.4.1)', () => {
  it('created: first stage highlighted as current, nothing reached', () => {
    const marks = deriveStageMarks('created', zh)
    expect(marks.map((m) => ({ id: m.id, reached: m.reached, current: m.current }))).toEqual([
      { id: 'imported', reached: false, current: true },
      { id: 'indexed', reached: false, current: false },
      { id: 'analyzed', reached: false, current: false },
    ])
  })

  it('indexed: imported + indexed reached, indexed current', () => {
    const marks = deriveStageMarks('indexed', zh)
    expect(marks.map((m) => ({ id: m.id, reached: m.reached, current: m.current }))).toEqual([
      { id: 'imported', reached: true, current: false },
      { id: 'indexed', reached: true, current: true },
      { id: 'analyzed', reached: false, current: false },
    ])
  })

  it('analyzed: all three reached', () => {
    const marks = deriveStageMarks('analyzed', zh)
    expect(marks.every((m) => m.reached)).toBe(true)
    expect(marks[2].current).toBe(true)
  })

  it('labels are 已导入/已索引/已分析', () => {
    expect(deriveStageMarks('analyzed', zh).map((m) => m.label)).toEqual(['已导入', '已索引', '已分析'])
  })
})

describe('deriveRecommendedNextView — service action ids mapped to copy/actions', () => {
  it('null → 一切正常 without an action', () => {
    const view = deriveRecommendedNextView(null, [], 's1', zh)
    expect(view.title).toBe('一切正常')
    expect(view.action).toBeNull()
  })

  it('re_analyze → navigate to the similarity page', () => {
    const view = deriveRecommendedNextView(
      { action: 're_analyze', target: 'similarity' },
      [{ kind: 'similarity', lastRunAt: '' }],
      's1', zh,
    )
    expect(view.action).toEqual({ type: 'navigate', to: '/sessions/s1/similarity' })
    expect(view.actionLabel).toBe('重新分析')
  })

  it('re_analyze with face-only staleness → navigate to the face page', () => {
    const view = deriveRecommendedNextView(
      { action: 're_analyze', target: 'similarity' },
      [{ kind: 'face', lastRunAt: '' }],
      's1', zh,
    )
    expect(view.action).toEqual({ type: 'navigate', to: '/sessions/s1/face-kw' })
  })

  it('resolve_conflicts → navigate to the culling conflict panel', () => {
    const view = deriveRecommendedNextView({ action: 'resolve_conflicts', target: 'metadata' }, [], 's1', zh)
    expect(view.action).toEqual({ type: 'navigate', to: '/sessions/s1/culling' })
  })

  it('retry_jobs → navigate to the global jobs page', () => {
    const view = deriveRecommendedNextView({ action: 'retry_jobs', target: 'jobs' }, [], 's1', zh)
    expect(view.action).toEqual({ type: 'navigate', to: '/jobs' })
  })

  it('start_culling / export → module routes', () => {
    expect(deriveRecommendedNextView({ action: 'start_culling', target: 'culling' }, [], 's1', zh).action)
      .toEqual({ type: 'navigate', to: '/sessions/s1/culling' })
    expect(deriveRecommendedNextView({ action: 'export', target: 'export' }, [], 's1', zh).action)
      .toEqual({ type: 'navigate', to: '/sessions/s1/export' })
  })

  it('scan_incomplete → informational, no navigation', () => {
    const view = deriveRecommendedNextView({ action: 'scan_incomplete', target: 'index' }, [], 's1', zh)
    expect(view.action).toEqual({ type: 'none' })
  })
})

describe('deriveWorkspaceHeaderCopy — 文案规范 (3.3.3 / 3.3.4)', () => {
  it('live progress while indexing with numbers', () => {
    const copy = deriveWorkspaceHeaderCopy(status({
      stage: 'imported',
      indexing: { total: 12847, done: 12547, percent: 98, status: 'active' },
    }), 12547, false, zh)
    expect(copy).toEqual({ kind: 'scanning', countText: '正在索引 12547 / 12847', percent: 98 })
  })

  it('扫描中… while indexing without numbers yet', () => {
    expect(deriveWorkspaceHeaderCopy(status({ stage: 'created' }), 0, false, zh))
      .toEqual({ kind: 'scanning', countText: '扫描中…', percent: null })
  })

  it('扫描中… for a queued scan with zero progress (not settled)', () => {
    expect(deriveWorkspaceHeaderCopy(status({
      stage: 'imported',
      indexing: { total: 0, done: 0, percent: 0, status: 'active' },
    }), 0, false, zh))
      .toEqual({ kind: 'scanning', countText: '扫描中…', percent: null })
  })

  it('索引失败 with the error kind after a failed scan, never a count', () => {
    expect(deriveWorkspaceHeaderCopy(status({
      stage: 'imported',
      indexing: { total: 0, done: 0, percent: 0, status: 'failed' },
    }), 12847, false, zh))
      .toEqual({ kind: 'error', countText: '索引失败', percent: null })
    // 截断导入 + 扫描失败同样不允许展示阶段计数。
    expect(deriveWorkspaceHeaderCopy(status({
      stage: 'imported',
      indexing: { total: 0, done: 0, percent: 0, status: 'failed' },
    }), 12847, true, zh))
      .toEqual({ kind: 'error', countText: '索引失败', percent: null })
  })

  it('exact count once settled', () => {
    expect(deriveWorkspaceHeaderCopy(status({ stage: 'indexed' }), 12847, false, zh))
      .toEqual({ kind: 'count', countText: '已索引 12847 张照片', percent: null })
  })

  it('truncated import drops the ≥ prefix once the scan succeeded (stage indexed)', () => {
    // 回归：stage 达 indexed 意味着 metadata.scan 成功、精确总数已回填，
    // 与 SessionDetail indexProgress 一致，≥ 前缀必须去除。
    expect(deriveWorkspaceHeaderCopy(status({ stage: 'indexed' }), 12847, true, zh))
      .toEqual({ kind: 'count', countText: '已索引 12847 张照片', percent: null })
  })

  it('truncated import keeps ≥ while the index has not settled', () => {
    expect(deriveWorkspaceHeaderCopy(status({ stage: 'imported' }), 12847, true, zh))
      .toEqual({ kind: 'count', countText: '已索引 ≥12847 张照片', percent: null })
  })

  it('no photos yet shows 暂无照片', () => {
    expect(deriveWorkspaceHeaderCopy(status({ stage: 'indexed' }), 0, false, zh))
      .toEqual({ kind: 'count', countText: '暂无照片', percent: null })
  })
})

describe('deriveCapsuleView — C1 连接状态 绿/黄/红 (2.3.5)', () => {
  it('loading state is gray', () => {
    expect(deriveCapsuleView(null, false, zh)).toMatchObject({ tone: 'gray', label: '检测中…' })
  })

  it('error state is red', () => {
    expect(deriveCapsuleView(null, true, zh)).toMatchObject({ tone: 'red', label: '状态未知' })
  })

  it('synced / safeToCleanup → green', () => {
    expect(deriveCapsuleView(syncView({ state: 'synced' }), false, zh)).toMatchObject({
      tone: 'green',
      label: '已同步',
    })
    expect(deriveCapsuleView(syncView({ state: 'safeToCleanup' }), false, zh)).toMatchObject({
      tone: 'green',
      label: '可安全清理',
    })
  })

  it('c1Read / syncing / connected → yellow', () => {
    expect(deriveCapsuleView(syncView({ state: 'c1Read' }), false, zh).tone).toBe('yellow')
    expect(deriveCapsuleView(syncView({ state: 'syncing' }), false, zh)).toMatchObject({
      tone: 'yellow',
      label: '同步中',
    })
    expect(deriveCapsuleView(syncView({ state: 'connected' }), false, zh).tone).toBe('yellow')
  })

  it('disconnected / failed / conflict → red', () => {
    expect(deriveCapsuleView(syncView({ state: 'disconnected' }), false, zh)).toMatchObject({
      tone: 'red',
      label: '连接中断',
    })
    expect(deriveCapsuleView(syncView({ state: 'failed' }), false, zh)).toMatchObject({
      tone: 'red',
      label: '同步失败',
    })
    expect(deriveCapsuleView(syncView({ state: 'conflict' }), false, zh)).toMatchObject({
      tone: 'red',
      label: '存在冲突',
    })
  })

  it('detail copy explains the next step for the human', () => {
    expect(deriveCapsuleView(syncView({ state: 'conflict' }), false, zh).detail).toContain('冲突')
  })
})

describe('c1QueueCount — 写回队列计数 (2.3.5)', () => {
  it('sums pending/writing/written (rows Capture One has not confirmed)', () => {
    const view = syncView({ xmp: { pending: 3, writing: 2, written: 1, failed: 0, conflict: 0, synced: 9 } })
    expect(c1QueueCount(view)).toBe(6)
  })

  it('null state counts zero', () => {
    expect(c1QueueCount(null)).toBe(0)
  })
})
