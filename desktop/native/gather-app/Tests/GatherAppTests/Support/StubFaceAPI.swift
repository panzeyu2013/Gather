// desktop/native/gather-app/Tests/GatherAppTests/Support/StubFaceAPI.swift
// Cut 1 / B8.1a 测试共享：FaceAPI 的类型化替身。
//
// 与 StubAPIs.swift / StubCullingAPI.swift 同款结构（LockedBox + 记录入参 +
// 可注入错误/延迟）。FaceKeywordingViewModelTests / LayoutBudgetTests 直接
// 注入类型化替身驱动人脸分析、簇读取、绑定与确认写回。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

private struct B8FaceState {
    var clustersValue: [FaceClusterData] = []
    var analyzeResultValue = FaceAnalysisResult(
        status: "done", detectionFailures: 0, encodingFailures: 0
    )
    var modelsValue = FaceModelsStatus(
        provider: "vision",
        fallbackToOnnxEnabled: false,
        modelsPresent: true,
        downloading: false
    )
    var previewValue = WritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    var writebackResultValue = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: ""
    )
    var retryResultValue = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: ""
    )
    var cleanupResultValue = CleanupResult(deletedCount: 0, errors: [])
    var unbindResultValue = FkwUnbindResult(done: true, removedKeywords: [])
    var confirmSyncResult = true
    var splitResultValue = FaceSplitResult(
        newClusterId: 2, movedCount: 0, remainingCount: 0, label: "Person 2"
    )
    var reviewPageValue = FaceReviewPage(
        items: [], nextCursor: nil, total: 0, suspectTotal: 0, clusters: []
    )

    var clustersError: (any Error)?
    var bindError: (any Error)?
    var mergeError: (any Error)?
    var removeMemberError: (any Error)?
    var analyzeError: (any Error)?
    var reclusterError: (any Error)?
    var cancelError: (any Error)?
    var unbindError: (any Error)?
    var previewError: (any Error)?
    var writebackError: (any Error)?
    var confirmSyncError: (any Error)?
    var cleanupError: (any Error)?
    var modelsError: (any Error)?
    var splitError: (any Error)?
    var reviewError: (any Error)?

    var analyzeGate: AsyncGate?
    var responseDelay = Duration.zero

    var clusterCalls: [String] = []
    var bindInputs: [FaceBindInput] = []
    var mergeInputs: [FaceMergeInput] = []
    var removeMemberInputs: [FaceRemoveMemberInput] = []
    var analyzeInputs: [FaceAnalyzeInput] = []
    var reclusterInputs: [FaceReclusterInput] = []
    var cancelCalls: [String] = []
    var unbindInputs: [Confirmed<FaceUnbindInput>] = []
    var previewInputs: [FacePreviewInput] = []
    var writebackInputs: [Confirmed<FaceWritebackInput>] = []
    var confirmSyncCalls: [String] = []
    var cleanupInputs: [Confirmed<SessionReference>] = []
    var splitInputs: [Confirmed<FaceSplitInput>] = []
    var reviewInputs: [FaceReviewInput] = []
    var modelsCalls = 0
}

/// 可配置 FaceAPI：默认无簇、分析成功、模型可用；记录全部类型化入参。
final class B8FaceAPIStub: FaceAPI, @unchecked Sendable {
    private let box = LockedBox(B8FaceState())

    var clustersValue: [FaceClusterData] {
        get { box.lock.withLock { box.clustersValue } }
        set { box.lock.withLock { box.clustersValue = newValue } }
    }

    var analyzeResultValue: FaceAnalysisResult {
        get { box.lock.withLock { box.analyzeResultValue } }
        set { box.lock.withLock { box.analyzeResultValue = newValue } }
    }

    var modelsValue: FaceModelsStatus {
        get { box.lock.withLock { box.modelsValue } }
        set { box.lock.withLock { box.modelsValue = newValue } }
    }

    var previewValue: WritebackPreview {
        get { box.lock.withLock { box.previewValue } }
        set { box.lock.withLock { box.previewValue = newValue } }
    }

    var writebackResultValue: WritebackResult {
        get { box.lock.withLock { box.writebackResultValue } }
        set { box.lock.withLock { box.writebackResultValue = newValue } }
    }

    var retryResultValue: WritebackResult {
        get { box.lock.withLock { box.retryResultValue } }
        set { box.lock.withLock { box.retryResultValue = newValue } }
    }

    var cleanupResultValue: CleanupResult {
        get { box.lock.withLock { box.cleanupResultValue } }
        set { box.lock.withLock { box.cleanupResultValue = newValue } }
    }

    var unbindResultValue: FkwUnbindResult {
        get { box.lock.withLock { box.unbindResultValue } }
        set { box.lock.withLock { box.unbindResultValue = newValue } }
    }

    var confirmSyncResult: Bool {
        get { box.lock.withLock { box.confirmSyncResult } }
        set { box.lock.withLock { box.confirmSyncResult = newValue } }
    }

