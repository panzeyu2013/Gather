// desktop/native/gather-app/Tests/GatherAppTests/CullingPreloadTests.swift
// P0-4（Wave1 20-culling-browse #4）：挑片页邻张预取的纯逻辑 + 接线用例。
//
// 背景：preloadPreviews / prioritizeThumbnail 与 ImagePreloadService 早已实现，
// 但 GatherUI 零调用（翻一张 = 现解一次 RAW）。修复后：
// - 计划换算（±2 邻张、近邻/远邻/下一张分组）是纯逻辑，可直测；
// - 近邻写查看器同键缓存（命中即跳过），远邻/下一张走 photoAPI 既有命令，
//   同一页内同路径只发一次；
// - 切图/离开/隐藏时取消未完成预取（本用例只验证"未调度则不发生"）。
import AppKit
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

@Suite("挑片页邻张预取（P0-4）", .serialized)
@MainActor
struct CullingPreloadTests {
    // MARK: - 计划换算

    private func asset(_ id: String) -> CullingAsset { b8CullingAsset(id) }

    @Test("中间照片：近邻 ±1 在前，远邻 ±2 在后，下一张单列")
    func planMiddle() {
        let assets = ["p1", "p2", "p3", "p4", "p5"].map(asset)
        let plan = CullingPreloadPlanner.plan(assets: assets, currentPhotoId: "p3")
        #expect(plan.nearRing.map(\.offset) == [1, -1])
        #expect(plan.nearRing.map(\.photoId) == ["p4", "p2"])
        #expect(plan.farRing.map(\.offset) == [2, -2])
        #expect(plan.farRing.map(\.photoId) == ["p5", "p1"])
        #expect(plan.nextTarget?.photoId == "p4")
        #expect(!plan.isEmpty)
    }

    @Test("首张：没有上一张/前二张，越界偏移被跳过")
    func planFirst() {
        let assets = ["p1", "p2", "p3"].map(asset)
        let plan = CullingPreloadPlanner.plan(assets: assets, currentPhotoId: "p1")
        #expect(plan.nearRing.map(\.photoId) == ["p2"])
        #expect(plan.farRing.map(\.photoId) == ["p3"])
        #expect(plan.nextTarget?.photoId == "p2")
    }

    @Test("末张：没有下一张，nextTarget 为 nil")
    func planLast() {
        let assets = ["p1", "p2", "p3"].map(asset)
        let plan = CullingPreloadPlanner.plan(assets: assets, currentPhotoId: "p3")
        #expect(plan.nearRing.map(\.photoId) == ["p2"])
        #expect(plan.farRing.map(\.photoId) == ["p1"])
        #expect(plan.nextTarget == nil)
    }

    @Test("currentPhotoId 为空/不在页内时回退首张（与查看器 currentIndex 同口径）")
    func planFallsBackToFirst() {
        let assets = ["p1", "p2"].map(asset)
        #expect(CullingPreloadPlanner.plan(assets: assets, currentPhotoId: nil).nextTarget?.photoId == "p2")
        #expect(CullingPreloadPlanner.plan(assets: assets, currentPhotoId: "gone").nextTarget?.photoId == "p2")
    }

    @Test("空页/空路径不产生预取项")
    func planSkipsEmpty() {
        #expect(CullingPreloadPlanner.plan(assets: [], currentPhotoId: "p1").isEmpty)

        // 路径为空（未索引/已移出）不得交给解码器。
        var broken = b8CullingAsset("p2")
        broken.photo.filepath = ""
        let plan = CullingPreloadPlanner.plan(assets: [b8CullingAsset("p1"), broken], currentPhotoId: "p1")
        #expect(plan.nearRing.isEmpty, "空路径不得进预取计划")
        #expect(plan.nextTarget == nil)
    }

    @Test("radius 参数可收窄（radius=1 时没有远邻）")
    func planRadius() {
        let assets = ["p1", "p2", "p3", "p4", "p5"].map(asset)
        let plan = CullingPreloadPlanner.plan(assets: assets, currentPhotoId: "p3", radius: 1)
        #expect(plan.farRing.isEmpty)
        #expect(plan.nearRing.count == 2)
    }

    // MARK: - VM 接线

    private func makeStack() -> (CullingViewModel, PreloadPhotoAPIStub) {
        // 内存缩略图缓存是进程级的：同套件前一条用例预热过的键会让"应该发生
        // 预取"的断言静默变绿/变红。每次装配先推进缓存代，隔离用例。
        PhotoThumbnailCache.invalidateAll()
        let photo = PreloadPhotoAPIStub()
        let viewModel = CullingViewModel(
            sessionId: "s1",
            culling: B8CullingAPIStub(),
            navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(),
            jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub(),
            captureOne: CaptureOneBridge(),
            photo: photo
        )
        viewModel.page = b8CullingPage(["p1", "p2", "p3", "p4", "p5"].map { b8CullingAsset($0) })
        viewModel.currentPhotoId = "p3"
        return (viewModel, photo)
    }

