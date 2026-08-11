// desktop/native/gather-app/Tests/GatherAppTests/SimilarityViewModelTests.swift
// Phase 3.3 Similarity 视图模型行为测试。
// 覆盖：运行状态机（idle/running/result/error）、参数草稿（阈值/组大小/
// 分组模式/预设）、进度轮询、取消、重新聚类、阈值档切换（防抖 + 过期守卫）、
// 结果采纳清空选择、挂载恢复；集成用例用真实临时 SQLite + 路由直连
// （sim.result 直读 + sim.analyze 全链路复用预置 hash）。

import Foundation
import Testing
@testable import GatherApp
@testable import GatherCore

// MARK: - 支撑

/// 测试可控制的放行闸（对齐 SimilarityServiceTests 的 AsyncGate）。
private final class AsyncGate {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        let mustWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if released { return false }
            return true
        }()
        guard mustWait else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

// MARK: - Stub（状态机注入）

private final class StubSimilarityProvider: SimilarityDataProvider {
    var result: SimilarityResult?
    var tiers: [Int: SimilarityResult] = [:]
    var jobs: [AnalysisJobData] = []
    var resultError: String?
    var analyzeError: String?
    var reclusterError: String?
    var analyzeGate: AsyncGate?
    var reclusterResults: [SimilarityResult] = []
    private(set) var analyzeCalls: [(threshold: Int?, minGroupSize: Int?, groupingMode: SimilarityGroupingMode)] = []
    private(set) var cancelCalls: [String] = []
    private(set) var reclusterCalls: [(threshold: Int, minGroupSize: Int, groupingMode: SimilarityGroupingMode)] = []
    private(set) var resultCalls: [(sessionId: String, threshold: Int?)] = []

    func getResult(sessionId: String, threshold: Int?) throws -> SimilarityResult? {
        resultCalls.append((sessionId, threshold))
        if let resultError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: resultError])
        }
        if let threshold, let tier = tiers[threshold] { return tier }
        return result
    }

    func analyze(sessionId: String, threshold: Int?, minGroupSize: Int?, groupingMode: SimilarityGroupingMode) async throws {
        analyzeCalls.append((threshold, minGroupSize, groupingMode))
        if let analyzeGate { await analyzeGate.wait() }
        if let analyzeError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: analyzeError])
        }
    }

    func cancelAnalysis(sessionId: String) async throws -> Bool {
        cancelCalls.append(sessionId)
        return true
    }

    func recluster(sessionId: String, threshold: Int, minGroupSize: Int, groupingMode: SimilarityGroupingMode) async throws -> SimilarityResult {
        reclusterCalls.append((threshold, minGroupSize, groupingMode))
        if let reclusterError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: reclusterError])
        }
        return reclusterResults.removeFirst()
    }

    func listSimilarityJobs(sessionId: String) throws -> [AnalysisJobData] {
        jobs
    }

    func previewWriteback(sessionId: String, assignments: [SimilarityKeywordAssignment], threshold: Int?) throws -> WritebackPreview {
        WritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    }

    func writeback(sessionId: String, itemIds: [Int], threshold: Int?) async throws -> WritebackResult {
        WritebackResult(totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: "")
    }

    func retryFailedWriteback(sessionId: String) async throws -> WritebackResult {
        WritebackResult(totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: "")
    }

    func confirmSync(sessionId: String) throws {}

    func cleanupWriteback(sessionId: String) async throws -> CleanupResult {
        CleanupResult(deletedCount: 0, errors: [])
    }

    static func result(
        totalGroups: Int = 2,
        totalUngrouped: Int = 1,
        threshold: Double = 10,
        minGroupSize: Int = 2,
        groupingMode: SimilarityGroupingMode = .global,
        precomputed: Bool? = nil
    ) -> SimilarityResult {
        let groups: [SimilarityGroup] = (0..<totalGroups).map { index in
            SimilarityGroup(
                id: index + 1,
                label: "Group \(index + 1)",
                count: 2,
                images: [SimilarityImage(path: "/vault/a\(index).NEF", representative: true),
                         SimilarityImage(path: "/vault/b\(index).JPG")]
            )
        }
        return SimilarityResult(
            groups: groups,
            ungrouped: (0..<totalUngrouped).map { SimilarityImage(path: "/vault/u\($0).NEF") },
            stats: SimilarityResultStats(
                totalGroups: totalGroups,
                totalUngrouped: totalUngrouped,
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                precomputed: precomputed
            )
        )
    }

    static func job(id: String, status: AnalysisJobStatus, current: Int = 0, total: Int = 0, message: String = "") -> AnalysisJobData {
        AnalysisJobData(
            id: id, type: .similarityAnalyze, scopeType: "session", scopeId: "s1",
            dedupeKey: "similarity.analyze:s1", status: status, priority: 0,
            progressCurrent: current, progressTotal: total, progressMessage: message,
            inputFingerprint: "", modelId: "", modelVersion: "", checkpoint: [:],
            attemptCount: 1, leaseOwner: "", heartbeatAt: "", errorCode: "",
            errorMessage: "", createdAt: "2026-01-01T00:00:00.000Z", startedAt: "",
            finishedAt: "", updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }
}

