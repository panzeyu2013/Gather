// Control Center 纯逻辑（design_improvements.md 1.4.1–1.4.3 / 2.3.5）。
// 与 DOM 无关的派生函数，供页面与单测共用：Action Inbox 聚合、三硬阶段
// 进度、推荐下一步映射、C1 健康胶囊映射、工作区头部文案规范（3.3.3）。

import type { WorkspaceStatus, WorkspaceStage } from '@gather/shared'
import type { C1SyncStateView } from '../../../api/captureOne'
import { t as defaultT, type TypedTFunction } from '../../../locales'

// ---------- Action Inbox（1.4.3） ----------

export type InboxKind =
  | 'scan_incomplete'
  | 'xmp_conflict'
  | 'analysis_stale'
  | 'xmp_pending'
  | 'offline_photos'
  | 'job_failed'
  | 'export_pending'

export type InboxAction =
  | { type: 'navigate'; to: string }
  | { type: 'retry-job'; jobId: string }
  | { type: 'none' }

export interface InboxItem {
  kind: InboxKind
  label: string
  actionLabel: string
  action: InboxAction
}

export interface InboxFailedJobItem extends InboxItem {
  kind: 'job_failed'
  job: { id: string; type: string; message: string }
}

export const MAX_FAILED_JOB_ROWS = 3

const JOB_TYPE_KEYS: Record<string, 'inbox.jobType.metadataScan' | 'inbox.jobType.similarityAnalyze' | 'inbox.jobType.fkwAnalyze' | 'inbox.jobType.dupScan' | 'inbox.jobType.exportExecute' | 'inbox.jobType.qualityAnalyze' | 'inbox.jobType.navigationAnalyze' | 'inbox.jobType.cullingWriteback' | 'inbox.jobType.simWriteback'> = {
  'metadata.scan': 'inbox.jobType.metadataScan',
  'similarity.analyze': 'inbox.jobType.similarityAnalyze',
  'fkw.analyze': 'inbox.jobType.fkwAnalyze',
  'dup.scan': 'inbox.jobType.dupScan',
  'export.execute': 'inbox.jobType.exportExecute',
  'quality.analyze': 'inbox.jobType.qualityAnalyze',
  'navigation.analyze': 'inbox.jobType.navigationAnalyze',
  'culling.writeback': 'inbox.jobType.cullingWriteback',
  'sim.writeback': 'inbox.jobType.simWriteback',
}

export function jobTypeLabel(type: string, translator: TypedTFunction = defaultT): string {
  const key = JOB_TYPE_KEYS[type]
  return key ? translator(key) : type
}

/**
 * 固定优先级序列表（1.4.3）：索引未完成（信息型置顶）→ XMP 冲突 → 分析过期
 * → XMP 待写入 → 照片离线 → 任务失败（最多 3 行）→ 待导出。全部满足时返回空数组
 * （页面渲染"全部正常"空态）。
 */
const ANALYSIS_KIND_KEYS: Record<'similarity' | 'face', 'inbox.analysisKind.similarity' | 'inbox.analysisKind.face'> = {
  similarity: 'inbox.analysisKind.similarity',
  face: 'inbox.analysisKind.face',
}

