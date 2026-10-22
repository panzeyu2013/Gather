// desktop/native/gather-app/Tests/GatherAppTests/Support/StubSimilarityAPI.swift
// Cut 1 / B8.1a 测试共享：SimilarityAPI 的类型化替身。
//
// 与 StubAPIs.swift / StubCullingAPI.swift 同款结构（LockedBox + 记录入参 +
// 可注入错误/延迟/闸）。SimilarityViewModelTests / LayoutBudgetTests 不再
// 直接注入类型化 SimilarityAPI（旧 provider 适配器已在 B8.4 删除）。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain

private struct B8SimilarityState {
    var resultValue: SimilarityResult?
    var tiers: [Int: SimilarityResult] = [:]
    var resultError: (any Error)?

    var analyzeResult = true
    var analyzeError: (any Error)?
    var analyzeGate: AsyncGate?

    var reclusterResultValue: SimilarityResult?
    var reclusterResults: [SimilarityResult] = []
    var reclusterError: (any Error)?

    var cancelResult = true
    var cancelError: (any Error)?

    var previewValue = WritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    var previewError: (any Error)?

    var writebackItemsValue: [WritebackItem] = []
    var writebackItemsError: (any Error)?

    var writebackResultValue = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: ""
    )
    var writebackError: (any Error)?

    var retryResultValue = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: ""
    )
    var retryError: (any Error)?

    var confirmResult = true
    var confirmError: (any Error)?

    var cleanupResultValue = CleanupResult(deletedCount: 0, errors: [])
    var cleanupError: (any Error)?

    var responseDelay = Duration.zero

    var resultQueries: [SimilarityResultQuery] = []
    var analyzeInputs: [SimilarityAnalyzeInput] = []
    var reclusterInputs: [SimilarityAnalyzeInput] = []
    var cancelCalls: [String] = []
    var previewInputs: [SimilarityPreviewWritebackInput] = []
    var writebackItemsCalls: [String] = []
    var writebackInputs: [Confirmed<SimilarityWritebackInput>] = []
    var retryInputs: [Confirmed<SessionReference>] = []
    var confirmCalls: [String] = []
    var cleanupInputs: [Confirmed<SessionReference>] = []
}

/// 可配置 SimilarityAPI：默认无结果、分析成功、写回空结果；记录全部类型化入参。
final class B8SimilarityAPIStub: SimilarityAPI, @unchecked Sendable {
    private let box = LockedBox(B8SimilarityState())

    var resultValue: SimilarityResult? {
        get { box.lock.withLock { box.resultValue } }
        set { box.lock.withLock { box.resultValue = newValue } }
    }

    var tiers: [Int: SimilarityResult] {
        get { box.lock.withLock { box.tiers } }
        set { box.lock.withLock { box.tiers = newValue } }
    }

    var resultError: (any Error)? {
        get { box.lock.withLock { box.resultError } }
        set { box.lock.withLock { box.resultError = newValue } }
    }

    var analyzeResult: Bool {
        get { box.lock.withLock { box.analyzeResult } }
        set { box.lock.withLock { box.analyzeResult = newValue } }
    }

    var analyzeError: (any Error)? {
        get { box.lock.withLock { box.analyzeError } }
        set { box.lock.withLock { box.analyzeError = newValue } }
    }

    var analyzeGate: AsyncGate? {
        get { box.lock.withLock { box.analyzeGate } }
        set { box.lock.withLock { box.analyzeGate = newValue } }
    }

    var reclusterResultValue: SimilarityResult? {
        get { box.lock.withLock { box.reclusterResultValue } }
        set { box.lock.withLock { box.reclusterResultValue = newValue } }
    }

    var reclusterResults: [SimilarityResult] {
        get { box.lock.withLock { box.reclusterResults } }
        set { box.lock.withLock { box.reclusterResults = newValue } }
    }

