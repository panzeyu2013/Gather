// desktop/native/gather-app/Tests/GatherAppTests/Support/StubCullingAPI.swift
// Cut 1 / B8.1a 测试共享：CullingAPI / NavigationAPI 的类型化替身。
//
// 与 StubAPIs.swift（B5b）、StubExportMetadataAPIs.swift（B6b）同款结构：
// final class + LockedBox（@unchecked Sendable），方法可在任意隔离域调用；
// 记录每个类型化入参供断言，可注入错误/延迟。Culling/Face/Similarity 相关
// 测试不再以字符串命令 + JSONValue 为骨架。
//
// 命名带 B8 前缀：CullingViewModelAPITests / APIFaceUITests / APISimilarityUITests
// 已有同名 private 替身，模块级同名会触发 invalid redeclaration。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

// MARK: - 摘要/实体夹具

func b8SyncSummary(
    sessionId: String = "s1",
    pending: Int = 0,
    writing: Int = 0,
    written: Int = 0,
    failed: Int = 0,
    conflict: Int = 0,
    synced: Int = 0,
    items: [MetadataSyncItem] = []
) -> MetadataSyncSummary {
    MetadataSyncSummary(
        sessionId: sessionId, pending: pending, writing: writing, written: written,
        failed: failed, conflict: conflict, synced: synced, items: items
    )
}

