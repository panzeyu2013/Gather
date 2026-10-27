// desktop/native/gather-app/Tests/GatherAppTests/CullingKeywordViewModelTests.swift
// P0 / K0：关键词面板的 VM 状态、delta 入参、错误映射与补全。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

private enum KeywordPhotoStubError: Error { case unavailable }

private struct KeywordPhotoPathPolicy: PhotoPathPolicy {
    func containsFilepath(_ path: String) async throws -> Bool { false }
}

private final class KeywordPhotoAPIStub: PhotoAPI, @unchecked Sendable {
    func facets(_ input: PhotoFacetInput) async throws -> [PhotoFacetGroup] { [] }
    let pathPolicy: any PhotoPathPolicy = KeywordPhotoPathPolicy()
    var suggestionResult: [FilterSuggestion] = []
    var suggestionError: (any Error)?
    private(set) var queries: [PhotoSuggestionQuery] = []

    func page(_ query: PhotoPageQuery) async throws -> PhotoPage { throw KeywordPhotoStubError.unavailable }
    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult { throw KeywordPhotoStubError.unavailable }
    func suggestions(_ query: PhotoSuggestionQuery) async throws -> [FilterSuggestion] {
        queries.append(query)
        if let suggestionError { throw suggestionError }
        return suggestionResult
    }
    func dimensions(_ input: PhotoDimensionsInput) async throws -> [String: PhotoDimensions] {
        throw KeywordPhotoStubError.unavailable
    }
    func prioritizeThumbnail(_ input: ThumbnailPrioritizeInput) async throws {
        throw KeywordPhotoStubError.unavailable
    }
    func preloadThumbnails(_ input: ThumbnailPreloadInput) async throws -> JobHandle? {
        throw KeywordPhotoStubError.unavailable
    }
    func preloadPreviews(_ input: PreviewPreloadInput) async throws {
        throw KeywordPhotoStubError.unavailable
    }
}

@MainActor
private func makeKeywordVM(
    photo: (any PhotoAPI)? = nil
) -> (vm: CullingViewModel, metadata: B6bMetadataAPIStub, photoStub: KeywordPhotoAPIStub?) {
    let metadata = B6bMetadataAPIStub()
    let photoStub = photo as? KeywordPhotoAPIStub
    let vm = CullingViewModel(
        sessionId: "s1",
        culling: B8CullingAPIStub(),
        navigation: B8NavigationAPIStub(),
        metadata: metadata,
        jobs: B5bJobAPIStub(),
        quality: B5bQualityAPIStub(),
        captureOne: CaptureOneBridge(),
        photo: photo
    )
    return (vm, metadata, photoStub)
}

@MainActor
private func seedSelection(_ vm: CullingViewModel) {
    vm.page = CullingPage(
        assets: [
            b8CullingAsset("p1", keywords: ["Bride", "仪式"]),
            b8CullingAsset("p2", keywords: ["Bride"]),
        ],
        total: 2
    )
    vm.loadedPhotoIds = ["p1", "p2"]
    vm.currentPhotoId = "p1"
    vm.selectedPhotoIds = ["p1", "p2"]
}

@MainActor
@Suite("K0 关键词面板 VM")
struct CullingKeywordViewModelTests {
    @Test("多选并集与部分命中")
    func unionAndPartial() {
        let (vm, _, _) = makeKeywordVM()
        seedSelection(vm)

        #expect(vm.keywordTargetCount == 2)
        #expect(vm.keywordExistingKeywords == ["Bride", "仪式"])
        #expect(vm.keywordIsPartial("仪式"))
        #expect(!vm.keywordIsPartial("Bride"))
        #expect(vm.keywordCanPreview == false)
    }

    @Test("新增/移除与大小写去重")
    func addRemove() {
        let (vm, _, _) = makeKeywordVM()
        seedSelection(vm)

        vm.addKeyword("  新娘  ")
        #expect(vm.keywordAdded == ["新娘"])

        vm.addKeyword("bride")
        #expect(vm.keywordAdded == ["新娘"])

        vm.removeKeyword("仪式")
        #expect(vm.keywordRemoved == ["仪式"])
        #expect(vm.keywordEffectiveKeywords == ["Bride", "新娘"])
        #expect(vm.keywordCanPreview)

        vm.removeKeyword("新娘")
        #expect(vm.keywordAdded.isEmpty)
        #expect(vm.keywordEffectiveKeywords == ["Bride"])
    }

    @Test("预览记录 photoIds/added/removed 入参")
    func previewInputs() async {
        let (vm, metadata, _) = makeKeywordVM()
        seedSelection(vm)
        metadata.keywordPreviewResult = WritebackPreview(items: [], totalCount: 1, affectedPhotos: 2)
        vm.addKeyword("新娘")
        vm.removeKeyword("仪式")

        await vm.previewKeywordWriteback()

        let input = try? #require(metadata.keywordPreviewInputs.first)
        #expect(input?.photoIds == ["p1", "p2"])
        #expect(input?.addedKeywords == ["新娘"])
        #expect(input?.removedKeywords == ["仪式"])
        #expect(vm.keywordPreview != nil)
        #expect(vm.keywordCanApply)
    }

