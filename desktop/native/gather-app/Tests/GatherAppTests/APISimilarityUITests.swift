// desktop/native/gather-app/Tests/GatherAppTests/APISimilarityUITests.swift
// Cut 1 / B4b：SimilarityViewModel 的 SimilarityAPI/JobAPI 注入路径。
//
// 覆盖：
// - result：load 通过 SimilarityAPI.result(SimilarityResultQuery) 采纳结果；
// - analyze：startAnalyze 的参数落到 SimilarityAPI，完成后刷新 result；
// - writeback：未确认不发命令，确认后 Confirmed<SimilarityWritebackInput>(.userDialog)
//   且 itemIds 来自预览、threshold 来自结果档；
// - cancelAnalysis：走 SimilarityAPI（不再发 sim.cancel_analysis 路由命令）。
//
// 旧 provider 构造器的行为仍由 SimilarityViewModelTests 覆盖；本文件只验证
// 生产 RootView 使用的 API 注入路径。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

// MARK: - Stub JobAPI（SimilarityAPI 复用 Support/StubSimilarityAPI.swift 的 B8SimilarityAPIStub）

private final class StubSimilarityJobAPI: JobAPI, @unchecked Sendable {
    private struct BoxState {
        var jobs: [AnalysisJobData] = []
        var listCalls = 0
    }

    private let box = LockedBox(BoxState())

    var jobs: [AnalysisJobData] {
        get { box.lock.withLock { box.jobs } }
        set { box.lock.withLock { box.jobs = newValue } }
    }

    var listCalls: Int { box.lock.withLock { box.listCalls } }

    func list(_ filter: JobListFilter) async throws -> [AnalysisJobData] {
        _ = filter
        return box.lock.withLock {
            box.listCalls += 1
            return box.jobs
        }
    }

    func cancel(_ jobId: String) async throws -> Bool {
        _ = jobId
        return false
    }

    func retry(_ jobId: String) async throws -> Bool {
        _ = jobId
        return false
    }

    func clearCompleted(_ input: Confirmed<ClearCompletedInput>) async throws -> Int {
        _ = input
        return 0
    }

    func start(_ request: JobRequest) async throws -> JobHandle {
        _ = request
        throw GatherError.invalidParameter(field: "job", reason: "not used in this stub")
    }
}

// MARK: - 夹具

private func similarityResult(
    totalGroups: Int = 2,
    threshold: Double = 10,
    minGroupSize: Int = 2,
    groupingMode: SimilarityGroupingMode = .global
) -> SimilarityResult {
    let groups: [SimilarityGroup] = (0..<totalGroups).map { index in
        SimilarityGroup(
            id: index + 1,
            label: "Group \(index + 1)",
            count: 1,
            images: [SimilarityImage(path: "/vault/\(index).NEF", representative: true)]
        )
    }
    return SimilarityResult(
        groups: groups,
        ungrouped: [],
        stats: SimilarityResultStats(
            totalGroups: totalGroups,
            totalUngrouped: 0,
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            precomputed: nil
        )
    )
}

