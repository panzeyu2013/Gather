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
        navigation.selectWeb(.jobs)
        #expect(navigation.destination == .page(.jobs))
        #expect(navigation.isJobs)
        #expect(navigation.selectedWebPage == .jobs)

        navigation.selectWeb(.settings)
        #expect(navigation.isSettings)
        #expect(navigation.selectedWebPage == .settings)
    }

    @Test func selectingPersonsUsesNativePersonsRoute() {
        let navigation = RootNavigation()
        navigation.selectWeb(.persons)
        #expect(navigation.destination == .persons)
        #expect(navigation.isPersons)
        #expect(navigation.selectedWebPage == .persons)
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
        #expect(SessionTab.control.title == "控制中心")
        #expect(SessionTab.faceKw.title == "人脸")
        #expect(SessionTab.duplicates.title == "重复")
        #expect(SessionTab.culling.title == "挑片")
        #expect(SessionTab.export.title == "导出")
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
        #expect(RootNavigation.WebPage.allCases.map(\.rawValue) == ["persons", "jobs", "settings"])
        #expect(RootNavigation.WebPage.persons.title == "人脸库")
        #expect(RootNavigation.WebPage.jobs.title == "任务中心")
        #expect(RootNavigation.WebPage.settings.title == "设置")
    }
}
