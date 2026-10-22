// desktop/native/gather-app/Tests/GatherAppTests/APIFaceUITests.swift
// Cut 1 / B4b：FaceKeywordingViewModel 的 FaceAPI/JobAPI 注入路径。
//
// 覆盖：
// - analyze：参数（eps/minSamples）落到 FaceAPI，结果状态机进入审核；
// - clusters/bind：reload 读 AppServices.face 的簇，bind 送角色/关键字；
// - 破坏性写回：未确认不发命令，确认后构造 Confirmed<FaceWritebackInput>(.userDialog)；
// - cancelAnalysis 走 FaceAPI（不再发 fkw.cancel_analysis 路由命令）。
//
// B8.4 起唯一的 FaceKeywordingViewModel 构造器就是本文件覆盖的生产注入路径。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

// MARK: - Stub FaceAPI / JobAPI

private final class StubFaceAPI: FaceAPI, @unchecked Sendable {
    private struct BoxState {
        var clusters: [FaceClusterData] = []
        var analyzeResult = FaceAnalysisResult(status: "done", detectionFailures: 0, encodingFailures: 0)
        var analyzeError: Error?
        var models = FaceModelsStatus(
            provider: "vision",
            fallbackToOnnxEnabled: false,
            modelsPresent: true,
            downloading: false
        )
        var preview = WritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
        var writebackResult = WritebackResult(
            totalAffected: 0, written: 0, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: ""
        )
        var cleanupResult = CleanupResult(deletedCount: 0, errors: [])
        var clusterCalls: [String] = []
        var analyzeInputs: [FaceAnalyzeInput] = []
        var bindInputs: [FaceBindInput] = []
        var mergeInputs: [FaceMergeInput] = []
        var removeMemberInputs: [FaceRemoveMemberInput] = []
        var unbindInputs: [Confirmed<FaceUnbindInput>] = []
        var previewInputs: [FacePreviewInput] = []
        var writebackInputs: [Confirmed<FaceWritebackInput>] = []
        var confirmSyncCalls: [String] = []
        var cleanupInputs: [Confirmed<SessionReference>] = []
        var cancelCalls: [String] = []
        var modelsCalls = 0
    }

    private let box = LockedBox(BoxState())

    var clusters: [FaceClusterData] {
        get { box.lock.withLock { box.clusters } }
        set { box.lock.withLock { box.clusters = newValue } }
    }

    var analyzeResult: FaceAnalysisResult {
        get { box.lock.withLock { box.analyzeResult } }
        set { box.lock.withLock { box.analyzeResult = newValue } }
    }

    var analyzeError: Error? {
        get { box.lock.withLock { box.analyzeError } }
        set { box.lock.withLock { box.analyzeError = newValue } }
    }

    var preview: WritebackPreview {
        get { box.lock.withLock { box.preview } }
        set { box.lock.withLock { box.preview = newValue } }
    }

    var writebackResult: WritebackResult {
        get { box.lock.withLock { box.writebackResult } }
        set { box.lock.withLock { box.writebackResult = newValue } }
    }

    var clusterCalls: [String] { box.lock.withLock { box.clusterCalls } }
    var analyzeInputs: [FaceAnalyzeInput] { box.lock.withLock { box.analyzeInputs } }
    var bindInputs: [FaceBindInput] { box.lock.withLock { box.bindInputs } }
    var unbindInputs: [Confirmed<FaceUnbindInput>] { box.lock.withLock { box.unbindInputs } }
    var previewInputs: [FacePreviewInput] { box.lock.withLock { box.previewInputs } }
    var writebackInputs: [Confirmed<FaceWritebackInput>] { box.lock.withLock { box.writebackInputs } }
    var confirmSyncCalls: [String] { box.lock.withLock { box.confirmSyncCalls } }
    var cleanupInputs: [Confirmed<SessionReference>] { box.lock.withLock { box.cleanupInputs } }
    var cancelCalls: [String] { box.lock.withLock { box.cancelCalls } }
    var modelsCalls: Int { box.lock.withLock { box.modelsCalls } }