func b8CullingPhoto(_ id: String, sessionId: String = "s1") -> PhotoData {
    PhotoData(
        id: id,
        sessionId: sessionId,
        filepath: "/shoot/\(id).jpg",
        filename: "\(id).jpg",
        checksum: "",
        hasExistingXmp: false,
        faceCount: 0,
        width: 100,
        height: 100,
        metadata: [:],
        result: [:],
        status: "ready",
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

func b8CullingState(
    _ id: String,
    revision: Int = 1,
    pickState: PickState = .unreviewed,
    rating: Double = 0,
    colorLabel: CaptureOneColorLabel = .none
) -> AssetCullingState {
    AssetCullingState(
        photoId: id,
        pickState: pickState,
        rating: rating,
        colorLabel: colorLabel,
        source: .manual,
        revision: revision,
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

func b8CullingAsset(
    _ id: String,
    revision: Int = 1,
    pickState: PickState = .unreviewed,
    sessionId: String = "s1",
    keywords: [String] = []
) -> CullingAsset {
    CullingAsset(
        photo: b8CullingPhoto(id, sessionId: sessionId),
        state: b8CullingState(id, revision: revision, pickState: pickState),
        xmpPath: "/shoot/\(id).xmp",
        syncStatus: .clean,
        people: [],
        keywords: keywords,
        linkedVariantCount: 1,
        faceBboxes: []
    )
}

func b8CullingPage(_ assets: [CullingAsset]) -> CullingPage {
    CullingPage(assets: assets, total: assets.count)
}

func b8CullingGroup(
    groupId: String = "g1",
    photoIds: [String] = ["p1", "p2"]
) -> CullingGroup {
    CullingGroup(
        groupId: groupId,
        groupIndex: 0,
        images: photoIds.map {
            CullingImage(
                photoId: $0,
                filepath: "/shoot/\($0).jpg",
                filename: "\($0).jpg",
                decision: .pending
            )
        },
        keepCount: 0,
        rejectCount: 0,
        pendingCount: photoIds.count
    )
}

// MARK: - CullingAPI

private struct B8CullingState {
    var pageResult = CullingPage(assets: [], total: 0)
    var historyResult: [CullingHistoryOperation] = []
    var applyHistoryResults: [CullingUpdateResult] = []
    var updateResult = CullingUpdateResult(states: [], xmpPath: "", syncStatus: .clean)
    var batchUpdateResults: [CullingUpdateResult] = []
    var decideGroupResults: [CullingUpdateResult] = []
    var groupsResult: [CullingGroup] = []
    var summaryResult = CullingSummary(
        totalGroups: 0, totalPhotos: 0, kept: 0, rejected: 0, pending: 0, rated: 0, labeled: 0
    )
    var syncStatusResult = CullingSyncStatus(summary: b8SyncSummary())
    var resetResult = true
    var writebackResult = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: ""
    )
    var flushSummary = b8SyncSummary()
    var retrySyncSummary = b8SyncSummary()
    var retryFailedResult = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: ""
    )
    var cleanupResult = CleanupResult(deletedCount: 0, errors: [])
    var finalizeSummary = b8SyncSummary(synced: 1)
    var confirmSyncResult = true

    var triageSummaryResult: TriageSummary?
    var triageGenerateError: (any Error)?
    var triageGenerateInputs: [TriageGenerateInput] = []
    var applyTriageResult = TriageApplyResult()
    var applyTriageError: (any Error)?
    var applyTriageInputs: [Confirmed<TriageApplyInput>] = []

    var pageError: (any Error)?
    var historyError: (any Error)?
    var applyHistoryError: (any Error)?
    var updateError: (any Error)?
    var batchUpdateError: (any Error)?
    var decideGroupError: (any Error)?
    var groupsError: (any Error)?
    var summaryError: (any Error)?

    var syncStatusError: (any Error)?
    var resetError: (any Error)?
    var writebackError: (any Error)?
    var flushError: (any Error)?
    var retrySyncError: (any Error)?
    var retryFailedError: (any Error)?
    var cleanupError: (any Error)?
    var finalizeError: (any Error)?
    var confirmSyncError: (any Error)?
    var responseDelay = Duration.zero

    var pageQueries: [CullingPageQuery] = []
    var historyQueries: [CullingHistoryQuery] = []
    var applyHistoryInputs: [CullingApplyHistoryInput] = []
    var updateInputs: [CullingUpdateInput] = []
    var batchUpdateInputs: [CullingBatchUpdateInput] = []
    var decideGroupInputs: [CullingDecideGroupInput] = []
    var groupCalls: [String] = []
    var summaryCalls: [String] = []
    var syncStatusCalls: [String] = []
    /// B8.2e：按调用顺序覆盖 syncStatus 的结果/延迟（用于验证 async 刷新乱序）。
    var syncStatusResults: [CullingSyncStatus] = []
    var syncStatusDelays: [Duration] = []
    var resetInputs: [Confirmed<CullingResetInput>] = []
    var writebackInputs: [Confirmed<CullingWritebackInput>] = []
    var flushCalls: [String] = []
    var retrySyncCalls: [String] = []
    var retryFailedInputs: [Confirmed<SessionReference>] = []
    var cleanupInputs: [Confirmed<SessionReference>] = []
    var finalizeInputs: [Confirmed<SessionReference>] = []
    var confirmSyncCalls: [String] = []
}

/// 可配置 CullingAPI：默认空页/零摘要/空历史；记录全部类型化入参。
final class B8CullingAPIStub: CullingAPI, @unchecked Sendable {
    private let box = LockedBox(B8CullingState())

    var pageResult: CullingPage {
        get { box.lock.withLock { box.pageResult } }
        set { box.lock.withLock { box.pageResult = newValue } }
    }

    var historyResult: [CullingHistoryOperation] {
        get { box.lock.withLock { box.historyResult } }
        set { box.lock.withLock { box.historyResult = newValue } }
    }

    var applyHistoryResults: [CullingUpdateResult] {
        get { box.lock.withLock { box.applyHistoryResults } }
        set { box.lock.withLock { box.applyHistoryResults = newValue } }
    }

    var updateResult: CullingUpdateResult {
        get { box.lock.withLock { box.updateResult } }
        set { box.lock.withLock { box.updateResult = newValue } }
    }

    var batchUpdateResults: [CullingUpdateResult] {
        get { box.lock.withLock { box.batchUpdateResults } }
        set { box.lock.withLock { box.batchUpdateResults = newValue } }
    }

    var decideGroupResults: [CullingUpdateResult] {
        get { box.lock.withLock { box.decideGroupResults } }
        set { box.lock.withLock { box.decideGroupResults = newValue } }
    }

    var groupsResult: [CullingGroup] {
        get { box.lock.withLock { box.groupsResult } }
        set { box.lock.withLock { box.groupsResult = newValue } }
    }

    var summaryResult: CullingSummary {
        get { box.lock.withLock { box.summaryResult } }
        set { box.lock.withLock { box.summaryResult = newValue } }
    }

    var syncStatusResult: CullingSyncStatus {
        get { box.lock.withLock { box.syncStatusResult } }
        set { box.lock.withLock { box.syncStatusResult = newValue } }
    }

    /// 队列非空时按调用顺序消费；空时回退到 `syncStatusResult`。
    var syncStatusResults: [CullingSyncStatus] {
        get { box.lock.withLock { box.syncStatusResults } }
        set { box.lock.withLock { box.syncStatusResults = newValue } }
    }

    /// 与 `syncStatusResults` 对齐的每次调用延迟；空时按 `responseDelay`。
    var syncStatusDelays: [Duration] {
        get { box.lock.withLock { box.syncStatusDelays } }
        set { box.lock.withLock { box.syncStatusDelays = newValue } }
    }

    var resetResult: Bool {
        get { box.lock.withLock { box.resetResult } }
        set { box.lock.withLock { box.resetResult = newValue } }
    }

    var writebackResult: WritebackResult {
        get { box.lock.withLock { box.writebackResult } }
        set { box.lock.withLock { box.writebackResult = newValue } }
    }

    var flushSummary: MetadataSyncSummary {
        get { box.lock.withLock { box.flushSummary } }
        set { box.lock.withLock { box.flushSummary = newValue } }
    }

    var retrySyncSummary: MetadataSyncSummary {
        get { box.lock.withLock { box.retrySyncSummary } }
        set { box.lock.withLock { box.retrySyncSummary = newValue } }
    }

    var retryFailedResult: WritebackResult {
        get { box.lock.withLock { box.retryFailedResult } }
        set { box.lock.withLock { box.retryFailedResult = newValue } }
    }

    var cleanupResult: CleanupResult {
        get { box.lock.withLock { box.cleanupResult } }
        set { box.lock.withLock { box.cleanupResult = newValue } }
    }

    var finalizeSummary: MetadataSyncSummary {
        get { box.lock.withLock { box.finalizeSummary } }
        set { box.lock.withLock { box.finalizeSummary = newValue } }
    }

    var confirmSyncResult: Bool {
        get { box.lock.withLock { box.confirmSyncResult } }
        set { box.lock.withLock { box.confirmSyncResult = newValue } }
    }

    var pageError: (any Error)? {
        get { box.lock.withLock { box.pageError } }
        set { box.lock.withLock { box.pageError = newValue } }
    }

    var historyError: (any Error)? {
        get { box.lock.withLock { box.historyError } }
        set { box.lock.withLock { box.historyError = newValue } }
    }

    var applyHistoryError: (any Error)? {
        get { box.lock.withLock { box.applyHistoryError } }
        set { box.lock.withLock { box.applyHistoryError = newValue } }
    }

    var updateError: (any Error)? {
        get { box.lock.withLock { box.updateError } }
        set { box.lock.withLock { box.updateError = newValue } }
    }

    var batchUpdateError: (any Error)? {
        get { box.lock.withLock { box.batchUpdateError } }
        set { box.lock.withLock { box.batchUpdateError = newValue } }
    }

    var decideGroupError: (any Error)? {
        get { box.lock.withLock { box.decideGroupError } }
        set { box.lock.withLock { box.decideGroupError = newValue } }
    }

    var groupsError: (any Error)? {
        get { box.lock.withLock { box.groupsError } }
        set { box.lock.withLock { box.groupsError = newValue } }
    }

    var summaryError: (any Error)? {
        get { box.lock.withLock { box.summaryError } }
        set { box.lock.withLock { box.summaryError = newValue } }
    }

    var triageSummaryResult: TriageSummary? {
        get { box.lock.withLock { box.triageSummaryResult } }
        set { box.lock.withLock { box.triageSummaryResult = newValue } }
    }

    var triageGenerateError: (any Error)? {
        get { box.lock.withLock { box.triageGenerateError } }
        set { box.lock.withLock { box.triageGenerateError = newValue } }
    }

    var triageGenerateInputs: [TriageGenerateInput] {
        box.lock.withLock { box.triageGenerateInputs }
    }

    var applyTriageResult: TriageApplyResult {
        get { box.lock.withLock { box.applyTriageResult } }
        set { box.lock.withLock { box.applyTriageResult = newValue } }
    }

    var applyTriageError: (any Error)? {
        get { box.lock.withLock { box.applyTriageError } }
        set { box.lock.withLock { box.applyTriageError = newValue } }
    }

    var applyTriageInputs: [Confirmed<TriageApplyInput>] {
        box.lock.withLock { box.applyTriageInputs }
    }

    var syncStatusError: (any Error)? {
        get { box.lock.withLock { box.syncStatusError } }
        set { box.lock.withLock { box.syncStatusError = newValue } }
    }

    var resetError: (any Error)? {
        get { box.lock.withLock { box.resetError } }
        set { box.lock.withLock { box.resetError = newValue } }
    }

    var writebackError: (any Error)? {
        get { box.lock.withLock { box.writebackError } }
        set { box.lock.withLock { box.writebackError = newValue } }
    }

    var flushError: (any Error)? {
        get { box.lock.withLock { box.flushError } }
        set { box.lock.withLock { box.flushError = newValue } }
    }

    var retrySyncError: (any Error)? {
        get { box.lock.withLock { box.retrySyncError } }
        set { box.lock.withLock { box.retrySyncError = newValue } }
    }

    var retryFailedError: (any Error)? {
        get { box.lock.withLock { box.retryFailedError } }
        set { box.lock.withLock { box.retryFailedError = newValue } }
    }

    var cleanupError: (any Error)? {
        get { box.lock.withLock { box.cleanupError } }
        set { box.lock.withLock { box.cleanupError = newValue } }
    }

    var finalizeError: (any Error)? {
        get { box.lock.withLock { box.finalizeError } }
        set { box.lock.withLock { box.finalizeError = newValue } }
    }

    var confirmSyncError: (any Error)? {
        get { box.lock.withLock { box.confirmSyncError } }
        set { box.lock.withLock { box.confirmSyncError = newValue } }
    }

    var responseDelay: Duration {
        get { box.lock.withLock { box.responseDelay } }
        set { box.lock.withLock { box.responseDelay = newValue } }
    }

    var pageQueries: [CullingPageQuery] { box.lock.withLock { box.pageQueries } }
    var historyQueries: [CullingHistoryQuery] { box.lock.withLock { box.historyQueries } }
    var applyHistoryInputs: [CullingApplyHistoryInput] { box.lock.withLock { box.applyHistoryInputs } }
    var updateInputs: [CullingUpdateInput] { box.lock.withLock { box.updateInputs } }
    var batchUpdateInputs: [CullingBatchUpdateInput] { box.lock.withLock { box.batchUpdateInputs } }
    var decideGroupInputs: [CullingDecideGroupInput] { box.lock.withLock { box.decideGroupInputs } }
    var groupCalls: [String] { box.lock.withLock { box.groupCalls } }
    var summaryCalls: [String] { box.lock.withLock { box.summaryCalls } }
    var syncStatusCalls: [String] { box.lock.withLock { box.syncStatusCalls } }
    var resetInputs: [Confirmed<CullingResetInput>] { box.lock.withLock { box.resetInputs } }
    var writebackInputs: [Confirmed<CullingWritebackInput>] { box.lock.withLock { box.writebackInputs } }
    var flushCalls: [String] { box.lock.withLock { box.flushCalls } }
    var retrySyncCalls: [String] { box.lock.withLock { box.retrySyncCalls } }
    var retryFailedInputs: [Confirmed<SessionReference>] { box.lock.withLock { box.retryFailedInputs } }
    var cleanupInputs: [Confirmed<SessionReference>] { box.lock.withLock { box.cleanupInputs } }
    var finalizeInputs: [Confirmed<SessionReference>] { box.lock.withLock { box.finalizeInputs } }
    var confirmSyncCalls: [String] { box.lock.withLock { box.confirmSyncCalls } }

    private func delayIfNeeded() async throws {
        let delay = box.lock.withLock { box.responseDelay }
        if delay > .zero { try await Task.sleep(for: delay) }
    }
    func page(_ query: CullingPageQuery) async throws -> CullingPage {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, CullingPage) = box.lock.withLock {
            box.pageQueries.append(query)
            return (box.pageError, box.pageResult)
        }
        if let error { throw error }
        return result
    }

    func history(_ query: CullingHistoryQuery) async throws -> [CullingHistoryOperation] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [CullingHistoryOperation]) = box.lock.withLock {
            box.historyQueries.append(query)
            return (box.historyError, box.historyResult)
        }
        if let error { throw error }
        return result
    }

    func applyHistory(_ input: CullingApplyHistoryInput) async throws -> [CullingUpdateResult] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [CullingUpdateResult]) = box.lock.withLock {
            box.applyHistoryInputs.append(input)
            return (box.applyHistoryError, box.applyHistoryResults)
        }
        if let error { throw error }
        return result
    }

    func update(_ input: CullingUpdateInput) async throws -> CullingUpdateResult {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, CullingUpdateResult) = box.lock.withLock {
            box.updateInputs.append(input)
            return (box.updateError, box.updateResult)
        }
        if let error { throw error }
        return result
    }

    func batchUpdate(_ input: CullingBatchUpdateInput) async throws -> [CullingUpdateResult] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [CullingUpdateResult]) = box.lock.withLock {
            box.batchUpdateInputs.append(input)
            return (box.batchUpdateError, box.batchUpdateResults)
        }
        if let error { throw error }
        return result
    }

    func decideGroup(_ input: CullingDecideGroupInput) async throws -> [CullingUpdateResult] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [CullingUpdateResult]) = box.lock.withLock {
            box.decideGroupInputs.append(input)
            return (box.decideGroupError, box.decideGroupResults)
        }
        if let error { throw error }
        return result
    }

    func groups(_ sessionId: String) async throws -> [CullingGroup] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [CullingGroup]) = box.lock.withLock {
            box.groupCalls.append(sessionId)
            return (box.groupsError, box.groupsResult)
        }
        if let error { throw error }
        return result
    }

    func summary(_ sessionId: String) async throws -> CullingSummary {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, CullingSummary) = box.lock.withLock {
            box.summaryCalls.append(sessionId)
            return (box.summaryError, box.summaryResult)
        }
        if let error { throw error }
        return result
    }

    // P1 / D：淘汰移动（stub：直接回成功，不碰文件系统）。
    func moveRejected(_ input: Confirmed<CullingMoveRejectedInput>) async throws -> CullingMoveRejectedResult {
        CullingMoveRejectedResult(moved: input.value.photoIds, newPaths: [], failed: [])
    }

    func syncStatus(_ sessionId: String) async throws -> CullingSyncStatus {
        let (error, result, delay): ((any Error)?, CullingSyncStatus, Duration) = box.lock.withLock {
            box.syncStatusCalls.append(sessionId)
            let delay = box.syncStatusDelays.isEmpty
                ? box.responseDelay
                : box.syncStatusDelays.removeFirst()
            let result = box.syncStatusResults.isEmpty
                ? box.syncStatusResult
                : box.syncStatusResults.removeFirst()
            return (box.syncStatusError, result, delay)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        return result
    }

    func reset(_ input: Confirmed<CullingResetInput>) async throws -> Bool {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, Bool) = box.lock.withLock {
            box.resetInputs.append(input)
            return (box.resetError, box.resetResult)
        }
        if let error { throw error }
        return result
    }

    func writeback(_ input: Confirmed<CullingWritebackInput>) async throws -> WritebackResult {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, WritebackResult) = box.lock.withLock {
            box.writebackInputs.append(input)
            return (box.writebackError, box.writebackResult)
        }
        if let error { throw error }
        return result
    }

    func flush(_ sessionId: String) async throws -> MetadataSyncSummary {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, MetadataSyncSummary) = box.lock.withLock {
            box.flushCalls.append(sessionId)
            return (box.flushError, box.flushSummary)
        }
        if let error { throw error }
        return result
    }

    func retrySync(_ sessionId: String) async throws -> MetadataSyncSummary {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, MetadataSyncSummary) = box.lock.withLock {
            box.retrySyncCalls.append(sessionId)
            return (box.retrySyncError, box.retrySyncSummary)
        }
        if let error { throw error }
        return result
    }

    func retryFailedWriteback(_ input: Confirmed<SessionReference>) async throws -> WritebackResult {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, WritebackResult) = box.lock.withLock {
            box.retryFailedInputs.append(input)
            return (box.retryFailedError, box.retryFailedResult)
        }
        if let error { throw error }
        return result
    }

    func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, CleanupResult) = box.lock.withLock {
            box.cleanupInputs.append(input)
            return (box.cleanupError, box.cleanupResult)
        }
        if let error { throw error }
        return result
    }

    func finalizeSync(_ input: Confirmed<SessionReference>) async throws -> MetadataSyncSummary {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, MetadataSyncSummary) = box.lock.withLock {
            box.finalizeInputs.append(input)
            return (box.finalizeError, box.finalizeSummary)
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

    // P0 / T0：可配置返回/错误，并记录入参。
    func generateTriage(_ input: TriageGenerateInput) async throws -> TriageSummary {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, TriageSummary?) = box.lock.withLock {
            box.triageGenerateInputs.append(input)
            return (box.triageGenerateError, box.triageSummaryResult)
        }
        if let error { throw error }
        return result ?? TriageSummary(
            counts: TriageCounts(keep: 0, reject: 0, review: 0, total: 0, coverage: 0),
            stale: false,
            policyVersion: "triage-v1",
            inputFingerprint: "",
            generatedAt: ""
        )
    }

    func applyTriage(_ input: Confirmed<TriageApplyInput>) async throws -> TriageApplyResult {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, TriageApplyResult) = box.lock.withLock {
            box.applyTriageInputs.append(input)
            return (box.applyTriageError, box.applyTriageResult)
        }
        if let error { throw error }
        return result
    }
}