    @Test("应用构造 Confirmed 入参、成功后清空草稿")
    func applyInputsAndReset() async {
        let (vm, metadata, _) = makeKeywordVM()
        seedSelection(vm)
        metadata.keywordPreviewResult = WritebackPreview(items: [], totalCount: 1, affectedPhotos: 2)
        metadata.keywordApplyResult = MetadataKeywordApplyResult(
            result: WritebackResult(
                totalAffected: 2, written: 2, failed: 0, skipped: 0,
                errors: [], failedItems: [], report: ""),
            status: MetadataSyncSummary(
                sessionId: "s1", pending: 0, writing: 0, written: 2,
                failed: 0, conflict: 0, synced: 0, items: [])
        )
        vm.addKeyword("新娘")
        await vm.previewKeywordWriteback()
        await vm.applyKeywordWriteback()

        let confirmed = try? #require(metadata.keywordApplyInputs.first)
        #expect(confirmed?.value.addedKeywords == ["新娘"])
        #expect(confirmed?.source == .userDialog)
        #expect(vm.keywordAdded.isEmpty)
        #expect(vm.keywordPreview == nil)
        #expect(vm.keywordResult?.result.written == 2)
    }

    @Test("生成词删除错误映射为 KEYWORD_OWNED_BY_SOURCE")
    func ownedKeywordError() async {
        let (vm, metadata, _) = makeKeywordVM()
        seedSelection(vm)
        metadata.keywordPreviewResult = WritebackPreview(items: [], totalCount: 1, affectedPhotos: 2)
        metadata.keywordApplyError = GatherError(
            code: .KEYWORD_OWNED_BY_SOURCE,
            params: ["keyword": "Bride", "source": "face-keyword"]
        )
        vm.addKeyword("新娘")
        await vm.previewKeywordWriteback()
        await vm.applyKeywordWriteback()

        #expect(vm.keywordError?.code == "KEYWORD_OWNED_BY_SOURCE")
        #expect(vm.keywordAdded == ["新娘"], "失败时保留草稿，允许修正/重试")
    }

    @Test("重试调用 retryKeywordWriteback 并携带会话")
    func retry() async {
        let (vm, metadata, _) = makeKeywordVM()
        seedSelection(vm)
        metadata.keywordRetryResult = emptyKeywordApplyResultForTest(written: 1)

        await vm.retryKeywordWriteback()

        #expect(metadata.keywordRetryInputs.first?.value.sessionId == "s1")
        #expect(vm.keywordResult?.result.written == 1)
    }

    @Test("无 PhotoAPI 时退回本地关键词补全")
    func localSuggestions() async {
        let (vm, _, _) = makeKeywordVM()
        seedSelection(vm)
        vm.page = CullingPage(
            assets: [
                b8CullingAsset("p1", keywords: ["Bride"]),
                b8CullingAsset("p2", keywords: ["Bridal"]),
            ],
            total: 2
        )
        vm.selectedPhotoIds = ["p1"]

        await vm.loadKeywordSuggestions(prefix: "bri")

        #expect(vm.keywordSuggestions.contains("Bridal"))
        #expect(!vm.keywordSuggestions.contains("Bride"), "已有词不应作为建议")
    }

    @Test("PhotoAPI suggestions 优先")
    func serverSuggestions() async {
        let photo = KeywordPhotoAPIStub()
        photo.suggestionResult = [FilterSuggestion(field: "keyword", values: ["Bridal"])]
        let (vm, _, stub) = makeKeywordVM(photo: photo)
        seedSelection(vm)

        await vm.loadKeywordSuggestions(prefix: "bri")

        #expect(stub?.queries.first?.sessionId == "s1")
        #expect(vm.keywordSuggestions == ["Bridal"])
    }

    @Test("500 张上限：超出时不可预览")
    func selectionLimit() {
        let (vm, _, _) = makeKeywordVM()
        let assets = (1...501).map { b8CullingAsset("p\($0)") }
        vm.page = CullingPage(assets: assets, total: assets.count)
        vm.loadedPhotoIds = Set(assets.map(\.photo.id))
        vm.selectedPhotoIds = vm.loadedPhotoIds

        #expect(vm.keywordTargetCount == 501)
        #expect(!vm.keywordCanEdit)
        #expect(!vm.keywordCanPreview)
    }
}

private func emptyKeywordApplyResultForTest(written: Int) -> MetadataKeywordApplyResult {
    MetadataKeywordApplyResult(
        result: WritebackResult(
            totalAffected: written, written: written, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: ""),
        status: MetadataSyncSummary(
            sessionId: "s1", pending: 0, writing: 0, written: written,
            failed: 0, conflict: 0, synced: 0, items: [])
    )
}
