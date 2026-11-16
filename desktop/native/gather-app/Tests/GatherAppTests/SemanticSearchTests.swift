// desktop/native/gather-app/Tests/GatherAppTests/SemanticSearchTests.swift
// Wave5 batch7（E4 / 40-metadata-search D3 补充）：场景标签中文化（显示/检索/写回预览）。
//
// 覆盖：
// 1. SemanticLabelCatalog：30–60 个标签、中文显示名唯一、双向映射、别名、未命中回落；
// 2. 中文输入先映射英文再调用既有 labels 检索（API 入参必须英文）；
// 3. 结果行展示中文名 + 英文原标签（displayText）；
// 4. 写回预览显示中文名，关键词路径仍是 AI|场景|<英文>（可逆，不写中文）。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

private enum SemanticTestsStubError: Error { case unavailable }

private struct SemanticTestsPathPolicy: PhotoPathPolicy {
    func containsFilepath(_ path: String) async throws -> Bool { false }
}

private final class SemanticTestsPhotoAPIStub: PhotoAPI, @unchecked Sendable {
    let pathPolicy: any PhotoPathPolicy = SemanticTestsPathPolicy()

    private let lock = NSLock()
    private var recordedSemanticQueries: [SemanticSearchQuery] = []
    var semanticHits: [SemanticSearchHitSnapshot] = []
    var keywordPlan = SemanticKeywordPlan(
        sessionId: "s1", root: SemanticKeywordPath.scene, items: [],
        photosWithLabels: 0, photosWithoutLabels: 0, totalAdditions: 0)
    var appliedResult = SemanticKeywordApplyResult(
        sessionId: "s1", appliedPhotos: 0, appliedPhotoIds: [], skippedPhotos: 0,
        keywordsAdded: 0, keywordsRemoved: 0, batchId: "b-0")

    var semanticQueries: [SemanticSearchQuery] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSemanticQueries
    }

    func page(_ query: PhotoPageQuery) async throws -> PhotoPage {
        throw SemanticTestsStubError.unavailable
    }
    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        throw SemanticTestsStubError.unavailable
    }
    func select(_ query: PhotoSelectionQuery) async throws -> PhotoSelectionIds {
        throw SemanticTestsStubError.unavailable
    }
    func suggestions(_ query: PhotoSuggestionQuery) async throws -> [FilterSuggestion] {
        throw SemanticTestsStubError.unavailable
    }
    func facets(_ input: PhotoFacetInput) async throws -> [PhotoFacetGroup] { [] }
    func dimensions(_ input: PhotoDimensionsInput) async throws -> [String: PhotoDimensions] {
        throw SemanticTestsStubError.unavailable
    }
    func prioritizeThumbnail(_ input: ThumbnailPrioritizeInput) async throws {
        throw SemanticTestsStubError.unavailable
    }
    func preloadThumbnails(_ input: ThumbnailPreloadInput) async throws -> JobHandle? {
        throw SemanticTestsStubError.unavailable
    }
    func preloadPreviews(_ input: PreviewPreloadInput) async throws {
        throw SemanticTestsStubError.unavailable
    }

    func semanticSearch(
        _ query: SemanticSearchQuery
    ) async throws -> SemanticSearchOutcomeSnapshot {
        lock.withLock { recordedSemanticQueries.append(query) }
        return SemanticSearchOutcomeSnapshot(
            sessionId: query.sessionId,
            method: query.labels.isEmpty ? "featurePrint" : "labels",
            hits: semanticHits,
            scanned: semanticHits.count,
            skipped: 0)
    }

    func semanticKeywordPlan(
        _ input: SemanticKeywordPlanInput
    ) async throws -> SemanticKeywordPlan {
        keywordPlan
    }

    func applySemanticKeywords(
        _ input: Confirmed<SemanticKeywordApplyInput>
    ) async throws -> SemanticKeywordApplyResult {
        appliedResult
    }
}

/// 内存 store：测试不碰真实 Application Support。
@MainActor
private final class SemanticTestsBatchStore: SemanticKeywordBatchStoring {
    private var records: [String: SemanticKeywordBatchRecord] = [:]

    func load(sessionId: String) -> SemanticKeywordBatchRecord? { records[sessionId] }
    func save(_ record: SemanticKeywordBatchRecord, sessionId: String) { records[sessionId] = record }
    func clear(sessionId: String) { records[sessionId] = nil }
}

