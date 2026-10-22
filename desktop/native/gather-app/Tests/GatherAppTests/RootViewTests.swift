// desktop/native/gather-app/Tests/GatherAppTests/RootViewTests.swift
// RootNavigation 路由与选中态契约。
//
// 职责：
// 1. 默认落 Dashboard；侧栏原生页（persons）与 Web 选中态互斥；
// 2. 打开会话、图库、相似度、会话页签时保留 sessionId；
// 3. 页签顺序固定 control/face-kw/duplicates/culling/export，侧栏枚举稳定。
//
// 边界：只测 RootNavigation 的状态迁移，不构造 View、不启动 SwiftUI/AppKit
// 渲染，也不访问数据库或真实文件。
import Testing
@testable import GatherUI
@testable import GatherHost

@MainActor
@Suite("RootNavigation")
struct RootNavigationTests {
    @Test func defaultDestinationIsDashboard() {
        let navigation = RootNavigation()
        #expect(navigation.destination == .dashboard)
        #expect(navigation.isDashboard)
        #expect(navigation.selectedWebPage == nil)
    }

    @Test func selectingNativePageHighlightsSidebar() {
        let navigation = RootNavigation()
        navigation.openSession("s1")
        #expect(navigation.selectedWebPage == nil)
        navigation.selectWeb(.persons)
        #expect(navigation.destination == .page(.persons))
        #expect(navigation.isPersons)
        #expect(navigation.selectedWebPage == .persons)
        // 切到非 Web 页后选中态清空（侧栏高亮回到 Dashboard/Library）。
        navigation.selectLibrary()
        #expect(navigation.selectedWebPage == nil)
        #expect(!navigation.isPersons)
    }

    @Test func selectingPersonsUsesNativePersonsRoute() {
        let navigation = RootNavigation()
        navigation.selectWeb(.persons)
        // 单一表示：.page(.persons)（旧 .persons 枚举已删除，页面真实可达）。
        #expect(navigation.destination == .page(.persons))
        #expect(navigation.isPersons)
        #expect(navigation.selectedWebPage == .persons)
        // 切走再回来仍可达（不残留不可达枚举值）。
        navigation.selectDashboard()
        #expect(!navigation.isPersons)
        navigation.selectWeb(.persons)
        #expect(navigation.isPersons)
    }

    @Test func openingSessionRoutesToControlCenter() {
        let navigation = RootNavigation()
        navigation.openSession("s1")
        #expect(navigation.destination == .sessionTab("s1", .control))
        #expect(navigation.sessionTabDestination?.tab == .control)
        #expect(navigation.selectedWebPage == nil)
    }

    @Test func openingGalleryRemainsAnExplicitAction() {
        let navigation = RootNavigation()
        navigation.openGallery("s1")
        #expect(navigation.destination == .gallery("s1"))
        #expect(navigation.gallerySessionId == "s1")
    }

    @Test func openingSimilarityRoutesToNativePage() {
        let navigation = RootNavigation()
        navigation.openSimilarity("s1")
        #expect(navigation.destination == .similarity("s1"))
        #expect(navigation.similaritySessionId == "s1")
    }

    @Test func openingEachSessionTabKeepsSessionIdentity() {
        let navigation = RootNavigation()
        for tab in SessionTab.allCases {
            navigation.openSessionTab("s1", tab)
            #expect(navigation.destination == .sessionTab("s1", tab))
            #expect(navigation.sessionTabDestination?.sessionId == "s1")
            #expect(navigation.sessionTabDestination?.tab == tab)
        }
    }

    @Test func sessionTabsMatchProductOrder() {
        #expect(SessionTab.allCases.map(\.rawValue) == ["control", "face-kw", "duplicates", "culling", "export"])
        // 页签文案（中英双语）由 SessionTabBar.tabTitle 承载，SessionTab 不再持有 title。
    }

    @Test func selectingDashboardClearsAllNativeSelection() {
        let navigation = RootNavigation()
        navigation.selectWeb(.persons)
        navigation.selectDashboard()
        #expect(navigation.isDashboard)
        #expect(navigation.selectedWebPage == nil)
        #expect(navigation.gallerySessionId == nil)
        #expect(navigation.sessionTabDestination == nil)
    }

    @Test func sidebarCasesRemainStable() {
        // 产品决策：任务中心并入 Dashboard，删除独立 jobs 路由与侧栏项；
        // 设置是独立窗口（⌘,），不占 WebPage 路由。
        #expect(RootNavigation.WebPage.allCases.map(\.rawValue) == ["persons"])
        // Cut 4 / 4b-3：标题改为渲染期解析（title(with:)），断言直接给显式语言值，
        // 不再切进程全局 → 不必与其它套件互斥（AppLanguageLock 已不需要）。
        #expect(RootNavigation.WebPage.persons.title(with: L10n(language: .zhCN)) == "人脸库")
        #expect(RootNavigation.WebPage.persons.title(with: L10n(language: .en)) == "Face Library")
    }
}

// Cut 4 / 4a-2a-2：RootView 只在会话目的地激活 workspace。
//
// 会话 VM 已从 SessionDraftCache/单槽迁到 SessionStore；这里固定「目的地 →
// 活动工作区」的映射契约，避免图库/相似度/会话页签之外的页面误建 workspace。
@MainActor
@Suite("RootView workspace routing（4a-2a-2）")
struct RootViewWorkspaceRoutingTests {
    @Test("会话目的地都能解析出 sessionId")
    func sessionDestinationsResolveSessionId() {
        #expect(RootView.workspaceSessionId(for: .gallery("s1")) == "s1")
        #expect(RootView.workspaceSessionId(for: .similarity("s2")) == "s2")
        #expect(RootView.workspaceSessionId(for: .sessionTab("s3", .control)) == "s3")
        #expect(RootView.workspaceSessionId(for: .sessionTab("s3", .faceKw)) == "s3")
        #expect(RootView.workspaceSessionId(for: .sessionTab("s3", .duplicates)) == "s3")
        #expect(RootView.workspaceSessionId(for: .sessionTab("s3", .culling)) == "s3")
        #expect(RootView.workspaceSessionId(for: .sessionTab("s3", .export)) == "s3")
    }

    @Test("非会话页不激活任何 workspace")
    func globalPagesHaveNoWorkspace() {
        #expect(RootView.workspaceSessionId(for: .dashboard) == nil)
        #expect(RootView.workspaceSessionId(for: .library) == nil)
        #expect(RootView.workspaceSessionId(for: .page(.persons)) == nil)
    }
}
