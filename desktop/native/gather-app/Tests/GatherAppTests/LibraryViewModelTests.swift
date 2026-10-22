// desktop/native/gather-app/Tests/GatherAppTests/LibraryViewModelTests.swift
// Phase 3.2 Library 视图模型行为测试。
// 覆盖：buildCriteria 映射对账（TS Library.tsx:52-91）、分页（offset 语义/
// 页码边界）、筛选防抖（300ms 注入缩短）、criteriaKey 变更页码归零、
// 错误态（stub 注入）；集成用例用真实临时 SQLite + 路由直连。

import Foundation
import Testing
@testable import GatherUI
@testable import GatherHost
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherDomain

// MARK: - Stub（错误态与调用记录）

/// Swift 6 迁移：LibraryDataProvider 现经协议继承 Sendable，测试替身必须可跨隔离域。
/// 可变状态全部收归共享 LockedBox（Support/LockedBox.swift；NSLock 保护的锁盒）：
/// sessions/photos/total/listError/photosError/photosThrownError/fetchCalls/
/// destructiveCalls/albums/listAlbumsError。对外属性一律经锁内 get/set 转发
/// （测试调用点不变），stub 方法在临界区内取快照后立即释放锁，绝不持锁 await。
private final class StubLibraryProvider: LibraryDataProvider {
    /// stub 的可变状态；只能经 `box.lock.withLock` 访问（与旧私有 LockedBox 同一纪律）。
    private struct BoxState {
        var sessions: [SessionData] = []
        var photos: [GlobalPhotoResult] = []
        var total = 0
        var listError: String?
        var photosError: String?
        var photosThrownError: Error?
        var fetchCalls: [(criteria: FilterGroup, sessionId: String?, limit: Int, offset: Int)] = []
        var destructiveCalls: [(command: String, confirmed: Bool)] = []
        var albums: [SmartAlbumData] = []
        var listAlbumsError: String?
        var orphans: [MetadataOrphan] = []
        var orphanCalls = 0
        var metadataInputs: [Confirmed<MetadataResolveOrphanInput>] = []
    }

    private let box = LockedBox(BoxState())

    var sessions: [SessionData] {
        get { box.lock.withLock { box.sessions } }
        set { box.lock.withLock { box.sessions = newValue } }
    }

    var photos: [GlobalPhotoResult] {
        get { box.lock.withLock { box.photos } }
        set { box.lock.withLock { box.photos = newValue } }
    }

    var total: Int {
        get { box.lock.withLock { box.total } }
        set { box.lock.withLock { box.total = newValue } }
    }

    var listError: String? {
        get { box.lock.withLock { box.listError } }
        set { box.lock.withLock { box.listError = newValue } }
    }

    var photosError: String? {
        get { box.lock.withLock { box.photosError } }
        set { box.lock.withLock { box.photosError = newValue } }
    }

    /// 类型化错误注入（APIError/BridgeError 等）：NSError 形态覆盖不到
    /// 「非 LocalizedError 枚举桥接丢码 / 单冒号参数形被门槛误判」的回归。
    var photosThrownError: Error? {
        get { box.lock.withLock { box.photosThrownError } }
        set { box.lock.withLock { box.photosThrownError = newValue } }
    }

    var fetchCalls: [(criteria: FilterGroup, sessionId: String?, limit: Int, offset: Int)] {
        box.lock.withLock { box.fetchCalls }
    }

    /// 破坏性命令的 (命令名, confirmed) 记录：断言 VM 不会把取消伪造成确认。
    var destructiveCalls: [(command: String, confirmed: Bool)] {
        box.lock.withLock { box.destructiveCalls }
    }

    var albums: [SmartAlbumData] {
        get { box.lock.withLock { box.albums } }
        set { box.lock.withLock { box.albums = newValue } }
    }

    var listAlbumsError: String? {
        get { box.lock.withLock { box.listAlbumsError } }
        set { box.lock.withLock { box.listAlbumsError = newValue } }
    }

    var orphans: [MetadataOrphan] {
        get { box.lock.withLock { box.orphans } }
        set { box.lock.withLock { box.orphans = newValue } }
    }

    var orphanCalls: Int { box.lock.withLock { box.orphanCalls } }