private func similarityAnalysisJob(
    status: AnalysisJobStatus,
    current: Int = 0,
    total: Int = 0,
    message: String = ""
) -> AnalysisJobData {
    AnalysisJobData(
        id: "job-sim-1",
        type: .similarityAnalyze,
        scopeType: "session",
        scopeId: "s1",
        dedupeKey: "similarity.analyze:s1",
        status: status,
        priority: 0,
        progressCurrent: current,
        progressTotal: total,
        progressMessage: message,
        inputFingerprint: "",
        modelId: "",
        modelVersion: "",
        checkpoint: [:],
        attemptCount: 1,
        leaseOwner: "",
        heartbeatAt: "",
        errorCode: "",
        errorMessage: "",
        createdAt: "2026-01-01T00:00:00.000Z",
        startedAt: "",
        finishedAt: "",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func similarityWritebackItem() -> WritebackItem {
    WritebackItem(
        id: 11,
        photoId: "photo-11",
        photoPath: "/vault/photo-11.NEF",
        sessionId: "s1",
        module: "similarity",
        keywords: ["旅行"],
        xmpPath: "/vault/photo-11.xmp",
        backupPath: "",
        xmpStatus: "pending",
        errorMessage: "",
        attemptCount: 0,
        lastAttemptAt: "",
        preview: nil
    )
}

// MARK: - 用例

@Suite("SimilarityViewModel API 注入")
@MainActor
struct APISimilarityUITests {
    private func makeViewModel(
        _ api: B8SimilarityAPIStub,
        jobs: StubSimilarityJobAPI = StubSimilarityJobAPI()
    ) -> SimilarityViewModel {
        SimilarityViewModel(
            sessionId: "s1",
            similarity: api,
            jobs: jobs,
            // 布局/单测不需要真实计时器；拉长避免测试结束前空转。
            pollInterval: .seconds(3600),
            tierDebounceDelay: .milliseconds(5)
        )
    }

    @Test("result：load 通过 SimilarityAPI 查询并采纳结果")
    func loadUsesSimilarityAPIResult() async {
        let api = B8SimilarityAPIStub()
        api.resultValue = similarityResult(totalGroups: 3, threshold: 12)
        let viewModel = makeViewModel(api)

        await viewModel.load()

        #expect(viewModel.phase == .result)
        #expect(viewModel.result?.stats.totalGroups == 3)
        #expect(viewModel.threshold == 12)
        #expect(api.resultQueries.count >= 1)
        #expect(api.resultQueries[0].sessionId == "s1")
        #expect(api.resultQueries[0].threshold == nil, "load 读最近一档")
    }

    @Test("挂载恢复：JobAPI.list 的活跃 similarity.analyze 恢复进度")
    func loadRestoresActiveAnalysisJobFromJobAPI() async {
        let api = B8SimilarityAPIStub()
        api.resultValue = similarityResult()
        let jobs = StubSimilarityJobAPI()
        jobs.jobs = [similarityAnalysisJob(
            status: .running, current: 7, total: 21, message: "similarity.hash"
        )]
        let viewModel = makeViewModel(api, jobs: jobs)

        await viewModel.load()

        #expect(jobs.listCalls == 1)
        #expect(viewModel.isAnalyzing == true)
        #expect(viewModel.progressCurrent == 7)
        #expect(viewModel.progressTotal == 21)
        #expect(viewModel.progressMessage == "similarity.hash")
        viewModel.stopProgressPolling()
    }

    @Test("analyze：参数进 SimilarityAPI，完成后刷新 result")
    func analyzeUsesSimilarityAPI() async {
        let api = B8SimilarityAPIStub()
        api.resultValue = similarityResult(threshold: 10)
        let viewModel = makeViewModel(api)
        await viewModel.load()

        viewModel.threshold = 6
        viewModel.minGroupSize = 3
        viewModel.groupingMode = .sequential
        api.resultValue = similarityResult(
            totalGroups: 4, threshold: 6, minGroupSize: 3, groupingMode: .sequential
        )
        viewModel.startAnalyze()

        // 全量并行跑出的既有竞态：runAnalysis 先置 isAnalyzing=false / phase=.result，
        // 再 await refreshResult()。只等前两者会在刷新落地前读到旧 result（2 组），
        // 这里必须把「刷新后的值」一起纳入等待条件，断言才对应「完成后刷新」。
        #expect(await waitUntilAsync {
            viewModel.isAnalyzing == false
                && viewModel.phase == .result
                && viewModel.result?.stats.totalGroups == 4
        }, "分析应在测试结束前完成并刷新结果")

        #expect(api.analyzeInputs.count == 1)
        #expect(api.analyzeInputs[0].sessionId == "s1")
        #expect(api.analyzeInputs[0].threshold == 6)
        #expect(api.analyzeInputs[0].minGroupSize == 3)
        #expect(api.analyzeInputs[0].groupingMode == .sequential)
        #expect(viewModel.result?.stats.totalGroups == 4)
    }

    @Test("writeback：未确认不发命令；确认后 Confirmed(.userDialog) + 预览 itemIds")
    func writebackUsesConfirmedUserDialog() async {
        let api = B8SimilarityAPIStub()
        api.resultValue = similarityResult()
        api.previewValue = WritebackPreview(
            items: [similarityWritebackItem()], totalCount: 1, affectedPhotos: 1
        )
        let viewModel = makeViewModel(api)
        await viewModel.load()
        viewModel.toggleGroupSelection(1)
        viewModel.writebackKeywords = "旅行"

        await viewModel.previewKeywordWriteback()
        #expect(viewModel.writebackPreview != nil)
        #expect(api.previewInputs.count == 1)
        #expect(api.previewInputs[0].assignments.first?.groupId == 1)

        await viewModel.executeKeywordWriteback(confirmed: false)
        #expect(api.writebackInputs.isEmpty, "用户取消后不得发出写回")

        await viewModel.executeKeywordWriteback(confirmed: true)
        #expect(api.writebackInputs.count == 1)
        #expect(api.writebackInputs[0].source == .userDialog)
        #expect(api.writebackInputs[0].value.sessionId == "s1")
        #expect(api.writebackInputs[0].value.itemIds == [11])
        #expect(api.writebackInputs[0].value.threshold == 10)
    }

    @Test("cancelAnalysis：走 SimilarityAPI，不再发路由命令")
    func cancelUsesSimilarityAPI() async {
        let api = B8SimilarityAPIStub()
        api.resultValue = similarityResult()
        let viewModel = makeViewModel(api)
        await viewModel.load()
        await viewModel.cancelAnalysis()
        #expect(api.cancelCalls == ["s1"])
        #expect(viewModel.isAnalyzing == false)
    }
}
