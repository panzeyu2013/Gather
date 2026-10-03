// desktop/native/gather-core/Sources/GatherCore/Services/WorkspaceStatusService.swift
// TS 源: desktop/src/main/services/workspace/workspace-status.service.ts（Phase 3.1 Dashboard 移植）
// 工作区状态只读聚合（design_improvements.md 1.4.1–1.4.5）：
// 不引入新的权威数据源，全部从现有 SQLite 表（photos / analysis_jobs /
// analysis_runs / writeback_items / metadata_outbox）+ MetadataOutboxRepo
// 派生。唯一允许的写入是 offlinePhotos 的内存 TTL 缓存。
//
// 与 TS 的差异：TS 注入 MetadataSyncCoordinator 取 getSummary()；Swift 侧按
// getSummary 的计数投影直接查询 MetadataOutboxRepo（countBySession 分组计数
// 为主，getSummaryRowsBySession 逐行过滤兜底），语义一致（见 summaryCounts）。
import Foundation

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

    private let connection: DBConnection
    private let sessionRepo: SessionRepo
    private let photoRepo: PhotoRepo
    private let outboxRepo: MetadataOutboxRepo

    /// TS: Date.now()（offlinePhotos TTL 判定用，测试注入时钟）。
    private let clock: () -> Int

    /// TS: offlinePhotosCache（Map<sessionId, { count, cachedAt }>）。
    private var offlinePhotosCache: [String: (count: Int, cachedAt: Int)] = [:]
    private let cacheLock = NSLock()

    public init(
        connection: DBConnection,
        sessionRepo: SessionRepo,
        photoRepo: PhotoRepo,
        outboxRepo: MetadataOutboxRepo,
        clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.connection = connection
        self.sessionRepo = sessionRepo
        self.photoRepo = photoRepo
        self.outboxRepo = outboxRepo
        self.clock = clock
    }

    /// 聚合整个工作区状态；session 不存在时返回 nil（IPC 层转 err）。
    public func getStatus(sessionId: String) throws -> WorkspaceStatus? {
        guard let session = try sessionRepo.get(id: sessionId) else { return nil }

        let photoCount = try photoRepo.countBySession(sessionId: sessionId)
        let scanJob = try latestScanJob(sessionId)
        // 索引 job 按 dedupeKey `metadata.scan:<sessionId>` 创建且终态行会被
        // 复用为 retry，因此同一 session 至多一条 metadata.scan 行；"最近一次
        // 索引 job 成功结束且此后无待处理变更" 即等价于该行 status 为
        // 'succeeded'（活跃行 updated_at 必然更新，若存在活跃工作则 latest 就是它）。
        // 该行是阶段证据（stage 'indexed'），job.service 的 clear_completed 排除了
        // metadata.scan / export.execute 两类证据行（见 job.service.ts 注释），
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
        similarityRun: AnalysisRunRow?,
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

    /// 已写回的挑片决策：writeback_items（批量写回，module='culling'）或
    /// metadata_outbox（交互式 culling 同步，source_module='culling'）任一
    /// 出现 written/synced 行即视为已写回；synced 行会被 cleanup 删除，故两态都要。
    private func hasWrittenBackCulling(_ sessionId: String) throws -> Bool {
        let viaWritebackItems = try connection.prepare("""
            SELECT 1 FROM writeback_items
            WHERE session_id = ? AND module = 'culling' AND xmp_status IN ('written', 'synced')
            LIMIT 1
          """).get([.text(sessionId)])
        if viaWritebackItems != nil { return true }
        let viaOutbox = try connection.prepare("""
            SELECT 1
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ? AND o.source_module = 'culling' AND o.status IN ('written', 'synced')
            LIMIT 1
          """).get([.text(sessionId)])
        return viaOutbox != nil
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
        let rows = try connection.prepare("""
            SELECT checkpoint_json FROM analysis_jobs
            WHERE type = 'export.execute' AND scope_id = ? AND status = 'succeeded'
            ORDER BY updated_at DESC
            LIMIT 20
          """).query([.text(sessionId)])
        for row in rows {
            let raw = row.first?.textValue ?? ""
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
        let rows = try connection.prepare("""
            SELECT id, type, error_message, error_code
            FROM analysis_jobs
            WHERE scope_type = 'session' AND scope_id = ? AND status = 'failed'
            ORDER BY updated_at DESC
            LIMIT \(Self.maxFailedJobs)
          """).query([.text(sessionId)])
        return rows.map { row in
            WorkspaceFailedJob(
                id: row[0].textValue ?? "",
                type: row[1].textValue ?? "",
                code: row[3].textValue ?? "",
                message: row[2].textValue ?? ""
            )
        }
    }

    /// TS: latestScanJob —— 最近更新的 metadata.scan 行（scope_id = sessionId）。
    private func latestScanJob(_ sessionId: String) throws -> ScanJobRow? {
        guard let row = try connection.prepare("""
            SELECT status, progress_current, progress_total
            FROM analysis_jobs
            WHERE type = 'metadata.scan' AND scope_id = ?
            ORDER BY updated_at DESC
            LIMIT 1
          """).get([.text(sessionId)]) else { return nil }
        return ScanJobRow(
            status: row[0].textValue ?? "",
            progressCurrent: Int(row[1].intValue ?? 0),
            progressTotal: Int(row[2].intValue ?? 0)
        )
    }

    /// TS: latestOkRun —— 最近一次成功的分析 run（status='ok'，ORDER BY id DESC）。
    private func latestOkRun(_ sessionId: String, kind: WorkspaceStaleAnalysisKind) throws -> AnalysisRunRow? {
        guard let row = try connection.prepare("""
            SELECT kind, index_seq, finished_at
            FROM analysis_runs
            WHERE session_id = ? AND kind = ? AND status = 'ok'
            ORDER BY id DESC
            LIMIT 1
          """).get([.text(sessionId), .text(kind.rawValue)]) else { return nil }
        return AnalysisRunRow(
            kind: kind,
            indexSeq: Int(row[1].intValue ?? 0),
            finishedAt: row[2].textValue ?? ""
        )
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
        let row = try connection.prepare("""
            SELECT COUNT(*) AS count FROM photos
            WHERE session_id = ? AND status = 'missing'
          """).get([.text(sessionId)])
        let count = Int(row?[0].intValue ?? 0)
        cacheLock.lock()
        offlinePhotosCache[sessionId] = (count, now)
        cacheLock.unlock()
        return count
    }

    /// 对齐 metadata-sync-coordinator.getSummary 的计数投影：countBySession 的
    /// 分组计数为主，缺失的状态键回退到 getSummaryRowsBySession 逐行过滤
    /// （与 TS `counts[status] ?? items.filter(...).length` 一致）。
    private func summaryCounts(_ sessionId: String) throws -> (pending: Int, failed: Int, conflict: Int) {
        let counts = try outboxRepo.countBySession(sessionId)
        let items = try outboxRepo.getSummaryRowsBySession(sessionId)
        func count(_ status: String) -> Int {
            if let c = counts[status] { return Int(c) }
            return items.filter { $0.status == status }.count
        }
        return (count("pending"), count("failed"), count("conflict"))
    }
}

/// TS: ScanJobRow。
private struct ScanJobRow {
    let status: String
    let progressCurrent: Int
    let progressTotal: Int
}

/// TS: AnalysisRunRow（kind 收窄为相似度/人脸两值）。
private struct AnalysisRunRow {
    let kind: WorkspaceStaleAnalysisKind
    let indexSeq: Int
    let finishedAt: String
}
