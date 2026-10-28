// desktop/native/gather-core/Sources/GatherApplication/Services/WorkspaceStatusService.swift
// TS 源: desktop/src/main/services/workspace/workspace-status.service.ts（Phase 3.1 Dashboard 移植）
// 工作区状态只读聚合（design_improvements.md 1.4.1–1.4.5）：
// 不引入新的权威数据源，全部从现有 SQLite 表（photos / analysis_jobs /
// analysis_runs / deliveries + delivery_items）派生。唯一允许的写入是
// offlinePhotos 的内存 TTL 缓存。
// 写回软标记（culled）与 xmp 待处理计数都读统一交付模型：计数用
// DeliverySummaryQuery.metadataSummary 的旧摘要投影，按交付去重后只统计
// culling / face-keyword / similarity 三个写回模块（见 summaryCounts）。
//
// 与 TS 的差异：TS 注入 MetadataSyncCoordinator 取 getSummary()；Swift 侧不再
// 依赖协调器/旧 outbox，直接从 deliveries 的计数投影派生，语义按「一交付一行」
// 对齐（S5c-2b-3b-2b-1）。
//
// 已知过渡缺口：手动 rating/label 仍由 MetadataMutationService 写旧
// metadata_outbox（2b-2 才迁入交付），因此这些尚未产生交付行的手动变更暂时
// 不计入 xmp.pending；2b-2 完成后本缺口消失。
import Foundation
import GatherPersistence
import GatherProtocol

/// 工作区状态只读聚合（TS WorkspaceStatusService）。
public final class WorkspaceStatusService {
    /// 契约（design_improvements.md 1.4.5）：`photos.status='missing'` 是惰性
    /// 检测的，Inbox 每次刷新不能全盘 stat 文件。离线照片计数按 sessionId 缓存
    /// 至少 5 分钟，TTL 内不再查库。TS: OFFLINE_PHOTOS_TTL_MS。
    public static let offlinePhotosTTLMs = 5 * 60_000

    /// TS: ACTIVE_JOB_STATUSES（'queued' | 'running' | 'cancelling'）。
    private static let activeJobStatuses: Set<String> = ["queued", "running", "cancelling"]

    /// TS: MAX_FAILED_JOBS。
    private static let maxFailedJobs = 10

    private let sessionRepo: any SessionRepository
    private let photoRepo: any PhotoRepository
    private let jobRepo: any JobRepository
    private let deliverySummary: any DeliverySummaryReading

    /// TS: Date.now()（offlinePhotos TTL 判定用，测试注入时钟）。
    private let clock: () -> Int

    /// TS: offlinePhotosCache（Map<sessionId, { count, cachedAt }>）。
    private var offlinePhotosCache: [String: (count: Int, cachedAt: Int)] = [:]
    private let cacheLock = NSLock()

    public init(
        sessionRepo: any SessionRepository,
        photoRepo: any PhotoRepository,
        jobRepo: any JobRepository,
        deliverySummary: any DeliverySummaryReading,
        clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.sessionRepo = sessionRepo
        self.photoRepo = photoRepo
        self.jobRepo = jobRepo
        self.deliverySummary = deliverySummary
        self.clock = clock
    }