    func clusters(_ sessionId: String) async throws -> [FaceClusterData] {
        box.lock.withLock {
            box.clusterCalls.append(sessionId)
            return box.clusters
        }
    }

    func bind(_ input: FaceBindInput) async throws {
        box.lock.withLock { box.bindInputs.append(input) }
    }

    func merge(_ input: FaceMergeInput) async throws {
        box.lock.withLock { box.mergeInputs.append(input) }
    }

    func removeMember(_ input: FaceRemoveMemberInput) async throws {
        box.lock.withLock { box.removeMemberInputs.append(input) }
    }

    func analyze(_ input: FaceAnalyzeInput) async throws -> FaceAnalysisResult {
        let (error, result): (Error?, FaceAnalysisResult) = box.lock.withLock {
            box.analyzeInputs.append(input)
            return (box.analyzeError, box.analyzeResult)
        }
        if let error { throw error }
        return result
    }

    func recluster(_ input: FaceReclusterInput) async throws {
        _ = input
    }

    func cancelAnalysis(_ sessionId: String) async throws {
        box.lock.withLock { box.cancelCalls.append(sessionId) }
    }

    func unbind(_ input: Confirmed<FaceUnbindInput>) async throws -> FkwUnbindResult {
        box.lock.withLock { box.unbindInputs.append(input) }
        return FkwUnbindResult(done: true, removedKeywords: [])
    }

    func preview(_ input: FacePreviewInput) async throws -> WritebackPreview {
        let preview = box.lock.withLock {
            box.previewInputs.append(input)
            return box.preview
        }
        return preview
    }

    func writeback(_ input: Confirmed<FaceWritebackInput>) async throws -> WritebackResult {
        let result = box.lock.withLock {
            box.writebackInputs.append(input)
            return box.writebackResult
        }
        return result
    }

    func confirmSync(_ sessionId: String) async throws -> Bool {
        box.lock.withLock { box.confirmSyncCalls.append(sessionId) }
        return true
    }

    func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult {
        let result = box.lock.withLock {
            box.cleanupInputs.append(input)
            return box.cleanupResult
        }
        return result
    }

    func modelsStatus() async throws -> FaceModelsStatus {
        box.lock.withLock {
            box.modelsCalls += 1
            return box.models
        }
    }
}