export function deriveInboxItems(
  status: WorkspaceStatus,
  truncatedImport: boolean,
  translator: TypedTFunction = defaultT,
): InboxItem[] {
  const items: InboxItem[] = []
  const sessionBase = `/sessions/${status.sessionId}`

  // indexing.status 直接由主进程按 scan job 状态派生：queued/running/
  // cancelling → 'active'（即使进度仍为 0/0），failed → 'failed'。
  const indexingActive = status.stage === 'created' || status.indexing.status === 'active'
  // 1.4.4：scan_incomplete 指向截断标记——截断导入在索引成功（精确总数落定）
  // 前一直保留该条目；非截断 session 在扫描失败（failed）或扫描进行中
  // （queued 时进度 0/0 也视为未完成）同样显示该信息条目，与主进程
  // recommendedNext 的 scan_incomplete 判定保持一致。
  const scanIncomplete = indexingActive ||
    status.indexing.status === 'failed' ||
    (truncatedImport && status.stage === 'imported')
  if (scanIncomplete) {
    items.push({
      kind: 'scan_incomplete',
      label: translator('inbox.scanIncomplete.label'),
      actionLabel: translator('inbox.scanIncomplete.action'),
      action: { type: 'none' },
    })
  }

  if (status.xmp.conflict > 0) {
    items.push({
      kind: 'xmp_conflict',
      label: translator('inbox.xmpConflict.label', { count: status.xmp.conflict }),
      actionLabel: translator('inbox.xmpConflict.action'),
      action: { type: 'navigate', to: `${sessionBase}/culling` },
    })
  }

  if (status.staleAnalyses.length > 0) {
    const names = status.staleAnalyses
      .map((a) => translator(ANALYSIS_KIND_KEYS[a.kind === 'similarity' ? 'similarity' : 'face']))
      .join(translator('list.separator'))
    // 按过期分析类型路由：仅人脸过期 → 人脸页；否则（相似度过期或两者
    // 都有）→ 相似度页。
    const faceOnly = status.staleAnalyses.every((a) => a.kind === 'face')
    items.push({
      kind: 'analysis_stale',
      label: translator('inbox.analysisStale.label', { names }),
      actionLabel: translator('inbox.action.analyze'),
      action: { type: 'navigate', to: faceOnly ? `${sessionBase}/face-kw` : `${sessionBase}/similarity` },
    })
  }

  if (status.xmp.pending > 0) {
    items.push({
      kind: 'xmp_pending',
      label: translator('inbox.xmpPending.label', { count: status.xmp.pending }),
      actionLabel: translator('inbox.xmpPending.action'),
      action: { type: 'navigate', to: `${sessionBase}/culling` },
    })
  }

  if (status.offlinePhotos > 0) {
    items.push({
      kind: 'offline_photos',
      label: translator('inbox.offlinePhotos.label', { count: status.offlinePhotos }),
      actionLabel: translator('inbox.action.view'),
      action: { type: 'navigate', to: `${sessionBase}/gallery` },
    })
  }

  if (status.failedJobs.length > 0) {
    for (const job of status.failedJobs.slice(0, MAX_FAILED_JOB_ROWS)) {
      const item: InboxFailedJobItem = {
        kind: 'job_failed',
        label: translator('inbox.jobFailed.label', {
          type: jobTypeLabel(job.type, translator),
          message: job.message,
        }),
        actionLabel: translator('inbox.action.retry'),
        action: { type: 'retry-job', jobId: job.id },
        job,
      }
      items.push(item)
    }
  }

  if (status.softFlags.culled && !status.softFlags.exported) {
    items.push({
      kind: 'export_pending',
      label: translator('inbox.exportPending.label'),
      actionLabel: translator('inbox.exportPending.action'),
      action: { type: 'navigate', to: `${sessionBase}/export` },
    })
  }

  return items
}

// ---------- 三硬阶段进度条（1.4.1） ----------

export interface StageMark {
  id: 'imported' | 'indexed' | 'analyzed'
  label: string
  reached: boolean
  current: boolean
}

const STAGE_ORDER: Array<StageMark['id']> = ['imported', 'indexed', 'analyzed']
const STAGE_LABEL_KEYS: Record<StageMark['id'], 'workspace.stage.imported' | 'workspace.stage.indexed' | 'workspace.stage.analyzed'> = {
  imported: 'workspace.stage.imported',
  indexed: 'workspace.stage.indexed',
  analyzed: 'workspace.stage.analyzed',
}

export function deriveStageMarks(
  stage: WorkspaceStage,
  translator: TypedTFunction = defaultT,
): StageMark[] {
  const reachedIndex = stage === 'created' ? -1 : STAGE_ORDER.indexOf(stage)
  return STAGE_ORDER.map((id, i) => ({
    id,
    label: translator(STAGE_LABEL_KEYS[id]),
    reached: i <= reachedIndex,
    // created 窗口（一跳化导入后 0 张照片）时高亮第一个硬阶段。
    current: stage === 'created' ? i === 0 : i === reachedIndex,
  }))
}