    var reclusterError: (any Error)? {
        get { box.lock.withLock { box.reclusterError } }
        set { box.lock.withLock { box.reclusterError = newValue } }
    }

    var cancelResult: Bool {
        get { box.lock.withLock { box.cancelResult } }
        set { box.lock.withLock { box.cancelResult = newValue } }
    }

    var cancelError: (any Error)? {
        get { box.lock.withLock { box.cancelError } }
        set { box.lock.withLock { box.cancelError = newValue } }
    }

    var previewValue: WritebackPreview {
        get { box.lock.withLock { box.previewValue } }
        set { box.lock.withLock { box.previewValue = newValue } }
    }

    var previewError: (any Error)? {
        get { box.lock.withLock { box.previewError } }
        set { box.lock.withLock { box.previewError = newValue } }
    }

    var writebackItemsValue: [WritebackItem] {
        get { box.lock.withLock { box.writebackItemsValue } }
        set { box.lock.withLock { box.writebackItemsValue = newValue } }
    }

    var writebackItemsError: (any Error)? {
        get { box.lock.withLock { box.writebackItemsError } }
        set { box.lock.withLock { box.writebackItemsError = newValue } }
    }

    var writebackResultValue: WritebackResult {
        get { box.lock.withLock { box.writebackResultValue } }
        set { box.lock.withLock { box.writebackResultValue = newValue } }
    }

    var writebackError: (any Error)? {
        get { box.lock.withLock { box.writebackError } }
        set { box.lock.withLock { box.writebackError = newValue } }
    }

    var retryResultValue: WritebackResult {
        get { box.lock.withLock { box.retryResultValue } }
        set { box.lock.withLock { box.retryResultValue = newValue } }
    }

    var retryError: (any Error)? {
        get { box.lock.withLock { box.retryError } }
        set { box.lock.withLock { box.retryError = newValue } }
    }

    var confirmResult: Bool {
        get { box.lock.withLock { box.confirmResult } }
        set { box.lock.withLock { box.confirmResult = newValue } }
    }

    var confirmError: (any Error)? {
        get { box.lock.withLock { box.confirmError } }
        set { box.lock.withLock { box.confirmError = newValue } }
    }

    var cleanupResultValue: CleanupResult {
        get { box.lock.withLock { box.cleanupResultValue } }
        set { box.lock.withLock { box.cleanupResultValue = newValue } }
    }

    var cleanupError: (any Error)? {
        get { box.lock.withLock { box.cleanupError } }
        set { box.lock.withLock { box.cleanupError = newValue } }
    }

    var responseDelay: Duration {
        get { box.lock.withLock { box.responseDelay } }
        set { box.lock.withLock { box.responseDelay = newValue } }
    }

    var resultQueries: [SimilarityResultQuery] { box.lock.withLock { box.resultQueries } }
    var analyzeInputs: [SimilarityAnalyzeInput] { box.lock.withLock { box.analyzeInputs } }
    var reclusterInputs: [SimilarityAnalyzeInput] { box.lock.withLock { box.reclusterInputs } }
    var cancelCalls: [String] { box.lock.withLock { box.cancelCalls } }
    var previewInputs: [SimilarityPreviewWritebackInput] { box.lock.withLock { box.previewInputs } }
    var writebackItemsCalls: [String] { box.lock.withLock { box.writebackItemsCalls } }
    var writebackInputs: [Confirmed<SimilarityWritebackInput>] { box.lock.withLock { box.writebackInputs } }
    var retryInputs: [Confirmed<SessionReference>] { box.lock.withLock { box.retryInputs } }
    var confirmCalls: [String] { box.lock.withLock { box.confirmCalls } }
    var cleanupInputs: [Confirmed<SessionReference>] { box.lock.withLock { box.cleanupInputs } }