@Suite("场景标签中文映射（Wave5 batch7）")
struct SemanticLabelCatalogTests {
    @Test("30–60 个标签；中文显示名唯一（反向映射才确定）")
    func catalogSizeAndUniqueDisplayNames() {
        let english = SemanticLabelCatalog.supportedEnglishLabels
        #expect(english.count >= 30)
        #expect(english.count <= 60)
        let chinese = english.map { SemanticLabelCatalog.displayName(for: $0) }
        #expect(chinese.allSatisfy { !$0.isEmpty })
        #expect(Set(chinese).count == chinese.count, "中文显示名重复会让反向映射不确定")
    }

    @Test("双向映射：英文→中文；中文/别名→英文；未命中回落原串；英文规范化")
    func bidirectionalMapping() {
        #expect(SemanticLabelCatalog.displayName(for: "beach") == "海滩")
        #expect(SemanticLabelCatalog.displayName(for: "Wedding") == "婚礼")
        #expect(SemanticLabelCatalog.displayName(for: "unknown_label") == "unknown_label")

        #expect(SemanticLabelCatalog.englishLabels(for: ["海滩"]) == ["beach"])
        #expect(SemanticLabelCatalog.englishLabels(for: ["婚礼", "beach"]) == ["wedding", "beach"])
        #expect(SemanticLabelCatalog.englishLabels(for: ["沙滩"]) == ["beach"], "别名也应能映射")
        #expect(SemanticLabelCatalog.englishLabels(for: ["foo_bar"]) == ["foo bar"])
        #expect(SemanticLabelCatalog.englishLabels(for: ["不存在的词"]) == ["不存在的词"],
                "未收录中文原样透传，交给检索与 UI 提示")
        #expect(SemanticLabelCatalog.normalize("  Wedding_Ceremony ") == "wedding ceremony")
        // 结果展示：已收录中文名、未收录回落英文原串（不吞掉新标签）。
        #expect(SemanticLabelCatalog.displayList(["beach", "unknown_scene"])
            == ["海滩", "unknown_scene"])
    }

    @Test("写回路径取英文段；不翻译（AI|场景|beach → beach）")
    func labelSegmentFromKeywordPath() {
        #expect(SemanticLabelCatalog.labelSegment(of: "AI|场景|beach") == "beach")
        #expect(SemanticLabelCatalog.labelSegment(of: "beach") == nil)
    }
}

@Suite("场景标签中文化：检索与写回预览（Wave5 batch7）")
@MainActor
struct SemanticSearchChineseDisplayTests {
    private let l10n = L10n(language: .zhCN)

    private func makeModel(api: SemanticTestsPhotoAPIStub) -> SemanticSearchSheetModel {
        SemanticSearchSheetModel(
            api: api, sessionId: "s1", seedPhotoIds: [],
            batchStore: SemanticTestsBatchStore())
    }