    /// 聚合整个工作区状态；session 不存在时返回 nil（IPC 层转 err）。
    public func getStatus(sessionId: String) throws -> WorkspaceStatus? {
        guard let session = try sessionRepo.get(id: sessionId) else { return nil }

        // P1：工作区总数只算仍在工作区的照片（归档件不参与阶段判定/展示）。
        let photoCount = try photoRepo.countVisibleBySession(sessionId: sessionId)
        let scanJob = try latestScanJob(sessionId)
        // 索引 job 按 dedupeKey `metadata.scan:<sessionId>` 创建且终态行会被
        // 复用为 retry，因此同一 session 至多一条 metadata.scan 行；"最近一次
        // 索引 job 成功结束且此后无待处理变更" 即等价于该行 status 为
        // 'succeeded'（活跃行 updated_at 必然更新，若存在活跃工作则 latest 就是它）。
        // 该行是阶段证据（stage 'indexed'），job.service 的 clear_completed 排除了
        // metadata.scan / output.run 两类证据行（见 job.service.ts 注释），
        // 所以这里不需要用 index_seq>0 兜底——index_seq 只在扫描提交真实变更时
        // 自增，无变更的成功扫描（如文件数组导入后的补齐扫描）不会 bump，
        // 依赖它推导 indexed 会在 clear_completed 后误判为 imported。
        let indexed = scanJob?.status == "succeeded"
        let indexingActive = scanJob != nil && Self.activeJobStatuses.contains(scanJob!.status)
        let scanFailed = scanJob?.status == "failed"

        let indexSeq = session.indexSeq
        let similarityRun = try latestOkRun(sessionId, kind: .similarity)
        let faceRun = try latestOkRun(sessionId, kind: .face)

        // 1.4.2 过期判定：last_ok_run.index_seq < session.index_seq
        var staleAnalyses: [WorkspaceStaleAnalysis] = []
        if let similarityRun, similarityRun.indexSeq < indexSeq {
            staleAnalyses.append(WorkspaceStaleAnalysis(kind: .similarity, lastRunAt: similarityRun.finishedAt))
        }
        if let faceRun, faceRun.indexSeq < indexSeq {
            staleAnalyses.append(WorkspaceStaleAnalysis(kind: .face, lastRunAt: faceRun.finishedAt))
        }

        let total = scanJob?.progressTotal ?? 0
        let done = scanJob?.progressCurrent ?? 0
        // TS: Math.round(...)（百分比恒非负，rounded() 语义一致）。
        let percent: Double
        if let scanJob, scanJob.progressTotal > 0 {
            percent = (Double(scanJob.progressCurrent) / Double(scanJob.progressTotal) * 100).rounded()
        } else {
            percent = 0
        }
        // 3.3.4：失败信号进 payload（status: 'failed'），渲染层据此显示
        // "索引失败"+重试，而不是把阶段计数当权威数据展示。
        let indexingStatus: WorkspaceIndexingStatus = indexingActive ? .active : (scanFailed ? .failed : .idle)
        let indexing = WorkspaceIndexingProgress(
            total: total,
            done: done,
            percent: percent,
            status: indexingStatus
        )

        let (pending, failed, conflict) = try summaryCounts(sessionId)
        let softFlags = WorkspaceSoftFlags(
            culled: try hasWrittenBackCulling(sessionId),
            exported: try hasSuccessfulExport(sessionId)
        )
        let failedJobs = try listFailedJobs(sessionId)

        return WorkspaceStatus(
            sessionId: sessionId,
            stage: deriveStage(photoCount: photoCount, indexed: indexed, similarityRun: similarityRun, indexSeq: indexSeq),
            softFlags: softFlags,
            indexing: indexing,
            staleAnalyses: staleAnalyses,
            // 1.4.3 xmp_pending 动作定义覆盖 pending/failed 两态，故 pending 并入 failed。
            xmp: WorkspaceXmpCounts(pending: pending + failed, conflict: conflict),
            offlinePhotos: try getOfflinePhotosCount(sessionId),
            failedJobs: failedJobs,
            recommendedNext: deriveRecommendedNext(
                indexingActive: indexingActive,
                scanStatus: scanJob?.status,
                conflictCount: conflict,
                staleCount: staleAnalyses.count,
                failedCount: failedJobs.count,
                softFlags: softFlags
            ),
            generatedAt: nowISOString()
        )
    }

    /// TS: deriveStage —— 三硬阶段取"已满足的最高阶段"。analyzed 要求相似度
    /// run 未过期（1.4.2）。
    private func deriveStage(
        photoCount: Int,
        indexed: Bool,
        similarityRun: AnalysisRunRecord?,
        indexSeq: Int
    ) -> WorkspaceStage {
        if let similarityRun, similarityRun.indexSeq >= indexSeq { return .analyzed }
        if indexed { return .indexed }
        if photoCount > 0 { return .imported }
        // 一跳化导入先建 session 行后跑索引 job，此时 0 张照片连 imported 都未
        // 达成；docs 的联合类型补一个前置的 created 阶段表达这一窗口。
        return .created
    }

