// desktop/native/gather-app/Tests/GatherAppTests/WorkspaceVisibilityTests.swift
// R4 P1-2：SessionWorkspace 两级可见性回归。
//
// 旧行为：SessionStore.activate → workspace.setVisible(true) 对 7 个 VM 全量扇出，
// 进入任意会话就启动 gallery/control/similarity 的后台轮询，哪怕页面从未挂载。
// 新契约：
// 1. 会话级 setVisible(true) 只标记会话区域可见；setVisible(false) 仍全量停 7 个 VM；
// 2. 页面级 setVisible(true) 只由当前挂载页的 onAppear（经 setPageVisible）启动，
//    切页签由旧页 false + 新页 true 交接；
// 3. close 幂等，关闭后页面离场回调不复活 VM。
// 4. WP4d：7 个 VM 显式 conform PageVisibility，默认不可见；setPageVisible 的
//    7×{true,true,false,false,true} 序列只改自己的 VM 且重复调用幂等。
//
// 断言口径：未挂载页用 stub 调用计数 0（而不是 VM 可见性状态——可见性只证明
// 状态迁移，轮询是否真的启动由各页自己的生命周期用例按调用计数断言）。
import AppKit
import Foundation
import SwiftUI
import Testing
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

// MARK: - 探针

/// 只统计 workspace.status 轮询次数（R4 P1-4 起 init 不再补载，构造后计数即 0）。
private struct GalleryProbeState {
    var statusCalls = 0
}

private final class CountingGalleryProvider: GalleryDataProvider, @unchecked Sendable {
    private let box = LockedBox(GalleryProbeState())

    var statusCalls: Int { box.lock.withLock { box.statusCalls } }

    /// 清零后计数只反映可见性驱动的轮询（P1-4 修复后调用点已删除，保留备用）。
    func resetStatusCalls() { box.lock.withLock { box.statusCalls = 0 } }

    func getSession(_ sessionId: String) async throws -> SessionData? { nil }

    func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        ([], nil)
    }

    func workspaceStatus(_ sessionId: String) async throws -> WorkspaceStatus? {
        box.lock.withLock { box.statusCalls += 1 }
        return nil
    }
}

/// 全套探针：短轮询间隔（10ms），可在 100~150ms 的观察窗口里区分"已启动/未启动"。
@MainActor
private struct VisibilityProbe {
    let workspace: SessionWorkspace
    let store: SessionStore
    let gallery: GalleryViewModel
    let control: SessionControlViewModel
    let similarity: SimilarityViewModel
    let galleryProvider: CountingGalleryProvider
    let session: B8SessionAPIStub
    let similarityAPI: B8SimilarityAPIStub

    static func make(sessionId: String = "s1") -> VisibilityProbe {
        let galleryProvider = CountingGalleryProvider()
        let gallery = GalleryViewModel(
            sessionId: sessionId,
            provider: galleryProvider,
            job: B5bJobAPIStub(),
            activeStatusPollInterval: .milliseconds(10),
            idleStatusPollInterval: .milliseconds(10)
        )
        let session = B8SessionAPIStub()
        let control = SessionControlViewModel(
            sessionId: sessionId,
            session: session,
            culling: B8CullingAPIStub(),
            jobAPI: B5bJobAPIStub(),
            qualityAPI: B5bQualityAPIStub(),
            pollInterval: .milliseconds(10),
            activePollInterval: .milliseconds(10)
        )
        let similarityAPI = B8SimilarityAPIStub()
        let similarity = SimilarityViewModel(
            sessionId: sessionId,
            similarity: similarityAPI,
            jobs: B5bJobAPIStub(),
            pollInterval: .milliseconds(10),
            resultPollInterval: .milliseconds(10),
            captureOne: CaptureOneBridge()
        )
        let workspace = makeTestSessionWorkspace(
            sessionId: sessionId,
            control: control,
            gallery: gallery,
            similarity: similarity
        )
        let store = SessionStore(capacity: 4) { id in
            id == sessionId ? workspace : makeTestSessionWorkspace(sessionId: id)
        }
        return VisibilityProbe(
            workspace: workspace,
            store: store,
            gallery: gallery,
            control: control,
            similarity: similarity,
            galleryProvider: galleryProvider,
            session: session,
            similarityAPI: similarityAPI
        )
    }
}

// MARK: - 用例

