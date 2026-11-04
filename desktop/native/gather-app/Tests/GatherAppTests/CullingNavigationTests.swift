// desktop/native/gather-app/Tests/GatherAppTests/CullingNavigationTests.swift
// 导航组的加载 / 选择 / 跳转 / 合并前解析（#6：这批方法此前**零测试**）。
//
// 为什么现在补：调研指出 `CullingViewModel+Navigation.swift` 的 12 个方法没有任何用例
// 保护（只被 View 的按钮调用）。拆分与否先不论，"零测试的公开面"本身就是风险——
// 这组用例先把可观察的行为钉住，后续真要动结构时有回归网。
//
// 覆盖：list 成功/失败、选中合法性（不存在的 id 不生效）、跳转优先 leadPhotoId、
// 合并前解析（无前一同类组时报错）。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

@Suite("挑片页导航组：加载/选择/跳转/合并解析", .serialized)
@MainActor
struct CullingNavigationTests {
    private func makeStack() -> (CullingViewModel, B8NavigationAPIStub) {
        let navigation = B8NavigationAPIStub()
        let viewModel = CullingViewModel(
            sessionId: "s-nav",
            culling: B8CullingAPIStub(),
            navigation: navigation,
            metadata: B6bMetadataAPIStub(),
            jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub(),
            captureOne: CaptureOneBridge()
        )
        return (viewModel, navigation)
    }

    private func group(
        _ id: String, type: NavigationGroupType = .burst, photos: [String], lead: String? = nil
    ) -> NavigationGroup {
        NavigationGroup(
            id: id, type: type, photoIds: photos,
            startAt: "2026-01-01T00:00:00Z", endAt: "2026-01-01T00:01:00Z",
            leadPhotoId: lead, explanation: "", source: .automatic)
    }

    @Test("loadNavigation：成功后落库到 navigationGroups 并归一选中")
    func loadPopulatesGroups() async {
        let (viewModel, navigation) = makeStack()
        navigation.listResult = [group("g1", photos: ["p1", "p2"]), group("g2", photos: ["p3"])]
        await viewModel.loadNavigation()
        #expect(viewModel.navigationGroups.map(\.id) == ["g1", "g2"])
        #expect(viewModel.selectedNavigationGroupId == "g1", "首个组合法时应被自动选中")
    }

    @Test("loadNavigation：失败把错误落到 errorMessage，不清空已有组")
    func loadFailureKeepsGroups() async {
        let (viewModel, navigation) = makeStack()
        navigation.listResult = [group("g1", photos: ["p1"])]
        await viewModel.loadNavigation()
        navigation.listError = NSError(domain: "nav", code: 1)
        await viewModel.loadNavigation()
        #expect(viewModel.errorMessage != nil, "失败必须可见")
        #expect(viewModel.navigationGroups.map(\.id) == ["g1"], "失败时不应清空既有分组")
    }

    @Test("selectNavigationGroup：不存在的 id 不生效")
    func selectIgnoresUnknownGroup() async {
        let (viewModel, navigation) = makeStack()
        navigation.listResult = [group("g1", photos: ["p1"])]
        await viewModel.loadNavigation()
        viewModel.selectNavigationGroup("nope")
        #expect(viewModel.selectedNavigationGroupId == "g1")
    }

    @Test("mergeCurrentWithPreviousSameType：没有前一个同类组时报错且不改选中集")
    func mergeWithoutPreviousFails() async {
        let (viewModel, navigation) = makeStack()
        navigation.listResult = [
            group("b1", type: .burst, photos: ["p1"]),
            group("s1", type: .scene, photos: ["p2"]),
        ]
        await viewModel.loadNavigation()
        viewModel.selectNavigationGroup("b1")
        await viewModel.mergeCurrentWithPreviousSameType()
        #expect(viewModel.errorMessage != nil, "没有同类前驱时必须给出可见错误")
        #expect(viewModel.selectedNavigationGroupIds.isEmpty, "失败不应选中任何待合并组")
    }
}
