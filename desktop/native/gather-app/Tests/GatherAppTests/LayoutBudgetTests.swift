// desktop/native/gather-app/Tests/GatherAppTests/LayoutBudgetTests.swift
// 布局最小宽度预算（F01 / N01 的约束循环回归守卫）。
//
// 崩溃机制（来自系统崩溃日志的符号链）：
//   SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)
//     → NSHostingView.SizeConstraints.update(from:)
//     → AppKitPlatformViewHost.enqueueLayoutInvalidation()
//     → UpdateGroup.enqueueAction(reason:_:)
//   → 窗口在同一个显示周期里被反复要求重算约束 → NSGenericException → SIGABRT
//
// 也就是说：**页面内容对 NavigationSplitView 报告的最小宽度**如果大于窗口能给出的
// 宽度（窗口宽 − 侧栏 − 检查器），AppKit 就进入「撑大列 → 仍不满足 → 再撑」的循环。
// 这里把「最小宽度」变成可测量的断言：默认窗口 1180pt 减去侧栏与检查器后，
// 会话页内容的最小宽度必须留有余量。
import Foundation
import Testing
import AppKit
import SwiftUI
import GatherCore
@testable import GatherApp

@MainActor
@Suite("layout budget")
struct LayoutBudgetTests {
    /// 硬上限取自**最小窗口**能给出的内容宽度（G 报告：此前写的 700 比真实值宽松）：
    /// RootView 的窗口最小宽 860pt − 侧栏最小 180pt（含分隔线余量）= 680pt。
    /// 会话页还会叠加 .inspector 的理想列宽，所以能过这一关就意味着最小窗口下
    /// SplitViewChildController 不会拿到「大于可用宽度」的最小宽度。
    /// D-2（审计 5）：不再写死 680——直接引用外壳的尺寸定义，窗口/侧栏常量漂移时
    /// 这条预算会跟着变，不会「两边各改一半而测试仍绿」。
    private static var contentMinWidthBudget: CGFloat { RootShellMetrics.contentMinWidthBudget }