    var splitResultValue: FaceSplitResult {
        get { box.lock.withLock { box.splitResultValue } }
        set { box.lock.withLock { box.splitResultValue = newValue } }
    }

    var reviewPageValue: FaceReviewPage {
        get { box.lock.withLock { box.reviewPageValue } }
        set { box.lock.withLock { box.reviewPageValue = newValue } }
    }

    var splitError: (any Error)? {
        get { box.lock.withLock { box.splitError } }
        set { box.lock.withLock { box.splitError = newValue } }
    }

    var reviewError: (any Error)? {
        get { box.lock.withLock { box.reviewError } }
        set { box.lock.withLock { box.reviewError = newValue } }
    }

    var clustersError: (any Error)? {
        get { box.lock.withLock { box.clustersError } }
        set { box.lock.withLock { box.clustersError = newValue } }
    }

    var bindError: (any Error)? {
        get { box.lock.withLock { box.bindError } }
        set { box.lock.withLock { box.bindError = newValue } }
    }

    var mergeError: (any Error)? {
        get { box.lock.withLock { box.mergeError } }
        set { box.lock.withLock { box.mergeError = newValue } }
    }

    var removeMemberError: (any Error)? {
        get { box.lock.withLock { box.removeMemberError } }
        set { box.lock.withLock { box.removeMemberError = newValue } }
    }

    var analyzeError: (any Error)? {
        get { box.lock.withLock { box.analyzeError } }
        set { box.lock.withLock { box.analyzeError = newValue } }
    }

    var reclusterError: (any Error)? {
        get { box.lock.withLock { box.reclusterError } }
        set { box.lock.withLock { box.reclusterError = newValue } }
    }

    var cancelError: (any Error)? {
        get { box.lock.withLock { box.cancelError } }
        set { box.lock.withLock { box.cancelError = newValue } }
    }

    var unbindError: (any Error)? {
        get { box.lock.withLock { box.unbindError } }
        set { box.lock.withLock { box.unbindError = newValue } }
    }

    var previewError: (any Error)? {
        get { box.lock.withLock { box.previewError } }
        set { box.lock.withLock { box.previewError = newValue } }
    }

    var writebackError: (any Error)? {
        get { box.lock.withLock { box.writebackError } }
        set { box.lock.withLock { box.writebackError = newValue } }
    }

    var confirmSyncError: (any Error)? {
        get { box.lock.withLock { box.confirmSyncError } }
        set { box.lock.withLock { box.confirmSyncError = newValue } }
    }

    var cleanupError: (any Error)? {
        get { box.lock.withLock { box.cleanupError } }
        set { box.lock.withLock { box.cleanupError = newValue } }
    }

    var modelsError: (any Error)? {
        get { box.lock.withLock { box.modelsError } }
        set { box.lock.withLock { box.modelsError = newValue } }
    }

    var analyzeGate: AsyncGate? {
        get { box.lock.withLock { box.analyzeGate } }
        set { box.lock.withLock { box.analyzeGate = newValue } }
    }

    var responseDelay: Duration {
        get { box.lock.withLock { box.responseDelay } }
        set { box.lock.withLock { box.responseDelay = newValue } }
    }

    var clusterCalls: [String] { box.lock.withLock { box.clusterCalls } }
    var bindInputs: [FaceBindInput] { box.lock.withLock { box.bindInputs } }
    var mergeInputs: [FaceMergeInput] { box.lock.withLock { box.mergeInputs } }
    var removeMemberInputs: [FaceRemoveMemberInput] { box.lock.withLock { box.removeMemberInputs } }
    var analyzeInputs: [FaceAnalyzeInput] { box.lock.withLock { box.analyzeInputs } }
    var reclusterInputs: [FaceReclusterInput] { box.lock.withLock { box.reclusterInputs } }
    var cancelCalls: [String] { box.lock.withLock { box.cancelCalls } }
    var unbindInputs: [Confirmed<FaceUnbindInput>] { box.lock.withLock { box.unbindInputs } }
    var previewInputs: [FacePreviewInput] { box.lock.withLock { box.previewInputs } }
    var writebackInputs: [Confirmed<FaceWritebackInput>] { box.lock.withLock { box.writebackInputs } }
    var confirmSyncCalls: [String] { box.lock.withLock { box.confirmSyncCalls } }
    var cleanupInputs: [Confirmed<SessionReference>] { box.lock.withLock { box.cleanupInputs } }
    var splitInputs: [Confirmed<FaceSplitInput>] { box.lock.withLock { box.splitInputs } }
    var reviewInputs: [FaceReviewInput] { box.lock.withLock { box.reviewInputs } }
    var modelsCalls: Int { box.lock.withLock { box.modelsCalls } }