@MainActor
@Suite("SessionWorkspace 两级可见性（R4 P1-2）")
struct WorkspaceVisibilityTests {
    /// 进入 sessionTab(culling)：activate 只标记会话可见；CullingView.onAppear
    /// 只启动 culling，gallery/control/similarity 一次请求都不发。
    @Test("进入 sessionTab(culling)：只有 culling 启动，gallery/control/similarity 请求计数 0")
    func enteringSessionTabStartsOnlyMountedPageViewModel() async {
        let probe = VisibilityProbe.make()
        let destination = AppRoute.session(sessionId: "s1", page: .culling)
        let sessionId = RootView.workspaceSessionId(for: destination)
        #expect(sessionId == "s1", "sessionTab 应映射到会话 id")

        // R4 P1-4 已修：GalleryViewModel.init 不再补载（不再查 workspace.status），
        // 因此从构造起计数就是 0；下面的观察窗口直接断言未挂载页零请求。

        // 外壳进入会话：SessionStore.activate → workspace.setVisible(true)。
        let entered = probe.store.activate(sessionId)
        #expect(entered === probe.workspace)
        #expect(probe.workspace.isVisible)
        #expect(!probe.workspace.isClosed)

        // 页面尚未挂载：三个隐藏页不得因"会话可见"而在后台空转。
        await awaitNegativeWindow(.milliseconds(120))
        #expect(probe.galleryProvider.statusCalls == 0, "图库未挂载却开始了 workspace.status 轮询")
        #expect(probe.session.getCalls.isEmpty, "控制中心未挂载却开始了 session.get 轮询")
        #expect(probe.similarityAPI.resultQueries.isEmpty, "相似度未挂载却开始了结果轮询")

        // CullingView.onAppear（页面唯一可见性入口）：只启动 culling 自己。
        probe.workspace.setPageVisible(.culling, true)
        #expect(probe.workspace.culling.isActive)

        // 观察窗口内仍然只有 culling 动，其它三页保持 0。
        await awaitNegativeWindow(.milliseconds(120))
        #expect(probe.galleryProvider.statusCalls == 0)
        #expect(probe.session.getCalls.isEmpty)
        #expect(probe.similarityAPI.resultQueries.isEmpty)
    }