    @Test("远邻走 photoAPI.preloadPreviews(±2, 2560)，下一张走 prioritizeThumbnail")
    func runPreloadCallsHostAPIs() async throws {
        let (viewModel, photo) = makeStack()
        await viewModel.runNeighborPreload()

        #expect(photo.prioritizeInputs.count == 1)
        #expect(photo.prioritizeInputs.first?.path == "/shoot/p4.jpg", "下一张是 +1")
        #expect(photo.prioritizeInputs.first?.size == CullingViewModel.preloadPriorityThumbnailSize)

        #expect(photo.preloadInputs.count == 1)
        let input = try #require(photo.preloadInputs.first)
        #expect(input.paths == ["/shoot/p5.jpg", "/shoot/p1.jpg"], "只预热远邻 ±2")
        #expect(input.maxDimension == CullingViewModel.preloadPreviewDimension)
        #expect(CullingViewModel.preloadPreviewDimension == PhotoDetailTier.baseDimension)
    }

    @Test("同一页内不重复向宿主发同一路径的预取（不重复解）")
    func runPreloadDoesNotRepeatHostCalls() async {
        let (viewModel, photo) = makeStack()
        await viewModel.runNeighborPreload()
        await viewModel.runNeighborPreload()
        #expect(photo.preloadInputs.count == 1)
        #expect(photo.prioritizeInputs.count == 1)
    }

    @Test("已在显示缓存里的邻张不再发给宿主（命中即跳过）")
    func runPreloadSkipsCachedNeighbors() async {
        let (viewModel, photo) = makeStack()
        for id in ["p1", "p2", "p4", "p5"] {
            let key = PhotoThumbnailCache.key(
                path: "/shoot/\(id).jpg",
                size: PhotoDetailTier.baseDimension,
                preview: true
            )
            PhotoThumbnailCache.setImage(NSImage(size: NSSize(width: 2, height: 2)), for: key)
        }
        await viewModel.runNeighborPreload()
        #expect(photo.preloadInputs.isEmpty, "远邻全部在缓存里时不应再解一遍")
        #expect(photo.prioritizeInputs.isEmpty, "下一张已在缓存里时不需要优先级信号")
    }

    @Test("schedule 去抖后自动预热；取消后不再发生")
    func scheduleAndCancel() async {
        let (viewModel, photo) = makeStack()
        viewModel.setVisible(true)
        viewModel.preloadDebounceMilliseconds = 5
        viewModel.scheduleNeighborPreload()
        #expect(await waitUntilAsync { photo.preloadInputs.count == 1 }, "调度后应自动预热")
        #expect(photo.prioritizeInputs.count == 1)

        // 另一份干净 VM：调度后立刻取消 → 去抖窗口内不得发生任何宿主调用。
        let (cancelledVM, cancelledPhoto) = makeStack()
        cancelledVM.setVisible(true)
        cancelledVM.preloadDebounceMilliseconds = 40
        cancelledVM.scheduleNeighborPreload()
        cancelledVM.cancelNeighborPreload()
        await awaitNegativeWindow(.milliseconds(120))
        #expect(cancelledPhoto.preloadInputs.isEmpty)
        #expect(cancelledPhoto.prioritizeInputs.isEmpty)
    }
}

// MARK: - 宿主 PHOTO API 记录替身

private enum PreloadPhotoStubError: Error {
    case unavailable
}

private struct PreloadPathPolicyStub: PhotoPathPolicy {
    func containsFilepath(_ path: String) async throws -> Bool { true }
}

/// 只记录两个预取命令；其余查询面一律显式失败（不伪造成功）。
private final class PreloadPhotoAPIStub: PhotoAPI, Sendable {
    /// 具体类型存储 + 计算属性返回协议存在：final class 的 Sendable 推导要求
    /// 存储属性本身 Sendable（`any PhotoPathPolicy` 存在类型不参与推导）。
    private let policy = PreloadPathPolicyStub()
    var pathPolicy: any PhotoPathPolicy { policy }

    private struct State {
        var preloadInputs: [PreviewPreloadInput] = []
        var prioritizeInputs: [ThumbnailPrioritizeInput] = []
    }

    private let box = LockedBox(State())

    var preloadInputs: [PreviewPreloadInput] {
        box.lock.withLock { box.preloadInputs }
    }

    var prioritizeInputs: [ThumbnailPrioritizeInput] {
        box.lock.withLock { box.prioritizeInputs }
    }

    func page(_ query: PhotoPageQuery) async throws -> PhotoPage {
        throw PreloadPhotoStubError.unavailable
    }

    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        throw PreloadPhotoStubError.unavailable
    }

    func select(_ query: PhotoSelectionQuery) async throws -> PhotoSelectionIds {
        throw PreloadPhotoStubError.unavailable
    }

    func suggestions(_ query: PhotoSuggestionQuery) async throws -> [FilterSuggestion] { [] }

    func facets(_ input: PhotoFacetInput) async throws -> [PhotoFacetGroup] { [] }

    func dimensions(_ input: PhotoDimensionsInput) async throws -> [String: PhotoDimensions] { [:] }

    func prioritizeThumbnail(_ input: ThumbnailPrioritizeInput) async throws {
        box.lock.withLock { box.prioritizeInputs.append(input) }
    }

    func preloadThumbnails(_ input: ThumbnailPreloadInput) async throws -> JobHandle? { nil }

    func preloadPreviews(_ input: PreviewPreloadInput) async throws {
        box.lock.withLock { box.preloadInputs.append(input) }
    }
}
