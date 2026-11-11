// desktop/native/gather-app/Tests/GatherAppTests/SemanticSearchSheetModelTests.swift
// Wave4a / task-39（E2 UI 侧）：场景标签写回面板的批级撤销——写回保存服务端回传的
// appliedPhotoIds，撤销只回传本批 scope；没有可撤销批次时不得调用写回 API（防误删）。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

private enum SemanticSheetStubError: Error { case unavailable }

private struct SemanticSheetPathPolicy: PhotoPathPolicy {
    func containsFilepath(_ path: String) async throws -> Bool { false }
}

private final class SemanticSheetPhotoAPIStub: PhotoAPI, @unchecked Sendable {
    let pathPolicy: any PhotoPathPolicy = SemanticSheetPathPolicy()

    private let lock = NSLock()
    private var recordedInputs: [SemanticKeywordApplyInput] = []
    var appliedResult = SemanticKeywordApplyResult(
        sessionId: "s1", appliedPhotos: 0, appliedPhotoIds: [], skippedPhotos: 0,
        keywordsAdded: 0, keywordsRemoved: 0, batchId: "b-0")
    var keywordPlan = SemanticKeywordPlan(
        sessionId: "s1", root: SemanticKeywordPath.scene, items: [],
        photosWithLabels: 0, photosWithoutLabels: 0, totalAdditions: 0)

    var inputs: [SemanticKeywordApplyInput] {
        lock.lock(); defer { lock.unlock() }
        return recordedInputs
    }

    func page(_ query: PhotoPageQuery) async throws -> PhotoPage {
        throw SemanticSheetStubError.unavailable
    }
    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        throw SemanticSheetStubError.unavailable
    }
    func select(_ query: PhotoSelectionQuery) async throws -> PhotoSelectionIds {
        throw SemanticSheetStubError.unavailable
    }
    func suggestions(_ query: PhotoSuggestionQuery) async throws -> [FilterSuggestion] {
        throw SemanticSheetStubError.unavailable
    }
    func facets(_ input: PhotoFacetInput) async throws -> [PhotoFacetGroup] { [] }
    func dimensions(_ input: PhotoDimensionsInput) async throws -> [String: PhotoDimensions] {
        throw SemanticSheetStubError.unavailable
    }
    func prioritizeThumbnail(_ input: ThumbnailPrioritizeInput) async throws {
        throw SemanticSheetStubError.unavailable
    }
    func preloadThumbnails(_ input: ThumbnailPreloadInput) async throws -> JobHandle? {
        throw SemanticSheetStubError.unavailable
    }
    func preloadPreviews(_ input: PreviewPreloadInput) async throws {
        throw SemanticSheetStubError.unavailable
    }

    func semanticSearch(
        _ query: SemanticSearchQuery
    ) async throws -> SemanticSearchOutcomeSnapshot {
        SemanticSearchOutcomeSnapshot(
            sessionId: query.sessionId, method: "featurePrint", hits: [],
            scanned: 0, skipped: 0, unavailableReason: nil)
    }

    func semanticKeywordPlan(
        _ input: SemanticKeywordPlanInput
    ) async throws -> SemanticKeywordPlan {
        keywordPlan
    }

    func applySemanticKeywords(
        _ input: Confirmed<SemanticKeywordApplyInput>
    ) async throws -> SemanticKeywordApplyResult {
        lock.withLock { recordedInputs.append(input.value) }
        return appliedResult
    }
}

/// 内存 store：现有 UI 用例不碰真实 Application Support（隔离测试副作用）。
@MainActor
private final class InMemorySemanticKeywordBatchStore: SemanticKeywordBatchStoring {
    private var records: [String: SemanticKeywordBatchRecord] = [:]

    func load(sessionId: String) -> SemanticKeywordBatchRecord? { records[sessionId] }
    func save(_ record: SemanticKeywordBatchRecord, sessionId: String) { records[sessionId] = record }
    func clear(sessionId: String) { records[sessionId] = nil }
}

@MainActor
struct SemanticSearchSheetModelTests {
    private let l10n = L10n(language: .zhCN)

    @Test("写回保存 appliedPhotoIds；撤销只回传本批 scope，完成后清空（E2）")
    func undoUsesAppliedBatchScope() async {
        let api = SemanticSheetPhotoAPIStub()
        api.appliedResult = SemanticKeywordApplyResult(
            sessionId: "s1", appliedPhotos: 2, appliedPhotoIds: ["p1", "p2"],
            skippedPhotos: 0, keywordsAdded: 2, keywordsRemoved: 0, batchId: "b-1")
        let model = SemanticSearchSheetModel(
            api: api, sessionId: "s1", seedPhotoIds: [],
            batchStore: InMemorySemanticKeywordBatchStore())

        await model.applyWriteback(.write, l10n: l10n)
        #expect(api.inputs.count == 1)
        #expect(api.inputs.first?.remove == false)
        #expect(api.inputs.first?.photoIds == nil, "写回本身是会话范围（与预览一致）")
        #expect(model.canUndoWriteback)
        #expect(model.lastWriteScopePhotoIds == ["p1", "p2"])

        api.appliedResult = SemanticKeywordApplyResult(
            sessionId: "s1", appliedPhotos: 2, appliedPhotoIds: ["p1", "p2"],
            skippedPhotos: 0, keywordsAdded: 0, keywordsRemoved: 2, batchId: "b-2")
        await model.applyWriteback(.undo, l10n: l10n)
        #expect(api.inputs.count == 2)
        #expect(api.inputs[1].remove == true)
        #expect(api.inputs[1].photoIds == ["p1", "p2"], "撤销必须只清上一次写回改动的照片")
        #expect(model.canUndoWriteback == false)
        #expect(model.lastWriteScopePhotoIds.isEmpty, "撤销后不应再允许重复撤销")
    }