    var metadataInputs: [Confirmed<MetadataResolveOrphanInput>] {
        box.lock.withLock { box.metadataInputs }
    }

    func deleteAlbum(albumId: String, confirmed: Bool) throws {
        box.lock.withLock {
            box.destructiveCalls.append(("album.delete", confirmed))
            box.albums.removeAll { $0.id == albumId }
        }
    }

    func updateAssetCandidate(candidateId: String, accept: Bool, confirmed: Bool) throws {
        box.lock.withLock {
            box.destructiveCalls.append((accept ? "assets.accept_candidate" : "assets.reject_candidate", confirmed))
        }
    }

    func relinkAssetRoot(oldRoot: String, newRoot: String, confirmed: Bool) throws -> Int {
        box.lock.withLock { box.destructiveCalls.append(("assets.relink_root", confirmed)) }
        return 0
    }

    func listMetadataOrphans() async throws -> [MetadataOrphan] {
        box.lock.withLock {
            box.orphanCalls += 1
            return box.orphans
        }
    }

    func resolveMetadataOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
    ) async throws -> [MetadataOrphan] {
        box.lock.withLock {
            box.metadataInputs.append(input)
            box.destructiveCalls.append((
                "metadata.resolve_orphan." + input.value.action.rawValue,
                true
            ))
        }
        return []
    }

    func listSessions() throws -> [SessionData] {
        let (error, sessions): (String?, [SessionData]) = box.lock.withLock { (box.listError, box.sessions) }
        if let error {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        return sessions
    }

    func globalPhotos(criteria: FilterGroup, sessionId: String?, limit: Int, offset: Int) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        let (thrown, error, photos, total): (Error?, String?, [GlobalPhotoResult], Int) = box.lock.withLock {
            (box.photosThrownError, box.photosError, box.photos, box.total)
        }
        if let thrown { throw thrown }
        if let error {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        box.lock.withLock { box.fetchCalls.append((criteria, sessionId, limit, offset)) }
        return (photos, total)
    }

    func albumPhotos(albumId: String, limit: Int, offset: Int) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        box.lock.withLock { (box.photos, box.total) }
    }

    func listAlbums() throws -> [SmartAlbumData] {
        let (error, albums): (String?, [SmartAlbumData]) = box.lock.withLock { (box.listAlbumsError, box.albums) }
        if let error {
            throw NSError(domain: "stub", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
        return albums
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

/// NotificationCenter 观察盒：addObserver 回调闭包是 @Sendable、可能在任意线程执行，
/// Swift 6 禁止闭包直接改捕获的可变 var（#SendableClosureCaptures）。用 NSLock 保护
/// 记录值，append 与读取都走同一把锁；断言语义与原「局部 var」写法一致。
private final class NotificationRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }

    var values: [Value] {
        lock.withLock { storage }
    }

    var count: Int {
        lock.withLock { storage.count }
    }
}

/// 以 zh-CN 解析分页区间文案：文案已延迟到渲染期（VM 只存 key + 参数），
/// 解析语言显式给定，不再依赖进程级 appLanguage。
@MainActor
private func chineseRangeText(_ viewModel: LibraryViewModel) -> String {
    L10n(language: .zhCN).resolve(viewModel.rangeText)
}

@MainActor
private func makeStubVM(delay: Duration = .milliseconds(5)) -> (LibraryViewModel, StubLibraryProvider) {
    let stub = StubLibraryProvider()
    return (LibraryViewModel(provider: stub, debounceDelay: delay), stub)
}

// MARK: - 真实服务集成（临时 SQLite + 路由直连）

private func makeLiveProvider() throws -> (LiveLibraryDataProvider, DBConnection) {
    let db = try makeGatherTestDB()
    let services = AppServices.live(composition: AppComposition.make(db: db))
    return (LiveLibraryDataProvider(
        session: services.session,
        photo: services.photo,
        asset: services.asset,
        album: services.album,
        metadata: services.metadata
    ), db)
}

private func insertSession(_ db: DBConnection, _ id: String, name: String = "工作区") throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, created_at, updated_at)
        VALUES (?, ?, 'photos_loaded', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(name)])
}

