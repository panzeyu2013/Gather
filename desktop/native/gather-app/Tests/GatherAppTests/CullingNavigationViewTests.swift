// desktop/native/gather-app/Tests/GatherAppTests/CullingNavigationViewTests.swift
// Wave5 batch4（50-ai-similarity §2 P1-6/P1-7）：场景/连拍最佳帧视图 + 人物筛选。
//
// 覆盖：
// 1. 组视图把当前页收窄到该组 photoIds，lead 必在首、其余按 quality 降序；
// 2. 当前照片定位到 lead；退出组视图恢复进入前的服务端页；
// 3. 人物精确匹配（Ann 不得命中 Anna）+ 与服务端筛选 AND + 清除后恢复；
// 4. 一键保留最佳的目标集合（keep=lead，reject=组内其余）与两次批量提交；
// 5. 网格折叠计数（photoId -> 组员数）。
//
// 纯 VM 级测试：stub CullingAPI 只记录入参/回显页，不建库、不跑真解码。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

private func navViewAsset(
    _ id: String,
    people: [String] = [],
    qualityScore: Double? = nil,
    pickState: PickState = .unreviewed
) -> CullingAsset {
    var quality: CullingQuality?
    if let qualityScore {
        quality = CullingQuality(
            status: .succeeded,
            score: qualityScore,
            sharpness: qualityScore,
            exposure: qualityScore,
            warnings: [])
    }
    return CullingAsset(
        photo: b8CullingPhoto(id),
        state: b8CullingState(id, pickState: pickState),
        xmpPath: "/shoot/\(id).xmp",
        syncStatus: .clean,
        people: people,
        keywords: [],
        linkedVariantCount: 1,
        faceBboxes: [],
        quality: quality
    )
}

private func navViewPage(_ assets: [CullingAsset]) -> CullingPage {
    CullingPage(assets: assets, total: assets.count)
}

private func navViewGroup(
    id: String = "g1",
    type: NavigationGroupType = .burst,
    photoIds: [String],
    lead: String?
) -> NavigationGroup {
    NavigationGroup(
        id: id,
        type: type,
        photoIds: photoIds,
        startAt: "2026-01-01T00:00:00.000Z",
        endAt: "2026-01-01T00:00:02.000Z",
        leadPhotoId: lead,
        explanation: "NAV_RECOMMEND_QUALITY",
        source: .automatic)
}

@MainActor
private func makeNavViewVM(
    culling: B8CullingAPIStub = B8CullingAPIStub()
) -> CullingViewModel {
    CullingViewModel(
        sessionId: "s1",
        culling: culling,
        navigation: B8NavigationAPIStub(),
        metadata: B6bMetadataAPIStub(),
        jobs: B5bJobAPIStub(),
        quality: B5bQualityAPIStub(),
        captureOne: CaptureOneBridge())
}

// .serialized：客户端投影基准是进程内 static 缓存（按 sessionId 存页），
// 并行用例会互相覆盖基准页 —— 这是测试隔离要求，不是产品缺陷。
@Suite("挑片页：场景/连拍组视图（Wave5 batch4）", .serialized)
@MainActor
struct CullingNavigationViewTests {
    @Test("组视图：lead 置顶 + 组内按 quality 降序 + 当前照片定位到 lead")
    func groupViewOrdersLeadFirstThenQuality() async {
        let vm = makeNavViewVM()
        // 页内顺序 p1/p2/p3；lead=p3（质量最低也必须置顶）；p1 质量 > p2。
        let assets = [
            navViewAsset("p1", qualityScore: 0.9),
            navViewAsset("p2", qualityScore: 0.5),
            navViewAsset("p3", qualityScore: 0.1),
            navViewAsset("p4", qualityScore: 0.99),
        ]
        vm.page = navViewPage(assets)
        vm.pageVersion += 1
        vm.navigationGroups = [
            navViewGroup(photoIds: ["p1", "p2", "p3"], lead: "p3")
        ]
        vm.selectedNavigationGroupId = "g1"

        await vm.enterNavigationGroupViewForGroup("g1")

        #expect(vm.isNavigationGroupViewActive)
        #expect(vm.page?.assets.map(\.photo.id) == ["p3", "p1", "p2"])
        #expect(vm.currentPhotoId == "p3")
        #expect(vm.page?.total == 3)
        #expect(vm.hasMore == false)
    }