    /// NSHostingView.fittingSize 就是 SwiftUI 交给 AppKit 约束系统的最小尺寸，
    /// 与 SplitViewChildController 询问的是同一份数据。
    private func fittingSize<V: View>(_ view: V, height: CGFloat = 780, pump: TimeInterval = 0) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 980, height: height)
        host.layoutSubtreeIfNeeded()
        if pump > 0 {
            // 让 .task 里的异步加载跑完，页面才会进入真实分支（workbench）。
            RunLoop.current.run(until: Date().addingTimeInterval(pump))
            host.layoutSubtreeIfNeeded()
        }
        return host.fittingSize
    }

    private func cullingView() -> some View {
        CullingView(
            sessionId: "s1",
            router: StubCommandRouter.empty(),
            onBack: {},
            onOpenSimilarity: { _ in },
            onOpenTab: { _, _ in },
            onOpenGallery: { _ in },
            onOpenSettings: {}
        )
    }

    @Test("会话页签行不向 split view 索要超预算的最小宽度")
    func tabStripStaysWithinBudget() {
        let strip = SessionPageTabStrip(
            selection: .tab(.culling),
            onBrowse: {},
            onSimilarity: {},
            onSelectTab: { _ in }
        )
        let size = fittingSize(strip, height: 44)
        print("[layout budget] tab strip fitting size = \(size)")
        #expect(size.width <= Self.contentMinWidthBudget)
    }

    @Test("挑片页（空范围）不向 split view 索要超预算的最小宽度")
    func cullingEmptyPageStaysWithinBudget() {
        let size = fittingSize(cullingView())
        print("[layout budget] culling (empty page) fitting size = \(size)")
        #expect(size.width <= Self.contentMinWidthBudget)
    }

    /// 造一个「1 张照片的工作区」：只有这条路径会渲染 workbench（查看器 + 胶片 +
    /// 工具栏），也就是验收报告里实际崩溃的那条路径。
    private func stubWithOneAsset() throws -> StubCommandRouter {
        let photo = PhotoData(
            id: "p1",
            sessionId: "s1",
            filepath: "/tmp/gather-layout-p1.NEF",
            filename: "p1.NEF",
            checksum: "",
            hasExistingXmp: false,
            faceCount: 0,
            width: 4000,
            height: 3000,
            metadata: [:],
            result: [:],
            status: "ready",
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        let asset = CullingAsset(
            photo: photo,
            state: AssetCullingState(
                photoId: "p1",
                pickState: .unreviewed,
                rating: 0,
                colorLabel: .none,
                source: .manual,
                revision: 1,
                updatedAt: "2026-01-01T00:00:00.000Z"
            ),
            xmpPath: "/tmp/gather-layout-p1.xmp",
            syncStatus: .clean,
            people: [],
            keywords: [],
            linkedVariantCount: 1,
            faceBboxes: []
        )
        let page = CullingPage(assets: [asset], total: 1)
        let session = SessionData(
            id: "s1",
            name: "Layout",
            status: .photosLoaded,
            photoCount: 1,
            analysisStatus: .idle,
            writebackStatus: .idle,
            importSource: "local",
            sourcePath: "/tmp",
            failedWritebackCount: 0,
            truncatedImport: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        return StubCommandRouter(responses: [
            "culling.list_page": try GatherCore.JSONValue(from: page),
            "session.get": try GatherCore.JSONValue(from: session),
        ])
    }

    @Test("挑片页（1 张照片，workbench 路径）在默认窗口内可放下")
    func cullingWorkbenchStaysWithinBudget() throws {
        let view = CullingView(
            sessionId: "s1",
            router: try stubWithOneAsset(),
            onBack: {},
            onOpenSimilarity: { _ in },
            onOpenTab: { _, _ in },
            onOpenGallery: { _ in },
            onOpenSettings: {}
        )
        // 页面在 .task 里异步 load：先泵 0.3s 让它进入 workbench 分支再测量。
        let size = fittingSize(view, pump: 0.3)
        print("[layout budget] culling workbench fitting size = \(size)")
        #expect(size.width <= Self.contentMinWidthBudget)
    }

    /// A2（第三轮审计）：人脸页的 HSplitView 只在 clusters 非空时渲染，
    /// 喂空桩的「其余会话页」用例覆盖不到它。这里用带簇的桩把**审核分支**量出来。
    @Test("人脸页审核分支（两栏 + 成员行）在默认窗口内可放下")
    func faceReviewBranchStaysWithinBudget() throws {
        let member = ClusterMember(
            memberId: 1,
            photoId: "p1",
            photoPath: "/tmp/gather-layout-face.NEF",
            filename: "gather-layout-face.NEF",
            bbox: [0.1, 0.1, 0.2, 0.2],
            confidence: 0.93
        )
        let cluster = FaceClusterData(
            id: 1,
            sessionId: "s1",
            label: "Person 1",
            size: 2,
            status: "ready",
            thumbnailBase64: "",
            binding: nil,
            thumbnailPhotoId: nil,
            members: [member]
        )
        let router = StubCommandRouter(responses: [
            "fkw.clusters": try GatherCore.JSONValue(from: [cluster]),
            "jobs.list": .array([]),
        ])
        let size = fittingSize(FaceKeywordingView(sessionId: "s1", router: router), pump: 0.15)
        print("[layout budget] faceKw review branch fitting size = \(size)")
        #expect(size.width <= Self.contentMinWidthBudget, "人脸页审核分支最小宽度超预算：\(size.width)")
        // D-2（审计 5）实测结论（保留在此以免后来者误判覆盖度）：
        // 整个页面的 fittingSize 被**外壳**（页签行/子导航，实测 576pt）压住，
        // 因此它**不能**守住 HSplitView 两栏的最小宽度——320+280=601 仍会得到
        // 同一个 576。这里如实断言在预算内（防止两栏之和真的超过可用宽度），
        // 两栏具体值由代码审查 + CullingView/FaceKeywordingView 里的注释约定：
        // 两栏最小宽度之和必须 ≤ contentMinWidthBudget − 页签行占用（当前 520 ≤ 576）。
    }

    /// 会话页的公共骨架：页签行 + 页面内容（部分页面还有 .inspector）。
    /// 只要任何一页的内容把最小宽度顶过预算，这里就会失败——不必等真机崩溃。
    @Test("其余会话页在默认窗口内可放下")
    func otherSessionPagesStayWithinBudget() throws {
        let router = StubCommandRouter.empty()
        let pages: [(String, AnyView)] = [
            ("control", AnyView(SessionControlView(sessionId: "s1", router: router))),
            ("faceKw", AnyView(FaceKeywordingView(sessionId: "s1", router: router))),
            ("duplicates", AnyView(DuplicatesView(sessionId: "s1", router: router))),
            ("export", AnyView(ExportView(sessionId: "s1", router: router))),
        ]
        for (name, page) in pages {
            // pump 只给到 0.1s：够让 .task 里的同步 load 跑完，又不至于把
            // 页面的轮询计时器都启动起来（避免污染并行的其他测试）。
            let size = fittingSize(page, pump: 0.1)
            print("[layout budget] \(name) fitting size = \(size)")
            #expect(size.width <= Self.contentMinWidthBudget, "\(name) 最小宽度超预算：\(size.width)")
        }
    }

    /// 全局图库 / 工作区图库 / 相似度 / 人脸库：都用真 provider + 内存库驱动，
    /// 避免手写 stub 与真实装配漂移（这些页面的最小宽度此前从未被测量过）。
    @Test("其余四个非会话页在默认窗口内可放下")
    func globalPagesStayWithinBudget() throws {
        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        let router = SessionCommandRouter.makeDefault(db: db)

        let gallery = GalleryViewModel(
            sessionId: "s1",
            provider: LiveGalleryDataProvider(router: router)
        )
        let similarity = SimilarityViewModel(
            sessionId: "s1",
            provider: LiveSimilarityDataProvider(router: router),
            // 轮询间隔拉到 1 小时：本测试只关心布局，不希望留下后台轮询任务
            // （全量并行运行时会拖慢/拖挂其他套件的异步等待）。
            pollInterval: .seconds(3600),
            captureOne: CaptureOneBridge(router: router)
        )
        let library = LibraryViewModel(provider: LiveLibraryDataProvider(router: router))
        let persons = PersonsViewModel(provider: LivePersonsDataProvider(router: router))
        // 测量结束立刻停掉本测试自己启动的轮询（NSHostingView 丢弃时不会触发
        // onDisappear，页面里的 stop 逻辑不会执行）。
        defer {
            gallery.stopIndexStatusPolling()
            similarity.stopProgressPolling()
            similarity.stopResultPolling()
        }

        let pages: [(String, AnyView)] = [
            ("gallery", AnyView(GalleryView(
                viewModel: gallery,
                router: router,
                onBack: {},
                onOpenSimilarity: { _ in },
                onOpenTab: { _, _ in },
                onOpenSettings: {}
            ))),
            ("similarity", AnyView(SimilarityView(
                viewModel: similarity,
                router: router,
                onBack: {},
                onOpenGallery: { _ in },
                onOpenTab: { _, _ in },
                onOpenSettings: {}
            ))),
            ("library", AnyView(LibraryView(viewModel: library, isActive: true))),
            ("persons", AnyView(PersonsView(viewModel: persons, isActive: true))),
        ]
        // 不 pump：这些页面的 VM 会启动轮询/防抖任务，跑起来后不会随本测试结束而停止
        // （NSHostingView 被丢弃不触发 onDisappear），会拖慢并行运行的其他套件
        //（实测把 SimilarityViewModel / GatherToast 的时序断言拖挂）。
        // 测的是**加载态骨架**：页签行、工具栏、筛选条、检查器、HSplitView 都在这一层，
        // 正是最小宽度的来源；有数据的分支由会话页（Culling workbench）单独覆盖。
        for (name, page) in pages {
            let size = fittingSize(page)
            print("[layout budget] \(name) fitting size = \(size)")
            #expect(size.width <= Self.contentMinWidthBudget, "\(name) 最小宽度超预算：\(size.width)")
        }
    }

    @Test("空工作区（只有引导空态）不向 split view 索要超预算的最小宽度")
    func cullingEmptySessionStaysWithinBudget() {
        let view = CullingView(
            sessionId: "",
            router: StubCommandRouter.empty(),
            onBack: {},
            onOpenSimilarity: { _ in },
            onOpenTab: { _, _ in },
            onOpenGallery: { _ in },
            onOpenSettings: {}
        )
        let size = fittingSize(view)
        print("[layout budget] culling (no session) fitting size = \(size)")
        #expect(size.width <= Self.contentMinWidthBudget)
    }

    @Test("挑片页 + 页签行叠加后仍在预算内")
    func sessionChromePlusCullingStaysWithinBudget() {
        let page = cullingView()
            .sessionPageChrome(
                subtitle: "挑片",
                selection: .tab(.culling),
                onBrowse: {},
                onSimilarity: {},
                onSelectTab: { _ in }
            )
        let size = fittingSize(page)
        print("[layout budget] culling + chrome fitting size = \(size)")
        #expect(size.width <= Self.contentMinWidthBudget)
    }
}