    private func delayIfNeeded() async throws {
        let delay = box.lock.withLock { box.responseDelay }
        if delay > .zero { try await Task.sleep(for: delay) }
    }
    func result(_ query: SimilarityResultQuery) async throws -> SimilarityResult? {
        try await delayIfNeeded()
        let (error, tier, value): ((any Error)?, SimilarityResult?, SimilarityResult?) = box.lock.withLock {
            box.resultQueries.append(query)
            let tier = query.threshold.flatMap { box.tiers[$0] }
            return (box.resultError, tier, box.resultValue)
        }
        if let error { throw error }
        if let tier { return tier }
        return value
    }

    func analyze(_ input: SimilarityAnalyzeInput) async throws -> Bool {
        let (gate, error, result): (AsyncGate?, (any Error)?, Bool) = box.lock.withLock {
            box.analyzeInputs.append(input)
            return (box.analyzeGate, box.analyzeError, box.analyzeResult)
        }
        if let gate { await gate.wait() }
        try await delayIfNeeded()
        if let error { throw error }
        return result
    }

    func recluster(_ input: SimilarityAnalyzeInput) async throws -> SimilarityResult? {
        try await delayIfNeeded()
        let (error, queued, fallback): ((any Error)?, [SimilarityResult], SimilarityResult?) = box.lock.withLock {
            box.reclusterInputs.append(input)
            return (box.reclusterError, box.reclusterResults, box.reclusterResultValue)
        }
        if let error { throw error }
        if !queued.isEmpty {
            var remaining = queued
            let first = remaining.removeFirst()
            box.lock.withLock { box.reclusterResults = remaining }
            return first
        }
        return fallback
    }

    func cancelAnalysis(_ sessionId: String) async throws -> Bool {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, Bool) = box.lock.withLock {
            box.cancelCalls.append(sessionId)
            return (box.cancelError, box.cancelResult)
        }
        if let error { throw error }
        return result
    }

    func previewWriteback(
        _ input: SimilarityPreviewWritebackInput
    ) async throws -> WritebackPreview {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, WritebackPreview) = box.lock.withLock {
            box.previewInputs.append(input)
            return (box.previewError, box.previewValue)
        }
        if let error { throw error }
        return result
    }

    func writebackItems(_ sessionId: String) async throws -> [WritebackItem] {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, [WritebackItem]) = box.lock.withLock {
            box.writebackItemsCalls.append(sessionId)
            return (box.writebackItemsError, box.writebackItemsValue)
        }
        if let error { throw error }
        return result
    }

    func writeback(_ input: Confirmed<SimilarityWritebackInput>) async throws -> WritebackResult {
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
            box.confirmCalls.append(sessionId)
            return (box.confirmError, box.confirmResult)
        }
        if let error { throw error }
        return result
    }

    func retryFailedWriteback(
        _ input: Confirmed<SessionReference>
    ) async throws -> WritebackResult {
        try await delayIfNeeded()
        let (error, result): ((any Error)?, WritebackResult) = box.lock.withLock {
            box.retryInputs.append(input)
            return (box.retryError, box.retryResultValue)
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
}

// MARK: - 夹具

func b8SimilarityResult(
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
            images: [
                SimilarityImage(path: "/vault/a\(index).NEF", representative: true),
                SimilarityImage(path: "/vault/b\(index).JPG")
            ]
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

/// 可写回的预览项（含 id，供 writeback itemIds 断言）。
func b8SimilarityWritebackItem(
    id: Int = 1,
    photoId: String = "photo-1",
    status: String = "pending",
    keywords: [String] = ["旅行"]
) -> WritebackItem {
    WritebackItem(
        id: id,
        photoId: photoId,
        photoPath: "/vault/\(photoId).NEF",
        sessionId: "s1",
        module: "similarity",
        keywords: keywords,
        xmpPath: "/vault/\(photoId).xmp",
        backupPath: "",
        xmpStatus: status,
        errorMessage: "",
        attemptCount: 0,
        lastAttemptAt: "",
        preview: nil
    )
}
