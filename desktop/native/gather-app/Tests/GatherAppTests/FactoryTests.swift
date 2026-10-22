// desktop/native/gather-app/Tests/GatherAppTests/FactoryTests.swift
// Cut 4 / 4a-2a-1：SessionWorkspaceFactory + SessionStore 接线。
//
// 覆盖：
// 1. 工厂用 RootShellDependencies 一次构造 7 个 VM（culling/duplicates/export/
//    face/control/gallery/similarity），sessionId 全部等于入参；
// 2. SessionStore.workspace(for:) 命中复用同一 SessionWorkspace 实例（7 个 VM
//    不重建）；
// 3. capacity 超限按 LRU 淘汰最久未访问项；pinned 项不被淘汰、淘汰顺延到次久项；
// 4. activate 只切可见性（旧 workspace suspend + 新 workspace activate），不重建。
//
// 夹具原则：全部用现有测试替身（B8SessionAPIStub / B5bJobAPIStub / …）与三个
// 只做"空返回"的 provider 替身；本文件不测任何 VM 行为，只测装配与 LRU 语义。
import Foundation
import Testing
import SwiftUI
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

// MARK: - 仅满足 RootShellDependencies 形状的替身（工厂不调用它们）

private struct FactoryGalleryProviderStub: GalleryDataProvider {
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

private struct FactoryLibraryProviderStub: LibraryDataProvider {
    func listSessions() async throws -> [SessionData] { [] }

    func globalPhotos(
        criteria: FilterGroup,
        sessionId: String?,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        ([], 0)
    }
}

/// 可变的 Dashboard Provider：RootView 删除接线用例要经真实 VM 删除并刷新列表。
private final class FactoryDashboardProviderStub: DashboardDataProvider, @unchecked Sendable {
    var sessions: [SessionData] = []
    private(set) var deletedIds: [String] = []

    func listSessions() async throws -> [SessionData] { sessions }

    func createSession(name: String, source: String, sourcePath: String) async throws -> SessionData {
        throw APIError.failed("FACTORY_TEST_UNUSED")
    }

    func deleteSession(_ sessionId: String, confirmed: Bool) async throws {
        deletedIds.append(sessionId)
        sessions.removeAll { $0.id == sessionId }
    }

    func workspaceStatus(sessionId: String) async throws -> WorkspaceStatus? { nil }

    func listJobs(includeCheckpoint: Bool) async throws -> [AnalysisJobData] { [] }

    func cancelJob(_ jobId: String) async throws -> Bool { false }

    func retryJob(_ jobId: String) async throws -> Bool { false }

    func clearCompletedJobs() async throws -> Int { 0 }
}

private struct FactoryPersonAPIStub: PersonAPI {
    func list() async throws -> [PersonData] { [] }

    func get(_ personId: String) async throws -> PersonDetailData {
        throw APIError.failed("FACTORY_TEST_UNUSED")
    }

    func create(_ input: PersonCreateParams) async throws -> PersonCreateResult {
        throw APIError.failed("FACTORY_TEST_UNUSED")
    }

    func update(_ input: PersonUpdateParams) async throws {
        throw APIError.failed("FACTORY_TEST_UNUSED")
    }

    func delete(_ input: Confirmed<PersonDeleteInput>) async throws {
        throw APIError.failed("FACTORY_TEST_UNUSED")
    }

    func merge(_ input: Confirmed<PersonMergeInput>) async throws {
        throw APIError.failed("FACTORY_TEST_UNUSED")
    }

    func removePhoto(_ input: Confirmed<PersonRemovePhotoInput>) async throws {
        throw APIError.failed("FACTORY_TEST_UNUSED")
    }

