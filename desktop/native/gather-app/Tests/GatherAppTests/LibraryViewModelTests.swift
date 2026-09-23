// desktop/native/gather-app/Tests/GatherAppTests/LibraryViewModelTests.swift
// Phase 3.2 Library 视图模型行为测试。
// 覆盖：buildCriteria 映射对账（TS Library.tsx:52-91）、分页（offset 语义/
// 页码边界）、筛选防抖（300ms 注入缩短）、criteriaKey 变更页码归零、
// 错误态（stub 注入）；集成用例用真实临时 SQLite + 路由直连。

import Foundation
import Testing
@testable import GatherApp
@testable import GatherCore

private func makeTempPhotoStore() async throws -> any GatherCore.PhotoStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-photos-\(UUID().uuidString).sqlite").path
    try MigrationRunner().migrate(try DBConnection(path: path))
    return try GatherCore.SQLitePhotoStore(database: try GatherCore.SQLiteDatabase(path: path))
}


private func makeTempAssetStore() async throws -> any GatherCore.AssetStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-assets-\(UUID().uuidString).sqlite").path
    try MigrationRunner().migrate(try DBConnection(path: path))
    return try GatherCore.SQLiteAssetStore(database: try GatherCore.SQLiteDatabase(path: path))
}


// MARK: - Stub（错误态与调用记录）

private final class StubLibraryProvider: LibraryDataProvider {
    var sessions: [SessionData] = []
    var photos: [GlobalPhotoResult] = []
    var total = 0
    var listError: String?
    var photosError: String?
    private(set) var fetchCalls: [(criteria: FilterGroup, sessionId: String?, limit: Int, offset: Int)] = []

    func listSessions() throws -> [SessionData] {
        if let listError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: listError])
        }
        return sessions
    }

    func globalPhotos(criteria: FilterGroup, sessionId: String?, limit: Int, offset: Int) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        if let photosError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: photosError])
        }
        fetchCalls.append((criteria, sessionId, limit, offset))
        return (photos, total)
    }

    func albumPhotos(albumId: String, limit: Int, offset: Int) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        (photos, total)
    }

    static func session(_ id: String, name: String = "工作区") -> SessionData {
        SessionData(
            id: id, name: name, status: .photosLoaded, photoCount: 3,
            analysisStatus: .idle, writebackStatus: .idle, importSource: "folder",
            sourcePath: "", failedWritebackCount: 0, truncatedImport: false,
            createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    static func photo(_ id: String, sessionId: String = "s1") -> GlobalPhotoResult {
        GlobalPhotoResult(
            photoId: id, assetId: id, sessionId: sessionId, sessionName: "工作区",
            sessionIds: [sessionId], sessionNames: ["工作区"], filename: "\(id).jpg",
            filepath: "/tmp/\(id).jpg", status: "online", rating: 0, label: "", keywords: []
        )
    }
}

@MainActor
private func makeStubVM(delay: Duration = .milliseconds(5)) -> (LibraryViewModel, StubLibraryProvider) {
    let stub = StubLibraryProvider()
    return (LibraryViewModel(provider: stub, debounceDelay: delay), stub)
}

// MARK: - 真实服务集成（临时 SQLite + 路由直连）

private func makeLiveProvider() async throws -> (LiveLibraryDataProvider, DBConnection) {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    let tempStorePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-library-\(UUID().uuidString).sqlite").path
    try MigrationRunner().migrate(try DBConnection(path: tempStorePath))
    let tempJobStore = try SQLiteJobStore(database: try SQLiteDatabase(path: tempStorePath))
    let settings = try makeTestSettings()
    let router = SessionCommandRouter.makeDefault(
        db: db, settings: settings.snapshot, settingsAPI: settings.api, templates: settings.templates, albums: settings.albums, workspace: settings.workspace, persons: settings.persons, personStore: settings.personStore, faceStore: settings.faceStore, metadataStore: settings.metadataStore, cullingStore: settings.cullingStore, similarityStore: settings.similarityStore, writebackStore: settings.writebackStore, jobStore: tempJobStore, assetStore: try await makeTempAssetStore(), photoStore: try await makeTempPhotoStore())
    return (LiveLibraryDataProvider(router: router), db)
}

private func insertSession(_ db: DBConnection, _ id: String, name: String = "工作区") throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, ?, 'photos_loaded', 'idle', 'idle', 'folder', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(name)])
}