    /// TS: deriveRecommendedNext —— 固定优先级序列表 + 布尔门控
    /// （design_improvements.md 1.4.3，明确不引入规则引擎）：
    /// 1. scan_incomplete → 等待/查看索引（信息型置顶）
    /// 2. xmp_conflict > 0 → 裁决冲突（P1 优先于一切）
    /// 3. analysis_stale → 重新分析（P1）
    /// 4. job_failed → 重试失败任务（P2）
    /// 5. 全部正常 → 推进流程（软标记未满足的下一步：culling → export）
    ///
    /// C1 连接状态门控（写回/清理类动作才需要）有意跳过：本推荐列表不含此类
    /// 动作，接线 c1:health 会引入对问题二工作流的依赖，收益为零。
    private func deriveRecommendedNext(
        indexingActive: Bool,
        scanStatus: String?,
        conflictCount: Int,
        staleCount: Int,
        failedCount: Int,
        softFlags: WorkspaceSoftFlags
    ) -> WorkspaceRecommendedNext? {
        // scan_incomplete：索引尚未成功结束（活跃 job、job 失败，或从未有过
        // 成功的索引 job——含 0 照片的新 session，此时"查看/开始索引"正是下一步）。
        let scanIncomplete = indexingActive || scanStatus != "succeeded"
        if scanIncomplete { return WorkspaceRecommendedNext(action: "scan_incomplete", target: "index") }
        if conflictCount > 0 { return WorkspaceRecommendedNext(action: "resolve_conflicts", target: "metadata") }
        if staleCount > 0 { return WorkspaceRecommendedNext(action: "re_analyze", target: "similarity") }
        if failedCount > 0 { return WorkspaceRecommendedNext(action: "retry_jobs", target: "jobs") }
        if !softFlags.culled { return WorkspaceRecommendedNext(action: "start_culling", target: "culling") }
        if !softFlags.exported { return WorkspaceRecommendedNext(action: "export", target: "export") }
        return nil
    }

    /// 已写回的挑片决策：统一交付模型里本会话 culling 模块的 delivery_items
    /// 出现 written/synced 即视为已写回（synced 会在 cleanup 后删除，故两态都要）。
    /// 与旧 writeback_items / metadata_outbox 窗口同义：同一 (session, module)
    /// 下只要有一条落盘成功的项就为真，不看交付行状态（item 收敛已蕴含）。
    private func hasWrittenBackCulling(_ sessionId: String) throws -> Bool {
        try deliverySummary.hasWrittenBackItem(sessionId: sessionId, module: .culling)
    }

    /// 存在**实际交付了文件**的成功导出任务（审查 D02）。
    ///
    /// 旧实现只查 status='succeeded'。执行器把单文件失败收集进结果后正常返回，
    /// 于是 exported=0 / failed=N 的全失败也被写成成功，工作区阶段徽章与待办随之
    /// 误报「已导出」。现在读 checkpoint 里的交付摘要：exported > 0 才算交付完成。
    ///
    /// 兼容：本次改动之前的历史成功任务没有摘要键，无法回溯区分，按原语义视为
    /// 已导出（不因为一次审计把老用户已有的工作区状态全部清掉）。
    private func hasSuccessfulExport(_ sessionId: String) throws -> Bool {
        let rows = try jobRepo.successfulExportCheckpoints(sessionId: sessionId, limit: 20)
        for raw in rows {
            guard !raw.isEmpty, let checkpoint = try? JSONValue.parse(raw) else {
                return true
            }
            guard let exported = checkpoint.objectValue?["exported"]?.numberValue else {
                return true
            }
            if exported > 0 { return true }
        }
        return false
    }