    func searchPhotos(_ input: PersonSearchPhotosParams) async throws -> PersonPhotosResult {
        throw APIError.failed("FACTORY_TEST_UNUSED")
    }
}

// MARK: - 用例

@MainActor
@Suite("SessionWorkspaceFactory（4a-2a-1）")
struct FactoryTests {
    /// 每例独立的依赖包：只装配替身，不建库、不启运行时。
    private func makeDeps(
        dashboard: FactoryDashboardProviderStub = FactoryDashboardProviderStub()
    ) -> RootShellDependencies {
        RootShellDependencies(
            session: B8SessionAPIStub(),
            job: B5bJobAPIStub(),
            settings: B8SettingsAPIStub(),
            culling: B8CullingAPIStub(),
            navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(),
            quality: B5bQualityAPIStub(),
            face: B8FaceAPIStub(),
            similarity: B8SimilarityAPIStub(),
            duplicate: B5bDuplicateAPIStub(),
            export: B6bExportAPIStub(),
            person: FactoryPersonAPIStub(),
            captureOne: CaptureOneBridge(),
            libraryProvider: FactoryLibraryProviderStub(),
            galleryProvider: FactoryGalleryProviderStub(),
            dashboardProvider: dashboard
        )
    }

    private func makeFactory() -> SessionWorkspaceFactory {
        SessionWorkspaceFactory(deps: makeDeps())
    }

    private func makeStore(capacity: Int) -> SessionStore {
        SessionStore(capacity: capacity, make: makeFactory().makeWorkspace)
    }

    /// 4a-3a：RootView 的必填语言依赖；独立 NotificationCenter 避免订阅
    /// 进程级 languageChanged。
    private func makeLanguageStore() -> LanguageStore {
        LanguageStore(language: .zhCN, notificationCenter: NotificationCenter())
    }

    @Test("工厂：一次构造 7 个 VM，sessionId 全部一致且 workspace 初始不可见")
    func buildsSevenViewModelsWithSameSessionId() {
        let workspace = makeFactory().makeWorkspace(sessionId: "s-4a")

        #expect(workspace.sessionId == "s-4a")
        #expect(workspace.culling.sessionId == "s-4a")
        #expect(workspace.duplicates.sessionId == "s-4a")
        #expect(workspace.export.sessionId == "s-4a")
        #expect(workspace.face.sessionId == "s-4a")
        #expect(workspace.control.sessionId == "s-4a")
        #expect(workspace.gallery.sessionId == "s-4a")
        #expect(workspace.similarity.sessionId == "s-4a")

        // 构造不等于可见：可见性只由 SessionStore.activate 写。
        #expect(workspace.lifecycle == .suspended)
        #expect(!workspace.isVisible)
    }

    @Test("工厂：不同 sessionId 互不复用 VM（每会话一套）")
    func distinctSessionsGetDistinctViewModels() {
        let factory = makeFactory()
        let first = factory.makeWorkspace(sessionId: "s1")
        let second = factory.makeWorkspace(sessionId: "s2")

        #expect(first !== second)
        #expect(first.culling !== second.culling)
        #expect(first.gallery !== second.gallery)
        #expect(first.similarity !== second.similarity)
        #expect(second.gallery.sessionId == "s2")
    }

    @Test("SessionStore：workspace(for:) 命中复用同一实例，只登记一次")
    func storeReusesWorkspaceInstance() {
        let store = makeStore(capacity: 4)

        let first = store.workspace(for: "s1")
        let second = store.workspace(for: "s1")

        #expect(first === second)
        #expect(store.workspaces.count == 1)
        #expect(store.recent == ["s1"])
        #expect(store.workspace(for: "s1").culling === first.culling)
    }

    @Test("capacity：超限按 LRU 淘汰最久未访问的非保护项")
    func capacityEvictsLeastRecentlyUsed() {
        let store = makeStore(capacity: 2)

        let s1 = store.workspace(for: "s1")
        let s2 = store.workspace(for: "s2")
        let s3 = store.workspace(for: "s3")

        #expect(store.workspaces.count == 2)
        #expect(store.workspaces["s1"] == nil)
        #expect(s1.isClosed)
        #expect(store.workspaces["s2"] === s2)
        #expect(store.workspaces["s3"] === s3)
        #expect(store.recent == ["s3", "s2"])
    }

    @Test("active：可见项不淘汰，淘汰顺延到次久未访问项")
    func activeWorkspaceSurvivesCapacity() {
        let store = makeStore(capacity: 2)

        let s1 = store.workspace(for: "s1")
        store.activate("s1")
        let s2 = store.workspace(for: "s2")
        let s3 = store.workspace(for: "s3")

        #expect(store.activeSessionId == "s1")
        #expect(store.workspaces["s1"] === s1)
        #expect(!s1.isClosed)
        #expect(store.workspaces["s2"] == nil)
        #expect(s2.isClosed)
        #expect(store.workspaces["s3"] === s3)
        #expect(store.workspaces.count == 2)
    }

