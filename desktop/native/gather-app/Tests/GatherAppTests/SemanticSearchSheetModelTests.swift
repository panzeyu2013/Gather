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

@MainActor
struct SemanticSearchSheetModelTests {
    private let l10n = L10n(language: .zhCN)

    @Test("写回保存 appliedPhotoIds；撤销只回传本批 scope，完成后清空（E2）")
    func undoUsesAppliedBatchScope() async {
        let api = SemanticSheetPhotoAPIStub()
        api.appliedResult = SemanticKeywordApplyResult(
            sessionId: "s1", appliedPhotos: 2, appliedPhotoIds: ["p1", "p2"],
            skippedPhotos: 0, keywordsAdded: 2, keywordsRemoved: 0, batchId: "b-1")
        let model = SemanticSearchSheetModel(api: api, sessionId: "s1", seedPhotoIds: [])

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
        let model = SemanticSearchSheetModel(api: api, sessionId: "s1", seedPhotoIds: [])
        await model.applyWriteback(.undo, l10n: l10n)
        #expect(api.inputs.isEmpty, "无批可撤时绝不能带着 nil photoIds 去删整个会话")
        #expect(model.canUndoWriteback == false)
        #expect(model.error == nil)
        #expect(model.notice?.isEmpty == false)
    }
}
