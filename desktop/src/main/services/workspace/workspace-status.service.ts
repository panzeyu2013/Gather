// desktop/src/main/services/workspace/workspace-status.service.ts
// 工作区状态只读聚合（design_improvements.md 1.4.1–1.4.5）：
// 不引入新的权威数据源，全部从现有 SQLite 表（photos / analysis_jobs /
// analysis_runs / writeback_items / metadata_outbox）+ MetadataSyncCoordinator
// 派生。唯一允许的写入是 offlinePhotos 的内存 TTL 缓存。

import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { Database } from '../../db/database'
import { SessionRepository } from '../../db/repositories/session.repo'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import type { MetadataSyncCoordinator } from '../metadata/metadata-sync-coordinator'
import type {
  AnalysisJobStatus,
  WorkspaceRecommendedNext,
  WorkspaceStaleAnalysis,
  WorkspaceStatus,
} from '@gather/shared'

/** 契约（design_improvements.md 1.4.5）：`photos.status='missing'` 是惰性
 * 检测的，Inbox 每次刷新不能全盘 stat 文件。离线照片计数按 sessionId 缓存
 * 至少 5 分钟，TTL 内不再查库。 */
export const OFFLINE_PHOTOS_TTL_MS = 5 * 60_000

const ACTIVE_JOB_STATUSES: ReadonlySet<AnalysisJobStatus> = new Set([
  'queued',
  'running',
  'cancelling',
])

const MAX_FAILED_JOBS = 10

interface OfflinePhotosCacheEntry {
  count: number
  cachedAt: number
}

interface ScanJobRow {
  status: AnalysisJobStatus
  progress_current: number
  progress_total: number
}

interface FailedJobRow {
  id: string
  type: string
  error_message: string
  error_code: string
}

interface AnalysisRunRow {
  kind: 'similarity' | 'face'
  index_seq: number
  finished_at: string
}

@injectable()
export class WorkspaceStatusService {
  private readonly offlinePhotosCache = new Map<string, OfflinePhotosCacheEntry>()