    @Test("activate：只切可见性，不重建 workspace")
    func activateTogglesVisibilityWithoutRebuild() {
        let store = makeStore(capacity: 4)

        let first = store.activate("s1")
        let again = store.workspace(for: "s1")
        #expect(first === again)
        #expect(first?.isVisible == true)
        #expect(first?.lifecycle == .active)
        #expect(store.activeSessionId == "s1")
        #expect(store.lastSessionId == "s1")

        let second = store.activate("s2")
        #expect(second?.isVisible == true)
        // 旧 workspace 只 suspend，不被销毁。
        #expect(first?.isVisible == false)
        #expect(first?.lifecycle == .suspended)
        #expect(!(first?.isClosed ?? true))
        #expect(store.activeSessionId == "s2")
        #expect(store.lastSessionId == "s2")

        // activate(nil)：只 suspend，不淘汰（失效边界 §4.4）。
        store.activate(nil)
        #expect(store.activeSessionId == nil)
        #expect(second?.isVisible == false)
        #expect(store.workspaces.count == 2)
    }

    // MARK: - Cut 4 / 4a-2a-2：RootView / 页面接 workspace

    @Test("页面：7 个会话页从 workspace 取 VM（生产 init 不再接收单独 VM）")
    func sessionPagesConstructFromWorkspace() {
        let store = makeStore(capacity: 4)
        let workspace = store.workspace(for: "s-4a")
        let culling = B8CullingAPIStub()

        _ = SessionControlView(workspace: workspace, culling: culling)
        _ = CullingView(workspace: workspace, culling: culling)
        _ = DuplicatesView(workspace: workspace, culling: culling)
        _ = ExportView(workspace: workspace, culling: culling)
        _ = FaceKeywordingView(workspace: workspace, culling: culling)
        _ = GalleryView(workspace: workspace, culling: culling)
        _ = SimilarityView(workspace: workspace, culling: culling)

        // 页面构造不得反向创建/替换 workspace，也不得把 workspace 置为可见
        //（可见性只由 SessionStore.activate 写）。
        #expect(store.workspaces.count == 1)
        #expect(workspace.isVisible == false)
        #expect(workspace.sessionId == "s-4a")
    }

    @Test("RootView：deps + store 注入，默认不预建 workspace")
    func rootViewDefersWorkspaceCreation() {
        let store = makeStore(capacity: 4)
        _ = RootView(
            deps: makeDeps(),
            sessionStore: store,
            languageStore: makeLanguageStore()
        )
        #expect(store.workspaces.isEmpty)
        #expect(store.activeSessionId == nil)
    }

    @Test("RootView：初始目的地为图库时激活对应 workspace")
    func rootViewActivatesInitialWorkspace() {
        let store = makeStore(capacity: 4)
        let navigation = RootNavigation()
        navigation.openGallery("s-initial")
        _ = RootView(
            deps: makeDeps(),
            sessionStore: store,
            languageStore: makeLanguageStore(),
            navigation: navigation
        )
        #expect(store.activeSessionId == "s-initial")
        #expect(store.workspaces["s-initial"]?.isVisible == true)
    }

    @Test("人脸深链：faceKwInitialRole 迁到 workspace.faceRole（take 取出即清）")
    func faceRoleDeepLinkUsesWorkspaceIntent() {
        let store = makeStore(capacity: 4)
        let workspace = store.workspace(for: "s-face")

        #expect(workspace.take(.faceRole) == nil, "未播种时不得凭空产生角色意图")
        workspace.enqueue(.faceRole("model"))
        #expect(workspace.take(.faceRole) == .faceRole("model"))
        #expect(workspace.take(.faceRole) == nil, "意图是一次性事件，取出即清")
    }

    // MARK: - Cut 4 / 4a-2c：意图收口 / 标题缓存 / close 扇出

