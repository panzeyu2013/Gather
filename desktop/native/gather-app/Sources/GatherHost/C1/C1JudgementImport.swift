// desktop/native/gather-app/Sources/GatherHost/C1/C1JudgementImport.swift
// M1（Wave4 / task-6）：从 AppBootstrap.swift 拆出的 C1 判断落库调度。
//
// 纯移动：类型/成员逐行未改，只补文件头与 import；装配仍在 AppBootstrap.makeScene / wire
// 里调用 makeService / scanStatusProvider / scheduleApply（同 target，internal 可见）。
import GatherProtocol
import GatherPersistence
import GatherApplication
import GatherUI
// MARK: - C1 判断落库调度（Wave2 / G3；入口统一在 AppImport.C1ImportCoordinator）

/// C1 判断的落库调度：导入钩子里只调度、不等待（导入返回速度不变）。
///
/// Wave5 batch7（A2/R5）：快照读取与 pending 队列已下沉到 AppImport（C1ImportCoordinator /
/// C1PendingJudgements），三个 C1 入口共用；本类型只保留"等 metadata.scan 终态再落库"
/// 的 DB 侧调度。
enum C1JudgementImport {
    /// 后台等本会话 metadata.scan 终态，再把 C1 rating/色标/pick/关键词写进新会话。
    ///
    /// 为什么不能立即写：metadata.scan 的 MetadataExtractionService 用整行 upsert 覆盖
    /// photo_metadata_cache（XMP 无 rating 时写回 0 / 空关键词），先写的判断会被清掉。
    /// 等待有上限（服务内默认 10 分钟）；仅扫描成功才落库（A2），否则跳过并在日志/report
    /// 记 skippedReason（失败/取消/超时写入会被后续成功扫描的整行 upsert 清掉）。
    /// 与 C1PendingJudgementReplay 共用同一 apply/scan-status 口径。
    static func makeService(database: DBConnection) -> C1ImportJudgementService {
        let cache = MetadataCacheRepo(connection: database)
        return C1ImportJudgementService(
            photos: PhotoRepo(connection: database),
            cache: cache,
            decisions: CullingDecisionRepo(connection: database),
            keywordIndex: KeywordIndexSync(
                index: KeywordRepo(connection: database),
                metadata: cache),
            transactions: database)
    }

    /// metadata.scan 状态读取（等待/重放共用；见 C1ScanJobSelection 的稳定排序）。
    static func scanStatusProvider(
        database: DBConnection
    ) -> @Sendable (String) throws -> String? {
        { id in
            // P2（Wave4b）：latestScanJob 只按 updated_at DESC，同毫秒并列时顺序不定。
            // 轮询阶段先看活跃扫描（廉价、与排序无关）；没有活跃扫描时才做一次
            // (updatedAt, id) 全序选择，避免等错 job 的终态。
            let repo = AnalysisJobRepo(connection: database)
            if try !repo.activeJobIDs(type: .metadataScan, scopeId: id).isEmpty {
                return AnalysisJobStatus.running.rawValue
            }
            let jobs = try repo.list(includeCheckpoint: false)
            return C1ScanJobSelection.latestScanStatus(jobs: jobs, sessionId: id)
        }
    }

    /// 调度落库；`onSkipped` 在扫描非 succeeded 时回调（Wave4c：登记 pending 重放）。
    static func scheduleApply(
        database: DBConnection,
        sessionId: String,
        judgements: [C1VariantJudgement],
        onSkipped: (@MainActor @Sendable (C1ImportJudgementReport) -> Void)? = nil
    ) {
        Task.detached(priority: .utility) {
            let service = Self.makeService(database: database)
            let report = await service.applyAfterIndexing(
                sessionId: sessionId,
                judgements: judgements,
                scanStatus: Self.scanStatusProvider(database: database))
            GatherLogger.log(
                "c1.judgements session=\(sessionId) applied=\(report.applied)"
                    + " missing=\(report.missing) ratings=\(report.ratings)"
                    + " labels=\(report.labels) keeps=\(report.keeps)"
                    + " keywords=\(report.keywords)"
                    + " manualPreserved=\(report.preservedManualDecisions)"
                    + " waited=\(report.waitedForIndexing) timedOut=\(report.indexingTimedOut)"
                    + " skippedReason=\(report.skippedReason ?? "-")"
                    + " errors=\(report.errors.count)",
                level: report.errors.isEmpty && report.skippedReason == nil ? .info : .warn)
            if report.skippedReason != nil, let onSkipped {
                await MainActor.run { onSkipped(report) }
            }
            guard report.applied > 0 else { return }
            await MainActor.run {
                // 广播挑片域变更：已挂载的挑片页/图库据此重拉星级、色标与决策。
                GatherEventCenter.postDomainChange(
                    .culling, sessionId: sessionId, origin: "c1-import-judgements")
            }
        }
    }
}