    @Test("中文输入先映射英文再检索；结果行中文名 + 英文原标签都可展示")
    func chineseQueryMapsToEnglishLabels() async {
        let api = SemanticTestsPhotoAPIStub()
        api.semanticHits = [SemanticSearchHitSnapshot(
            photoId: "p1", similarity: nil,
            labels: ["beach", "wedding"],
            matchedLabels: ["beach", "wedding"])]
        let model = makeModel(api: api)
        model.mode = .labels
        model.labelQuery = "海滩, 婚礼"

        #expect(model.labelMappings.map(\.input) == ["海滩", "婚礼"])
        #expect(model.labelMappings.map(\.english) == ["beach", "wedding"])

        await model.searchLabels(l10n: l10n)
        #expect(api.semanticQueries.count == 1)
        #expect(api.semanticQueries.first?.labels == ["beach", "wedding"],
                "检索参数必须仍是英文标签")
        let matched = model.hits.first?.matchedLabels ?? []
        #expect(model.displayText(matched) == "海滩 · 婚礼")
        #expect(matched.joined(separator: " · ") == "beach · wedding")
        #expect(model.notice == nil)
    }

    @Test("英文输入不翻译：原样作为检索参数（大小写/下划线规范化）")
    func englishQueryPassesThrough() async {
        let api = SemanticTestsPhotoAPIStub()
        let model = makeModel(api: api)
        model.mode = .labels
        model.labelQuery = "Beach, wedding_ceremony"
        #expect(model.labelMappings.isEmpty, "英文输入不需要中文映射提示")

        await model.searchLabels(l10n: l10n)
        #expect(api.semanticQueries.first?.labels == ["beach", "wedding ceremony"])
    }

    @Test("未收录中文：原样透传 + 空结果给换词提示（不能静默空）")
    func unknownChineseFallsBackWithHint() async {
        let api = SemanticTestsPhotoAPIStub()
        let model = makeModel(api: api)
        model.mode = .labels
        model.labelQuery = "不存在的标签"

        #expect(model.unmappedChineseTerms == ["不存在的标签"])
        #expect(model.labelMappings.isEmpty)
        await model.searchLabels(l10n: l10n)
        #expect(api.semanticQueries.first?.labels == ["不存在的标签"])
        #expect(model.hits.isEmpty)
        #expect(model.notice?.contains("暂无映射") == true)
    }

    @Test("写回预览显示中文名，路径仍是英文（AI|场景|beach，可逆）")
    func writebackPreviewShowsChineseButKeepsEnglishPath() async {
        let api = SemanticTestsPhotoAPIStub()
        api.keywordPlan = SemanticKeywordPlan(
            sessionId: "s1", root: "AI|场景",
            items: [SemanticKeywordPlanItem(
                photoId: "p1",
                keywords: ["AI|场景|beach", "AI|场景|wedding"],
                alreadyPresent: false)],
            photosWithLabels: 1, photosWithoutLabels: 0, totalAdditions: 2)
        let model = makeModel(api: api)

        await model.previewWriteback(l10n: l10n)
        let planned = model.plannedKeywords
        #expect(planned.map(\.displayName) == ["海滩", "婚礼"])
        #expect(planned.map(\.englishLabel) == ["beach", "wedding"])
        #expect(planned.map(\.path) == ["AI|场景|beach", "AI|场景|wedding"],
                "写回路径必须保留英文标签，中文只用于显示")
        #expect(planned.allSatisfy {
            SemanticLabelCatalog.labelSegment(of: $0.path) == $0.englishLabel
        })
    }

    @Test("未预览前没有写回关键词预览")
    func noPlannedKeywordsBeforePreview() {
        let model = makeModel(api: SemanticTestsPhotoAPIStub())
        #expect(model.plannedKeywords.isEmpty)
    }
}

// MARK: - Wave5 batch8：场景标签入口上移（挑片/Gallery 常驻入口）

@Suite("场景标签入口 gating（Wave5 batch8）")
struct SceneTagsEntryTests {
    @Test("有语义 API + 有种子才可开；无 API / 无种子都禁用")
    func gating() {
        #expect(SceneTagsEntryPolicy.canOpenSceneTags(
            hasSemanticAPI: true, selection: ["p1"]))
        #expect(!SceneTagsEntryPolicy.canOpenSceneTags(
            hasSemanticAPI: false, selection: ["p1"]),
            "photoAPI 未接线时必须禁用并说明，不能静默无反应")
        #expect(!SceneTagsEntryPolicy.canOpenSceneTags(
            hasSemanticAPI: true, selection: []))
    }

    @Test("种子选择集映射：选择集优先、去重排序；无选择用当前照片；都无则空")
    func seedMapping() {
        #expect(SceneTagsEntryPolicy.seedPhotoIds(
            selection: ["p2", "p1", "p2"], currentPhotoId: "p9") == ["p1", "p2"],
            "有选择集时用选择集（排序稳定），忽略当前照片")
        #expect(SceneTagsEntryPolicy.seedPhotoIds(
            selection: [], currentPhotoId: "p9") == ["p9"],
            "无选择时回退当前照片")
        #expect(SceneTagsEntryPolicy.seedPhotoIds(
            selection: [], currentPhotoId: nil) == [])
        #expect(SceneTagsEntryPolicy.seedPhotoIds(
            selection: [""], currentPhotoId: nil) == [],
            "空 id 不算有效种子")
    }

    @Test("Gallery sheet 路由唯一：场景标签与相似照片/元数据不共 case（只弹一个 sheet）")
    func gallerySheetRoutesAreDistinct() {
        #expect(GalleryView.GallerySheet.sceneTags.id == "sceneTags")
        #expect(GalleryView.GallerySheet.sceneTags.id
            != GalleryView.GallerySheet.semantic.id)
        #expect(GalleryView.GallerySheet.sceneTags.id
            != GalleryView.GallerySheet.metadata.id)
    }
}
