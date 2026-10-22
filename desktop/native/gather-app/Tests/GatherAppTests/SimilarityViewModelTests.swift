// desktop/native/gather-app/Tests/GatherAppTests/SimilarityViewModelTests.swift
// Phase 3.3 Similarity 视图模型行为测试。
// 覆盖：运行状态机（idle/running/result/error）、参数草稿（阈值/组大小/
// 分组模式/预设）、进度轮询、取消、重新聚类、阈值档切换（防抖 + 过期守卫）、
// 结果采纳清空选择、挂载恢复；集成用例用真实临时 SQLite + 类型化 API
// （LiveSimilarityAPI + LiveJobAPI）。
//
// Cut 1 / B8.1a：状态机用例注入 B8SimilarityAPIStub + B5bJobAPIStub，
// 不再经过旧 provider 适配器或 字符串命令。

import Foundation
import Testing
@testable import GatherUI
@testable import GatherHost
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
import GatherTestSupport

// MARK: - 支撑

// AsyncGate / LockedBox / waitUntilAsync / awaitNegativeWindow 已在 Support 共享。

/// 类型化三依赖装配：Result/analyze/recluster/写回全部经 SimilarityAPI，
// 进度轮询经 JobAPI。
@MainActor
private func makeStubVM(
    poll: Duration = .milliseconds(10),
    resultPoll: Duration = .milliseconds(10),
    tierDelay: Duration = .milliseconds(5)
) -> (SimilarityViewModel, B8SimilarityAPIStub, B5bJobAPIStub) {
    let api = B8SimilarityAPIStub()
    let jobs = B5bJobAPIStub()
    let viewModel = SimilarityViewModel(
        sessionId: "s1",
        similarity: api,
        jobs: jobs,
        pollInterval: poll,
        resultPollInterval: resultPoll,
        tierDebounceDelay: tierDelay
    )
    return (viewModel, api, jobs)
}

// MARK: - 真实服务集成（临时 SQLite + 类型化 API）

private func makeLiveAPIs() throws -> (api: LiveSimilarityAPI, jobs: LiveJobAPI, db: DBConnection) {
    let db = try makeTestDB()
    let composition = AppComposition.make(db: db)
    // JobService 需先注册 executor 再 start() 才能运行（TS index.ts:476 主进程
    // 启动语义；否则 sim.analyze job 永不执行，waitForResult 挂满超时）。
    // runtime.start() 与生产组合根同一入口（注册 8 个 executor + JobService.start）。
    try composition.runtime.start()
    let api = LiveSimilarityAPI(
        similarityService: composition.similarityService,
        jobService: composition.jobService,
        settingsService: composition.settingsService
    )
    return (api, LiveJobAPI(jobService: composition.jobService), db)
}

private func insertSession(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, created_at, updated_at)
        VALUES (?, '工作区', 'photos_loaded', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id)])
}

/// 照片（V1 仍保留 checksum_file_size/mtime；analyze 的索引统计快路径
/// 直接复用它们，无需真实文件）。
private func insertPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filepath: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, checksum_file_size, checksum_file_mtime_ms, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 100, 1000, 'ready', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
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
@Suite("SimilarityViewModel", .serialized)
struct SimilarityViewModelTests {
    init() {
        // Cut 3 / 3b-3（E-19 相邻）：C1 会话同步状态聚合在生产由
        // AppBootstrap 注册（Host 适配器 → GatherDomain 唯一实现）；测试
        // 直接装同一实现，避免 UI 复制判定逻辑。
        CaptureOneSyncStateRulesRegistry.install(HostCaptureOneSyncStateRules())
    }

    // ── 状态机：加载 ──