/// 轮询等待条件成立（async 版：不阻塞 MainActor，防抖 Task 才能推进）。
@discardableResult
private func waitUntilAsync(
    timeout: TimeInterval = 5,
    interval: TimeInterval = 0.01,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(interval * 1000))
    }
    return condition()
}

@MainActor
private func makeStubVM(
    poll: Duration = .milliseconds(10),
    tierDelay: Duration = .milliseconds(5)
) -> (SimilarityViewModel, StubSimilarityProvider) {
    let stub = StubSimilarityProvider()
    return (SimilarityViewModel(sessionId: "s1", provider: stub, pollInterval: poll, tierDebounceDelay: tierDelay), stub)
}

// MARK: - 真实服务集成（临时 SQLite + 路由直连）

private func makeLiveProvider() throws -> (LiveSimilarityDataProvider, DBConnection) {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    let router = SessionCommandRouter.makeDefault(db: db)
    // JobService 需 start() 后 drain 才运行（TS index.ts:476 主进程启动语义；
    // 否则 sim.analyze job 永不执行，waitForResult 挂满超时）。
    router.jobService.start()
    return (LiveSimilarityDataProvider(router: router), db)
}

private func insertSession(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, '工作区', 'photos_loaded', 'idle', 'idle', 'folder', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id)])
}

/// 照片（checksum_file_size > 0 → analyze 的 stat 兜底直接取索引统计，
/// 无需真实文件）。
private func insertPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filepath: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, checksum_file_size, checksum_file_mtime_ms, status, metadata, result, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 100, 1000, 'online', '{}', '{}', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(sessionId), .text(filepath), .text((filepath as NSString).lastPathComponent)])
}

/// 预置相似度 hash（file_size/mtime 与索引统计一致 → analyze 直接复用）。
private func insertHash(_ db: DBConnection, sessionId: String, photoId: String, hashHex: String) throws {
    _ = try db.prepare("""
        INSERT INTO similarity_hashes (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
        VALUES (?, ?, ?, 100, 1000)
    """).run([.text(sessionId), .text(photoId), .text(hashHex)])
}

// MARK: - 用例

@MainActor
@Suite("SimilarityViewModel")
struct SimilarityViewModelTests {
    // ── 状态机：加载 ──

    // 无结果 → idle；有结果 → result + 参数同步（阈值恒同步；非预计算档
    // 组大小/分组模式也同步）。
    @Test func loadSettlesPhaseAndSyncsParams() async {
        let (viewModel, stub) = makeStubVM()
        await viewModel.load()
        #expect(viewModel.phase == .idle)
        #expect(viewModel.result == nil)

        stub.result = StubSimilarityProvider.result(threshold: 16, minGroupSize: 3, groupingMode: .sequential)
        await viewModel.load()
        #expect(viewModel.phase == .result)
        #expect(viewModel.result != nil)
        #expect(viewModel.threshold == 16)
        #expect(viewModel.minGroupSize == 3)
        #expect(viewModel.groupingMode == .sequential)
    }

    // 预计算档只同步阈值（草稿组大小/分组模式保留，TS lastSyncedResult 语义）。
    @Test func precomputedResultSyncsOnlyThreshold() async {
        let (viewModel, stub) = makeStubVM()
        stub.result = StubSimilarityProvider.result(threshold: 8, minGroupSize: 4, groupingMode: .sequential, precomputed: true)
        viewModel.minGroupSize = 5
        viewModel.groupingMode = .global
        await viewModel.load()
        #expect(viewModel.threshold == 8)
        #expect(viewModel.minGroupSize == 5, "预计算档不覆盖组大小草稿")
        #expect(viewModel.groupingMode == .global)
    }

