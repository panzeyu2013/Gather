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
//
// Cut 1 / B8.1a：Culling / Face / Similarity 页面用类型化 API 替身装配
// （B8CullingAPIStub / B8FaceAPIStub / B8SimilarityAPIStub），不再使用旧命令面 适配器。
import Foundation
import Testing
import AppKit
import SwiftUI
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost
import GatherTestSupport

/// Cut 4 / 4a-2a-2：workspace 装配只需要一个空返回的图库 provider
///（本文件只测布局，不测取页行为；GalleryViewModel.init 的首屏补载会命中空页）。
private struct LayoutGalleryProviderStub: GalleryDataProvider {
    func getSession(_ sessionId: String) async throws -> SessionData? { nil }

    func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        ([], nil)
    }
}

@MainActor
@Suite("layout budget", .serialized)
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

    /// 类型化 Culling 五依赖装配（culling/navigation/metadata/jobs/quality）。
    /// 页面 chrome 的 C1 胶囊另接一个 CullingAPI 替身（B8.2e）。
    private func makeCullingViewModel(sessionId: String = "s1") -> CullingViewModel {
        CullingViewModel(
            sessionId: sessionId,
            culling: B8CullingAPIStub(),
            navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(),
            jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub(),
            captureOne: CaptureOneBridge()
        )
    }

    /// Cut 4 / 4a-2a-2：会话页 VM 统一来自 workspace（等价于
    /// `SessionStore.workspace(for:)` 的产物）；culling 可注入自定义 VM
    /// 供 workbench 用例复用，其余 6 个 VM 用空桩。
    private func makeWorkspace(
        sessionId: String = "s1",
        culling: CullingViewModel? = nil,
        face: FaceKeywordingViewModel? = nil,
        gallery: GalleryViewModel? = nil,
        similarity: SimilarityViewModel? = nil
    ) -> SessionWorkspace {
        SessionWorkspace(
            sessionId: sessionId,
            culling: culling ?? makeCullingViewModel(sessionId: sessionId),
            duplicates: DuplicatesViewModel(
                sessionId: sessionId,
                duplicate: B5bDuplicateAPIStub(),
                jobs: B5bJobAPIStub()
            ),
            export: ExportViewModel(
                sessionId: sessionId,
                export: B6bExportAPIStub(),
                session: B8SessionAPIStub()
            ),
            face: face ?? FaceKeywordingViewModel(
                sessionId: sessionId,
                face: B8FaceAPIStub(),
                jobs: B5bJobAPIStub(),
                captureOne: CaptureOneBridge()
            ),
            control: SessionControlViewModel(
                sessionId: sessionId,
                session: B8SessionAPIStub(),
                culling: B8CullingAPIStub(),
                jobAPI: B5bJobAPIStub(),
                qualityAPI: B5bQualityAPIStub()
            ),
            gallery: gallery ?? GalleryViewModel(
                sessionId: sessionId,
                provider: LayoutGalleryProviderStub(),
                job: B5bJobAPIStub()
            ),
            similarity: similarity ?? SimilarityViewModel(
                sessionId: sessionId,
                similarity: B8SimilarityAPIStub(),
                jobs: B5bJobAPIStub(),
                // 轮询间隔拉到 1 小时：本测试只关心布局，不希望留下后台轮询任务。
                pollInterval: .seconds(3600),
                captureOne: CaptureOneBridge()
            )
        )
    }

    private func cullingView() -> some View {
        CullingView(
            workspace: makeWorkspace(),
            culling: B8CullingAPIStub(),
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
            onBack: nil,
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
    private func cullingAPIWithOneAsset() -> B8CullingAPIStub {
        let page = b8CullingPage([b8CullingAsset("p1")])
        let api = B8CullingAPIStub()
        api.pageResult = page
        api.summaryResult = CullingSummary(
            totalGroups: 1, totalPhotos: 1, kept: 0, rejected: 0, pending: 1, rated: 0, labeled: 0
        )
        return api
    }

    @Test("挑片页（1 张照片，workbench 路径）在默认窗口内可放下")
    func cullingWorkbenchStaysWithinBudget() async {
        let api = cullingAPIWithOneAsset()
        let viewModel = CullingViewModel(
            sessionId: "s1",
            culling: api,
            navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(),
            jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub(),
            captureOne: CaptureOneBridge()
        )
        let view = CullingView(
            workspace: makeWorkspace(culling: viewModel),
            culling: api,
            onBack: {},
            onOpenSimilarity: { _ in },
            onOpenTab: { _, _ in },
            onOpenGallery: { _ in },
            onOpenSettings: {}
        )
        // 类型化 load 是 async：先显式加载，让页面进入 workbench 分支再测量。
        // 不再用 RunLoop 泵 0.3s——泵会阻塞 MainActor，拖慢并行套件的异步断言。
        await viewModel.load()
        let size = fittingSize(view)
        print("[layout budget] culling workbench fitting size = \(size)")
        #expect(size.width <= Self.contentMinWidthBudget)
        #expect(api.pageQueries.count >= 1, "页面必须经 CullingAPI.page 加载")
    }

    /// A2（第三轮审计）：人脸页的 HSplitView 只在 clusters 非空时渲染，
    /// 喂空桩的「其余会话页」用例覆盖不到它。这里用带簇的桩把**审核分支**量出来。
    @Test("人脸页审核分支（两栏 + 成员行）在默认窗口内可放下")
    func faceReviewBranchStaysWithinBudget() async {
        let face = B8FaceAPIStub()
        face.clustersValue = [
            b8FaceCluster(
                id: 1,
                sessionId: "s1",
                size: 2,
                members: [b8FaceMember(id: 1, photoId: "p1")]
            )
        ]
        let viewModel = FaceKeywordingViewModel(
            sessionId: "s1",
            face: face,
            jobs: B5bJobAPIStub(),
            captureOne: CaptureOneBridge()
        )
        // 先显式 reload 让 clusters 落地；页面 .task 还会再 reload 一次，
        // 用异步让出（而非阻塞 RunLoop）等它落定，避免测到加载态骨架。
        await viewModel.reload()
        let view = FaceKeywordingView(
            workspace: makeWorkspace(face: viewModel),
            culling: B8CullingAPIStub()
        )
        try? await Task.sleep(for: .milliseconds(80))
        #expect(viewModel.clusters.count == 1)
        #expect(!viewModel.isLoading)
        #expect(viewModel.step == .review)
        let size = fittingSize(view, pump: 0.05)
        print("[layout budget] faceKw review branch fitting size = \(size)")
        #expect(size.width <= Self.contentMinWidthBudget, "人脸页审核分支最小宽度超预算：\(size.width)")
        #expect(face.clusterCalls.count >= 1, "页面必须经 FaceAPI.clusters 加载")
        // D-2（审计 5）实测结论（保留在此以免后来者误判覆盖度）：
        // 整个页面的 fittingSize 被**外壳**（页签行/子导航，实测 576pt）压住，
        // 因此它**不能**守住 HSplitView 两栏的最小宽度——320+280=601 仍会得到
        // 同一个 576。这里如实断言在预算内（防止两栏之和真的超过可用宽度），
        // 两栏具体值由代码审查 + CullingView/FaceKeywordingView 里的注释约定：
        // 两栏最小宽度之和必须 ≤ contentMinWidthBudget − 页签行占用（当前 520 ≤ 576）。
    }

    /// 会话页的公共骨架：页签行 + 页面内容（部分页面还有 .inspector）。
    /// 只要任何一页的内容把最小宽度顶过预算，这里就会失败——不必等真机崩溃。
    ///
    /// 4a-2a-2：四个会话页统一用**同一个 workspace** 的 VM 装配（生产形状：
    /// 页面只从 workspace 取 VM，外壳不再缓存 VM）。
    @Test("其余会话页在默认窗口内可放下")
    func otherSessionPagesStayWithinBudget() {
        let workspace = makeWorkspace()
        let pages: [(String, AnyView)] = [
            ("control", AnyView(SessionControlView(
                workspace: workspace,
                culling: B8CullingAPIStub()
            ))),
            ("faceKw", AnyView(FaceKeywordingView(
                workspace: workspace,
                culling: B8CullingAPIStub()
            ))),
            ("duplicates", AnyView(DuplicatesView(
                workspace: workspace,
                culling: B8CullingAPIStub()
            ))),
            ("export", AnyView(ExportView(
                workspace: workspace,
                culling: B8CullingAPIStub()
            ))),
        ]
        for (name, page) in pages {
            // 不泵 RunLoop：泵会阻塞 MainActor，拖慢并行套件的异步断言；
            // 这里测的是加载态骨架（页签行/工具栏/检查器），不需要数据落地。
            let size = fittingSize(page)
            print("[layout budget] \(name) fitting size = \(size)")
            #expect(size.width <= Self.contentMinWidthBudget, "\(name) 最小宽度超预算：\(size.width)")
        }
    }

    /// 全局图库 / 工作区图库 / 相似度 / 人脸库：会话页之外的四个页面。
    /// 相似度用类型化 API 替身；图库/图库库仍复用其生产 provider（本步不删）。
    @Test("其余四个非会话页在默认窗口内可放下")
    func globalPagesStayWithinBudget() throws {
        let db = try makeTestDB()
        let composition = AppComposition.make(db: db)
        let services = AppServices.live(composition: composition)

        let gallery = GalleryViewModel(
            sessionId: "s1",
            provider: LiveGalleryDataProvider(
                photo: services.photo,
                session: services.session,
                settings: services.settings
            ),
            job: B5bJobAPIStub()
        )
        let similarity = SimilarityViewModel(
            sessionId: "s1",
            similarity: B8SimilarityAPIStub(),
            jobs: B5bJobAPIStub(),
            // 轮询间隔拉到 1 小时：本测试只关心布局，不希望留下后台轮询任务
            // （全量并行运行时会拖慢/拖挂其他套件的异步等待）。
            pollInterval: .seconds(3600),
            captureOne: CaptureOneBridge()
        )
        let library = LibraryViewModel(provider: LiveLibraryDataProvider(
            session: services.session,
            photo: services.photo,
            asset: services.asset,
            album: services.album,
            metadata: services.metadata
        ))
        // Cut 1 / B7b：人物域走类型化 PersonAPI（与生产 RootView 同一注入形状）。
        let persons = PersonsViewModel(person: LivePersonAPI(personRepo: composition.personRepo))
        // 测量结束立刻停掉本测试自己启动的轮询（NSHostingView 丢弃时不会触发
        // onDisappear，页面里的 stop 逻辑不会执行）。
        defer {
            gallery.stopIndexStatusPolling()
            similarity.stopProgressPolling()
            similarity.stopResultPolling()
        }

        let globalWorkspace = makeWorkspace(gallery: gallery, similarity: similarity)
        let pages: [(String, AnyView)] = [
            ("gallery", AnyView(GalleryView(
                workspace: globalWorkspace,
                culling: B8CullingAPIStub(),
                onBack: {},
                onOpenSimilarity: { _ in },
                onOpenTab: { _, _ in },
                onOpenSettings: {}
            ))),
            ("similarity", AnyView(SimilarityView(
                workspace: globalWorkspace,
                culling: B8CullingAPIStub(),
                onBack: {},
                onOpenGallery: { _ in },
                onOpenTab: { _, _ in },
                onOpenSettings: {}
            ))),
            ("library", AnyView(LibraryView(viewModel: library))),
            ("persons", AnyView(PersonsView(viewModel: persons))),
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
            workspace: makeWorkspace(sessionId: ""),
            culling: B8CullingAPIStub(),
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