    // 无结果 → idle；有结果 → result + 参数同步（阈值恒同步；非预计算档
    // 组大小/分组模式也同步）。
    @Test func loadSettlesPhaseAndSyncsParams() async {
        let (viewModel, api, _) = makeStubVM()
        await viewModel.load()
        #expect(viewModel.phase == .idle)
        #expect(viewModel.result == nil)

        api.resultValue = b8SimilarityResult(threshold: 16, minGroupSize: 3, groupingMode: .sequential)
        await viewModel.load()
        #expect(viewModel.phase == .result)
        #expect(viewModel.result != nil)
        #expect(viewModel.threshold == 16)
        #expect(viewModel.minGroupSize == 3)
        #expect(viewModel.groupingMode == .sequential)
    }

    // 预计算档只同步阈值（草稿组大小/分组模式保留，TS lastSyncedResult 语义）。
    @Test func precomputedResultSyncsOnlyThreshold() async {
        let (viewModel, api, _) = makeStubVM()
        api.resultValue = b8SimilarityResult(
            threshold: 8, minGroupSize: 4, groupingMode: .sequential, precomputed: true
        )
        viewModel.minGroupSize = 5
        viewModel.groupingMode = .global
        await viewModel.load()
        #expect(viewModel.threshold == 8)
        #expect(viewModel.minGroupSize == 5, "预计算档不覆盖组大小草稿")
        #expect(viewModel.groupingMode == .global)
    }

