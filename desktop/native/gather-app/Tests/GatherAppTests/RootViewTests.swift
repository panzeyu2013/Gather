// desktop/native/gather-app/Tests/GatherAppTests/RootViewTests.swift
// RootNavigation 路由与选中态契约。
//
// 职责：
// 1. 默认落 Dashboard；侧栏原生页（persons）与 Web 选中态互斥；
// 2. 打开会话、图库、相似度、会话页面时保留 sessionId；
// 3. 页面顺序固定 gallery/similarity/control/face-kw/duplicates/culling/export。
//
// 边界：只测 RootNavigation 的状态迁移，不构造 View、不启动 SwiftUI/AppKit
// 渲染，也不访问数据库或真实文件。
import Testing
@testable import GatherUI

@MainActor
@Suite("RootNavigation")
struct RootNavigationTests {
    @Test func defaultDestinationIsDashboard() {
        let navigation = RootNavigation()
        #expect(navigation.route == .dashboard)
        #expect(navigation.isDashboard)
    }

    @Test func selectingNativePageHighlightsSidebar() {
        let navigation = RootNavigation()
        navigation.openSession("s1")
        navigation.selectWeb(.persons)
        #expect(navigation.route == .persons)
        #expect(navigation.isPersons)
        navigation.selectLibrary()
        #expect(navigation.route == .library)
        #expect(!navigation.isPersons)
    }

    @Test func selectingPersonsUsesNativePersonsRoute() {
        let navigation = RootNavigation()
        navigation.selectWeb(.persons)
        #expect(navigation.route == .persons)
        #expect(navigation.isPersons)
        navigation.selectDashboard()
        #expect(!navigation.isPersons)
        navigation.selectWeb(.persons)
        #expect(navigation.isPersons)
    }

    @Test func openingSessionRoutesToControlCenter() {
        let navigation = RootNavigation()
        navigation.openSession("s1")
        #expect(navigation.route == .session(sessionId: "s1", page: .control))
        #expect(navigation.isSessionPage(sessionId: "s1", page: .control))
    }

    @Test func openingGalleryRemainsAnExplicitAction() {
        let navigation = RootNavigation()
        navigation.openGallery("s1")
        #expect(navigation.route == .session(sessionId: "s1", page: .gallery))
        #expect(navigation.isGallery(sessionId: "s1"))
    }

    @Test func openingSimilarityRoutesToNativePage() {
        let navigation = RootNavigation()
        navigation.openSimilarity("s1")
        #expect(navigation.route == .session(sessionId: "s1", page: .similarity))
        #expect(navigation.isSimilarity(sessionId: "s1"))
    }

    @Test func openingEachSessionPageKeepsSessionIdentity() {
        let navigation = RootNavigation()
        for page in [SessionPage.control, .faceKw, .duplicates, .culling, .export] {
            navigation.openSessionPage("s1", page)
            #expect(navigation.route == .session(sessionId: "s1", page: page))
            #expect(navigation.isSessionPage(sessionId: "s1", page: page))
        }
    }

    @Test func sessionPagesMatchProductOrder() {
        #expect(SessionPage.control.rawValue == "control")
        #expect(SessionPage.faceKw.rawValue == "face-kw")
        #expect(SessionPage.tabOrder == [.gallery, .similarity, .control, .faceKw, .duplicates, .culling, .export])
        #expect(SessionPage.gallery.titleKey == "浏览")
    }

    @Test func selectingDashboardClearsAllNativeSelection() {
        let navigation = RootNavigation()
        navigation.selectWeb(.persons)
        navigation.selectDashboard()
        #expect(navigation.route == .dashboard)
        #expect(navigation.isDashboard)
    }

    @Test func sidebarCasesRemainStable() {
        #expect(RootNavigation.WebPage.allCases.map(\.rawValue) == ["persons"])
        #expect(RootNavigation.WebPage.persons.title(with: L10n(language: .zhCN)) == "人脸库")
        #expect(RootNavigation.WebPage.persons.title(with: L10n(language: .en)) == "Face Library")
    }
}

@MainActor
@Suite("RootView workspace routing（4a-2a-2）")
struct RootViewWorkspaceRoutingTests {
    @Test("会话目的地都能解析出 sessionId")
    func sessionDestinationsResolveSessionId() {
        #expect(RootView.workspaceSessionId(for: .session(sessionId: "s1", page: .gallery)) == "s1")
        #expect(RootView.workspaceSessionId(for: .session(sessionId: "s2", page: .similarity)) == "s2")
        #expect(RootView.workspaceSessionId(for: .session(sessionId: "s3", page: .control)) == "s3")
        #expect(RootView.workspaceSessionId(for: .session(sessionId: "s3", page: .faceKw)) == "s3")
        #expect(RootView.workspaceSessionId(for: .session(sessionId: "s3", page: .duplicates)) == "s3")
        #expect(RootView.workspaceSessionId(for: .session(sessionId: "s3", page: .culling)) == "s3")
        #expect(RootView.workspaceSessionId(for: .session(sessionId: "s3", page: .export)) == "s3")
    }

    @Test("非会话页不激活任何 workspace")
    func globalPagesHaveNoWorkspace() {
        #expect(RootView.workspaceSessionId(for: AppRoute.dashboard) == nil)
        #expect(RootView.workspaceSessionId(for: AppRoute.library) == nil)
        #expect(RootView.workspaceSessionId(for: AppRoute.persons) == nil)
    }
}