    @Test("退出组视图恢复进入前的服务端页与当前照片")
    func exitGroupViewRestoresBasePage() async {
        let vm = makeNavViewVM()
        let base = [
            navViewAsset("p1", qualityScore: 0.9),
            navViewAsset("p2", qualityScore: 0.5),
            navViewAsset("p3", qualityScore: 0.1),
        ]
        vm.page = navViewPage(base)
        vm.pageVersion += 1
        vm.currentPhotoId = "p2"
        vm.navigationGroups = [navViewGroup(photoIds: ["p1", "p2", "p3"], lead: "p3")]

        await vm.enterNavigationGroupViewForGroup("g1")
        #expect(vm.page?.assets.map(\.photo.id) == ["p3", "p1", "p2"])

        await vm.exitNavigationGroupView()
        #expect(!vm.isNavigationGroupViewActive)
        #expect(vm.page?.assets.map(\.photo.id) == ["p1", "p2", "p3"])
    }

    @Test("人物筛选：精确匹配（Ann 不命中 Anna）+ 与服务端筛选 AND + 清除恢复")
    func personFilterPreciseAndCombinesWithServerFilter() async {
        let stub = B8CullingAPIStub()
        let vm = makeNavViewVM(culling: stub)
        let assets = [
            navViewAsset("p1", people: ["Ann"]),
            navViewAsset("p2", people: ["Ann", "Bob"]),
            navViewAsset("p3", people: ["Bob"]),
            navViewAsset("p4", people: ["Anna"]),
        ]
        vm.page = navViewPage(assets)
        vm.pageVersion += 1
        stub.pageResult = navViewPage(assets)

        await vm.setPersonFilter("Ann")
        #expect(vm.personFilter == "Ann")
        #expect(vm.page?.assets.map(\.photo.id) == ["p1", "p2"])

        // 服务端筛选（未处理）变化：保留人物投影并重放到新服务端页上 => AND。
        stub.pageResult = navViewPage([assets[0], assets[2]])
        await vm.setFilterStateKeepingClientProjection { $0.unreviewedOnly = true }
        #expect(vm.filterState.unreviewedOnly)
        #expect(vm.personFilter == "Ann")
        #expect(vm.page?.assets.map(\.photo.id) == ["p1"])

        // 清除人物：恢复服务端基准页（不再按人物收窄）。
        await vm.clearPersonFilter()
        #expect(vm.personFilter == nil)
        #expect(vm.page?.assets.map(\.photo.id) == ["p1", "p3"])
    }

    @Test("一键保留最佳：计划 keep=lead / reject=组内其余；执行两次批量提交")
    func keepBestDecisionTargets() async throws {
        let stub = B8CullingAPIStub()
        let vm = makeNavViewVM(culling: stub)
        vm.page = navViewPage([
            navViewAsset("p1", qualityScore: 0.9),
            navViewAsset("p2", qualityScore: 0.5),
            navViewAsset("p3", qualityScore: 0.1),
        ])
        vm.pageVersion += 1
        vm.navigationGroups = [
            navViewGroup(photoIds: ["p2", "p1", "p3"], lead: "p3")
        ]

        let plan = try #require(vm.prepareNavigationGroupDecision(groupId: "g1"))
        #expect(plan.groupType == .burst)
        #expect(plan.keepPhotoId == "p3")
        #expect(plan.rejectPhotoIds == ["p2", "p1"])
        #expect(plan.totalCount == 3)
        #expect(plan.visibleCount == 3)

        await vm.performNavigationGroupDecision(Confirmed(plan, source: .userDialog))

        #expect(stub.batchUpdateInputs.count == 2)
        let keep = stub.batchUpdateInputs.first
        #expect(keep?.photoIds == ["p3"])
        #expect(keep?.patch.pickState?.rawValue == "picked")
        let reject = stub.batchUpdateInputs.last
        #expect(reject?.photoIds == ["p1", "p2"])  // 提交端按 id 排序
        #expect(reject?.patch.pickState?.rawValue == "rejected")
    }

    @Test("网格折叠计数：photoId -> 所属导航组组员数（只收 >=2 的组）")
    func groupSizeByPhotoID() {
        let vm = makeNavViewVM()
        vm.navigationGroups = [
            navViewGroup(id: "g1", photoIds: ["p1", "p2"], lead: "p1"),
            navViewGroup(id: "g2", type: .scene, photoIds: ["p3"], lead: "p3"),
        ]
        let sizes = vm.navigationGroupSizeByPhotoID
        #expect(sizes["p1"] == 2)
        #expect(sizes["p2"] == 2)
        #expect(sizes["p3"] == nil)
    }
}
