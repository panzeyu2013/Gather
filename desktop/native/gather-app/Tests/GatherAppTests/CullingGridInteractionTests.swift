// desktop/native/gather-app/Tests/GatherAppTests/CullingGridInteractionTests.swift
// P0 / G0：网格交互的纯逻辑测试（键盘映射 + 选择模型），不依赖 NSView。
import AppKit
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

@MainActor
private func makeCullingVM() -> CullingViewModel {
    makeCullingVMWithStub().vm
}

@MainActor
private func makeCullingVMWithStub() -> (vm: CullingViewModel, api: B8CullingAPIStub) {
    let api = B8CullingAPIStub()
    let vm = CullingViewModel(
        sessionId: "s1",
        culling: api,
        navigation: B8NavigationAPIStub(),
        metadata: B6bMetadataAPIStub(),
        jobs: B5bJobAPIStub(),
        quality: B5bQualityAPIStub(),
        captureOne: CaptureOneBridge()
    )
    return (vm, api)
}

@MainActor
@Suite("G0 网格交互")
struct CullingGridInteractionTests {
    @Test("键盘映射：评分/决策/色标/全选")
    func keyMapper() {
        #expect(CullingGridKeyMapper.action(characters: "0", command: false, option: false) == .rating(0))
        #expect(CullingGridKeyMapper.action(characters: "5", command: false, option: false) == .rating(5))
        #expect(CullingGridKeyMapper.action(characters: "p", command: false, option: false) == .pick(.picked))
        #expect(CullingGridKeyMapper.action(characters: "x", command: false, option: false) == .pick(.rejected))
        #expect(CullingGridKeyMapper.action(characters: "u", command: false, option: false) == .pick(.unreviewed))
        #expect(CullingGridKeyMapper.action(characters: "1", command: false, option: true) == .color(.red))
        #expect(CullingGridKeyMapper.action(characters: "7", command: false, option: true) == .color(.purple))
        #expect(CullingGridKeyMapper.action(characters: "a", command: true, option: false) == .selectAll)
        #expect(CullingGridKeyMapper.action(characters: " ", command: false, option: false) == .keep)
        #expect(CullingGridKeyMapper.action(characters: "z", command: false, option: false) == nil)
        #expect(CullingGridKeyMapper.action(characters: "8", command: false, option: true) == nil)
    }

    @Test("页大小约束在 50...1000")
    func pageLimitClamp() {
        let vm = makeCullingVM()
        vm.applyPageLimit(10)
        #expect(vm.pageLimit == 50)
        vm.applyPageLimit(5_000)
        #expect(vm.pageLimit == 1_000)
    }

    @Test("选择：全选已加载 / ⇧ 范围 / ⌘ 切换 / 单击清空")
    func selectionModel() {
        let vm = makeCullingVM()
        vm.page = CullingPage(assets: (1...3).map { b8CullingAsset("p\($0)") }, total: 3)
        vm.loadedPhotoIds = ["p1", "p2", "p3"]
        vm.currentPhotoId = "p1"

        vm.selectAllLoaded()
        #expect(vm.selectedPhotoIds == ["p1", "p2", "p3"])

        vm.clearSelection()
        vm.currentPhotoId = "p1"
        vm.gridClick("p3", modifiers: [.shift])
        #expect(vm.selectedPhotoIds == ["p1", "p2", "p3"])

        vm.gridClick("p2", modifiers: [.command])
        #expect(vm.selectedPhotoIds == ["p1", "p3"])

        vm.gridClick("p2", modifiers: [])
        #expect(vm.selectedPhotoIds == ["p2"])
        #expect(vm.currentPhotoId == "p2")
    }