    @Test("意图：6 种 Kind 各自 take 取出即清，同类后到覆盖先到")
    func intentsTakeAndClear() {
        let workspace = makeFactory().makeWorkspace(sessionId: "s-intent")
        workspace.enqueue(.galleryFilter(.offline))
        workspace.enqueue(.galleryFilter(.hasFace))
        workspace.enqueue(.galleryPhoto(id: "p1", path: "/a.jpg"))
        workspace.enqueue(.cullingConflicts)
        workspace.enqueue(.faceAnalyze)
        workspace.enqueue(.faceRole("model"))
        workspace.enqueue(.exportRange(.picks))

        #expect(workspace.take(.galleryFilter) == .galleryFilter(.hasFace))
        #expect(workspace.take(.galleryPhoto) == .galleryPhoto(id: "p1", path: "/a.jpg"))
        #expect(workspace.take(.cullingConflicts) == .cullingConflicts)
        #expect(workspace.take(.faceAnalyze) == .faceAnalyze)
        #expect(workspace.take(.faceRole) == .faceRole("model"))
        #expect(workspace.take(.exportRange) == .exportRange(.picks))

        for kind in WorkspaceIntent.Kind.allCases {
            #expect(workspace.take(kind) == nil, "取出后必须清空：\(kind.rawValue)")
        }
    }

    @Test("标题缓存：SessionAPI.get 只查一次；close 清空且不再查")
    func sessionNameIsCached() async {
        let workspace = makeFactory().makeWorkspace(sessionId: "s-title")
        let stub = B8SessionAPIStub(sessions: [makeSessionData(id: "s-title", name: "命名会话")])
        workspace.loadSessionNameIfNeeded(using: stub)
        for _ in 0..<100 where workspace.sessionName == nil {
            await Task.yield()
        }
        #expect(workspace.sessionName == "命名会话")
        #expect(stub.getCalls == ["s-title"])

        // 已有缓存：重复调用不再发请求。
        workspace.loadSessionNameIfNeeded(using: stub)
        await Task.yield()
        #expect(stub.getCalls.count == 1)

        workspace.close()
        #expect(workspace.sessionName == nil)
        workspace.loadSessionNameIfNeeded(using: stub)
        #expect(stub.getCalls.count == 1, "close 是终态，不再查标题")
    }

    @Test("close：7 个 VM 全部 shutdown，且 setVisible/enqueue 不再复活")
    func closeShutsDownEveryViewModel() {
        let workspace = makeFactory().makeWorkspace(sessionId: "s-close")
        workspace.setVisible(true)
        workspace.close()

        #expect(workspace.isClosed)
        #expect(!workspace.isVisible)
        #expect(workspace.culling.isShutdown)
        #expect(workspace.duplicates.isShutdown)
        #expect(workspace.export.isShutdown)
        #expect(workspace.face.isShutdown)
        #expect(workspace.control.isShutdown)
        #expect(workspace.gallery.isShutdown)
        #expect(workspace.similarity.isShutdown)

        workspace.setVisible(true)
        #expect(!workspace.isVisible, "关闭是终态")
        workspace.enqueue(.faceAnalyze)
        #expect(workspace.take(.faceAnalyze) == nil)
        workspace.close() // 幂等
    }

    @Test("页面：不再暴露 isActive 存储属性（4a-2c 删除参数）")
    func pagesHaveNoIsActiveParameter() {
        let workspace = makeStore(capacity: 4).workspace(for: "s-4a")
        let culling = B8CullingAPIStub()
        let views: [(String, Any)] = [
            ("culling", CullingView(workspace: workspace, culling: culling)),
            ("duplicates", DuplicatesView(workspace: workspace, culling: culling)),
            ("export", ExportView(workspace: workspace, culling: culling)),
            ("face", FaceKeywordingView(workspace: workspace, culling: culling)),
            ("gallery", GalleryView(workspace: workspace, culling: culling)),
            ("similarity", SimilarityView(workspace: workspace, culling: culling)),
            ("control", SessionControlView(workspace: workspace, culling: culling)),
            ("library", LibraryView(viewModel: LibraryViewModel(provider: FactoryLibraryProviderStub()))),
            ("persons", PersonsView(viewModel: PersonsViewModel(person: FactoryPersonAPIStub()))),
        ]
        for (name, view) in views {
            let labels = Mirror(reflecting: view).children.compactMap(\.label)
            #expect(!labels.contains("isActive"), "\(name) 仍暴露 isActive 存储属性")
        }
    }

