import Testing
@testable import GatherApp

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
        navigation.selectWeb(.settings)
        #expect(navigation.destination == .page(.settings))
        #expect(navigation.isSettings)
        #expect(navigation.selectedWebPage == .settings)
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
        navigation.selectWeb(.settings)
        navigation.selectDashboard()
        #expect(navigation.isDashboard)
        #expect(navigation.selectedWebPage == nil)
        #expect(navigation.gallerySessionId == nil)
        #expect(navigation.sessionTabDestination == nil)
    }

    @Test func sidebarCasesRemainStable() {
        // 产品决策：任务中心并入 Dashboard，删除独立 jobs 路由与侧栏项。
        #expect(RootNavigation.WebPage.allCases.map(\.rawValue) == ["persons", "settings"])
        // 标题经 l() 出当前语言：断言用同源查询，避免绑定本机语言。
        // 文案断言与切语言的套件互斥（appLanguage 是进程级全局量）。
        AppLanguageLock.withStableCopy {
            #expect(RootNavigation.WebPage.persons.title == GatherLocalization.l("人脸库"))
            #expect(RootNavigation.WebPage.settings.title == GatherLocalization.l("设置"))
        }
    }
}
