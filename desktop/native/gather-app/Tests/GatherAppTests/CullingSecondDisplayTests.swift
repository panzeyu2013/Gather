// desktop/native/gather-app/Tests/GatherAppTests/CullingSecondDisplayTests.swift
// Wave3 / task-20：第二屏镜像桥（CullingSecondDisplayCoordinator）的状态单测。
//
// 第二屏是「主窗口写、第二屏读」的单向镜像：这里的用例钉住四个语义——
// attach 登记会话/布局；布局切换跟随；缩放/平移发布（非法 zoom 收敛）；
// detach 只断开数据源、不清会话（主窗口重开后第二屏能自动恢复）。
//
// 窗口场景与只读画布是 SwiftUI 视图，不做渲染断言（单窗口/双窗口行为由
// GatherApp 的 Window 场景装配保证，实机验收在 Lead 侧）。
import CoreGraphics
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("第二屏镜像桥（Wave3）", .serialized)
@MainActor
struct CullingSecondDisplayTests {
    @Test("初始状态：未 attach、无会话、无数据源")
    func initialState() {
        let coordinator = CullingSecondDisplayCoordinator()
        #expect(coordinator.sessionId == nil)
        #expect(coordinator.layoutRaw == nil)
        #expect(coordinator.zoom == 1)
        #expect(coordinator.offset == .zero)
        #expect(!coordinator.isSourceAttached)
    }

    @Test("attach 登记会话与布局并标记数据源就绪")
    func attachRegistersSession() {
        let coordinator = CullingSecondDisplayCoordinator()
        coordinator.attach(sessionId: "s1", layoutRaw: "compare2")
        #expect(coordinator.sessionId == "s1")
        #expect(coordinator.layoutRaw == "compare2")
        #expect(coordinator.isSourceAttached)
    }

    @Test("布局切换跟随；空串不清数据源状态")
    func layoutFollows() {
        let coordinator = CullingSecondDisplayCoordinator()
        coordinator.attach(sessionId: "s1", layoutRaw: "single")
        coordinator.updateLayoutRaw("survey")
        #expect(coordinator.layoutRaw == "survey")

        coordinator.updateLayoutRaw("")
        #expect(coordinator.layoutRaw == "", "空串原样保存（调用方渲染期回退单图）")
        #expect(coordinator.isSourceAttached, "空布局不改数据源状态")
    }

    @Test("缩放/平移发布：非法 zoom（NaN/0）收敛为 1")
    func publishTransformClamps() {
        let coordinator = CullingSecondDisplayCoordinator()
        coordinator.publishViewerTransform(zoom: 3.75, offset: CGSize(width: 12, height: -8))
        #expect(coordinator.zoom == 3.75)
        #expect(coordinator.offset == CGSize(width: 12, height: -8))

        coordinator.publishViewerTransform(zoom: .nan, offset: .zero)
        #expect(coordinator.zoom == 1)
        coordinator.publishViewerTransform(zoom: 0.25, offset: .zero)
        #expect(coordinator.zoom == 1, "1:1 以下的镜像没有意义（主查看器 fit 下限是 1）")
    }

    @Test("detach 只断开数据源，不清会话（主窗口重开可恢复）")
    func detachKeepsSession() {
        let coordinator = CullingSecondDisplayCoordinator()
        coordinator.attach(sessionId: "s1", layoutRaw: "compare4")
        coordinator.detach()
        #expect(!coordinator.isSourceAttached)
        #expect(coordinator.sessionId == "s1", "会话保留，第二屏空态可提示主窗口已关闭")
        #expect(coordinator.layoutRaw == "compare4")

        // 重新 attach（主窗口重开并进挑片页）后恢复展示。
        coordinator.attach(sessionId: "s1", layoutRaw: "compare4")
        #expect(coordinator.isSourceAttached)
    }
}
