// desktop/native/gather-core/Tests/GatherCoreTests/Services/RecordingFaceWritebackProvider.swift
// 测试替身收口（P2）：FaceWritebackProvider 的唯一共享记录器。
//
// 原 FakeWritebackProvider（FaceKeywordingServiceTests）与 MirrorFaceWriteback
// （DeliveryFaceSimilarityMirrorTests）语义一致，收口后按需注入返回值/失败，
// 并记录调用入参。测试串行执行，可变状态仅做记录，故标 @unchecked Sendable。

import Foundation
import GatherApplication

/// 可配置的 face_kw 写回端口记录器：返回值可注入，调用入参按序记录。
final class RecordingFaceWritebackProvider: FaceWritebackProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var removedEntriesStorage: [FaceKeywordEntry] = []
    private var previewArgsStorage: (
        options: FaceKwWritebackOptions?, boundPhotoIds: Set<String>, additions: [String: [String]]
    )?
    private var executedItemsStorage: [FaceKwWritebackItem] = []
    private var syncedSessionIdsStorage: [String] = []
    private var cleanupCallsStorage: [String] = []

    var removedKeywords: [String] = ["Alice"]
    var previewResult = FaceKwWritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    var executeResult = FaceKwWritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: "")
    var executeError: Error?

    var removedEntries: [FaceKeywordEntry] {
        lock.withLock { removedEntriesStorage }
    }

    var previewArgs: (
        options: FaceKwWritebackOptions?, boundPhotoIds: Set<String>, additions: [String: [String]]
    )? {
        lock.withLock { previewArgsStorage }
    }

    var executedItems: [FaceKwWritebackItem] {
        lock.withLock { executedItemsStorage }
    }

    var syncedSessionIds: [String] {
        lock.withLock { syncedSessionIdsStorage }
    }

    var cleanupCalls: [String] {
        lock.withLock { cleanupCallsStorage }
    }

    func removeOwnedFaceKeywords(
        sessionId: String, entries: [FaceKeywordEntry]
    ) async throws -> [String] {
        lock.withLock { removedEntriesStorage = entries }
        return removedKeywords
    }

    func preview(
        sessionId: String,
        options: FaceKwWritebackOptions?,
        boundPhotoIds: Set<String>,
        additions: [String: [String]]
    ) async throws -> FaceKwWritebackPreview {
        lock.withLock { previewArgsStorage = (options, boundPhotoIds, additions) }
        return previewResult
    }

    func execute(
        sessionId: String, items: [FaceKwWritebackItem]
    ) async throws -> FaceKwWritebackResult {
        lock.withLock { executedItemsStorage = items }
        if let executeError { throw executeError }
        return executeResult
    }

    func confirmSync(sessionId: String) async throws {
        lock.withLock { syncedSessionIdsStorage.append(sessionId) }
    }

    func cleanup(sessionId: String) async throws -> FaceKwCleanupResult {
        lock.withLock { cleanupCallsStorage.append(sessionId) }
        return FaceKwCleanupResult(deletedCount: 0, errors: [])
    }
}