// MARK: - NavigationAPI

private struct B8NavigationState {
    var listResult: [NavigationGroup] = []
    var splitResult: [NavigationGroup] = []
    var mergeResult: [NavigationGroup] = []
    var analyzeResult: [NavigationGroup] = []
    var listError: (any Error)?
    var splitError: (any Error)?
    var mergeError: (any Error)?
    var analyzeError: (any Error)?
    var responseDelay = Duration.zero
    var listCalls: [String] = []
    var splitInputs: [NavigationSplitParams] = []
    var mergeInputs: [NavigationMergeParams] = []
    var analyzeInputs: [NavigationAnalyzeParams] = []
}

final class B8NavigationAPIStub: NavigationAPI, @unchecked Sendable {
    private let box = LockedBox(B8NavigationState())

    var listResult: [NavigationGroup] {
        get { box.lock.withLock { box.listResult } }
        set { box.lock.withLock { box.listResult = newValue } }
    }

    var splitResult: [NavigationGroup] {
        get { box.lock.withLock { box.splitResult } }
        set { box.lock.withLock { box.splitResult = newValue } }
    }

    var mergeResult: [NavigationGroup] {
        get { box.lock.withLock { box.mergeResult } }
        set { box.lock.withLock { box.mergeResult = newValue } }
    }