    @Test("筛选变化清空选择；commit 不提交不可见旧选择")
    func filterClearsHiddenSelection() async throws {
        let (vm, api) = makeCullingVMWithStub()
        vm.page = CullingPage(assets: [b8CullingAsset("p1"), b8CullingAsset("p2")], total: 2)
        vm.loadedPhotoIds = ["p1", "p2"]
        vm.selectedPhotoIds = ["p1"]
        vm.currentPhotoId = "p1"

        api.pageResult = CullingPage(assets: [b8CullingAsset("p2")], total: 1)
        await vm.setFilterState { $0.rating = 5 }
        #expect(vm.selectedPhotoIds.isEmpty)
        #expect(vm.currentPhotoId == "p2")

        // 旧选择若被某条路径重新塞回：可见交集为空时绝不回退到“当前照片”，
        // 否则会把决策写到用户没选中的照片。
        vm.selectedPhotoIds = ["p1"]
        vm.currentPhotoId = "p2"
        await vm.commit(patch: CullingUpdatePatch(pickState: .picked))
        #expect(api.updateInputs.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    @Test("从全部范围直接选相似组会强制加载 groups")
    func selectGroupFromAllLoadsGroups() async {
        let (vm, api) = makeCullingVMWithStub()
        api.groupsResult = [b8CullingGroup(groupId: "g1")]
        await vm.selectSimilarityGroup("g1")
        #expect(vm.scopeMode == .similarityGroup)
        #expect(vm.selectedSimilarityGroupId == "g1")
    }

    @Test("批量 commit 只提交当前页可见选择，不含隐藏旧选择")
    func batchCommitUsesVisibleSelection() async throws {
        let (vm, api) = makeCullingVMWithStub()
        vm.page = CullingPage(
            assets: [b8CullingAsset("p1"), b8CullingAsset("p2")], total: 2)
        vm.loadedPhotoIds = ["p1", "p2"]
        vm.selectedPhotoIds = ["p1", "p2", "p3"]
        vm.currentPhotoId = "p1"

        await vm.commit(patch: CullingUpdatePatch(pickState: .picked))
        let input = try #require(api.batchUpdateInputs.last)
        #expect(input.photoIds == ["p1", "p2"])
    }

    @Test("方向键移动时同步单选，避免决策落到旧照片")
    func arrowSyncsSelection() {
        let vm = makeCullingVM()
        vm.page = CullingPage(
            assets: [b8CullingAsset("p1"), b8CullingAsset("p2"), b8CullingAsset("p3")],
            total: 3)
        vm.currentPhotoId = "p1"
        vm.selectedPhotoIds = ["p1", "p3"]

        vm.advanceCurrent()
        #expect(vm.currentPhotoId == "p2")
        #expect(vm.selectedPhotoIds == ["p2"])

        vm.retreatCurrent()
        #expect(vm.currentPhotoId == "p1")
        #expect(vm.selectedPhotoIds == ["p1"])
    }

    @Test("hasMore：只有 nextCursor 存在才还有下一页")
    func hasMoreUsesNextCursor() {
        let vm = makeCullingVM()
        vm.page = CullingPage(
            assets: [b8CullingAsset("p1")],
            total: 1,
            nextCursor: CullingPageCursor(sort: .captureDesc, dateKey: "2026-01-01", rowId: 1)
        )
        #expect(vm.hasMore)

        vm.page = CullingPage(assets: [b8CullingAsset("p1")], total: 1)
        #expect(!vm.hasMore)
    }

    @Test("排序/页大小/nextCursor 真正进入 CullingPageQuery")
    func sortAndCursorQuery() async throws {
        let (vm, api) = makeCullingVMWithStub()
        let cursor = CullingPageCursor(sort: .importOrder, rowId: 7)
        api.pageResult = CullingPage(
            assets: [b8CullingAsset("p1")],
            total: 1,
            nextCursor: cursor
        )

        vm.applyPageLimit(200)
        await vm.loadPage(reset: true)
        let first = try #require(api.pageQueries.last)
        #expect(first.sort == .importOrder)
        #expect(first.limit == 200)
        #expect(first.cursor == nil)

        await vm.loadMore()
        let more = try #require(api.pageQueries.last)
        #expect(more.cursor == cursor)
        #expect(more.limit == 200)

        await vm.setSort(.captureDesc)
        let sorted = try #require(api.pageQueries.last)
        #expect(vm.sortMode == .captureDesc)
        #expect(sorted.sort == .captureDesc)
        #expect(sorted.cursor == nil)
    }

    @Test("静默刷新页上限：超过 2000 已加载时跳过页刷新，避免折叠选择")
    func silentRefreshLimitBoundaries() {
        #expect(CullingViewModel.silentRefreshPageLimit(pageLimit: 200, loadedCount: 200) == 200)
        #expect(CullingViewModel.silentRefreshPageLimit(pageLimit: 200, loadedCount: 1_000) == 1_000)
        #expect(CullingViewModel.silentRefreshPageLimit(pageLimit: 200, loadedCount: 2_000) == 2_000)
        #expect(CullingViewModel.silentRefreshPageLimit(pageLimit: 200, loadedCount: 2_001) == nil)
    }
}