    /// 页面级路由矩阵：setPageVisible(page, true) 只置真该页的 VM，
    /// 其余页（以可观测的 culling/gallery/similarity 为代表）保持 false。
    @Test("页面级路由：7 个 Page 只启停自己的 VM（三页可观测矩阵）")
    func pageRoutingOnlyTouchesItsOwnViewModel() {
        let probe = VisibilityProbe.make()
        probe.workspace.setVisible(false)
        for page in SessionWorkspace.Page.allCases {
            probe.workspace.setPageVisible(page, true)
            #expect(
                probe.workspace.culling.isActive == (page == .culling),
                "page=\(page) 错误地改写了 culling"
            )
            #expect(
                probe.workspace.gallery.isVisible == (page == .gallery),
                "page=\(page) 错误地改写了 gallery"
            )
            #expect(
                probe.workspace.similarity.isVisible == (page == .similarity),
                "page=\(page) 错误地改写了 similarity"
            )
            probe.workspace.setPageVisible(page, false)
        }
        #expect(!probe.workspace.culling.isActive)
        #expect(!probe.workspace.gallery.isVisible)
        #expect(!probe.workspace.similarity.isVisible)
    }

    /// 切页签：旧页 onDisappear(false) + 新页 onAppear(true) 只交接自己的 VM。
    @Test("切到 gallery：gallery 启动、culling 停止，control/similarity 仍为 0")
    func switchingPageHandsOffOnlyThatPageViewModel() async {
        let probe = VisibilityProbe.make()
        // 归一化到"会话已进入、culling 已挂载"。
        probe.workspace.setVisible(false)
        probe.workspace.setVisible(true)
        probe.workspace.setPageVisible(.culling, true)
        #expect(probe.workspace.culling.isActive)

        let galleryCallsBefore = probe.galleryProvider.statusCalls
        // CullingView.onDisappear → GalleryView.onAppear。
        probe.workspace.setPageVisible(.culling, false)
        probe.workspace.setPageVisible(.gallery, true)

        #expect(!probe.workspace.culling.isActive, "离开挑片页必须停 culling")
        #expect(probe.workspace.gallery.isVisible)
        #expect(
            await waitUntilAsync { probe.galleryProvider.statusCalls > galleryCallsBefore },
            "GalleryView.onAppear 后索引状态轮询未启动"
        )
        // 未挂载的 control/similarity 不得被这次页签切换顺带启动。
        await awaitNegativeWindow(.milliseconds(120))
        #expect(probe.session.getCalls.isEmpty)
        #expect(probe.similarityAPI.resultQueries.isEmpty)
    }

    /// 离开会话：activate(nil) → workspace.setVisible(false) 全量扇出停机。
    @Test("离开会话：7 个 VM 全部停止，隐藏页不再新增请求")
    func leavingSessionStopsEveryViewModel() async {
        let probe = VisibilityProbe.make()
        // 经 SessionStore 进入会话，activeSessionId 才会在离开时命中并 suspend。
        probe.store.activate("s1")
        probe.workspace.setPageVisible(.culling, true)
        probe.workspace.setPageVisible(.gallery, true)
        probe.workspace.setPageVisible(.similarity, true)
        probe.workspace.setPageVisible(.control, true)
        #expect(await waitUntilAsync { probe.galleryProvider.statusCalls > 0 })
        #expect(await waitUntilAsync { !probe.similarityAPI.resultQueries.isEmpty })
        #expect(await waitUntilAsync { !probe.session.getCalls.isEmpty })

        probe.store.activate(nil)
        #expect(probe.store.activeSessionId == nil)
        #expect(!probe.workspace.isVisible)
        #expect(!probe.workspace.culling.isActive)
        #expect(!probe.workspace.gallery.isVisible)
        #expect(!probe.workspace.similarity.isVisible)

        // 在途请求允许落定，但不得再开始新一轮轮询。
        await awaitNegativeWindow(.milliseconds(20))
        let galleryCalls = probe.galleryProvider.statusCalls
        let sessionCalls = probe.session.getCalls.count
        let similarityCalls = probe.similarityAPI.resultQueries.count
        await awaitNegativeWindow(.milliseconds(120))
        #expect(probe.galleryProvider.statusCalls == galleryCalls, "离开会话后图库轮询仍在跑")
        #expect(probe.session.getCalls.count == sessionCalls, "离开会话后控制中心轮询仍在跑")
        #expect(probe.similarityAPI.resultQueries.count == similarityCalls, "离开会话后相似度轮询仍在跑")
    }

    /// close：7 个 VM shutdown，重复 close 幂等，关闭后离场/迟到 onAppear 不复活。
    @Test("close：幂等且页面离场回调不复活 VM")
    func closeIsIdempotentAndDoesNotReviveViewModels() async {
        let probe = VisibilityProbe.make()
        probe.workspace.setPageVisible(.culling, true)

        probe.workspace.close()
        #expect(probe.workspace.isClosed)
        #expect(!probe.workspace.isVisible)
        #expect(!probe.workspace.culling.isActive)
        #expect(probe.workspace.culling.isShutdown)
        #expect(probe.workspace.duplicates.isShutdown)
        #expect(probe.workspace.export.isShutdown)
        #expect(probe.workspace.face.isShutdown)
        #expect(probe.workspace.control.isShutdown)
        #expect(probe.workspace.gallery.isShutdown)
        #expect(probe.workspace.similarity.isShutdown)

        // 重复 close / 迟到的页面回调 / 迟到的会话可见切换都不得复活。
        probe.workspace.close()
        probe.workspace.setPageVisible(.culling, true)
        probe.workspace.setPageVisible(.gallery, true)
        probe.workspace.setVisible(true)
        #expect(probe.workspace.isClosed)
        #expect(!probe.workspace.isVisible)
        #expect(!probe.workspace.culling.isActive)
        #expect(probe.workspace.gallery.isShutdown)
        #expect(probe.workspace.similarity.isShutdown)

        await awaitNegativeWindow(.milliseconds(120))
        #expect(probe.galleryProvider.statusCalls == 0, "关闭后图库轮询不得复活")
        #expect(probe.session.getCalls.isEmpty, "关闭后控制中心轮询不得复活")
        #expect(probe.similarityAPI.resultQueries.isEmpty, "关闭后相似度轮询不得复活")
    }

    // MARK: - WP4d：PageVisibility 统一契约（默认不可见 + 幂等 + 显式 conformance）

    /// 7×{true,true,false,false,true} 幂等矩阵：
    /// - 构造后 7 个 VM 一律默认不可见（统一旧版 Control=false / 其余=true 的分裂）；
    /// - 每一步只改 `page` 自己的 VM，重复 true/false 幂等（状态不漂）；
    /// - 序列结束后回到可见；用例收尾 close 取消矩阵期间启动的轮询/首载 Task。
    @Test("WP4d：PageVisibility 7×{true,true,false,false,true} 幂等矩阵")
    func pageVisibilityContractMatrix() {
        let probe = VisibilityProbe.make()

        // 显式 conformance：7 个 VM 都能以存在类型交给统一生命周期入口。
        let pages: [any PageVisibility] = [
            probe.workspace.control,
            probe.workspace.face,
            probe.workspace.duplicates,
            probe.workspace.culling,
            probe.workspace.export,
            probe.workspace.gallery,
            probe.workspace.similarity,
        ]
        #expect(pages.count == SessionWorkspace.Page.allCases.count)

        for page in SessionWorkspace.Page.allCases {
            #expect(!Self.pageIsVisible(page, in: probe.workspace), "page=\(page) 默认必须不可见")
        }

        let sequence = [true, true, false, false, true]
        for page in SessionWorkspace.Page.allCases {
            for (step, visible) in sequence.enumerated() {
                probe.workspace.setPageVisible(page, visible)
                #expect(
                    Self.pageIsVisible(page, in: probe.workspace) == visible,
                    "page=\(page) step=\(step) 期望 visible=\(visible)"
                )
                for other in SessionWorkspace.Page.allCases where other != page {
                    #expect(
                        !Self.pageIsVisible(other, in: probe.workspace),
                        "page=\(page) 错误改写了 \(other)"
                    )
                }
            }
            // 归零，保证下一页的默认/路由断言不受上一页残留影响。
            probe.workspace.setPageVisible(page, false)
        }

        probe.workspace.close()
    }

    /// 真实挂载（Phase 4 收口）：GatherSessionPage 放进 NSWindow 后，onAppear /
    /// onDisappear 必须真的驱动页面级可见性。上一轮因 NSHostingView SIGSEGV
    /// 未保留，本轮改为挂真实 NSWindow（有窗口才有 appearance 回调）。
    @Test("真实挂载：GatherSessionPage 的 onAppear/onDisappear 驱动页面可见性")
    func mountedSessionPageDrivesPageVisibility() async throws {
        // 测试进程没有 NSApplication 时，创建 NSWindow/NSHostingView 会在
        // AppKit 初始化阶段 SIGSEGV；显式建一次 application 再挂窗口。
        _ = NSApplication.shared
        let probe = VisibilityProbe.make()
        probe.store.activate("s1")
        let view = GatherSessionPage(page: .gallery, workspace: probe.workspace) {
            Color.clear
        }
        .environment(\.navigator, RootNavigation())
        .environment(\.languageStore, LanguageStore(language: .zhCN, notificationCenter: NotificationCenter()))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        pumpRunLoop(0.3)
        #expect(probe.workspace.gallery.isVisible, "挂载后图库页未变为可见")
        // 卸载页面（onDisappear）：从窗口移除 contentView，而不是 close——
        // NSWindow.close 不保证 SwiftUI 的 onDisappear（实测可见性仍为 true）。
        window.contentView = nil
        pumpRunLoop(0.3)
        #expect(!probe.workspace.gallery.isVisible, "卸载页面后图库页仍可见")
        window.close()
        probe.workspace.close()
    }

    /// 同步泵一次主 RunLoop：async 测试里不能直接调 RunLoop.run。
    @MainActor
    private func pumpRunLoop(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// VM 的可见性真相读取：Culling 沿用 isActive，其余 6 个是 isVisible。
    private static func pageIsVisible(
        _ page: SessionWorkspace.Page,
        in workspace: SessionWorkspace
    ) -> Bool {
        switch page {
        case .control: workspace.control.isVisible
        case .faceKw: workspace.face.isVisible
        case .duplicates: workspace.duplicates.isVisible
        case .culling: workspace.culling.isActive
        case .export: workspace.export.isVisible
        case .gallery: workspace.gallery.isVisible
        case .similarity: workspace.similarity.isVisible
        }
    }
}