// ---------- 推荐下一步（1.4.3 固定优先级序列表的渲染映射） ----------

export interface RecommendedNextView {
  title: string
  detail: string
  actionLabel: string
  action: InboxAction | null
}

export function deriveRecommendedNextView(
  next: WorkspaceStatus['recommendedNext'],
  staleAnalyses: WorkspaceStatus['staleAnalyses'],
  sessionId: string,
  translator: TypedTFunction = defaultT,
): RecommendedNextView {
  const done: RecommendedNextView = {
    title: translator('recommended.done.title'),
    detail: translator('recommended.done.detail'),
    actionLabel: '',
    action: null,
  }
  if (!next) return done
  switch (next.action) {
    case 'scan_incomplete':
      // 索引进度就在本页（Control Center 头部），信息型条目无需跳转。
      return {
        title: translator('recommended.scanIncomplete.title'),
        detail: translator('recommended.scanIncomplete.detail'),
        actionLabel: translator('recommended.scanIncomplete.action'),
        action: { type: 'none' },
      }
    case 'resolve_conflicts':
      return {
        title: translator('recommended.resolveConflicts.title'),
        detail: translator('recommended.resolveConflicts.detail'),
        actionLabel: translator('recommended.resolveConflicts.action'),
        action: { type: 'navigate', to: `/sessions/${sessionId}/culling` },
      }
    case 're_analyze':
      // 按过期分析类型路由：仅人脸过期 → 人脸页，否则 → 相似度页。
      return {
        title: translator('recommended.reAnalyze.title'),
        detail: translator('recommended.reAnalyze.detail'),
        actionLabel: translator('recommended.reAnalyze.action'),
        action: {
          type: 'navigate',
          to: staleAnalyses.length > 0 && staleAnalyses.every((a) => a.kind === 'face')
            ? `/sessions/${sessionId}/face-kw`
            : `/sessions/${sessionId}/similarity`,
        },
      }
    case 'retry_jobs':
      return {
        title: translator('recommended.retryJobs.title'),
        detail: translator('recommended.retryJobs.detail'),
        actionLabel: translator('recommended.retryJobs.action'),
        action: { type: 'navigate', to: '/jobs' },
      }
    case 'start_culling':
      return {
        title: translator('recommended.startCulling.title'),
        detail: translator('recommended.startCulling.detail'),
        actionLabel: translator('recommended.startCulling.action'),
        action: { type: 'navigate', to: `/sessions/${sessionId}/culling` },
      }
    case 'export':
      return {
        title: translator('recommended.export.title'),
        detail: translator('recommended.export.detail'),
        actionLabel: translator('recommended.export.action'),
        action: { type: 'navigate', to: `/sessions/${sessionId}/export` },
      }
    default:
      return done
  }
}

// ---------- 工作区头部文案规范（3.3.3 / 3.3.4） ----------

export interface WorkspaceHeaderCopy {
  countText: string
  /** 索引活跃且有数值时 0-100，否则 null。 */
  percent: number | null
  /** 索引 job 状态：active 显示实时进度，failed 显示"索引失败"+重试，
   * count 显示（阶段计数落定后的）照片数。 */
  kind: 'scanning' | 'error' | 'count'
}

export function deriveWorkspaceHeaderCopy(
  status: WorkspaceStatus,
  photoCount: number,
  truncatedImport: boolean,
  translator: TypedTFunction = defaultT,
): WorkspaceHeaderCopy {
  // 文案规范：索引活跃/失败期间绝不把阶段计数当权威数据展示。queued 的
  // scan（进度 0/0）也由主进程标为 'active'，不会滑入 count 分支；created
  // 一跳化窗口（session 行已建、scan 尚未入队）同样视为进行中。
  if (status.stage === 'created' || status.indexing.status === 'active') {
    if (status.indexing.total > 0) {
      return {
        kind: 'scanning',
        countText: translator('controlCenter.indexingLive', {
          done: status.indexing.done,
          total: status.indexing.total,
        }),
        percent: status.indexing.percent,
      }
    }
    return { kind: 'scanning', countText: translator('index.scanningEllipsis'), percent: null }
  }
  if (status.indexing.status === 'failed') {
    return { kind: 'error', countText: translator('index.failed'), percent: null }
  }
  // 索引已落定（成功或从未运行）：stage 'indexed' 只在 scan 成功时可达，
  // 此时精确总数已回填，截断导入的 "≥" 前缀随之去除（与 SessionDetail
  // indexProgress 行为一致）；stage 未达 indexed 的截断导入仍保留 ≥。
  if (photoCount === 0) return { kind: 'count', countText: translator('gallery.empty'), percent: null }
  if (truncatedImport && status.stage !== 'indexed') {
    return { kind: 'count', countText: translator('index.indexedCountGE', { count: photoCount }), percent: null }
  }
  return { kind: 'count', countText: translator('index.indexedCount', { count: photoCount }), percent: null }
}