    @Test("没有可撤销批次时不调用写回 API（E2：防会话级误删）")
    func undoWithoutScopeDoesNotCallAPI() async {
        let api = SemanticSheetPhotoAPIStub()
        let model = SemanticSearchSheetModel(
            api: api, sessionId: "s1", seedPhotoIds: [],
            batchStore: InMemorySemanticKeywordBatchStore())
        await model.applyWriteback(.undo, l10n: l10n)
        #expect(api.inputs.isEmpty, "无批可撤时绝不能带着 nil photoIds 去删整个会话")
        #expect(model.canUndoWriteback == false)
        #expect(model.error == nil)
        #expect(model.notice?.isEmpty == false)
    }

    @Test("空写回不覆盖上一批撤销入口（E2：additions=0 时不能丢 scope）")
    func emptyWriteKeepsPreviousBatch() async {
        let store = InMemorySemanticKeywordBatchStore()
        let api = SemanticSheetPhotoAPIStub()
        api.appliedResult = SemanticKeywordApplyResult(
            sessionId: "s1", appliedPhotos: 1, appliedPhotoIds: ["p1"],
            skippedPhotos: 0, keywordsAdded: 1, keywordsRemoved: 0, batchId: "b-1")
        let model = SemanticSearchSheetModel(
            api: api, sessionId: "s1", seedPhotoIds: [], batchStore: store)
        await model.applyWriteback(.write, l10n: l10n)
        #expect(model.lastWriteScopePhotoIds == ["p1"])

        // 第二次写回没写到任何照片（例如全部已存在/被并发清掉）：不能把上一批清掉。
        api.appliedResult = SemanticKeywordApplyResult(
            sessionId: "s1", appliedPhotos: 0, appliedPhotoIds: [],
            skippedPhotos: 0, keywordsAdded: 0, keywordsRemoved: 0, batchId: "b-2")
        await model.applyWriteback(.write, l10n: l10n)
        #expect(model.canUndoWriteback, "空写不能让撤销入口消失")
        #expect(model.lastWriteScopePhotoIds == ["p1"])
        #expect(store.load(sessionId: "s1")?.photoIds == ["p1"])
    }

    @Test("写回批次持久化：新模型（模拟重启）加载后 undo 用持久化 scope（E2 收尾）")
    func undoScopePersistsAcrossModels() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-batch-\(UUID().uuidString)", isDirectory: true)
        defer { do { try FileManager.default.removeItem(at: dir) } catch {} }
        let store = FileSemanticKeywordBatchStore(directory: dir)

        let api = SemanticSheetPhotoAPIStub()
        api.appliedResult = SemanticKeywordApplyResult(
            sessionId: "s1", appliedPhotos: 2, appliedPhotoIds: ["p1", "p2"],
            skippedPhotos: 0, keywordsAdded: 2, keywordsRemoved: 0, batchId: "b-1")
        let model = SemanticSearchSheetModel(
            api: api, sessionId: "s1", seedPhotoIds: [],
            batchStore: store, timestamp: { "2026-11-11T00:00:00Z" })
        await model.applyWriteback(.write, l10n: l10n)
        #expect(model.canUndoWriteback)
        let saved = store.load(sessionId: "s1")
        #expect(saved?.photoIds == ["p1", "p2"])
        #expect(saved?.batchId == "b-1")
        #expect(saved?.savedAt == "2026-11-11T00:00:00Z")

        // 模拟重启：新模型 + 新 store 实例（同一目录）→ 撤销入口与 scope 都要恢复。
        let api2 = SemanticSheetPhotoAPIStub()
        api2.appliedResult = SemanticKeywordApplyResult(
            sessionId: "s1", appliedPhotos: 2, appliedPhotoIds: ["p1", "p2"],
            skippedPhotos: 0, keywordsAdded: 0, keywordsRemoved: 2, batchId: "b-2")
        let restored = SemanticSearchSheetModel(
            api: api2, sessionId: "s1", seedPhotoIds: [],
            batchStore: FileSemanticKeywordBatchStore(directory: dir))
        #expect(restored.canUndoWriteback, "重启后仍应允许撤销上一次写回")
        #expect(restored.lastWriteScopePhotoIds == ["p1", "p2"])
        #expect(restored.lastBatchSavedAt == "2026-11-11T00:00:00Z")

        await restored.applyWriteback(.undo, l10n: l10n)
        #expect(api2.inputs.count == 1)
        #expect(api2.inputs.first?.photoIds == ["p1", "p2"], "undo 必须用持久化 scope")
        #expect(restored.canUndoWriteback == false)
        #expect(FileSemanticKeywordBatchStore(directory: dir).load(sessionId: "s1") == nil,
                "撤销完成后持久化批次应清空，避免旧入口复活")
    }

    @Test("持久化文件损坏 → 回退无批次：不崩、undo 不调 API（E2 收尾）")
    func corruptedBatchFileFallsBack() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-batch-\(UUID().uuidString)", isDirectory: true)
        defer { do { try FileManager.default.removeItem(at: dir) } catch {} }
        let store = FileSemanticKeywordBatchStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not-json{{{".utf8).write(to: store.fileURL(sessionId: "s1"))

        let api = SemanticSheetPhotoAPIStub()
        let model = SemanticSearchSheetModel(
            api: api, sessionId: "s1", seedPhotoIds: [], batchStore: store)
        #expect(model.canUndoWriteback == false, "损坏文件不能当成有效批次")
        #expect(model.lastWriteScopePhotoIds.isEmpty)
        await model.applyWriteback(.undo, l10n: l10n)
        #expect(api.inputs.isEmpty)
        #expect(model.error == nil)
        #expect(model.notice?.isEmpty == false)
    }
}
