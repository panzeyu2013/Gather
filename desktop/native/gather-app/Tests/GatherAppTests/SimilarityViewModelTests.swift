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

/// Swift 6 迁移：SimilarityDataProvider 现经协议继承 Sendable，测试替身必须可跨隔离域。
/// 可变状态全部收归 LockedBox（NSLock 保护的 @unchecked Sendable 锁盒）：result/tiers/
/// jobs/resultError/analyzeError/reclusterError/analyzeGate/reclusterResults/各类
/// Calls 记录/previewItems/syncItems/syncItemsError。对外属性一律经锁内 get/set 转发
/// （测试调用点不变）；stub 方法在临界区内取快照后立即释放锁，唯一 await（analyzeGate）
/// 在锁外执行，绝不持锁 await。
private final class StubSimilarityProvider: SimilarityDataProvider {
    private final class LockedBox: @unchecked Sendable {
        let lock = NSLock()
        var result: SimilarityResult?
        var tiers: [Int: SimilarityResult] = [:]
        var jobs: [AnalysisJobData] = []
        var resultError: String?
        var analyzeError: String?
        var reclusterError: String?
        var analyzeGate: AsyncGate?
        var reclusterResults: [SimilarityResult] = []
        var analyzeCalls: [(threshold: Int?, minGroupSize: Int?, groupingMode: SimilarityGroupingMode)] = []
        var cancelCalls: [String] = []
        var reclusterCalls: [(threshold: Int, minGroupSize: Int, groupingMode: SimilarityGroupingMode)] = []
        var resultCalls: [(sessionId: String, threshold: Int?)] = []
        var writebackCalls: [(itemIds: [Int], threshold: Int?, confirmed: Bool)] = []
        var retryCalls: [Bool] = []
        var cleanupCalls: [Bool] = []
        var previewItems: [WritebackItem] = []
        var syncItems: [WritebackItem] = []
        var syncItemsError: Error?
    }

    private let box = LockedBox()

    var result: SimilarityResult? {
        get { box.lock.withLock { box.result } }
        set { box.lock.withLock { box.result = newValue } }
    }

    var tiers: [Int: SimilarityResult] {
        get { box.lock.withLock { box.tiers } }
        set { box.lock.withLock { box.tiers = newValue } }
    }

    var jobs: [AnalysisJobData] {
        get { box.lock.withLock { box.jobs } }
        set { box.lock.withLock { box.jobs = newValue } }
    }

    var resultError: String? {
        get { box.lock.withLock { box.resultError } }
        set { box.lock.withLock { box.resultError = newValue } }
    }

    var analyzeError: String? {
        get { box.lock.withLock { box.analyzeError } }
        set { box.lock.withLock { box.analyzeError = newValue } }
    }

    var reclusterError: String? {
        get { box.lock.withLock { box.reclusterError } }
        set { box.lock.withLock { box.reclusterError = newValue } }
    }

    var analyzeGate: AsyncGate? {
        get { box.lock.withLock { box.analyzeGate } }
        set { box.lock.withLock { box.analyzeGate = newValue } }
    }

    var reclusterResults: [SimilarityResult] {
        get { box.lock.withLock { box.reclusterResults } }
        set { box.lock.withLock { box.reclusterResults = newValue } }
    }

    var analyzeCalls: [(threshold: Int?, minGroupSize: Int?, groupingMode: SimilarityGroupingMode)] {
        box.lock.withLock { box.analyzeCalls }
    }

    var cancelCalls: [String] {
        box.lock.withLock { box.cancelCalls }
    }

    var reclusterCalls: [(threshold: Int, minGroupSize: Int, groupingMode: SimilarityGroupingMode)] {
        box.lock.withLock { box.reclusterCalls }
    }

    var resultCalls: [(sessionId: String, threshold: Int?)] {
        box.lock.withLock { box.resultCalls }
    }

    /// 确认语义：记录破坏性命令的调用与 confirmed 取值。
    var writebackCalls: [(itemIds: [Int], threshold: Int?, confirmed: Bool)] {
        box.lock.withLock { box.writebackCalls }
    }