// ---------- C1 健康胶囊（2.3.5） ----------

export type CapsuleTone = 'green' | 'yellow' | 'red' | 'gray'

export interface CapsuleView {
  tone: CapsuleTone
  label: string
  detail: string
}

const CAPSULE_LABEL_KEYS: Record<C1SyncStateView['state'], 'c1.capsule.synced.label' | 'c1.capsule.safeToCleanup.label' | 'c1.capsule.c1Read.label' | 'c1.capsule.syncing.label' | 'c1.capsule.connected.label' | 'c1.capsule.disconnected.label' | 'c1.capsule.failed.label' | 'c1.capsule.conflict.label'> = {
  synced: 'c1.capsule.synced.label',
  safeToCleanup: 'c1.capsule.safeToCleanup.label',
  c1Read: 'c1.capsule.c1Read.label',
  syncing: 'c1.capsule.syncing.label',
  connected: 'c1.capsule.connected.label',
  disconnected: 'c1.capsule.disconnected.label',
  failed: 'c1.capsule.failed.label',
  conflict: 'c1.capsule.conflict.label',
}

const CAPSULE_DETAIL_KEYS: Record<C1SyncStateView['state'], 'c1.capsule.synced.detail' | 'c1.capsule.safeToCleanup.detail' | 'c1.capsule.c1Read.detail' | 'c1.capsule.syncing.detail' | 'c1.capsule.connected.detail' | 'c1.capsule.disconnected.detail' | 'c1.capsule.failed.detail' | 'c1.capsule.conflict.detail'> = {
  synced: 'c1.capsule.synced.detail',
  safeToCleanup: 'c1.capsule.safeToCleanup.detail',
  c1Read: 'c1.capsule.c1Read.detail',
  syncing: 'c1.capsule.syncing.detail',
  connected: 'c1.capsule.connected.detail',
  disconnected: 'c1.capsule.disconnected.detail',
  failed: 'c1.capsule.failed.detail',
  conflict: 'c1.capsule.conflict.detail',
}

export function deriveCapsuleView(
  state: C1SyncStateView | null,
  error: boolean,
  translator: TypedTFunction = defaultT,
): CapsuleView {
  if (error) {
    return { tone: 'red', label: translator('c1.capsule.error.label'), detail: translator('c1.capsule.error.detail') }
  }
  if (!state) {
    return { tone: 'gray', label: translator('c1.capsule.checking.label'), detail: translator('c1.capsule.checking.detail') }
  }
  const labelKey = CAPSULE_LABEL_KEYS[state.state]
  if (labelKey) {
    return {
      tone: state.state === 'synced' || state.state === 'safeToCleanup' ? 'green'
        : state.state === 'disconnected' || state.state === 'failed' || state.state === 'conflict' ? 'red'
          : 'yellow',
      label: translator(labelKey),
      detail: translator(CAPSULE_DETAIL_KEYS[state.state]),
    }
  }
  return { tone: 'gray', label: translator('c1.capsule.unknown.label'), detail: state.state }
}

/** 写回队列计数（2.3.5）：尚未被 C1 确认读取的行（pending/writing/written）。 */
export function c1QueueCount(state: C1SyncStateView | null): number {
  if (!state) return 0
  return state.xmp.pending + state.xmp.writing + state.xmp.written
}