    private func delayIfNeeded() async throws {
        let delay = box.lock.withLock { box.responseDelay }
        if delay > .zero { try await Task.sleep(for: delay) }
    }
    func clusters(_ sessionId: String) async throws -> [FaceClusterData] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [FaceClusterData]) = box.lock.withLock {
            box.clusterCalls.append(sessionId)
            return (box.clustersError, box.clustersValue)
        }
        if let error { throw error }
        return result
    }

    func bind(_ input: FaceBindInput) async throws {
        try await delayIfNeeded()
        let error: (any Error)? = box.lock.withLock {
            box.bindInputs.append(input)
            return box.bindError
        }
        if let error { throw error }
    }

    func merge(_ input: FaceMergeInput) async throws {
        try await delayIfNeeded()
        let error: (any Error)? = box.lock.withLock {
            box.mergeInputs.append(input)
            return box.mergeError
        }
        if let error { throw error }
    }

    func removeMember(_ input: FaceRemoveMemberInput) async throws {
        try await delayIfNeeded()
        let error: (any Error)? = box.lock.withLock {
            box.removeMemberInputs.append(input)
            return box.removeMemberError
        }
        if let error { throw error }
    }

    func analyze(_ input: FaceAnalyzeInput) async throws -> FaceAnalysisResult {
        let (gate, error, result): (AsyncGate?, (any Error)?, FaceAnalysisResult) = box.lock.withLock {
            box.analyzeInputs.append(input)
            return (box.analyzeGate, box.analyzeError, box.analyzeResultValue)
        }
        if let gate { await gate.wait() }
        try await delayIfNeeded()
        if let error { throw error }
        return result
    }

    func recluster(_ input: FaceReclusterInput) async throws {
        try await delayIfNeeded()
        let error: (any Error)? = box.lock.withLock {
            box.reclusterInputs.append(input)
            return box.reclusterError
        }
        if let error { throw error }
    }

    func cancelAnalysis(_ sessionId: String) async throws {
        try await delayIfNeeded()
        let error: (any Error)? = box.lock.withLock {
            box.cancelCalls.append(sessionId)
            return box.cancelError
        }
        if let error { throw error }
    }

    func unbind(_ input: Confirmed<FaceUnbindInput>) async throws -> FkwUnbindResult {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, FkwUnbindResult) = box.lock.withLock {
            box.unbindInputs.append(input)
            return (box.unbindError, box.unbindResultValue)
        }
        if let error { throw error }
        return result
    }

    func preview(_ input: FacePreviewInput) async throws -> WritebackPreview {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, WritebackPreview) = box.lock.withLock {
            box.previewInputs.append(input)
            return (box.previewError, box.previewValue)
        }
        if let error { throw error }
        return result
    }

    func writeback(_ input: Confirmed<FaceWritebackInput>) async throws -> WritebackResult {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, WritebackResult) = box.lock.withLock {
            box.writebackInputs.append(input)
            return (box.writebackError, box.writebackResultValue)
        }
        if let error { throw error }
        return result
    }

    func confirmSync(_ sessionId: String) async throws -> Bool {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, Bool) = box.lock.withLock {
            box.confirmSyncCalls.append(sessionId)
            return (box.confirmSyncError, box.confirmSyncResult)
        }
        if let error { throw error }
        return result
    }

    func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, CleanupResult) = box.lock.withLock {
            box.cleanupInputs.append(input)
            return (box.cleanupError, box.cleanupResultValue)
        }
        if let error { throw error }
        return result
    }

    func modelsStatus() async throws -> FaceModelsStatus {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, FaceModelsStatus) = box.lock.withLock {
            box.modelsCalls += 1
            return (box.modelsError, box.modelsValue)
        }
        if let error { throw error }
        return result
    }

    func split(_ input: Confirmed<FaceSplitInput>) async throws -> FaceSplitResult {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, FaceSplitResult) = box.lock.withLock {
            box.splitInputs.append(input)
            return (box.splitError, box.splitResultValue)
        }
        if let error { throw error }
        return result
    }

    func review(_ input: FaceReviewInput) async throws -> FaceReviewPage {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, FaceReviewPage) = box.lock.withLock {
            box.reviewInputs.append(input)
            return (box.reviewError, box.reviewPageValue)
        }
        if let error { throw error }
        return result
    }
}

// MARK: - 夹具

func b8FaceCluster(
    id: Int = 1,
    sessionId: String = "s1",
    roleName: String? = nil,
    keywords: [String] = [],
    size: Int = 2,
    members: [ClusterMember] = []
) -> FaceClusterData {
    FaceClusterData(
        id: id,
        sessionId: sessionId,
        label: "簇 \(id)",
        size: size,
        status: "new",
        thumbnailBase64: "t\(id)",
        binding: roleName.map { FaceClusterBinding(roleName: $0, keywords: keywords.isEmpty ? [$0] : keywords) },
        thumbnailPhotoId: nil,
        members: members
    )
}

func b8FaceMember(id: Int = 1, photoId: String = "p1") -> ClusterMember {
    ClusterMember(
        memberId: id,
        photoId: photoId,
        photoPath: "/tmp/\(photoId).NEF",
        filename: "\(photoId).NEF",
        bbox: [0.1, 0.1, 0.2, 0.2],
        confidence: 0.93
    )
}