  constructor(
    @inject(DI_TOKENS.DB) private db: Database,
    @inject(DI_TOKENS.SESSION_REPO) private sessionRepo: SessionRepository,
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.METADATA_SYNC_COORDINATOR)
    private metadataSync: MetadataSyncCoordinator,
  ) {}

  /** 聚合整个工作区状态；session 不存在时返回 null（IPC 层转 err）。 */
  getStatus(sessionId: string): WorkspaceStatus | null {
    const session = this.sessionRepo.get(sessionId)
    if (!session) return null

    const photoCount = this.photoRepo.countBySession(sessionId)
    const scanJob = this.latestScanJob(sessionId)
    // 索引 job 按 dedupeKey `metadata.scan:<sessionId>` 创建且终态行会被
    // 复用为 retry，因此同一 session 至多一条 metadata.scan 行；"最近一次
    // 索引 job 成功结束且此后无待处理变更" 即等价于该行 status 为
    // 'succeeded'（活跃行 updated_at 必然更新，若存在活跃工作则 latest 就是它）。
    // 该行是阶段证据（stage 'indexed'），job.service 的 clear_completed 排除了
    // metadata.scan / export.execute 两类证据行（见 job.service.ts 注释），
    // 所以这里不需要用 index_seq>0 兜底——index_seq 只在扫描提交真实变更时
    // 自增，无变更的成功扫描（如文件数组导入后的补齐扫描）不会 bump，
    // 依赖它推导 indexed 会在 clear_completed 后误判为 imported。
    const indexed = scanJob?.status === 'succeeded'
    const indexingActive = scanJob !== null && ACTIVE_JOB_STATUSES.has(scanJob.status)
    const scanFailed = scanJob?.status === 'failed'

    const indexSeq = session.index_seq
    const similarityRun = this.latestOkRun(sessionId, 'similarity')
    const faceRun = this.latestOkRun(sessionId, 'face')

    // 1.4.2 过期判定：last_ok_run.index_seq < session.index_seq
    const staleAnalyses: WorkspaceStaleAnalysis[] = []
    if (similarityRun && similarityRun.index_seq < indexSeq) {
      staleAnalyses.push({ kind: 'similarity', lastRunAt: similarityRun.finished_at })
    }
    if (faceRun && faceRun.index_seq < indexSeq) {
      staleAnalyses.push({ kind: 'face', lastRunAt: faceRun.finished_at })
    }

    const indexing: WorkspaceStatus['indexing'] = {
      total: scanJob?.progress_total ?? 0,
      done: scanJob?.progress_current ?? 0,
      percent: scanJob && scanJob.progress_total > 0
        ? Math.round((scanJob.progress_current / scanJob.progress_total) * 100)
        : 0,
      // 3.3.4：失败信号进 payload（status: 'failed'），渲染层据此显示
      // "索引失败"+重试，而不是把阶段计数当权威数据展示。
      status: indexingActive ? 'active' : scanFailed ? 'failed' : 'idle',
    }

    const summary = this.metadataSync.getSummary(sessionId)
    const softFlags = {
      culled: this.hasWrittenBackCulling(sessionId),
      exported: this.hasSuccessfulExport(sessionId),
    }
    const failedJobs = this.listFailedJobs(sessionId)

    return {
      sessionId,
      stage: this.deriveStage(photoCount, indexed, similarityRun, indexSeq),
      softFlags,
      indexing,
      staleAnalyses,
      // 1.4.3 xmp_pending 动作定义覆盖 pending/failed 两态，故 pending 并入 failed。
      xmp: { pending: summary.pending + summary.failed, conflict: summary.conflict },
      offlinePhotos: this.getOfflinePhotosCount(sessionId),
      failedJobs,
      recommendedNext: this.deriveRecommendedNext(
        indexingActive,
        scanJob?.status,
        summary.conflict,
        staleAnalyses.length,
        failedJobs.length,
        softFlags,
      ),
      generatedAt: new Date().toISOString(),
    }
  }

  private deriveStage(
    photoCount: number,
    indexed: boolean,
    similarityRun: AnalysisRunRow | null,
    indexSeq: number,
  ): WorkspaceStatus['stage'] {
    // 三硬阶段取"已满足的最高阶段"。analyzed 要求相似度 run 未过期（1.4.2）。
    if (similarityRun && similarityRun.index_seq >= indexSeq) return 'analyzed'
    if (indexed) return 'indexed'
    if (photoCount > 0) return 'imported'
    // 一跳化导入先建 session 行后跑索引 job，此时 0 张照片连 imported 都未
    // 达成；docs 的联合类型补一个前置的 created 阶段表达这一窗口。
    return 'created'
  }

  /**
   * 固定优先级序列表 + 布尔门控（design_improvements.md 1.4.3，
   * 明确不引入规则引擎）：
   * 1. scan_incomplete → 等待/查看索引（信息型置顶）
   * 2. xmp_conflict > 0 → 裁决冲突（P1 优先于一切）
   * 3. analysis_stale → 重新分析（P1）
   * 4. job_failed → 重试失败任务（P2）
   * 5. 全部正常 → 推进流程（软标记未满足的下一步：culling → export）
   *
   * C1 连接状态门控（写回/清理类动作才需要）有意跳过：本推荐列表不含此类
   * 动作，接线 c1:health 会引入对问题二工作流的依赖，收益为零。
   */
  private deriveRecommendedNext(
    indexingActive: boolean,
    scanStatus: AnalysisJobStatus | undefined,
    conflictCount: number,
    staleCount: number,
    failedCount: number,
    softFlags: { culled: boolean; exported: boolean },
  ): WorkspaceRecommendedNext | null {
    // scan_incomplete：索引尚未成功结束（活跃 job、job 失败，或从未有过
    // 成功的索引 job——含 0 照片的新 session，此时"查看/开始索引"正是下一步）。
    const scanIncomplete = indexingActive || scanStatus !== 'succeeded'
    if (scanIncomplete) return { action: 'scan_incomplete', target: 'index' }
    if (conflictCount > 0) return { action: 'resolve_conflicts', target: 'metadata' }
    if (staleCount > 0) return { action: 're_analyze', target: 'similarity' }
    if (failedCount > 0) return { action: 'retry_jobs', target: 'jobs' }
    if (!softFlags.culled) return { action: 'start_culling', target: 'culling' }
    if (!softFlags.exported) return { action: 'export', target: 'export' }
    return null
  }

  /** 已写回的挑片决策：writeback_items（批量写回，module='culling'）或
   * metadata_outbox（交互式 culling 同步，source_module='culling'）任一
   * 出现 written/synced 行即视为已写回；synced 行会被 cleanup 删除，故两态都要。 */
  private hasWrittenBackCulling(sessionId: string): boolean {
    const viaWritebackItems = this.db.prepare(`
      SELECT 1 FROM writeback_items
      WHERE session_id = ? AND module = 'culling' AND xmp_status IN ('written', 'synced')
      LIMIT 1
    `).get(sessionId)
    if (viaWritebackItems !== undefined) return true
    const viaOutbox = this.db.prepare(`
      SELECT 1
      FROM metadata_outbox o
      JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
      WHERE os.session_id = ? AND o.source_module = 'culling' AND o.status IN ('written', 'synced')
      LIMIT 1
    `).get(sessionId)
    return viaOutbox !== undefined
  }

  /** 存在成功导出的 job 记录：analysis_jobs type='export.execute' status='succeeded'。 */
  private hasSuccessfulExport(sessionId: string): boolean {
    const row = this.db.prepare(`
      SELECT 1 FROM analysis_jobs
      WHERE type = 'export.execute' AND scope_id = ? AND status = 'succeeded'
      LIMIT 1
    `).get(sessionId)
    return row !== undefined
  }

  private listFailedJobs(sessionId: string): WorkspaceStatus['failedJobs'] {
    const rows = this.db.prepare(`
      SELECT id, type, error_message, error_code
      FROM analysis_jobs
      WHERE scope_type = 'session' AND scope_id = ? AND status = 'failed'
      ORDER BY updated_at DESC
      LIMIT ${MAX_FAILED_JOBS}
    `).all(sessionId) as FailedJobRow[]
    return rows.map(row => ({
      id: row.id,
      type: row.type,
      message: row.error_message || row.error_code || 'Unknown error',
    }))
  }

  private latestScanJob(sessionId: string): ScanJobRow | null {
    const row = this.db.prepare(`
      SELECT status, progress_current, progress_total
      FROM analysis_jobs
      WHERE type = 'metadata.scan' AND scope_id = ?
      ORDER BY updated_at DESC
      LIMIT 1
    `).get(sessionId) as ScanJobRow | undefined
    return row ?? null
  }

  private latestOkRun(sessionId: string, kind: 'similarity' | 'face'): AnalysisRunRow | null {
    const row = this.db.prepare(`
      SELECT kind, index_seq, finished_at
      FROM analysis_runs
      WHERE session_id = ? AND kind = ? AND status = 'ok'
      ORDER BY id DESC
      LIMIT 1
    `).get(sessionId, kind) as AnalysisRunRow | undefined
    return row ?? null
  }

  private getOfflinePhotosCount(sessionId: string): number {
    const cached = this.offlinePhotosCache.get(sessionId)
    const now = Date.now()
    if (cached && now - cached.cachedAt < OFFLINE_PHOTOS_TTL_MS) {
      return cached.count
    }
    const row = this.db.prepare(`
      SELECT COUNT(*) AS count FROM photos
      WHERE session_id = ? AND status = 'missing'
    `).get(sessionId) as { count: number } | undefined
    const count = row?.count ?? 0
    this.offlinePhotosCache.set(sessionId, { count, cachedAt: now })
    return count
  }
}