    // MARK: - R4 P1-3：删除会话 → SessionStore.endSession 清理

    @Test("endSession：active/其它/普通会话移除并 close，active/last 清空")
    func endSessionClearsEveryStateSlot() {
        let store = makeStore(capacity: 4)
        let active = store.activate("s-active")
        let other = store.workspace(for: "s-other")
        let plain = store.workspace(for: "s-plain")
        #expect(store.activeSessionId == "s-active")
        #expect(store.lastSessionId == "s-active")

        // 已删会话即使 active 也必须清（会话已不存在，不能再被复用）。
        store.endSession("s-active")
        #expect(store.activeSessionId == nil)
        #expect(store.lastSessionId == nil, "lastSessionId 不得继续指向已删会话")
        #expect(store.workspaces["s-active"] == nil)
        #expect(active?.isClosed == true)
        #expect(active?.isVisible == false)
        #expect(active?.culling.isShutdown == true, "close 必须扇出到 7 个 VM")
        #expect(!store.recent.contains("s-active"))

        // 非 active 的其它会话被删同样移除并 close。
        store.endSession("s-other")
        #expect(store.workspaces["s-other"] == nil)
        #expect(other.isClosed)

        // 普通会话同样移除并 close。
        store.endSession("s-plain")
        #expect(store.workspaces["s-plain"] == nil)
        #expect(plain.isClosed)
        #expect(store.workspaces.isEmpty)
        #expect(store.recent.isEmpty)

        // lastSessionId 悬空（activate(nil) 只 suspend、不清回退位）：删除同样
        // 必须清掉，否则侧栏回退仍指向已删会话。
        let dangling = makeStore(capacity: 2)
        _ = dangling.activate("s-last")
        dangling.activate(nil)
        #expect(dangling.lastSessionId == "s-last")
        dangling.endSession("s-last")
        #expect(dangling.lastSessionId == nil, "非 active 的回退位也必须清")
        #expect(dangling.workspaces.isEmpty)
    }

    @Test("RootView 接线：删除 active/其它/普通会话清 workspace 与侧栏回退")
    func rootViewWiresDeletionToSessionStore() async {
        let dashboard = FactoryDashboardProviderStub()
        dashboard.sessions = [
            makeSessionData(id: "s-active", name: "活动"),
            makeSessionData(id: "s-other", name: "其它"),
            makeSessionData(id: "s-plain", name: "普通"),
        ]
        let deps = makeDeps(dashboard: dashboard)
        let store = SessionStore(capacity: 4, make: SessionWorkspaceFactory(deps: deps).makeWorkspace)
        let rootView = RootView(deps: deps, sessionStore: store, languageStore: makeLanguageStore())

        // 三类 workspace + lastSessionId 指向最近会话（侧栏回退来源）。
        let active = store.activate("s-active")
        let other = store.workspace(for: "s-other")
        let plain = store.workspace(for: "s-plain")
        #expect(rootView.currentSidebarSessionId == "s-active")

        // 单删 active：Dashboard 回调 → endSession（active/last 清理 + close）。
        let single = await rootView.viewModel.deleteSession("s-active", confirmed: true)
        #expect(single)
        #expect(dashboard.deletedIds == ["s-active"])
        #expect(store.workspaces["s-active"] == nil)
        #expect(active?.isClosed == true)
        #expect(store.activeSessionId == nil)
        #expect(store.lastSessionId == nil)
        #expect(rootView.currentSidebarSessionId == nil, "侧栏回退不得指向已删会话")

        // 批量删其它 + 普通：两个 workspace 都必须清。
        let batch = await rootView.viewModel.deleteSessions(["s-other", "s-plain"], confirmed: true)
        #expect(batch)
        #expect(store.workspaces.isEmpty)
        #expect(other.isClosed)
        #expect(plain.isClosed)
        #expect(rootView.currentSidebarSessionId == nil)
    }

    private func makeSessionData(id: String, name: String) -> SessionData {
        SessionData(
            id: id,
            name: name,
            status: .photosLoaded,
            photoCount: 3,
            analysisStatus: .idle,
            writebackStatus: .idle,
            importSource: "local",
            sourcePath: "",
            failedWritebackCount: 0,
            truncatedImport: false,
            createdAt: "",
            updatedAt: ""
        )
    }
}