    /// TS: listFailedJobs —— scope_type='session' 的失败 job，按 updated_at 倒序，上限 10。
    private func listFailedJobs(_ sessionId: String) throws -> [WorkspaceFailedJob] {
        try jobRepo.failedJobs(sessionId: sessionId, limit: Self.maxFailedJobs).map { row in
            WorkspaceFailedJob(
                id: row.id,
                type: row.type,
                code: row.code,
                message: row.message
            )
        }
    }

    /// TS: latestScanJob —— 最近更新的 metadata.scan 行（scope_id = sessionId）。
    private func latestScanJob(_ sessionId: String) throws -> ScanJobRecord? {
        try jobRepo.latestScanJob(sessionId: sessionId)
    }

    /// TS: latestOkRun —— 最近一次成功的分析 run（status='ok'，ORDER BY id DESC）。
    private func latestOkRun(_ sessionId: String, kind: WorkspaceStaleAnalysisKind) throws -> AnalysisRunRecord? {
        try sessionRepo.latestAnalysisRun(sessionId: sessionId, kind: kind.rawValue)
    }

    /// TS: getOfflinePhotosCount —— 5 分钟 TTL 缓存 + COUNT(missing) 兜底。
    private func getOfflinePhotosCount(_ sessionId: String) throws -> Int {
        let now = clock()
        cacheLock.lock()
        let cached = offlinePhotosCache[sessionId]
        cacheLock.unlock()
        if let cached, now - cached.cachedAt < Self.offlinePhotosTTLMs {
            return cached.count
        }
        let count = try photoRepo.countByStatus(sessionId: sessionId, status: "missing")
        cacheLock.lock()
        offlinePhotosCache[sessionId] = (count, now)
        cacheLock.unlock()
        return count
    }

    /// 交付摘要投影：`DeliverySummaryQuery.metadataSummary` 把本会话的交付聚合成
    /// 旧 MetadataSyncSummary（一交付一行）。只统计 culling / face-keyword /
    /// similarity 三个写回模块；同一共享 sidecar 可能同时命中多个模块的摘要，按
    /// xmpPath 合并并取最高严重度，避免重复计数（计数单位仍是 sidecar 交付，不是 item）。
    ///
    /// 与旧 outbox 计数的差异：手动队列（MetadataMutationService）在 2b-2 之前仍写
    /// 旧表，这些尚未产生交付行的手动变更不再进入工作区 xmp 计数（过渡缺口，见文件头）。
    private func summaryCounts(_ sessionId: String) throws -> (pending: Int, failed: Int, conflict: Int) {
        var statusByPath: [String: MetadataSyncStatus] = [:]
        for module in [DeliveryModule.culling, .faceKeyword, .similarity] {
            let summary = try deliverySummary.metadataSummary(sessionId: sessionId, module: module)
            for item in summary.items {
                statusByPath[item.xmpPath] = Self.mergedStatus(
                    statusByPath[item.xmpPath], item.status)
            }
        }
        var pending = 0
        var failed = 0
        var conflict = 0
        for status in statusByPath.values {
            switch status {
            case .pending: pending += 1
            case .failed: failed += 1
            case .conflict: conflict += 1
            default: break
            }
        }
        return (pending, failed, conflict)
    }

    /// 多模块命中同一交付时取最严重状态（conflict > failed > pending > writing >
    /// written > synced/clean/cleaned），与 DeliverySessionSummary.state 同一套优先级。
    private static func mergedStatus(
        _ existing: MetadataSyncStatus?,
        _ incoming: MetadataSyncStatus
    ) -> MetadataSyncStatus {
        guard let existing else { return incoming }
        return severity(existing) >= severity(incoming) ? existing : incoming
    }

    private static func severity(_ status: MetadataSyncStatus) -> Int {
        switch status {
        case .conflict: 5
        case .failed: 4
        case .pending: 3
        case .writing: 2
        case .written: 1
        case .synced, .cleaned, .clean: 0
        }
    }
}