    var retryCalls: [Bool] {
        box.lock.withLock { box.retryCalls }
    }

    var cleanupCalls: [Bool] {
        box.lock.withLock { box.cleanupCalls }
    }

    var previewItems: [WritebackItem] {
        get { box.lock.withLock { box.previewItems } }
        set { box.lock.withLock { box.previewItems = newValue } }
    }

    /// sim.writeback_items 行（syncControls 状态机数据源）：默认空（→ synced），
    /// 可注入行状态驱动 syncing/c1Read/failed/conflict；可注入错误驱动错误态。
    /// 协议默认实现恒返回 [] —— 不覆写会让整个 syncControls 门控矩阵 0 覆盖。
    var syncItems: [WritebackItem] {
        get { box.lock.withLock { box.syncItems } }
        set { box.lock.withLock { box.syncItems = newValue } }
    }

    var syncItemsError: Error? {
        get { box.lock.withLock { box.syncItemsError } }
        set { box.lock.withLock { box.syncItemsError = newValue } }
    }

    func getResult(sessionId: String, threshold: Int?) throws -> SimilarityResult? {
        let (error, tier, result): (String?, SimilarityResult?, SimilarityResult?) = box.lock.withLock {
            box.resultCalls.append((sessionId, threshold))
            let tier = threshold.flatMap { box.tiers[$0] }
            return (box.resultError, tier, box.result)
        }
        if let error {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        if let tier { return tier }
        return result
    }

    func analyze(sessionId: String, threshold: Int?, minGroupSize: Int?, groupingMode: SimilarityGroupingMode) async throws {
        let (gate, error): (AsyncGate?, String?) = box.lock.withLock {
            box.analyzeCalls.append((threshold, minGroupSize, groupingMode))
            return (box.analyzeGate, box.analyzeError)
        }
        if let gate { await gate.wait() }
        if let error {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    func cancelAnalysis(sessionId: String) async throws -> Bool {
        box.lock.withLock { box.cancelCalls.append(sessionId) }
        return true
    }

    func recluster(sessionId: String, threshold: Int, minGroupSize: Int, groupingMode: SimilarityGroupingMode) async throws -> SimilarityResult {
        try box.lock.withLock {
            box.reclusterCalls.append((threshold, minGroupSize, groupingMode))
            if let reclusterError = box.reclusterError {
                throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: reclusterError])
            }
            return box.reclusterResults.removeFirst()
        }
    }

    func listSimilarityJobs(sessionId: String) throws -> [AnalysisJobData] {
        box.lock.withLock { box.jobs }
    }

    func previewWriteback(sessionId: String, assignments: [SimilarityKeywordAssignment], threshold: Int?) async throws -> WritebackPreview {
        let items = box.lock.withLock { box.previewItems }
        return WritebackPreview(items: items, totalCount: items.count, affectedPhotos: items.count)
    }

    func writeback(sessionId: String, itemIds: [Int], threshold: Int?, confirmed: Bool) async throws -> WritebackResult {
        box.lock.withLock { box.writebackCalls.append((itemIds, threshold, confirmed)) }
        return WritebackResult(totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: "")
    }

    func retryFailedWriteback(sessionId: String, confirmed: Bool) async throws -> WritebackResult {
        box.lock.withLock { box.retryCalls.append(confirmed) }
        return WritebackResult(totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: "")
    }

    func confirmSync(sessionId: String) async throws {}

    func syncStateItems(sessionId: String) throws -> [WritebackItem] {
        let (error, items): (Error?, [WritebackItem]) = box.lock.withLock { (box.syncItemsError, box.syncItems) }
        if let error { throw error }
        return items
    }

    func cleanupWriteback(sessionId: String, confirmed: Bool) async throws -> CleanupResult {
        box.lock.withLock { box.cleanupCalls.append(confirmed) }
        return CleanupResult(deletedCount: 0, errors: [])
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

    /// 可写回的预览项（含 id，供 sim.writeback 的 itemIds 断言）。
    /// syncControls 矩阵用的最简行（仅 xmpStatus 参与状态机）。
    static func writebackItem(status: String) -> WritebackItem {
        WritebackItem(
            id: 1, photoId: "photo-1", photoPath: "/vault/photo-1.NEF", sessionId: "s1",
            module: "similarity", keywords: ["旅行"], xmpPath: "/vault/photo-1.xmp",
            backupPath: "", xmpStatus: status, errorMessage: "", attemptCount: 0,
            lastAttemptAt: "", preview: nil
        )
    }

    static let previewItem = WritebackItem(
        id: 1,
        photoId: "photo-1",
        photoPath: "/vault/photo-1.NEF",
        sessionId: "s1",
        module: "similarity",
        keywords: ["旅行"],
        xmpPath: "/vault/photo-1.xmp",
        backupPath: "",
        xmpStatus: "pending",
        errorMessage: "",
        attemptCount: 0,
        lastAttemptAt: "",
        preview: nil
    )

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

// 条件等待 waitUntilAsync / awaitNegativeWindow 已抽到
// Support/AsyncWait.swift（本 target 共享）。

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
        INSERT INTO sessions (id, name, status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, '工作区', 'photos_loaded', 'idle', 'folder', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
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
        // 统一漏斗：未知码不再原样透出，回退通用文案（errorText 语义）。
        #expect(viewModel.phase == .error(GatherLocalization.errorText("SIM_QUERY_FAILED")))
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
        // 轮询首帧即读到进度（poll 循环先读后睡）：条件等待首帧，满足即返回。
        #expect(await waitUntilAsync { viewModel.progressCurrent == 7 })
        #expect(viewModel.progressCurrent == 7)
        #expect(viewModel.progressTotal == 21)
        #expect(viewModel.progressMessage == "similarity.hash")

        // 放行 → 分析完成 → 重新查询结果并同步参数。
        stub.jobs = []
        stub.result = StubSimilarityProvider.result(threshold: 12, minGroupSize: 2)
        gate.release()
        // 等终态：phase 在 isAnalyzing=false 之后的 refreshResult 里才置位。
        #expect(await waitUntilAsync { viewModel.phase == .result })
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
        #expect(await waitUntilAsync { viewModel.isAnalyzing == false })
        #expect(viewModel.isAnalyzing == false)
        #expect(viewModel.phase == .error(GatherLocalization.errorText("SIM_NO_HASH_DATA")))
    }

    // 取消：cancelAnalysis 委托 + 停止轮询 + 退出分析中。
    @Test func cancelStopsAnalysis() async {
        let (viewModel, stub) = makeStubVM()
        let gate = AsyncGate()
        stub.analyzeGate = gate
        stub.jobs = [StubSimilarityProvider.job(id: "j1", status: .running)]

        viewModel.startAnalyze()
        // 等分析任务真正起跑（analyze 已记录，随后挂在闸上）再断言运行态。
        #expect(await waitUntilAsync { stub.analyzeCalls.count == 1 })
        #expect(viewModel.isAnalyzing == true)

        await viewModel.cancelAnalysis()
        #expect(viewModel.isAnalyzing == false)
        #expect(stub.cancelCalls == ["s1"])
        // 进度轮询已停止：把任务进度改成 9/9，跨过 ≥3 个轮询周期（10ms）后，
        // 进度不得再被写进 VM。原实现只 sleep 40ms 却没有任何断言，这里补上
        // 真正的竞态断言（负向断言无法「满足即返回」，只能用有界窗口）。
        stub.jobs = [StubSimilarityProvider.job(id: "j1", status: .running, current: 9, total: 9)]
        await awaitNegativeWindow(.milliseconds(30))
        #expect(viewModel.progressCurrent == 0, "取消后进度轮询必须停止")
        #expect(viewModel.progressTotal == 0)
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
        #expect(viewModel.errorMessage == GatherLocalization.errorText("SIM_NO_HASH_RECLUSTER"))
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
        // 同上：轮询不参与本用例断言，拉长以避免并行负载下的假失败。
        let (viewModel, stub) = makeStubVM(poll: .seconds(3600), tierDelay: .milliseconds(5))
        stub.result = StubSimilarityProvider.result(threshold: 10)
        await viewModel.load()

        viewModel.threshold = 8
        viewModel.thresholdDraftChanged()
        // 防抖（5ms）后必然发起一次档位查询（resultCalls 记录），查询即判定：
        // 等它落定后断言「无匹配档 → 不采纳（result 保持 10）」。
        #expect(await waitUntilAsync { stub.resultCalls.contains { $0.threshold == 8 } })
        #expect(viewModel.result?.stats.threshold == 10)
        #expect(viewModel.threshold == 8, "草稿值保留")
    }

    // 快速连续拖动：仅最新请求采纳（tierRequestID 守卫）。
    @Test func rapidThresholdChangesAdoptOnlyLatest() async {
        // 轮询拉长到 1 小时：本用例断言的是「只采纳最新档」的守卫，而不是轮询刷新。
        // 10ms 轮询在并行重负载下会把 stub 的默认结果写回来，使断言偶发失败
        //（把「时序竞争」误报成「守卫失效」）。
        let (viewModel, stub) = makeStubVM(poll: .seconds(3600), tierDelay: .milliseconds(5))
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
        // 同上：取消语义与轮询无关，轮询拉长避免干扰。
        let (viewModel, stub) = makeStubVM(poll: .seconds(3600), tierDelay: .milliseconds(10))
        stub.result = StubSimilarityProvider.result(threshold: 10)
        await viewModel.load()
        // 档 6 必须**真的有**预计算档：否则「没被采纳」与「取消生效」不可区分，
        // 断言恒真。补上该档后，若取消失效 result 会被改写成 6 → 断言可失败。
        stub.tiers[6] = StubSimilarityProvider.result(totalGroups: 4, threshold: 6)

        viewModel.threshold = 6
        viewModel.thresholdDraftChanged()
        viewModel.threshold = 10
        viewModel.thresholdDraftChanged()
        // 跨过 ≥3 个防抖周期（10ms）再断言：负向窗口必须等满。
        await awaitNegativeWindow(.milliseconds(30))
        #expect(viewModel.result?.stats.threshold == 10)
        #expect(stub.resultCalls.contains { $0.threshold == 6 } == false,
                "回到结果档位必须取消挂起请求")
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

    // ── 确认语义（假确认防线：取消不发命令，确认后才送 confirmed: true）──

    // sim.writeback：未确认（用户取消）绝不发命令；先预览再确认才真正写回。
    @Test func writebackRequiresConfirmation() async {
        let (viewModel, stub) = makeStubVM()
        stub.result = StubSimilarityProvider.result()
        stub.previewItems = [StubSimilarityProvider.previewItem]
        await viewModel.load()
        viewModel.toggleGroupSelection(1)
        viewModel.writebackKeywords = "旅行"

        await viewModel.executeKeywordWriteback(confirmed: false)
        #expect(stub.writebackCalls.isEmpty, "用户取消后不得发出 sim.writeback")

        await viewModel.previewKeywordWriteback()
        #expect(viewModel.writebackPreview != nil, "确认弹窗必须先拿到可展示影响范围的预览")

        await viewModel.executeKeywordWriteback(confirmed: true)
        #expect(stub.writebackCalls.count == 1)
        #expect(stub.writebackCalls[0].confirmed == true, "确认后必须真的发出写回")
        #expect(stub.writebackCalls[0].itemIds == [1])
    }

    // sim.retry_failed_writeback / sim.cleanup：未确认不发命令。
    @Test func retryAndCleanupRequireConfirmation() async {
        let (viewModel, stub) = makeStubVM()
        await viewModel.retryKeywordWriteback(confirmed: false)
        await viewModel.cleanupKeywordWriteback(confirmed: false)
        #expect(stub.retryCalls.isEmpty, "用户取消后不得发出 sim.retry_failed_writeback")
        #expect(stub.cleanupCalls.isEmpty, "用户取消后不得发出 sim.cleanup")
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

        #expect(await waitUntilAsync(timeout: 10) { viewModel.isAnalyzing == false },
                "分析应在 10s 超时内完成")
        #expect(viewModel.phase == .result)
        let result = viewModel.result
        #expect(result?.stats.totalGroups == 1)
        #expect(result?.groups[0].count == 3)
        #expect(result?.stats.threshold == 0)
        // 进度帧断言不做：快路径下轮询必然错过（进度轮询行为已由
        // stub analyzeGate 测试覆盖，见 makeStubVM 进度用例）。
    }

    // ── C1 同步状态机（sim.writeback_items 行计数 → aggregateSessionState）──
    //
    // 期望值与 CullingSyncFlowTests 的门控矩阵同源（TS deriveSyncControls），
    // 但 Similarity 走 core 的 aggregateSessionState：终态行在未 ack 时仍是
    // c1Read（而非 Culling 的 safeToCleanup）—— 这是有意的语义分歧，钉在此。

    /// 便捷构造：大多数期望值只关心三个布尔 + 状态文案。
    private func controls(
        _ load: Bool, _ confirm: Bool, _ cleanup: Bool,
        loadHint: String?, confirmHint: String?, cleanupHint: String?, status: String
    ) -> SimilaritySyncControls {
        SimilaritySyncControls(
            canLoadMetadata: load, canConfirmSync: confirm, canCleanup: cleanup,
            loadHint: loadHint, confirmHint: confirmHint, cleanupHint: cleanupHint,
            statusText: status)
    }

    @Test("syncControls：行状态 → 门控/提示/文案矩阵（含未加载与 core c1Read 语义）")
    func syncControlsMatrix() async {
        // 未加载（syncView == nil）→ 保守全禁用。
        let (fresh, _) = makeStubVM()
        AppLanguageLock.withCopy("zh-CN") {
            let loading = fresh.syncControls
            #expect(loading.canLoadMetadata == false)
            #expect(loading.canConfirmSync == false)
            #expect(loading.canCleanup == false)
            #expect(loading.statusText == "同步状态加载中…")
        }

        let confirmAckHint = "请先在 Capture One 中加载元数据，再确认同步"
        let cleanupWaitHint = "请先加载元数据并确认同步，再执行清理"
        let cases: [(label: String, rows: [String], expected: SimilaritySyncControls)] = [
            ("空行 → synced（全禁用）",
             [],
             controls(false, false, false,
                      loadHint: "已完成同步，无需再次加载元数据",
                      confirmHint: "已完成同步", cleanupHint: "已完成清理", status: "已同步")),
            ("pending → syncing（仅可加载）",
             ["pending"],
             controls(true, false, false,
                      loadHint: nil, confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: "同步中：Gather 正在写入 XMP…")),
            ("written → c1Read（未 ack 不可确认/清理）",
             ["written"],
             controls(true, false, false,
                      loadHint: nil, confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: "Gather 已写入，等待 C1 读取")),
            ("全终态行（synced）无 ack → c1Read（core 语义，非 safeToCleanup）",
             ["synced"],
             controls(true, false, false,
                      loadHint: nil, confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: "Gather 已写入，等待 C1 读取")),
            ("未知状态行 → c1Read（保守：绝不声称可清理）",
             ["weird"],
             controls(true, false, false,
                      loadHint: nil, confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: "Gather 已写入，等待 C1 读取")),
            ("failed → 全禁用 + 重试引导",
             ["failed"],
             controls(false, false, false,
                      loadHint: "存在写入失败项，请先重试",
                      confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: "有写入失败项，请先重试")),
            ("conflict → 全禁用 + 裁决引导",
             ["conflict"],
             controls(false, false, false,
                      loadHint: "存在 XMP 冲突，请先裁决",
                      confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: "存在 XMP 冲突，请先裁决")),
        ]
        // 回归用例：`syncStateItems` 曾只在协议扩展里定义、不是 protocol requirement，
        // 而 VM 的 provider 是 existential → 调用永远静态分发到扩展默认 []，注入的行
        // 读不到、syncView 恒 .synced、C1 同步面板永久全禁用（T4 变异审查发现的 P0）。
        // 现已声明为 requirement；本用例严格断言（不再用 withKnownIssue 包装）。
        for item in cases {
            let (viewModel, stub) = makeStubVM()
            stub.syncItems = item.rows.map(StubSimilarityProvider.writebackItem(status:))
            await viewModel.load()
            AppLanguageLock.withCopy("zh-CN") {
                #expect(viewModel.syncControls == item.expected, Comment(rawValue: item.label))
            }
        }
    }

    @Test("syncControls：行查询失败 → 保留全禁用 + 可见 errorMessage（不静默）")
    func syncControlsQueryFailureSurfaces() async {
        // 回归用例：requirement 化后 stub 的 throw 才会真正冒泡（修复前静态分发到默认 []）。
        let (viewModel, stub) = makeStubVM()
        stub.syncItemsError = NativeCommandError.failed("SIM_SYNC_ITEMS_FAILED")
        await viewModel.load()
        #expect(viewModel.errorMessage == GatherLocalization.errorText("SIM_SYNC_ITEMS_FAILED"))
        #expect(viewModel.syncControls.canLoadMetadata == false)
        #expect(viewModel.syncControls.canConfirmSync == false)
        #expect(viewModel.syncControls.canCleanup == false)
    }

    // MARK: 审计 5：浏览状态跨页签保留（C-1）与结果参数过期标记（B-2）

    @Test("C-1：展开态/显示全部在 VM 上保留（页面条件构建销毁不影响）")
    func browseStateSurvivesPageRebuild() async {
        let (viewModel, stub) = makeStubVM(poll: .seconds(3600))
        stub.result = StubSimilarityProvider.result(threshold: 10)
        await viewModel.load()
        viewModel.expandedGroupIds = [3]
        viewModel.showAllMemberGroupIds = [7]
        // 页面按目的地条件构建：离开即销毁、回来重建同一个 VM。
        // 状态在 VM 上所以仍然在（旧实现在视图 @State 上，重建即丢）。
        #expect(viewModel.expandedGroupIds == [3])
        #expect(viewModel.showAllMemberGroupIds == [7])
    }

    @Test("C-1：结果被替换时清空展开态（分组 id 可能已变）")
    func resultReplacementClearsBrowseState() async {
        let (viewModel, stub) = makeStubVM(poll: .seconds(3600), tierDelay: .milliseconds(5))
        stub.result = StubSimilarityProvider.result(threshold: 10)
        await viewModel.load()
        viewModel.expandedGroupIds = [1]
        stub.result = StubSimilarityProvider.result(totalGroups: 4, threshold: 10)
        await viewModel.load()
        #expect(viewModel.expandedGroupIds.isEmpty, "新结果不得沿用旧展开态")
    }

    @Test("B-2：改最小组合/分组范围后结果标记过期，回到原参数则不再过期")
    func resultGoesStaleOnGroupingParameterChange() async {
        let (viewModel, stub) = makeStubVM(poll: .seconds(3600))
        stub.result = StubSimilarityProvider.result(threshold: 10)
        await viewModel.load()
        #expect(!viewModel.isResultStale, "刚采纳的结果不该是过期状态")
        let originalMin = viewModel.minGroupSize
        viewModel.minGroupSize = originalMin + 3
        #expect(viewModel.isResultStale, "改最小组合后旧分组必须标记过期（B-2）")
        viewModel.minGroupSize = originalMin
        #expect(!viewModel.isResultStale)
        let originalMode = viewModel.groupingMode
        viewModel.groupingMode = originalMode == .global ? .sequential : .global
        #expect(viewModel.isResultStale, "改分组范围后同样应标记过期")
    }
}