/// 照片 + 可选元数据缓存行（rating/label/keywords/status）。
private func insertPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    // V1 photos.status 只允许 pending/ready/removed/missing；Library 的
    // "online" 是过滤器语义（status != missing），落库用 ready。
    status: String = "ready",
    rating: Int = 0,
    label: String = "",
    keywords: String = "[]",
    createdAt: String = "2026-01-01T00:00:00.000Z"
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', ?, ?, ?)
    """).run([.text(id), .text(sessionId), .text("/tmp/\(id).jpg"), .text("\(id).jpg"), .text(status), .text(createdAt), .text(createdAt)])
    _ = try db.prepare("""
        INSERT INTO photo_metadata_cache (photo_id, session_id, rating, label, keywords, cached_at)
        VALUES (?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(sessionId), .int(Int64(rating)), .text(label), .text(keywords)])
}

// MARK: - 用例

@MainActor
// .serialized：本套件里有多个用例会写库并广播领域变更（NotificationCenter 是
// 进程级总线），并行执行时别的用例发出的 .library/.metadata 会串进观察者的
// 数组里 —— 广播断言必须在无并发发布的条件下做。
@Suite("LibraryViewModel", .serialized)
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
        #expect(chineseRangeText(viewModel) == "第 1–2 张")
    }

    // 分页：total 驱动页码边界与 offset 语义（TS prevPage/nextPage）。
    @Test func paginationAdvancesOffsetAndClamps() async {
        let (viewModel, stub) = makeStubVM()
        stub.total = 250
        stub.photos = Array(0..<LibraryViewModel.pageSize).map { StubLibraryProvider.photo("p\($0)") }

        await viewModel.load()
        #expect(viewModel.hasNextPage == true)
        #expect(chineseRangeText(viewModel) == "第 1–60 张")

        viewModel.nextPage()
        #expect(await waitUntilAsync { viewModel.page == 1 })
        #expect(stub.fetchCalls.last?.offset == LibraryViewModel.pageSize)

        viewModel.nextPage()
        #expect(await waitUntilAsync { viewModel.page == 2 })
        #expect(stub.fetchCalls.last?.offset == 2 * LibraryViewModel.pageSize)

        viewModel.nextPage()
        // 第 3 页 (offset 180 < 250) 允许。
        #expect(await waitUntilAsync { viewModel.page == 3 })
        viewModel.nextPage()
        // 第 4 页 (offset 240)：TS 按钮禁用条件 (page+1)*PAGE >= total
        // → (3+1)*60=240 < 250 仍可进入；第 5 页 (300 >= 250) 才禁。
        #expect(await waitUntilAsync { viewModel.page == 4 })
        viewModel.nextPage()
        // goToPage 的边界守卫是同步早退（不派发取数 Task）：page 不变可立即断言。
        #expect(viewModel.page == 4, "超出 total 的页码不应前进")

        viewModel.prevPage()
        #expect(await waitUntilAsync { viewModel.page == 3 })
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
        #expect(await waitUntilAsync { stub.fetchCalls.count == 2 })
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
        // 防抖窗口内不应提交：防抖 Task 与测试同在 MainActor，测试不挂起它就
        // 绝无机会运行 —— 立即断言是确定性的，不需要「睡 2ms 抢窗口」。
        #expect(stub.fetchCalls.count == 1)
        // 窗口过后提交一次（连续输入合并）：条件等待，满足即返回。
        viewModel.filter.search = "DSC_00"
        viewModel.onFilterChanged()
        #expect(await waitUntilAsync { stub.fetchCalls.count == 2 })
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
        #expect(await waitUntilAsync { viewModel.page == 1 })

        viewModel.filter.label = "Red"
        viewModel.onFilterChanged()
        // commitFilter 同步归零页码；再等新首页取数落定校验 offset。
        #expect(viewModel.page == 0)
        #expect(await waitUntilAsync { stub.fetchCalls.last?.offset == 0 })
    }

    // 会话筛选：sessionFilter 生效（传 sessionId 且页码归零）。
    @Test func sessionFilterScopesQuery() async {
        let (viewModel, stub) = makeStubVM()
        stub.total = 30
        stub.photos = [StubLibraryProvider.photo("p1")]
        await viewModel.load()

        viewModel.sessionFilter = "s2"
        viewModel.onSessionFilterChanged()
        #expect(viewModel.page == 0)
        #expect(await waitUntilAsync { stub.fetchCalls.last?.sessionId == "s2" })
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
        // activeFilterCount/advancedFilterCount 读草稿态：无需等提交即成立。
        #expect(viewModel.activeFilterCount == 3)
        #expect(viewModel.advancedFilterCount == 1)
        // search 是防抖字段：等它提交，拿到「会话筛选已进入 criteriaKey」的基线。
        #expect(await waitUntilAsync { stub.fetchCalls.count == 2 })
        #expect(stub.fetchCalls.last?.sessionId == "s1", "会话筛选必须并入 criteriaKey")

        viewModel.clearFilters()
        #expect(viewModel.activeFilterCount == 0)
        #expect(viewModel.filter == LibraryFilterState())
        #expect(viewModel.sessionFilter == "")
        // 清除筛选必须真的重新取数一次（而不是沿用上一条结果）。
        #expect(await waitUntilAsync { stub.fetchCalls.count == 3 })
        #expect(stub.fetchCalls.last?.sessionId == nil)
    }

    // ── 错误态 ──

    @Test func firstPageFailureSetsFailedPhase() async throws {
        let (viewModel, stub) = makeStubVM()
        stub.photosError = "FILTER_QUERY_FAILED"
        await viewModel.load()
        // Cut 4 / 4a-3b-2a：phase 只存错误载体（码/诊断）；未映射码在渲染期回退
        // 通用文案，视图仍以"加载照片失败：%@"包装（不再把原始诊断直显）。
        let error = try #require(viewModel.phase.error)
        #expect(error.code.isEmpty)
        #expect(error.diagnostic == "FILTER_QUERY_FAILED")
        let l10n = L10n(language: .zhCN)
        #expect(CommandErrorText.resolve(error, with: l10n) == l10n.errorText("NOT_A_CODE"))
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
        #expect(await waitUntilAsync { viewModel.actionError != nil })
        #expect(viewModel.phase == .loaded)
        // P3：非错误码/未映射码不得直显 —— 界面回退通用文案，原始诊断只进诊断位。
        let error = viewModel.actionError
        #expect(error?.code.isEmpty == true)
        #expect(error?.diagnostic.contains("PAGE_FAILED") == true)
        #expect(CommandErrorText.resolve(error!, with: L10n(language: .zhCN)) == L10n(language: .zhCN).errorText("NOT_A_CODE"))
    }

    // 端到端（审查 B）：路由透传的「已知码: 参数」经 Library 漏斗不再被判成散文。
    // 可达：metadata.resolve_orphan → DeliveryError.otherSessionNotConfirmed 的
    // description（"XMP_CONFIRM_OTHER_SESSION_PENDING: <会话>"）→ 路由 errorMessage
    // → APIError.failed(该串)。
    @Test func parameterizedCodeFailureShowsParameterizedText() async throws {
        let (viewModel, stub) = makeStubVM()
        let raw = "XMP_CONFIRM_OTHER_SESSION_PENDING: s1"
        stub.photosThrownError = APIError.failed(raw)
        await viewModel.load()
        // 参数化码原样进载体，渲染期插值不丢参数。
        let error = try #require(viewModel.phase.error)
        #expect(error.code == raw)
        let l10n = L10n(language: .zhCN)
        let expected = CommandErrorText.resolve(error, with: l10n)
        #expect(expected == l10n.errorText(raw))
        #expect(expected.contains("s1"))
        #expect(expected != l10n.errorText("NOT_A_CODE"))
    }

    // 审查 B 回归：码形门槛不得吞掉「已知码 + 单冒号参数」的参数化模板。
    // 可达输入：metadata.resolve_orphan → MetadataSyncCoordinator.confirmSync 抛
    // DeliveryError.otherSessionNotConfirmed(sessionId:)（description 为
    // "XMP_CONFIRM_OTHER_SESSION_PENDING: <会话>"），经路由 errorMessage 透传。
    @Test func userFacingTextTranslatesParameterizedCode() {
        AppLanguageLock.withStableCopy {
            // Cut 4 / 4b-1：文案改为渲染期按 L10n 解析；用固定 zh 语言同时做期望，
            // 避免断言跟随进程级 appLanguage 漂移。
            let l10n = L10n(language: .zhCN)
            let raw = "XMP_CONFIRM_OTHER_SESSION_PENDING: s1"
            #expect(CommandError.isParameterizedErrorCode(raw))
            let text = LibraryViewModel.userFacingText(for: raw, with: l10n)
            // 与 errorText 同一插值语义：参数不丢（旧门槛判为散文 → 通用文案）。
            #expect(text == l10n.errorText(raw))
            #expect(text.contains("s1"))
            // 正例：双冒号参数形照旧走码形分支。
            #expect(LibraryViewModel.userFacingText(for: "FILTER_FIELD_UNKNOWN::rating", with: l10n)
                == l10n.errorText("FILTER_FIELD_UNKNOWN::rating"))
            // 负例：未知码 / 散文仍不猜，回退通用文案（门槛未被放宽成"有冒号就当码"）。
            let generic = l10n.errorText("NOT_A_CODE")
            #expect(LibraryViewModel.userFacingText(for: "UNKNOWN_CODE:limit", with: l10n) == generic)
            #expect(LibraryViewModel.userFacingText(for: "Some prose: detail", with: l10n) == generic)
            #expect(LibraryViewModel.userFacingText(for: "NOT_A_CODE", with: l10n) == generic)
            #expect(LibraryViewModel.userFacingText(for: "", with: l10n) == generic)
        }
    }

    // ── 跨页刷新：库级/元数据写成功后必须广播领域变更（review §4.7）──

    @Test func successfulMutationsPublishDomainChanges() async throws {
        let (viewModel, _) = makeStubVM()
        let received = NotificationRecorder<(domain: GatherDomain, origin: String?)>()
        let token = NotificationCenter.default.addObserver(
            forName: GatherEventCenter.domainChanged, object: nil, queue: nil
        ) { notification in
            // R7 P0-2：domainChanged 是进程级通知，并行套件（挑片/人物/相似度写回）
            // 也会发同一条通知。只收本发布者的 origin，避免把别人的事件算进
            // 「恰好四条」与「origin 必须一致」两个断言。
            guard let change = notification.object as? GatherDomainChange,
                  change.origin == LibraryViewModel.changeOrigin else { return }
            received.append((change.domain, change.origin))
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await viewModel.deleteAlbum(id: "album-1", confirmed: true)
        let candidate = AssetLinkCandidateData(
            id: "c1", leftFileId: "f1", rightFileId: "f2",
            leftPath: "/x/a.NEF", rightPath: "/x/a.JPG",
            confidence: 0.9, status: .pending, evidence: [:]
        )
        await viewModel.updateCandidate(candidate, accept: true, confirmed: true)
        await viewModel.relinkVolume(root: "/Volumes/A", newRoot: "/Users/me/A", confirmed: true)
        let orphan = MetadataOrphan(
            xmpPath: "/x/a.xmp", photoPath: "/x/a.jpg", status: "pending",
            revision: 1, errorMessage: "", updatedAt: "2026-01-01T00:00:00.000Z"
        )
        await viewModel.resolveOrphan(orphan, action: .restore, confirmed: true)

        #expect(received.values.map { $0.domain } == [.library, .library, .library, .metadata],
            "相册/资产/重链接 → .library；孤立 XMP → .metadata")
        #expect(received.values.allSatisfy { $0.origin == LibraryViewModel.changeOrigin },
            "发布者必须带 origin，监听方才能跳过自己发出的变更")
    }

    @Test func failedMutationsPublishNothing() async {
        let (viewModel, stub) = makeStubVM()
        stub.listAlbumsError = "ALBUM_FAILED"
        // 与上一个用例同理：只统计本发布者的事件；并行套件的 domainChanged
        // 不得被误判成「失败也广播」。
        let received = NotificationRecorder<GatherDomainChange>()
        let token = NotificationCenter.default.addObserver(
            forName: GatherEventCenter.domainChanged, object: nil, queue: nil
        ) { notification in
            guard let change = notification.object as? GatherDomainChange,
                  change.origin == LibraryViewModel.changeOrigin else { return }
            received.append(change)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await viewModel.deleteAlbum(id: "album-1", confirmed: true)

        #expect(received.count == 0, "写失败不得广播（否则常驻页会白刷一轮）")
        #expect(viewModel.actionError != nil)
    }

    // ── 真实服务集成 ──

    // 真实库：photos_global 按 rating/label 筛选 + total + 会话名聚合。
    @Test func liveProviderFiltersAndCountsGlobally() async throws {
        let (provider, db) = try makeLiveProvider()
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
        #expect(await waitUntilAsync { viewModel.total == 2 })
        #expect(Set(viewModel.photos.map(\.photoId)) == Set(["p1", "p3"]))
        #expect(viewModel.photos.first { $0.photoId == "p1" }?.label == "Red")

        // 会话筛选：仅 s1 → p1。
        viewModel.sessionFilter = "s1"
        viewModel.onSessionFilterChanged()
        #expect(await waitUntilAsync { viewModel.total == 1 })
        #expect(viewModel.photos.map(\.photoId) == ["p1"])
        #expect(viewModel.photos[0].sessionName == "甲")
    }

    // 真实库：status 筛选（missing 离线）与 keywords contains_any。
    @Test func liveProviderFiltersByStatusAndKeywords() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", status: "missing", keywords: "[\"旅行\",\"风景\"]")
        try insertPhoto(db, id: "p2", sessionId: "s1", keywords: "[]")

        let viewModel = LibraryViewModel(provider: provider, debounceDelay: .milliseconds(5))
        await viewModel.load()
        #expect(viewModel.total == 2)

        viewModel.filter.status = "missing"
        viewModel.onFilterChanged()
        #expect(await waitUntilAsync { viewModel.total == 1 })
        #expect(viewModel.photos.map(\.photoId) == ["p1"])

        viewModel.filter.status = ""
        viewModel.filter.keyword = "旅行"
        viewModel.onFilterChanged()
        // total 上一段已是 1，无法作为落定信号：等关键词投影本身出现。
        #expect(await waitUntilAsync { viewModel.photos.first?.keywords == ["旅行", "风景"] })
        #expect(viewModel.total == 1)
        #expect(viewModel.photos.first?.keywords == ["旅行", "风景"])
    }

    // 真实库：photo.list 会话下拉数据 + 分页 total 与 photos 一致性。
    @Test func liveProviderPaginationCountsTotal() async throws {
        let (provider, db) = try makeLiveProvider()
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
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", rating: 5)

        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "rating", operator: .gte, value: .number(4))),
        ])
        let created = try provider.createAlbum(name: "高评分", criteria: criteria)
        #expect(created.name == "高评分")
        #expect(try provider.listAlbums().contains(where: { $0.id == created.id }))

        let page = try await provider.albumPhotos(albumId: created.id, limit: 60, offset: 0)
        #expect(page.total == 1)
        #expect(page.photos.map(\.photoId) == ["p1"])

        try provider.updateAlbum(albumId: created.id, criteria: FilterGroup(logic: .and, conditions: []))
        try provider.deleteAlbum(albumId: created.id, confirmed: true)
        #expect(try provider.listAlbums().contains(where: { $0.id == created.id }) == false)

        _ = try provider.listAssetCandidates()
        _ = try await provider.listMetadataOrphans()
        _ = try provider.listAssetVolumes()
    }

    // ── 破坏性命令的确认契约（审查 §4.4「假确认」的回归防线）──
    //
    // 不变量：VM/Provider 绝不把「没有用户确认」伪造成 confirmed=true。
    // confirmed 是显式参数，取消路径根本不发命令（视图层只在确认动作里传 true，
    // 并用 reportActionCancelled 写可见文案）。

    @Test func destructiveCommandsForwardConfirmedVerbatim() async throws {
        let (viewModel, stub) = makeStubVM()

        await viewModel.deleteAlbum(id: "album-1", confirmed: false)
        await viewModel.deleteAlbum(id: "album-1", confirmed: true)

        let candidate = AssetLinkCandidateData(
            id: "c1", leftFileId: "f1", rightFileId: "f2",
            leftPath: "/x/a.NEF", rightPath: "/x/a.JPG",
            confidence: 0.9, status: .pending, evidence: [:]
        )
        await viewModel.updateCandidate(candidate, accept: true, confirmed: false)
        await viewModel.updateCandidate(candidate, accept: false, confirmed: true)

        let orphan = MetadataOrphan(
            xmpPath: "/x/a.xmp", photoPath: "/x/a.jpg", status: "pending",
            revision: 1, errorMessage: "", updatedAt: "2026-01-01T00:00:00.000Z"
        )
        // B6b：MetadataAPI 只接收 Confirmed<T>。未确认时 VM 本地拒绝
        //（METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED），不发请求、不伪造确认。
        let callsBeforeOrphan = stub.destructiveCalls.count
        await viewModel.resolveOrphan(orphan, action: .restore, confirmed: false)
        #expect(stub.destructiveCalls.count == callsBeforeOrphan)
        #expect(stub.metadataInputs.isEmpty)
        #expect(viewModel.actionError != nil)

        await viewModel.resolveOrphan(orphan, action: .keep, confirmed: true)
        #expect(stub.metadataInputs.count == 1)
        #expect(stub.metadataInputs.first?.source == .userDialog)
        #expect(stub.metadataInputs.first?.value.action == .keep)
        #expect(stub.metadataInputs.first?.value.xmpPath == orphan.xmpPath)

        await viewModel.relinkVolume(root: "/Volumes/A", newRoot: "/Users/me/A", confirmed: false)
        await viewModel.relinkVolume(root: "/Volumes/A", newRoot: "/Users/me/A", confirmed: true)

        #expect(stub.destructiveCalls.map { $0.command } == [
            "album.delete", "album.delete",
            "assets.accept_candidate", "assets.reject_candidate",
            "metadata.resolve_orphan.keep",
            "assets.relink_root", "assets.relink_root",
        ])
        // 逐条断言：false 进去必须是 false 出来（不得被提升为 true）；
        // 元数据处置的 Confirmed 只从确认分支构造（source = userDialog）。
        #expect(stub.destructiveCalls.map { $0.confirmed } == [
            false, true, false, true, true, false, true,
        ])
    }

    @Test func cancelledDestructiveActionIssuesNoCommandButShowsCopy() async throws {
        let (viewModel, stub) = makeStubVM()
        #expect(stub.destructiveCalls.isEmpty)

        // 视图的取消分支只调用这一个入口：必须留下可见文案且零命令。
        viewModel.reportActionCancelled()

        #expect(stub.destructiveCalls.isEmpty)
        let error = viewModel.actionError
        #expect(error?.origin == .localValidation)
        #expect(CommandErrorText.resolve(error!, with: L10n(language: .zhCN)).isEmpty == false)
    }

    // MARK: - B6b：metadata.orphans / resolve_orphan 迁移

    @Test func reloadSupportLoadsMetadataOrphans() async throws {
        let (viewModel, stub) = makeStubVM()
        let orphan = b6bOrphan()
        stub.orphans = [orphan]

        await viewModel.reloadSupport()

        #expect(stub.orphanCalls == 1, "孤立 XMP 刷新必须走 provider 的异步入口")
        #expect(viewModel.metadataOrphans.map(\.xmpPath) == [orphan.xmpPath])
        #expect(viewModel.actionError == nil)
    }

    @Test func resolveOrphanRefreshesListFromMetadataAPI() async throws {
        let (viewModel, stub) = makeStubVM()
        let orphan = b6bOrphan()
        stub.orphans = [orphan]
        await viewModel.reloadSupport()
        #expect(viewModel.metadataOrphans.count == 1)

        await viewModel.resolveOrphan(orphan, action: .keep, confirmed: true)

        let input = try #require(stub.metadataInputs.first)
        #expect(input.source == .userDialog)
        #expect(input.value.xmpPath == orphan.xmpPath)
        #expect(input.value.action == .keep)
        // 返回的剩余列表直接替换本地状态（stub 返回空 = 已结清）。
        #expect(viewModel.metadataOrphans.isEmpty)
    }
}