private final class StubFaceJobAPI: JobAPI, @unchecked Sendable {
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

private func faceCluster(id: Int = 1, roleName: String? = nil) -> FaceClusterData {
    FaceClusterData(
        id: id,
        sessionId: "s1",
        label: "簇 \(id)",
        size: 2,
        status: "ready",
        thumbnailBase64: "",
        binding: roleName.map { FaceClusterBinding(roleName: $0, keywords: [$0]) },
        thumbnailPhotoId: nil,
        members: []
    )
}

private func faceWritebackItem() -> WritebackItem {
    WritebackItem(
        id: 1,
        photoId: "photo-1",
        photoPath: "/vault/photo-1.NEF",
        sessionId: "s1",
        module: "face",
        keywords: ["张三"],
        xmpPath: "/vault/photo-1.xmp",
        backupPath: "",
        xmpStatus: "pending",
        errorMessage: "",
        attemptCount: 0,
        lastAttemptAt: "",
        preview: nil
    )
}

private func faceAnalysisJob(
    status: AnalysisJobStatus,
    current: Int = 0,
    total: Int = 0,
    message: String = ""
) -> AnalysisJobData {
    AnalysisJobData(
        id: "job-face-1",
        type: .faceAnalyze,
        scopeType: "session",
        scopeId: "s1",
        dedupeKey: "face.analyze:s1",
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

// MARK: - 用例

@Suite("FaceKeywordingViewModel API 注入")
@MainActor
struct APIFaceUITests {
    private func makeViewModel(
        _ face: StubFaceAPI,
        jobs: StubFaceJobAPI = StubFaceJobAPI()
    ) -> FaceKeywordingViewModel {
        FaceKeywordingViewModel(
            sessionId: "s1",
            face: face,
            jobs: jobs,
            captureOne: CaptureOneBridge()
        )
    }

    @Test("analyze：eps/minSamples 进 FaceAPI，成功态进入审核")
    func analyzeUsesFaceAPI() async {
        let face = StubFaceAPI()
        face.analyzeResult = FaceAnalysisResult(
            status: "done", detectionFailures: 1, encodingFailures: 0
        )
        let viewModel = makeViewModel(face)
        viewModel.eps = 0.5
        viewModel.minSamples = 2

        await viewModel.analyze()

        #expect(face.analyzeInputs.count == 1)
        #expect(face.analyzeInputs[0].sessionId == "s1")
        #expect(face.analyzeInputs[0].eps == 0.5)
        #expect(face.analyzeInputs[0].minSamples == 2)
        #expect(viewModel.analysisResult?.detectionFailures == 1)
        #expect(viewModel.analysisPhase == .done)
        #expect(viewModel.step == .review)
        // analyze 成功后 reload：簇/模型状态/job 恢复都走注入的端口。
        #expect(face.clusterCalls == ["s1"])
        #expect(face.modelsCalls == 1)
    }

    @Test("recoverAnalysis：JobAPI.list 的活跃 face.analyze 恢复进度")
    func reloadRecoversActiveAnalysisJob() async {
        let face = StubFaceAPI()
        let jobs = StubFaceJobAPI()
        jobs.jobs = [faceAnalysisJob(
            status: .running, current: 4, total: 12, message: "face.detecting"
        )]
        let viewModel = makeViewModel(face, jobs: jobs)

        await viewModel.reload()

        #expect(jobs.listCalls == 1)
        #expect(viewModel.analysisPhase == .running)
        #expect(viewModel.progressCurrent == 4)
        #expect(viewModel.progressTotal == 12)
        #expect(viewModel.progressPhase == "face.detecting")
    }

    @Test("clusters/bind：reload 读 FaceAPI，bind 送角色与关键字")
    func clustersAndBindUseFaceAPI() async {
        let face = StubFaceAPI()
        face.clusters = [faceCluster()]
        let viewModel = makeViewModel(face)

        await viewModel.reload()
        #expect(viewModel.clusters.count == 1)
        #expect(face.clusterCalls == ["s1"])

        guard let cluster = viewModel.clusters.first else {
            Issue.record("缺少簇夹具")
            return
        }
        viewModel.roleName = " 张三 "
        viewModel.keywords = "朋友, 旅行"
        await viewModel.bind(cluster)

        #expect(face.bindInputs.count == 1)
        #expect(face.bindInputs[0].clusterId == 1)
        #expect(face.bindInputs[0].roleName == "张三", "角色名必须 trim")
        #expect(face.bindInputs[0].keywords == ["朋友", "旅行"])
        #expect(viewModel.reviewActionError == nil)
        #expect(face.clusterCalls.count == 2, "bind 成功后应 reload")
    }

    @Test("writeback：未确认不发命令；确认后 Confirmed(.userDialog) + 预览 items")
    func writebackRequiresUserDialogConfirmation() async {
        let face = StubFaceAPI()
        face.preview = WritebackPreview(
            items: [faceWritebackItem()], totalCount: 1, affectedPhotos: 1
        )
        let viewModel = makeViewModel(face)
        await viewModel.analyze()

        await viewModel.previewWriteback()
        #expect(viewModel.preview?.items.count == 1)
        #expect(face.previewInputs.count == 1)

        await viewModel.writeback(confirmed: false)
        #expect(face.writebackInputs.isEmpty, "用户取消后不得发出写回")

        await viewModel.writeback(confirmed: true)
        #expect(face.writebackInputs.count == 1)
        #expect(face.writebackInputs[0].source == .userDialog)
        #expect(face.writebackInputs[0].value.items.count == 1)
        #expect(face.writebackInputs[0].value.items[0].id == 1)
    }

    @Test("cancelAnalysis：走 FaceAPI，不再发路由命令")
    func cancelUsesFaceAPI() async {
        let face = StubFaceAPI()
        let viewModel = makeViewModel(face)
        await viewModel.cancel()
        #expect(face.cancelCalls == ["s1"])
        #expect(viewModel.notice != nil)
    }
}