/// 照片 + 可选元数据缓存行（rating/label/keywords/status）。
private func insertPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    status: String = "online",
    rating: Int = 0,
    label: String = "",
    keywords: String = "[]",
    createdAt: String = "2026-01-01T00:00:00.000Z"
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', ?, '{}', '{}', ?, ?)
    """).run([.text(id), .text(sessionId), .text("/tmp/\(id).jpg"), .text("\(id).jpg"), .text(status), .text(createdAt), .text(createdAt)])
    _ = try db.prepare("""
        INSERT INTO photo_metadata_cache (photo_id, session_id, rating, label, keywords, cached_at)
        VALUES (?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(sessionId), .int(Int64(rating)), .text(label), .text(keywords)])
}

// MARK: - 用例

@MainActor
@Suite("LibraryViewModel")
struct LibraryViewModelTests {
    // ── buildCriteria 映射对账（TS Library.tsx buildCriteria 逐条件）──

    @Test func buildCriteriaMapsEveryField() {
        var state = LibraryFilterState()
        state.search = "  DSC_001  "
        state.rating = "4"
        state.label = "Red"
        state.status = "online"
        state.keyword = " 旅行 "
        state.directory = "/Volumes/Photo"
        state.volume = "vol:1"
        state.person = "小明"
        state.duplicates = "yes"
        state.recentDays = "7"

        let criteria = buildLibraryCriteria(state)
        #expect(criteria.logic == .and)
        #expect(criteria.conditions.count == 10)
        let rules = criteria.conditions.compactMap { condition -> FilterRule? in
            if case .rule(let rule) = condition { return rule }
            return nil
        }
        func rule(_ field: String) -> FilterRule? {
            rules.first { $0.field == field }
        }
        // 自由文本 trim 后入条件。
        #expect(rule("filename")?.operator == .contains)
        #expect(rule("filename")?.value == .string("DSC_001"))
        #expect(rule("rating")?.operator == .gte)
        #expect(rule("rating")?.value == .number(4))
        #expect(rule("label")?.value == .string("Red"))
        // online → status neq 'missing'；missing → eq。
        #expect(rule("status")?.operator == .neq)
        #expect(rule("status")?.value == .string("missing"))
        // keywords → contains_any [keyword]。
        #expect(rule("keywords")?.operator == .containsAny)
        #expect(rule("keywords")?.value == .array([.string("旅行")]))
        #expect(rule("directory")?.operator == .startsWith)
        #expect(rule("directory")?.value == .string("/Volumes/Photo"))
        #expect(rule("volume")?.value == .string("vol:1"))
        #expect(rule("person")?.operator == .contains)
        #expect(rule("person")?.value == .string("小明"))
        // duplicates yes → has_duplicates eq true。
        #expect(rule("has_duplicates")?.operator == .eq)
        #expect(rule("has_duplicates")?.value == .bool(true))
        // recentDays → created_at gte ISO8601（毫秒精度）。
        let since = rule("created_at")
        #expect(since?.operator == .gte)
        if case .string(let iso)? = since?.value {
            #expect(ISO8601DateFormatter().date(from: iso) != nil)
        } else {
            Issue.record("created_at 值应为 ISO 字符串")
        }
    }