    var analyzeResult: [NavigationGroup] {
        get { box.lock.withLock { box.analyzeResult } }
        set { box.lock.withLock { box.analyzeResult = newValue } }
    }

    var listError: (any Error)? {
        get { box.lock.withLock { box.listError } }
        set { box.lock.withLock { box.listError = newValue } }
    }

    var splitError: (any Error)? {
        get { box.lock.withLock { box.splitError } }
        set { box.lock.withLock { box.splitError = newValue } }
    }

    var mergeError: (any Error)? {
        get { box.lock.withLock { box.mergeError } }
        set { box.lock.withLock { box.mergeError = newValue } }
    }

    var analyzeError: (any Error)? {
        get { box.lock.withLock { box.analyzeError } }
        set { box.lock.withLock { box.analyzeError = newValue } }
    }

    var responseDelay: Duration {
        get { box.lock.withLock { box.responseDelay } }
        set { box.lock.withLock { box.responseDelay = newValue } }
    }

    var listCalls: [String] { box.lock.withLock { box.listCalls } }
    var splitInputs: [NavigationSplitParams] { box.lock.withLock { box.splitInputs } }
    var mergeInputs: [NavigationMergeParams] { box.lock.withLock { box.mergeInputs } }
    var analyzeInputs: [NavigationAnalyzeParams] { box.lock.withLock { box.analyzeInputs } }

    private func delayIfNeeded() async throws {
        let delay = box.lock.withLock { box.responseDelay }
        if delay > .zero { try await Task.sleep(for: delay) }
    }

    func list(_ sessionId: String) async throws -> [NavigationGroup] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [NavigationGroup]) = box.lock.withLock {
            box.listCalls.append(sessionId)
            return (box.listError, box.listResult)
        }
        if let error { throw error }
        return result
    }

    func split(_ input: NavigationSplitParams) async throws -> [NavigationGroup] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [NavigationGroup]) = box.lock.withLock {
            box.splitInputs.append(input)
            return (box.splitError, box.splitResult)
        }
        if let error { throw error }
        return result
    }

    func merge(_ input: NavigationMergeParams) async throws -> [NavigationGroup] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [NavigationGroup]) = box.lock.withLock {
            box.mergeInputs.append(input)
            return (box.mergeError, box.mergeResult)
        }
        if let error { throw error }
        return result
    }

    func analyze(_ input: NavigationAnalyzeParams) async throws -> [NavigationGroup] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [NavigationGroup]) = box.lock.withLock {
            box.analyzeInputs.append(input)
            return (box.analyzeError, box.analyzeResult)
        }
        if let error { throw error }
        return result
    }
}