    @Test func loadFailureSetsErrorPhase() async {
        let (viewModel, stub) = makeStubVM()
        stub.resultError = "SIM_QUERY_FAILED"
        await viewModel.load()
        #expect(viewModel.phase == .error("SIM_QUERY_FAILED"))
    }

    // 挂载恢复：jobs 中存在活跃 similarity.analyze → 恢复分析中状态与进度。
    @Test func loadRestoresRunningAnalysisFromJobs() async {
        let (viewModel, stub) = makeStubVM()
        stub.jobs = [StubSimilarityProvider.job(
            id: "j1", status: .running, current: 5, total: 20, message: "similarity.cluster"
        )]
        await viewModel.load()
        #expect(viewModel.isAnalyzing == true)
        #expect(viewModel.progressCurrent == 5)
        #expect(viewModel.progressTotal == 20)
        #expect(viewModel.progressMessage == "similarity.cluster")
    }

    // ── 状态机：分析运行/完成/取消 ──

    // 运行：isAnalyzing + 进度轮询（jobs.list 活跃任务）；闸放行后完成 →
    // 刷新结果 + 参数同步。
    @Test func analyzeRunsWithProgressAndCompletes() async throws {
        let (viewModel, stub) = makeStubVM()
        let gate = AsyncGate()
        stub.analyzeGate = gate
        // 分析期间轮询看到进度；完成后 jobs 清空。
        stub.jobs = [StubSimilarityProvider.job(
            id: "j1", status: .running, current: 7, total: 21, message: "similarity.hash"
        )]

        viewModel.startAnalyze()
        #expect(viewModel.isAnalyzing == true)
        // 轮询首帧即读到进度（poll 循环先读后睡）。
        try? await Task.sleep(for: .milliseconds(30))
        #expect(viewModel.progressCurrent == 7)
        #expect(viewModel.progressTotal == 21)
        #expect(viewModel.progressMessage == "similarity.hash")

        // 放行 → 分析完成 → 重新查询结果并同步参数。
        stub.jobs = []
        stub.result = StubSimilarityProvider.result(threshold: 12, minGroupSize: 2)
        gate.release()
        let deadline = Date().addingTimeInterval(2)
        while viewModel.isAnalyzing && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.isAnalyzing == false)
        #expect(viewModel.phase == .result)
        #expect(viewModel.threshold == 12)
        #expect(stub.analyzeCalls.count == 1)
        #expect(stub.analyzeCalls[0].threshold == SimilarityViewModel.defaultThreshold)
        #expect(stub.analyzeCalls[0].minGroupSize == SimilarityViewModel.defaultMinGroupSize)
        #expect(stub.analyzeCalls[0].groupingMode == .global)
    }

    // 分析失败（无既有结果）→ error 态。
    @Test func analyzeFailureSetsErrorPhase() async {
        let (viewModel, stub) = makeStubVM()
        stub.analyzeError = "SIM_NO_HASH_DATA"
        viewModel.startAnalyze()
        let deadline = Date().addingTimeInterval(2)
        while viewModel.isAnalyzing && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.isAnalyzing == false)
        #expect(viewModel.phase == .error("SIM_NO_HASH_DATA"))
    }

    // 取消：cancelAnalysis 委托 + 停止轮询 + 退出分析中。
    @Test func cancelStopsAnalysis() async {
        let (viewModel, stub) = makeStubVM()
        let gate = AsyncGate()
        stub.analyzeGate = gate
        stub.jobs = [StubSimilarityProvider.job(id: "j1", status: .running)]

        viewModel.startAnalyze()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(viewModel.isAnalyzing == true)

        await viewModel.cancelAnalysis()
        #expect(viewModel.isAnalyzing == false)
        #expect(stub.cancelCalls == ["s1"])
        // 进度轮询已停止：进度不再被推进。
        stub.jobs = [StubSimilarityProvider.job(id: "j1", status: .running, current: 9, total: 9)]
        try? await Task.sleep(for: .milliseconds(40))
        gate.release()
    }

    // ── 重新聚类 ──

    // recluster：新结果采纳（参数同步 + 清空选择）。
    @Test func reclusterAdoptsNewResultAndClearsSelection() async {
        let (viewModel, stub) = makeStubVM()
        stub.result = StubSimilarityProvider.result()
        await viewModel.load()
        viewModel.toggleGroupSelection(1)
        #expect(viewModel.selectedGroupIds == [1])

        stub.reclusterResults = [StubSimilarityProvider.result(totalGroups: 3, threshold: 20)]
        await viewModel.recluster()
        #expect(viewModel.isReclustering == false)
        #expect(viewModel.result?.stats.totalGroups == 3)
        #expect(viewModel.threshold == 20)
        #expect(viewModel.selectedGroupIds.isEmpty, "新结果采纳时清空旧选择")
        #expect(stub.reclusterCalls.count == 1)
        #expect(stub.reclusterCalls[0].threshold == 10)
        #expect(stub.reclusterCalls[0].minGroupSize == 2)
    }

    @Test func reclusterFailureKeepsExistingResult() async {
        let (viewModel, stub) = makeStubVM()
        stub.result = StubSimilarityProvider.result()
        await viewModel.load()

        stub.reclusterError = "SIM_NO_HASH_RECLUSTER"
        await viewModel.recluster()
        #expect(viewModel.result != nil)
        #expect(viewModel.errorMessage == "SIM_NO_HASH_RECLUSTER")
        #expect(viewModel.phase == .result, "既有结果不被重聚类失败推翻")
    }

    // ── 阈值档切换（TS tier 防抖 + 过期守卫）──

    // 草稿阈值命中预计算档 → 防抖后采纳（result.stats.threshold 校验）。
    @Test func thresholdDraftAdoptsMatchingTier() async {
        let (viewModel, stub) = makeStubVM(tierDelay: .milliseconds(5))
        stub.result = StubSimilarityProvider.result(threshold: 10)
        await viewModel.load()
        #expect(viewModel.threshold == 10)

        viewModel.threshold = 6
        stub.tiers[6] = StubSimilarityProvider.result(totalGroups: 4, threshold: 6)
        viewModel.thresholdDraftChanged()
        #expect(await waitUntilAsync { viewModel.result?.stats.threshold == 6 },
                "应采纳档 6，实际 \(viewModel.result?.stats.threshold ?? -1)")

        #expect(viewModel.result?.stats.totalGroups == 4)
        // 档位结果经过 getResult(sessionId, threshold: 6) 查询。
        #expect(stub.resultCalls.contains { $0.threshold == 6 })
    }

    // 无匹配档 → 保留草稿（不采纳、不报错）。
    @Test func thresholdDraftWithoutTierKeepsDraft() async {
        let (viewModel, stub) = makeStubVM(tierDelay: .milliseconds(5))
        stub.result = StubSimilarityProvider.result(threshold: 10)
        await viewModel.load()

        viewModel.threshold = 8
        viewModel.thresholdDraftChanged()
        // 防抖（5ms）后提交：无匹配档 → 不采纳（result 保持 10）。
        #expect(await waitUntilAsync { viewModel.threshold == 8 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(viewModel.result?.stats.threshold == 10)
        #expect(viewModel.threshold == 8, "草稿值保留")
    }

    // 快速连续拖动：仅最新请求采纳（tierRequestID 守卫）。
    @Test func rapidThresholdChangesAdoptOnlyLatest() async {
        let (viewModel, stub) = makeStubVM(tierDelay: .milliseconds(5))
        stub.result = StubSimilarityProvider.result(threshold: 10)
        await viewModel.load()

        // 档 6 与档 4 都命中；最后停在 4 → 只采纳 4。
        stub.tiers[6] = StubSimilarityProvider.result(totalGroups: 4, threshold: 6)
        stub.tiers[4] = StubSimilarityProvider.result(totalGroups: 5, threshold: 4)
        viewModel.threshold = 6
        viewModel.thresholdDraftChanged()
        viewModel.threshold = 4
        viewModel.thresholdDraftChanged()
        #expect(await waitUntilAsync { viewModel.result?.stats.threshold == 4 },
                "应只采纳最新档 4，实际 \(viewModel.result?.stats.threshold ?? -1)")

        #expect(viewModel.result?.stats.totalGroups == 5)
    }

    // 阈值回到结果档位 → 取消挂起请求。
    @Test func thresholdBackToResultCancelsPendingTier() async {
        let (viewModel, stub) = makeStubVM(tierDelay: .milliseconds(20))
        stub.result = StubSimilarityProvider.result(threshold: 10)
        await viewModel.load()

        viewModel.threshold = 6
        viewModel.thresholdDraftChanged()
        viewModel.threshold = 10
        viewModel.thresholdDraftChanged()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.result?.stats.threshold == 10)
    }

    // ── 预设（TS strict/balanced/loose）──

    @Test func presetsMapToTSValues() async {
        let (viewModel, _) = makeStubVM()
        #expect(viewModel.activePreset == "balanced")
        viewModel.applyPreset("strict")
        #expect(viewModel.threshold == 6)
        #expect(viewModel.minGroupSize == 2)
        #expect(viewModel.activePreset == "strict")
        viewModel.applyPreset("loose")
        #expect(viewModel.threshold == 16)
        #expect(viewModel.minGroupSize == 3)
        #expect(viewModel.activePreset == "loose")
        // 草稿值不匹配任何预设。
        viewModel.threshold = 12
        #expect(viewModel.activePreset == nil)
    }

    // ── 分组选择 ──

    @Test func selectionToggleAndSelectAll() async {
        let (viewModel, stub) = makeStubVM()
        stub.result = StubSimilarityProvider.result(totalGroups: 3)
        await viewModel.load()

        viewModel.toggleGroupSelection(2)
        viewModel.toggleGroupSelection(3)
        #expect(viewModel.selectedGroupIds == [2, 3])
        viewModel.setAllGroupsSelected(true)
        #expect(viewModel.selectedGroupIds == [1, 2, 3])
        viewModel.setAllGroupsSelected(false)
        #expect(viewModel.selectedGroupIds.isEmpty)
    }

    // ── 真实服务集成 ──

    // 真实库：sim.result 直读预置结果（groups_json 旧格式路径，无需成员表）。
    @Test func liveProviderReadsSeededResult() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        let groupsJSON = """
        {"groups":[{"id":1,"label":"Group 1","count":2,"images":[{"path":"/vault/a.NEF","representative":true},{"path":"/vault/b.JPG"}]}],"ungrouped":[{"path":"/vault/u.NEF"}]}
        """
        let statsJSON = """
        {"totalGroups":1,"totalUngrouped":1,"threshold":10,"minGroupSize":2,"groupingMode":"global"}
        """
        _ = try db.prepare("""
            INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES ('s1', ?, ?, 10, 2, '2026-01-01T00:00:00.000Z')
        """).run([.text(groupsJSON), .text(statsJSON)])

        let viewModel = SimilarityViewModel(sessionId: "s1", provider: provider)
        await viewModel.load()
        #expect(viewModel.phase == .result)
        let result = viewModel.result
        #expect(result?.stats.totalGroups == 1)
        #expect(result?.groups.count == 1)
        #expect(result?.groups[0].label == "Group 1")
        #expect(result?.groups[0].images.count == 2)
        #expect(result?.groups[0].images[0].representative == true)
        #expect(viewModel.threshold == 10)

        // 无结果会话 → idle。
        let empty = SimilarityViewModel(sessionId: "s2", provider: provider)
        await empty.load()
        #expect(empty.phase == .idle)
    }

    // 真实库全链路：sim.analyze（JobService executor）复用预置 hash →
    // 聚类 1 组 3 张 → 完成刷新结果。
    @Test func liveAnalyzeClustersSeededHashes() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        // 三张同哈希照片（阈值 0 下 1 组 3 张）。
        for index in 0..<3 {
            try insertPhoto(db, id: "photo-\(index)", sessionId: "s1", filepath: "/vault/photo-\(index).NEF")
            try insertHash(db, sessionId: "s1", photoId: "photo-\(index)", hashHex: "ab" + String(repeating: "0", count: 62))
        }

        let viewModel = SimilarityViewModel(
            sessionId: "s1",
            provider: provider,
            pollInterval: .milliseconds(10)
        )
        viewModel.threshold = 0
        viewModel.startAnalyze()

        let deadline = Date().addingTimeInterval(10)
        while viewModel.isAnalyzing && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.isAnalyzing == false, "分析应在 10s 内完成")
        #expect(viewModel.phase == .result)
        let result = viewModel.result
        #expect(result?.stats.totalGroups == 1)
        #expect(result?.groups[0].count == 3)
        #expect(result?.stats.threshold == 0)
        // 进度帧断言不做：快路径下轮询必然错过（进度轮询行为已由
        // stub analyzeGate 测试覆盖，见 makeStubVM 进度用例）。
    }
}