    @Test func buildCriteriaSkipsEmptyFields() {
        let criteria = buildLibraryCriteria(LibraryFilterState())
        #expect(criteria.conditions.isEmpty)
        var state = LibraryFilterState()
        state.status = "missing"
        state.duplicates = "no"
        let criteria2 = buildLibraryCriteria(state)
        let rules = criteria2.conditions.compactMap { condition -> FilterRule? in
            if case .rule(let rule) = condition { return rule }
            return nil
        }
        // missing → status eq 'missing'；duplicates no → has_duplicates eq false。
        #expect(rules.first { $0.field == "status" }?.operator == .eq)
        #expect(rules.first { $0.field == "has_duplicates" }?.value == .bool(false))
    }

    // ── 加载与分页 ──

    @Test func loadFetchesSessionsAndFirstPage() async {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [StubLibraryProvider.session("s1"), StubLibraryProvider.session("s2")]
        stub.photos = [StubLibraryProvider.photo("p1"), StubLibraryProvider.photo("p2")]
        stub.total = 2

        await viewModel.load()

        #expect(viewModel.phase == .loaded)
        #expect(viewModel.sessions.count == 2)
        #expect(viewModel.photos.count == 2)
        #expect(viewModel.total == 2)
        // 首页 offset 0、limit PAGE_SIZE。
        #expect(stub.fetchCalls.count == 1)
        #expect(stub.fetchCalls[0].limit == LibraryViewModel.pageSize)
        #expect(stub.fetchCalls[0].offset == 0)
        #expect(stub.fetchCalls[0].sessionId == nil)
        #expect(viewModel.hasNextPage == false)
        #expect(viewModel.rangeText == "第 1–2 张")
    }

    // 分页：total 驱动页码边界与 offset 语义（TS prevPage/nextPage）。
    @Test func paginationAdvancesOffsetAndClamps() async {
        let (viewModel, stub) = makeStubVM()
        stub.total = 250
        stub.photos = Array(0..<LibraryViewModel.pageSize).map { StubLibraryProvider.photo("p\($0)") }

        await viewModel.load()
        #expect(viewModel.hasNextPage == true)
        #expect(viewModel.rangeText == "第 1–60 张")

        viewModel.nextPage()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.page == 1)
        #expect(stub.fetchCalls.last?.offset == LibraryViewModel.pageSize)