    @Test func loadFailureSetsErrorPhase() async throws {
        let (viewModel, api, _) = makeStubVM()
        api.resultError = NSError(
            domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: "SIM_QUERY_FAILED"]
        )
        await viewModel.load()
        // Cut 4 / 4a-3b-2a + 4c-3：phase.error 是页级错误的唯一存储来源，
        // errorMessage 只是它的只读代理；未知码不再原样透出，渲染期回退通用文案。
        let error = try #require(viewModel.errorMessage)
        #expect(viewModel.phase == .error(error))
        #expect(error.code.isEmpty)
        #expect(error.diagnostic == "SIM_QUERY_FAILED")
        #expect(
            CommandErrorText.resolve(error, with: L10n(language: .zhCN))
                == L10n(language: .zhCN).errorText("NOT_A_CODE")
        )
    }

    // 挂载恢复：jobs 中存在活跃 similarity.analyze → 恢复分析中状态与进度。
    @Test func loadRestoresRunningAnalysisFromJobs() async {
        let (viewModel, _, jobs) = makeStubVM()
        jobs.jobs = [b5bJobData(
            id: "j1",
            type: .similarityAnalyze,
            status: .running,
            scopeId: "s1",
            progressCurrent: 5,
            progressTotal: 20,
            progressMessage: "similarity.cluster"
        )]
        await viewModel.load()
        #expect(viewModel.isAnalyzing == true)
        #expect(viewModel.progressCurrent == 5)
        #expect(viewModel.progressTotal == 20)
        #expect(viewModel.progressMessage == "similarity.cluster")
        viewModel.stopProgressPolling()
    }

    // ── 状态机：分析运行/完成/取消 ──

    // 运行：isAnalyzing + 进度轮询（jobs.list 活跃任务）；闸放行后完成 →
    // 刷新结果 + 参数同步。
    @Test func analyzeRunsWithProgressAndCompletes() async throws {
        let (viewModel, api, jobs) = makeStubVM()
        let gate = AsyncGate()
        api.analyzeGate = gate
        // 分析期间轮询看到进度；完成后 jobs 清空。
        jobs.jobs = [b5bJobData(
            id: "j1",
            type: .similarityAnalyze,
            status: .running,
            scopeId: "s1",
            progressCurrent: 7,
            progressTotal: 21,
            progressMessage: "similarity.hash"
        )]

        // WP4d：默认不可见（PageVisibility）；页面挂载后才会推进进度轮询。
        viewModel.setVisible(true)
        viewModel.startAnalyze()
        #expect(viewModel.isAnalyzing == true)
        // 轮询首帧即读到进度（poll 循环先读后睡）：条件等待首帧，满足即返回。
        #expect(await waitUntilAsync { viewModel.progressCurrent == 7 })
        #expect(viewModel.progressCurrent == 7)
        #expect(viewModel.progressTotal == 21)
        #expect(viewModel.progressMessage == "similarity.hash")

        // 放行 → 分析完成 → 重新查询结果并同步参数。
        jobs.jobs = []
        api.resultValue = b8SimilarityResult(threshold: 12, minGroupSize: 2)
        gate.release()
        // 等终态：phase 在 isAnalyzing=false 之后的 refreshResult 里才置位。
        #expect(await waitUntilAsync { viewModel.phase == .result })
        #expect(viewModel.isAnalyzing == false)
        #expect(viewModel.phase == .result)
        #expect(viewModel.threshold == 12)
        #expect(api.analyzeInputs.count == 1)
        #expect(api.analyzeInputs[0].threshold == SimilarityViewModel.defaultThreshold)
        #expect(api.analyzeInputs[0].minGroupSize == SimilarityViewModel.defaultMinGroupSize)
        #expect(api.analyzeInputs[0].groupingMode == .global)
    }

    // 分析失败（无既有结果）→ error 态。
    @Test func analyzeFailureSetsErrorPhase() async throws {
        let (viewModel, api, _) = makeStubVM()
        api.analyzeError = NSError(
            domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: "SIM_NO_HASH_DATA"]
        )
        viewModel.startAnalyze()
        #expect(await waitUntilAsync { viewModel.isAnalyzing == false })
        #expect(viewModel.isAnalyzing == false)
        // Cut 4 / 4c-3：phase.error 是唯一存储，errorMessage 代理出同一 CommandError。
        let error = try #require(viewModel.errorMessage)
        #expect(viewModel.phase == .error(error))
        #expect(error.code == "SIM_NO_HASH_DATA")
    }

    // 取消：cancelAnalysis 委托 + 停止轮询 + 退出分析中。
    @Test func cancelStopsAnalysis() async {
        let (viewModel, api, jobs) = makeStubVM()
        let gate = AsyncGate()
        api.analyzeGate = gate
        jobs.jobs = [b5bJobData(
            id: "j1", type: .similarityAnalyze, status: .running, scopeId: "s1"
        )]

        viewModel.startAnalyze()
        // 等分析任务真正起跑（analyze 已记录，随后挂在闸上）再断言运行态。
        #expect(await waitUntilAsync { api.analyzeInputs.count == 1 })
        #expect(viewModel.isAnalyzing == true)

        await viewModel.cancelAnalysis()
        #expect(viewModel.isAnalyzing == false)
        #expect(api.cancelCalls == ["s1"])
        // 进度轮询已停止：把任务进度改成 9/9，跨过 ≥3 个轮询周期（10ms）后，
        // 进度不得再被写进 VM。原实现只 sleep 40ms 却没有任何断言，这里补上
        // 真正的竞态断言（负向断言无法「满足即返回」，只能用有界窗口）。
        jobs.jobs = [b5bJobData(
            id: "j1", type: .similarityAnalyze, status: .running, scopeId: "s1",
            progressCurrent: 9, progressTotal: 9
        )]
        await awaitNegativeWindow(.milliseconds(30))
        #expect(viewModel.progressCurrent == 0, "取消后进度轮询必须停止")
        #expect(viewModel.progressTotal == 0)
        gate.release()
    }

    // ── 重新聚类 ──

    // recluster：新结果采纳（参数同步 + 清空选择）。
    @Test func reclusterAdoptsNewResultAndClearsSelection() async {
        let (viewModel, api, _) = makeStubVM()
        api.resultValue = b8SimilarityResult()
        await viewModel.load()
        viewModel.toggleGroupSelection(1)
        #expect(viewModel.selectedGroupIds == [1])

        api.reclusterResults = [b8SimilarityResult(totalGroups: 3, threshold: 20)]
        await viewModel.recluster()
        #expect(viewModel.isReclustering == false)
        #expect(viewModel.result?.stats.totalGroups == 3)
        #expect(viewModel.threshold == 20)
        #expect(viewModel.selectedGroupIds.isEmpty, "新结果采纳时清空旧选择")
        #expect(api.reclusterInputs.count == 1)
        #expect(api.reclusterInputs[0].threshold == 10)
        #expect(api.reclusterInputs[0].minGroupSize == 2)
    }

    @Test func reclusterFailureKeepsExistingResult() async {
        let (viewModel, api, _) = makeStubVM()
        api.resultValue = b8SimilarityResult()
        await viewModel.load()

        api.reclusterError = NSError(
            domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: "SIM_NO_HASH_RECLUSTER"]
        )
        await viewModel.recluster()
        #expect(viewModel.result != nil)
        #expect(viewModel.errorMessage?.code == "SIM_NO_HASH_RECLUSTER")
        #expect(viewModel.phase == .result, "既有结果不被重聚类失败推翻")
    }

    // ── 阈值档切换（TS tier 防抖 + 过期守卫）──

    // 草稿阈值命中预计算档 → 防抖后采纳（result.stats.threshold 校验）。
    @Test func thresholdDraftAdoptsMatchingTier() async {
        let (viewModel, api, _) = makeStubVM(tierDelay: .milliseconds(5))
        api.resultValue = b8SimilarityResult(threshold: 10)
        await viewModel.load()
        #expect(viewModel.threshold == 10)

        viewModel.threshold = 6
        api.tiers[6] = b8SimilarityResult(totalGroups: 4, threshold: 6)
        viewModel.thresholdDraftChanged()
        #expect(await waitUntilAsync { viewModel.result?.stats.threshold == 6 },
                "应采纳档 6，实际 \(viewModel.result?.stats.threshold ?? -1)")

        #expect(viewModel.result?.stats.totalGroups == 4)
        // 档位结果经过 result(query threshold: 6) 查询。
        #expect(api.resultQueries.contains { $0.threshold == 6 })
    }

    // 无匹配档 → 保留草稿（不采纳、不报错）。
    @Test func thresholdDraftWithoutTierKeepsDraft() async {
        // 同上：轮询不参与本用例断言，拉长以避免并行负载下的假失败。
        let (viewModel, api, _) = makeStubVM(poll: .seconds(3600), tierDelay: .milliseconds(5))
        api.resultValue = b8SimilarityResult(threshold: 10)
        await viewModel.load()

        viewModel.threshold = 8
        viewModel.thresholdDraftChanged()
        // 防抖（5ms）后必然发起一次档位查询（resultQueries 记录），查询即判定：
        // 等它落定后断言「无匹配档 → 不采纳（result 保持 10）」。
        #expect(await waitUntilAsync { api.resultQueries.contains { $0.threshold == 8 } })
        #expect(viewModel.result?.stats.threshold == 10)
        #expect(viewModel.threshold == 8, "草稿值保留")
    }

    // 快速连续拖动：仅最新请求采纳（tierRequestID 守卫）。
    @Test func rapidThresholdChangesAdoptOnlyLatest() async {
        // 轮询拉长到 1 小时：本用例断言的是「只采纳最新档」的守卫，而不是轮询刷新。
        // 10ms 轮询在并行重负载下会把 stub 的默认结果写回来，使断言偶发失败
        //（把「时序竞争」误报成「守卫失效」）。
        let (viewModel, api, _) = makeStubVM(poll: .seconds(3600), tierDelay: .milliseconds(5))
        api.resultValue = b8SimilarityResult(threshold: 10)
        await viewModel.load()

        // 档 6 与档 4 都命中；最后停在 4 → 只采纳 4。
        api.tiers[6] = b8SimilarityResult(totalGroups: 4, threshold: 6)
        api.tiers[4] = b8SimilarityResult(totalGroups: 5, threshold: 4)
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
        let (viewModel, api, _) = makeStubVM(poll: .seconds(3600), tierDelay: .milliseconds(10))
        api.resultValue = b8SimilarityResult(threshold: 10)
        await viewModel.load()
        // 档 6 必须**真的有**预计算档：否则「没被采纳」与「取消生效」不可区分，
        // 断言恒真。补上该档后，若取消失效 result 会被改写成 6 → 断言可失败。
        api.tiers[6] = b8SimilarityResult(totalGroups: 4, threshold: 6)

        viewModel.threshold = 6
        viewModel.thresholdDraftChanged()
        viewModel.threshold = 10
        viewModel.thresholdDraftChanged()
        // 跨过 ≥3 个防抖周期（10ms）再断言：负向窗口必须等满。
        await awaitNegativeWindow(.milliseconds(30))
        #expect(viewModel.result?.stats.threshold == 10)
        #expect(api.resultQueries.contains { $0.threshold == 6 } == false,
                "回到结果档位必须取消挂起请求")
    }

    // ── 预设（TS strict/balanced/loose）──

    @Test func presetsMapToTSValues() async {
        let (viewModel, _, _) = makeStubVM()
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
        let (viewModel, api, _) = makeStubVM()
        api.resultValue = b8SimilarityResult(totalGroups: 3)
        await viewModel.load()

        viewModel.toggleGroupSelection(2)
        viewModel.toggleGroupSelection(3)
        #expect(viewModel.selectedGroupIds == [2, 3])
        viewModel.setAllGroupsSelected(true)
        #expect(viewModel.selectedGroupIds == [1, 2, 3])
        viewModel.setAllGroupsSelected(false)
        #expect(viewModel.selectedGroupIds.isEmpty)
    }

    // ── 确认语义（假确认防线：取消不发 API，确认后才送 Confirmed(.userDialog)）──

    // sim.writeback：未确认绝不调用 API；先预览再确认才真正写回。
    @Test func writebackRequiresConfirmation() async {
        let (viewModel, api, _) = makeStubVM()
        api.resultValue = b8SimilarityResult()
        api.previewValue = WritebackPreview(
            items: [b8SimilarityWritebackItem()], totalCount: 1, affectedPhotos: 1
        )
        await viewModel.load()
        viewModel.toggleGroupSelection(1)
        viewModel.writebackKeywords = "旅行"

        await viewModel.executeKeywordWriteback(confirmed: false)
        #expect(api.writebackInputs.isEmpty, "用户取消后不得调用 SimilarityAPI.writeback")
        // 取消文案只存 key，渲染期才解析（Cut 4 / 4b-2c）。
        #expect(viewModel.notice?.resolve(with: L10n(language: .zhCN)) == "未确认，已取消写入")

        await viewModel.previewKeywordWriteback()
        #expect(viewModel.writebackPreview != nil, "确认弹窗必须先拿到可展示影响范围的预览")
        #expect(api.previewInputs.count == 1)
        #expect(api.previewInputs[0].assignments.first?.groupId == 1)

        await viewModel.executeKeywordWriteback(confirmed: true)
        #expect(api.writebackInputs.count == 1)
        #expect(api.writebackInputs[0].source == .userDialog, "确认后必须真的发出写回")
        #expect(api.writebackInputs[0].value.itemIds == [1])
        #expect(api.writebackInputs[0].value.threshold == 10)
    }

    // 取消文案：notice 只存 key + 动作名（LocalizedText），渲染期一起解析，
    // 切语言后不会留下旧语言的片段（Cut 4 / 4b-2c）。
    @Test func cancellationNoticeResolvesAtRenderTime() {
        let (viewModel, _, _) = makeStubVM()
        viewModel.reportCancellation(LocalizedText("写入 XMP"))
        #expect(viewModel.notice?.resolve(with: L10n(language: .zhCN))
                == "已取消“写入 XMP”，未执行任何更改")
        #expect(viewModel.notice?.resolve(with: L10n(language: .en))
                == "Cancelled “Write XMP”; nothing was changed")
        #expect(viewModel.errorMessage == nil)
    }

    // sim.retry_failed_writeback / sim.cleanup：未确认不调用 API。
    @Test func retryAndCleanupRequireConfirmation() async {
        let (viewModel, api, _) = makeStubVM()
        await viewModel.retryKeywordWriteback(confirmed: false)
        await viewModel.cleanupKeywordWriteback(confirmed: false)
        #expect(api.retryInputs.isEmpty, "用户取消后不得调用 SimilarityAPI.retryFailedWriteback")
        #expect(api.cleanupInputs.isEmpty, "用户取消后不得调用 SimilarityAPI.cleanup")
    }

    // ── 真实服务集成 ──

    // 真实库：sim.result 直读预置结果（groups_json 旧格式路径，无需成员表）。
    @Test func liveProviderReadsSeededResult() async throws {
        let live = try makeLiveAPIs()
        try insertSession(live.db, "s1")
        let groupsJSON = """
        {"groups":[{"id":1,"label":"Group 1","count":2,"images":[{"path":"/vault/a.NEF","representative":true},{"path":"/vault/b.JPG"}]}],"ungrouped":[{"path":"/vault/u.NEF"}]}
        """
        let statsJSON = """
        {"totalGroups":1,"totalUngrouped":1,"threshold":10,"minGroupSize":2,"groupingMode":"global"}
        """
        _ = try live.db.prepare("""
            INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES ('s1', ?, ?, 10, 2, '2026-01-01T00:00:00.000Z')
        """).run([.text(groupsJSON), .text(statsJSON)])

        let viewModel = SimilarityViewModel(sessionId: "s1", similarity: live.api, jobs: live.jobs)
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
        let empty = SimilarityViewModel(sessionId: "s2", similarity: live.api, jobs: live.jobs)
        await empty.load()
        #expect(empty.phase == .idle)
        empty.stopResultPolling()
    }

    // 真实库全链路：sim.analyze（JobService executor）复用预置 hash →
    // 聚类 1 组 3 张 → 完成刷新结果。
    @Test func liveAnalyzeClustersSeededHashes() async throws {
        let live = try makeLiveAPIs()
        try insertSession(live.db, "s1")
        // 三张同哈希照片（阈值 0 下 1 组 3 张）。
        for index in 0..<3 {
            try insertPhoto(
                live.db, id: "photo-\(index)", sessionId: "s1",
                filepath: "/vault/photo-\(index).NEF"
            )
            try insertHash(
                live.db, sessionId: "s1", photoId: "photo-\(index)",
                hashHex: "ab" + String(repeating: "0", count: 62)
            )
        }

        let viewModel = SimilarityViewModel(
            sessionId: "s1",
            similarity: live.api,
            jobs: live.jobs,
            pollInterval: .milliseconds(10)
        )
        viewModel.threshold = 0
        viewModel.startAnalyze()

        // B4b：isAnalyzing 先于 refreshResult 落定，等 phase/结果一起满足，
        // 避免并行负载下在「分析结束 → 结果刷新中」的窗口里误判。
        #expect(await waitUntilAsync(timeout: 10) {
            viewModel.isAnalyzing == false && viewModel.phase == .result
        }, "分析应在 10s 超时内完成并刷新结果")
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
    ///
    /// Cut 4 / 4b-2c：提示/状态文案只存 key（LocalizedText），VM 不读进程级语言；
    /// 期望值因此也是 key，渲染期才由 L10n 解析（上方另断言一次中文解析结果）。
    private func controls(
        _ load: Bool, _ confirm: Bool, _ cleanup: Bool,
        loadHint: LocalizedText?, confirmHint: LocalizedText?, cleanupHint: LocalizedText?,
        status: LocalizedText
    ) -> SimilaritySyncControls {
        SimilaritySyncControls(
            canLoadMetadata: load, canConfirmSync: confirm, canCleanup: cleanup,
            loadHint: loadHint, confirmHint: confirmHint, cleanupHint: cleanupHint,
            statusText: status)
    }

    @Test("syncControls：行状态 → 门控/提示/文案矩阵（含未加载与 core c1Read 语义）")
    func syncControlsMatrix() async {
        // 未加载（syncView == nil）→ 保守全禁用。
        let (fresh, _, _) = makeStubVM()
        let loading = fresh.syncControls
        #expect(loading.canLoadMetadata == false)
        #expect(loading.canConfirmSync == false)
        #expect(loading.canCleanup == false)
        #expect(loading.statusText == LocalizedText("同步状态加载中…"))
        // 渲染期解析走显式 L10n（VM 已不读进程级语言，切语言不脏化已存值）。
        #expect(loading.statusText.resolve(with: L10n(language: .zhCN)) == "同步状态加载中…")

        let confirmAckHint = LocalizedText("请先在 Capture One 中加载元数据，再确认同步")
        let cleanupWaitHint = LocalizedText("请先加载元数据并确认同步，再执行清理")
        let readWaiting = LocalizedText("Gather 已写入，等待 C1 读取")
        let cases: [(label: String, rows: [String], expected: SimilaritySyncControls)] = [
            ("空行 → synced（全禁用）",
             [],
             controls(false, false, false,
                      loadHint: LocalizedText("已完成同步，无需再次加载元数据"),
                      confirmHint: LocalizedText("已完成同步"),
                      cleanupHint: LocalizedText("已完成清理"),
                      status: LocalizedText("已同步"))),
            ("pending → syncing（仅可加载）",
             ["pending"],
             controls(true, false, false,
                      loadHint: nil, confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: LocalizedText("同步中：Gather 正在写入 XMP…"))),
            ("written → c1Read（未 ack 不可确认/清理）",
             ["written"],
             controls(true, false, false,
                      loadHint: nil, confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: readWaiting)),
            ("全终态行（synced）无 ack → c1Read（core 语义，非 safeToCleanup）",
             ["synced"],
             controls(true, false, false,
                      loadHint: nil, confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: readWaiting)),
            ("未知状态行 → c1Read（保守：绝不声称可清理）",
             ["weird"],
             controls(true, false, false,
                      loadHint: nil, confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: readWaiting)),
            ("failed → 全禁用 + 重试引导",
             ["failed"],
             controls(false, false, false,
                      loadHint: LocalizedText("存在写入失败项，请先重试"),
                      confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: LocalizedText("有写入失败项，请先重试"))),
            ("conflict → 全禁用 + 裁决引导",
             ["conflict"],
             controls(false, false, false,
                      loadHint: LocalizedText("存在 XMP 冲突，请先裁决"),
                      confirmHint: confirmAckHint, cleanupHint: cleanupWaitHint,
                      status: LocalizedText("存在 XMP 冲突，请先裁决"))),
        ]
        // 回归用例：writebackItems 是 protocol requirement；注入的行必须被读到，
        // 否则 syncView 恒 .synced、C1 同步面板永久全禁用。
        for item in cases {
            let (viewModel, api, _) = makeStubVM()
            api.writebackItemsValue = item.rows.map {
                b8SimilarityWritebackItem(status: $0)
            }
            await viewModel.load()
            #expect(viewModel.syncControls == item.expected, Comment(rawValue: item.label))
        }
    }

    @Test("syncControls：行查询失败 → 保留全禁用 + 可见 errorMessage（不静默）")
    func syncControlsQueryFailureSurfaces() async {
        // 回归用例：异常必须从 SimilarityAPI 冒泡（不得被默认空数组吞掉）。
        let (viewModel, api, _) = makeStubVM()
        api.writebackItemsError = APIError.failed("SIM_SYNC_ITEMS_FAILED")
        await viewModel.load()
        #expect(viewModel.errorMessage?.code.isEmpty == true)
        #expect(viewModel.errorMessage?.diagnostic == "SIM_SYNC_ITEMS_FAILED")
        #expect(viewModel.syncControls.canLoadMetadata == false)
        #expect(viewModel.syncControls.canConfirmSync == false)
        #expect(viewModel.syncControls.canCleanup == false)
    }

    // MARK: 审计 5：浏览状态跨页签保留（C-1）与结果参数过期标记（B-2）

    @Test("C-1：展开态/显示全部在 VM 上保留（页面条件构建销毁不影响）")
    func browseStateSurvivesPageRebuild() async {
        let (viewModel, api, _) = makeStubVM(poll: .seconds(3600))
        api.resultValue = b8SimilarityResult(threshold: 10)
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
        let (viewModel, api, _) = makeStubVM(poll: .seconds(3600), tierDelay: .milliseconds(5))
        api.resultValue = b8SimilarityResult(threshold: 10)
        await viewModel.load()
        viewModel.expandedGroupIds = [1]
        api.resultValue = b8SimilarityResult(totalGroups: 4, threshold: 10)
        await viewModel.load()
        #expect(viewModel.expandedGroupIds.isEmpty, "新结果不得沿用旧展开态")
    }

    @Test("B-2：改最小组合/分组范围后结果标记过期，回到原参数则不再过期")
    func resultGoesStaleOnGroupingParameterChange() async {
        let (viewModel, api, _) = makeStubVM(poll: .seconds(3600))
        api.resultValue = b8SimilarityResult(threshold: 10)
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

    // MARK: - Cut 4 / 4a-2b：可见性钩子

    // 进度轮询：隐藏停（窗口内无 jobs.list），恢复起（按 isAnalyzing 重开），
    // shutdown 后 setVisible(true) 不得复活。
    @Test func setVisibleStopsAndResumesProgressPolling() async {
        let (viewModel, api, jobs) = makeStubVM(poll: .milliseconds(10))
        let gate = AsyncGate()
        api.analyzeGate = gate
        jobs.jobs = [b5bJobData(
            id: "j1", type: .similarityAnalyze, status: .running, scopeId: "s1"
        )]
        viewModel.setVisible(true)
        viewModel.startAnalyze()
        #expect(await waitUntilAsync { jobs.listFilters.count >= 1 })

        viewModel.setVisible(false)
        let stopped = jobs.listFilters.count
        await awaitNegativeWindow(.milliseconds(100))
        #expect(jobs.listFilters.count == stopped, "隐藏后不得继续轮询 jobs.list")

        viewModel.setVisible(true)
        #expect(await waitUntilAsync { jobs.listFilters.count > stopped }, "恢复可见后进度轮询必须重启")

        viewModel.shutdown()
        gate.release()
        viewModel.setVisible(true)
        let shutDown = jobs.listFilters.count
        await awaitNegativeWindow(.milliseconds(100))
        #expect(jobs.listFilters.count == shutDown, "shutdown 后 setVisible(true) 不得重启轮询")
    }

    // 结果轮询：无结果时的 2s 轮询同样随可见性启停，shutdown 后不复活。
    @Test func setVisibleStopsAndResumesResultPolling() async {
        let (viewModel, api, _) = makeStubVM(resultPoll: .milliseconds(10))
        viewModel.setVisible(true)
        #expect(await waitUntilAsync { api.resultQueries.count >= 1 })

        viewModel.setVisible(false)
        let stopped = api.resultQueries.count
        await awaitNegativeWindow(.milliseconds(100))
        #expect(api.resultQueries.count == stopped, "隐藏后不得继续轮询 sim.result")

        viewModel.setVisible(true)
        #expect(await waitUntilAsync { api.resultQueries.count > stopped }, "恢复可见后结果轮询必须重启")

        viewModel.shutdown()
        viewModel.setVisible(true)
        let shutDown = api.resultQueries.count
        await awaitNegativeWindow(.milliseconds(100))
        #expect(api.resultQueries.count == shutDown, "shutdown 后 setVisible(true) 不得重启结果轮询")
    }
}