        viewModel.nextPage()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.page == 2)
        #expect(stub.fetchCalls.last?.offset == 2 * LibraryViewModel.pageSize)

        viewModel.nextPage()
        try? await Task.sleep(for: .milliseconds(200))
        // 第 3 页 (offset 180 < 250) 允许。
        #expect(viewModel.page == 3)
        viewModel.nextPage()
        try? await Task.sleep(for: .milliseconds(200))
        // 第 4 页 (offset 240)：TS 按钮禁用条件 (page+1)*PAGE >= total
        // → (3+1)*60=240 < 250 仍可进入；第 5 页 (300 >= 250) 才禁。
        #expect(viewModel.page == 4)
        viewModel.nextPage()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.page == 4, "超出 total 的页码不应前进")

        viewModel.prevPage()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.page == 3)
    }

    // ── 筛选提交与防抖 ──

    // 非防抖字段（rating/label/status/volume/duplicates/recentDays）立即提交。
    @Test func nonDebouncedFilterCommitsImmediately() async {
        let (viewModel, stub) = makeStubVM()
        stub.total = 10
        stub.photos = [StubLibraryProvider.photo("p1")]
        await viewModel.load()

        viewModel.filter.rating = "4"
        viewModel.onFilterChanged()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(stub.fetchCalls.count == 2)
        let call = stub.fetchCalls[1]
        let rules = call.criteria.conditions.compactMap { condition -> FilterRule? in
            if case .rule(let rule) = condition { return rule }
            return nil
        }
        #expect(rules.first { $0.field == "rating" }?.value == .number(4))
        #expect(viewModel.page == 0)
    }

    // 防抖字段（search/keyword/directory/person）延迟 300ms（注入 5ms）后提交。
    @Test func debouncedFilterCommitsAfterDelay() async {
        let (viewModel, stub) = makeStubVM(delay: .milliseconds(5))
        stub.total = 10
        stub.photos = [StubLibraryProvider.photo("p1")]
        await viewModel.load()

        viewModel.filter.search = "DSC"
        viewModel.onFilterChanged()
        // 防抖窗口内不应提交。
        try? await Task.sleep(for: .milliseconds(2))
        #expect(stub.fetchCalls.count == 1)
        // 窗口过后提交一次（连续输入合并）。注入防抖 5ms，等待 200ms：
        // 全套件并行跑时 30ms 的调度余量不够（Task.sleep 可能被延迟）。
        viewModel.filter.search = "DSC_00"
        viewModel.onFilterChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(stub.fetchCalls.count == 2)
        let call = stub.fetchCalls[1]
        let rules = call.criteria.conditions.compactMap { condition -> FilterRule? in
            if case .rule(let rule) = condition { return rule }
            return nil
        }
        #expect(rules.first { $0.field == "filename" }?.value == .string("DSC_00"))
    }

    // criteriaKey 变更 → 页码归零（TS useEffect setPage(0)）。
    @Test func criteriaChangeResetsPageToZero() async {
        let (viewModel, stub) = makeStubVM()
        stub.total = 250
        stub.photos = Array(0..<LibraryViewModel.pageSize).map { StubLibraryProvider.photo("p\($0)") }
        await viewModel.load()

        viewModel.nextPage()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.page == 1)

        viewModel.filter.label = "Red"
        viewModel.onFilterChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.page == 0)
        #expect(stub.fetchCalls.last?.offset == 0)
    }

    // 会话筛选：sessionFilter 生效（传 sessionId 且页码归零）。
    @Test func sessionFilterScopesQuery() async {
        let (viewModel, stub) = makeStubVM()
        stub.total = 30
        stub.photos = [StubLibraryProvider.photo("p1")]
        await viewModel.load()

        viewModel.sessionFilter = "s2"
        viewModel.onSessionFilterChanged()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(stub.fetchCalls.last?.sessionId == "s2")
        #expect(viewModel.page == 0)
    }

    // 清除筛选：字段归零并提交。
    @Test func clearFiltersResetsAllFields() async {
        let (viewModel, stub) = makeStubVM()
        stub.total = 30
        stub.photos = [StubLibraryProvider.photo("p1")]
        await viewModel.load()

        viewModel.filter.search = "x"
        viewModel.filter.rating = "5"
        viewModel.filter.duplicates = "yes"
        viewModel.sessionFilter = "s1"
        viewModel.onFilterChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.activeFilterCount == 3)
        #expect(viewModel.advancedFilterCount == 1)

        viewModel.clearFilters()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.activeFilterCount == 0)
        #expect(viewModel.filter == LibraryFilterState())
        #expect(viewModel.sessionFilter == "")
        #expect(stub.fetchCalls.last?.sessionId == nil)
    }

    // ── 错误态 ──

    @Test func firstPageFailureSetsFailedPhase() async {
        let (viewModel, stub) = makeStubVM()
        stub.photosError = "FILTER_QUERY_FAILED"
        await viewModel.load()
        #expect(viewModel.phase == .failed("FILTER_QUERY_FAILED"))
        #expect(viewModel.photos.isEmpty)
    }

    @Test func paginationFailureShowsActionError() async {
        let (viewModel, stub) = makeStubVM()
        stub.total = 250
        stub.photos = [StubLibraryProvider.photo("p1")]
        await viewModel.load()
        #expect(viewModel.phase == .loaded)

        stub.photosError = "PAGE_FAILED"
        viewModel.nextPage()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.actionError == "PAGE_FAILED")
    }

    // ── 真实服务集成 ──

    // 真实库：photos_global 按 rating/label 筛选 + total + 会话名聚合。
    @Test func liveProviderFiltersAndCountsGlobally() async throws {
        let (provider, db) = try await makeLiveProvider()
        try insertSession(db, "s1", name: "甲")
        try insertSession(db, "s2", name: "乙")
        try insertPhoto(db, id: "p1", sessionId: "s1", rating: 5, label: "Red")
        try insertPhoto(db, id: "p2", sessionId: "s1", rating: 2)
        try insertPhoto(db, id: "p3", sessionId: "s2", rating: 4)

        let viewModel = LibraryViewModel(provider: provider, debounceDelay: .milliseconds(5))
        await viewModel.load()
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.sessions.count == 2)
        #expect(viewModel.total == 3)

        // rating ≥ 4 → p1（Red）、p3。
        viewModel.filter.rating = "4"
        viewModel.onFilterChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.total == 2)
        #expect(Set(viewModel.photos.map(\.photoId)) == Set(["p1", "p3"]))
        #expect(viewModel.photos.first { $0.photoId == "p1" }?.label == "Red")

        // 会话筛选：仅 s1 → p1。
        viewModel.sessionFilter = "s1"
        viewModel.onSessionFilterChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.total == 1)
        #expect(viewModel.photos.map(\.photoId) == ["p1"])
        #expect(viewModel.photos[0].sessionName == "甲")
    }

    // 真实库：status 筛选（missing 离线）与 keywords contains_any。
    @Test func liveProviderFiltersByStatusAndKeywords() async throws {
        let (provider, db) = try await makeLiveProvider()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", status: "missing", keywords: "[\"旅行\",\"风景\"]")
        try insertPhoto(db, id: "p2", sessionId: "s1", keywords: "[]")

        let viewModel = LibraryViewModel(provider: provider, debounceDelay: .milliseconds(5))
        await viewModel.load()
        #expect(viewModel.total == 2)

        viewModel.filter.status = "missing"
        viewModel.onFilterChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.total == 1)
        #expect(viewModel.photos.map(\.photoId) == ["p1"])

        viewModel.filter.status = ""
        viewModel.filter.keyword = "旅行"
        viewModel.onFilterChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.total == 1)
        #expect(viewModel.photos.first?.keywords == ["旅行", "风景"])
    }

    // 真实库：photo.list 会话下拉数据 + 分页 total 与 photos 一致性。
    @Test func liveProviderPaginationCountsTotal() async throws {
        let (provider, db) = try await makeLiveProvider()
        try insertSession(db, "s1")
        for index in 0..<5 {
            try insertPhoto(db, id: "p\(index)", sessionId: "s1", rating: index % 3)
        }

        let viewModel = LibraryViewModel(provider: provider, debounceDelay: .milliseconds(5))
        await viewModel.load()
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.total == 5)
        #expect(viewModel.photos.count == 5)
    }

    // Library 侧栏的真实路由对账：智能相册 CRUD/分页与资产、孤立 XMP、卷列表
    // 均必须可调用，不能只靠 UI stub 通过编译。
    @Test func liveProviderSupportsLibrarySupportCommands() async throws {
        let (provider, db) = try await makeLiveProvider()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", rating: 5)

        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "rating", operator: .gte, value: .number(4))),
        ])
        let created = try await provider.createAlbum(name: "高评分", criteria: criteria)
        #expect(created.name == "高评分")
        #expect(try await provider.listAlbums().contains(where: { $0.id == created.id }))

        let page = try await provider.albumPhotos(albumId: created.id, limit: 60, offset: 0)
        #expect(page.total == 1)
        #expect(page.photos.map(\.photoId) == ["p1"])

        try await provider.updateAlbum(albumId: created.id, criteria: FilterGroup(logic: .and, conditions: []))
        try await provider.deleteAlbum(albumId: created.id)
        #expect(try await provider.listAlbums().contains(where: { $0.id == created.id }) == false)

        _ = try await provider.listAssetCandidates()
        _ = try await provider.listMetadataOrphans()
        _ = try await provider.listAssetVolumes()
    }
}
