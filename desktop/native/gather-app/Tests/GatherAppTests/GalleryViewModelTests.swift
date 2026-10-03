// desktop/native/gather-app/Tests/GatherAppTests/GalleryViewModelTests.swift
// Phase 3.2 Gallery 视图模型行为测试。
// 覆盖：photo.list_page 首屏加载、变体折叠/展开（RAW/JPEG 资产分组）、键集
// 分页（滚动加载）、搜索/筛选链式拉满与退出截断（TS chain-fetch 语义）、
// 人脸过滤、错误态（stub 注入）；集成用例用真实临时 SQLite + 路由直连。

import Foundation
import Testing
@testable import GatherApp
@testable import GatherCore

// MARK: - Stub（错误态与调用记录）

// 条件等待 waitUntilAsync 已抽到 Support/AsyncWait.swift（本 target 共享）。

/// Swift 6 迁移：GalleryDataProvider 现经协议继承 Sendable，测试替身必须可跨隔离域。
/// 可变状态全部收归 LockedBox（NSLock 保护的 @unchecked Sendable 锁盒）：
/// session/rows/pageError/sessionError/thrownError/workspaceStatusValue/
/// workspaceStatusError/pageCalls。对外属性一律经锁内 get/set 转发（测试调用点不变），
/// stub 方法在临界区内取快照后立即释放锁，绝不持锁 await（无锁内 await）。
private final class StubGalleryProvider: GalleryDataProvider {
    private final class LockedBox: @unchecked Sendable {
        let lock = NSLock()
        var session: SessionData?
        var rows: [GalleryPhotoData] = []
        var pageError: String?
        var sessionError: String?
        var thrownError: Error?
        var workspaceStatusValue: WorkspaceStatus?
        var workspaceStatusError: String?
        var pageCalls: [(afterFirstRowid: Int64?, limit: Int, expandVariants: Bool)] = []
        /// D05：把**失败**也算进去的请求尝试数（pageCalls 只在成功时记录）。
        var pageAttempts = 0
        /// D04：可注入的响应延迟（模拟悬挂请求，用来构造乱序/过期响应）。
        var pageDelay: Duration = .zero
    }

    private let box = LockedBox()

    var session: SessionData? {
        get { box.lock.withLock { box.session } }
        set { box.lock.withLock { box.session = newValue } }
    }

    /// 模拟库中全部照片（键集语义：cursor = 已取行数，按序切片）。
    var rows: [GalleryPhotoData] {
        get { box.lock.withLock { box.rows } }
        set { box.lock.withLock { box.rows = newValue } }
    }

    var pageError: String? {
        get { box.lock.withLock { box.pageError } }
        set { box.lock.withLock { box.pageError = newValue } }
    }

    var sessionError: String? {
        get { box.lock.withLock { box.sessionError } }
        set { box.lock.withLock { box.sessionError = newValue } }
    }

    /// 类型化错误注入（NativeCommandError/BridgeError/SessionServiceError 等）：
    /// NSError 形态覆盖不到「非 LocalizedError 枚举经 NSError 桥接丢码」的回归。
    var thrownError: Error? {
        get { box.lock.withLock { box.thrownError } }
        set { box.lock.withLock { box.thrownError = newValue } }
    }

    /// workspace.status 桩（索引头数据源）。
    var workspaceStatusValue: WorkspaceStatus? {
        get { box.lock.withLock { box.workspaceStatusValue } }
        set { box.lock.withLock { box.workspaceStatusValue = newValue } }
    }

    var workspaceStatusError: String? {
        get { box.lock.withLock { box.workspaceStatusError } }
        set { box.lock.withLock { box.workspaceStatusError = newValue } }
    }

    /// 调用记录：只读（写入只在下方 stub 方法的锁内完成）。
    var pageCalls: [(afterFirstRowid: Int64?, limit: Int, expandVariants: Bool)] {
        box.lock.withLock { box.pageCalls }
    }

    /// 含失败在内的请求尝试数（D05 断言用：失败也要能被数到）。
    var pageAttempts: Int {
        box.lock.withLock { box.pageAttempts }
    }

    /// 请求延迟（D04：构造在途悬挂的旧响应）。
    var pageDelay: Duration {
        get { box.lock.withLock { box.pageDelay } }
        set { box.lock.withLock { box.pageDelay = newValue } }
    }

    func getSession(_ sessionId: String) throws -> SessionData? {
        let (thrown, sessionError, session): (Error?, String?, SessionData?) = box.lock.withLock {
            (box.thrownError, box.sessionError, box.session)
        }
        if let thrown { throw thrown }
        if let sessionError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: sessionError])
        }
        return session
    }

    func photoPage(sessionId: String, afterFirstRowid: Int64?, limit: Int, expandVariants: Bool) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        let (thrown, pageError, rows, delay): (Error?, String?, [GalleryPhotoData], Duration) = box.lock.withLock {
            box.pageAttempts += 1
            return (box.thrownError, box.pageError, box.rows, box.pageDelay)
        }
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        if let thrown { throw thrown }
        if let pageError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: pageError])
        }
        box.lock.withLock { box.pageCalls.append((afterFirstRowid, limit, expandVariants)) }
        let startIndex = Int(afterFirstRowid ?? 0)
        guard startIndex < rows.count else { return ([], nil) }
        let end = min(startIndex + limit, rows.count)
        let slice = Array(rows[startIndex..<end])
        return (slice, end < rows.count ? Int64(end) : nil)
    }

    func workspaceStatus(_ sessionId: String) async throws -> WorkspaceStatus? {
        let (error, value): (String?, WorkspaceStatus?) = box.lock.withLock {
            (box.workspaceStatusError, box.workspaceStatusValue)
        }
        if let error {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        return value
    }

    func retryIndex(sessionId: String) async throws {
        let error = box.lock.withLock { box.workspaceStatusError }
        if let error {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    static func session(_ id: String) -> SessionData {
        SessionData(
            id: id, name: "工作区", status: .photosLoaded, photoCount: 0,
            analysisStatus: .idle, writebackStatus: .idle, importSource: "folder",
            sourcePath: "", failedWritebackCount: 0, truncatedImport: false,
            createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    static func photo(_ id: String, faceCount: Int = 0, variantCount: Int = 1, filename: String? = nil) -> GalleryPhotoData {
        GalleryPhotoData(
            id: id, sessionId: "s1", filepath: "/tmp/\(id).jpg",
            filename: filename ?? "\(id).jpg", checksum: "", hasExistingXmp: false,
            faceCount: faceCount, width: 100, height: 100, status: "online",
            variantCount: variantCount, variants: [], createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z", assetId: id
        )
    }
}

@MainActor
private func makeStubVM(delay: Duration = .milliseconds(5)) -> (GalleryViewModel, StubGalleryProvider) {
    let stub = StubGalleryProvider()
    return (GalleryViewModel(sessionId: "s1", provider: stub, debounceDelay: delay), stub)
}

// MARK: - 真实服务集成（临时 SQLite + 路由直连）

private func makeLiveProvider() throws -> (LiveGalleryDataProvider, DBConnection) {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    return (LiveGalleryDataProvider(router: SessionCommandRouter.makeDefault(db: db)), db)
}

private func insertSession(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, '工作区', 'photos_loaded', 'idle', 'folder', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id)])
}

/// 照片行（asset_id/asset_file_id 可空；status 缺省 online）。
private func insertPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filename: String? = nil,
    assetId: String? = nil,
    assetFileId: String? = nil,
    status: String = "online"
) throws {
    let filepath = "/vault/\(id)"
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', ?, '{}', '{}', ?, ?, 100, 100, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(id), .text(sessionId), .text(filepath), .text(filename ?? id),
        .text(status),
        assetId.map { .text($0) } ?? .null,
        assetFileId.map { .text($0) } ?? .null,
    ])
}

/// 逻辑资产（RAW/JPEG 变体）种子：asset + asset_file×2 + member_role +
/// photo 行。
private func insertLinkedAsset(
    _ db: DBConnection,
    sessionId: String,
    rawId: String,
    jpegId: String,
    roleRaw: String = "raw",
    roleJpeg: String = "camera_jpeg"
) throws {
    _ = try db.prepare("""
        INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at)
        VALUES ('asset-\(rawId)', '', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([])
    for (fileId, filepath) in [("file-\(rawId)", "/vault/\(rawId).NEF"), ("file-\(jpegId)", "/vault/\(jpegId).JPG")] {
        _ = try db.prepare("""
            INSERT INTO asset_files (id, volume_id, file_identity, normalized_path, filename, extension, media_type, file_size, file_mtime_ms, checksum, online_status, created_at, updated_at)
            VALUES (?, 'dev:1', '', ?, ?, ?, 'image', 0, 0, '', 'online', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(fileId), .text(filepath), .text((filepath as NSString).lastPathComponent), .text((filepath as NSString).pathExtension)])
    }
    _ = try db.prepare("""
        INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, confidence, binding_source)
        VALUES ('asset-\(rawId)', 'file-\(rawId)', ?, 1, 1.0, 'import'), ('asset-\(rawId)', 'file-\(jpegId)', ?, 0, 1.0, 'import')
    """).run([.text(roleRaw), .text(roleJpeg)])
    try insertPhoto(db, id: rawId, sessionId: sessionId, filename: "\(rawId).NEF", assetId: "asset-\(rawId)", assetFileId: "file-\(rawId)")
    try insertPhoto(db, id: jpegId, sessionId: sessionId, filename: "\(jpegId).JPG", assetId: "asset-\(rawId)", assetFileId: "file-\(jpegId)")
}

private func insertFace(_ db: DBConnection, photoId: String, sessionId: String) throws {
    _ = try db.prepare("""
        INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, created_at)
        VALUES (?, ?, 0, 0, 10, 10, x'00', '2026-01-01T00:00:00.000Z')
    """).run([.text(photoId), .text(sessionId)])
}

// MARK: - 用例

@MainActor
@Suite("GalleryViewModel")
struct GalleryViewModelTests {
    // ── 首屏加载 ──

    @Test func loadFetchesFirstPageAndSession() async {
        let (viewModel, stub) = makeStubVM()
        stub.session = StubGalleryProvider.session("s1")
        stub.rows = [StubGalleryProvider.photo("p1"), StubGalleryProvider.photo("p2")]
        await viewModel.load()

        #expect(viewModel.phase == .loaded)
        #expect(viewModel.session?.id == "s1")
        #expect(viewModel.loadedPhotos.count == 2)
        // 2 行 < pageSize 200：首屏即取完，无更多页。
        #expect(viewModel.hasNextPage == false)
        #expect(stub.pageCalls.count == 1)
        #expect(stub.pageCalls[0].afterFirstRowid == nil)
        // 非搜索态 limit 200（TS PAGE_SIZE）。
        #expect(stub.pageCalls[0].limit == GalleryViewModel.pageSize)
    }

    // ── 键集分页（滚动加载）──

    // pageSize 恒 200（对齐 TS Gallery.tsx:69-71）：>200 行分两页推进游标。
    @Test func loadMoreAdvancesKeysetCursor() async {
        let (viewModel, stub) = makeStubVM()
        stub.rows = (0..<250).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        #expect(viewModel.loadedPhotos.count == 200)
        #expect(stub.pageCalls[0].afterFirstRowid == nil)

        await viewModel.loadMoreIfNeeded()
        #expect(viewModel.loadedPhotos.count == 250)
        #expect(stub.pageCalls[1].afterFirstRowid == 200)
        #expect(viewModel.hasNextPage == false)
    }

    // 无更多页后 loadMoreIfNeeded 不再取页（hasNextPage 守卫）。
    @Test func loadMoreSkipsWhenNoNextPage() async {
        let (viewModel, stub) = makeStubVM()
        stub.session = StubGalleryProvider.session("s1")
        stub.rows = [StubGalleryProvider.photo("p1"), StubGalleryProvider.photo("p2")]
        await viewModel.load()
        let callsBefore = stub.pageCalls.count
        // 首屏 2 行 < pageSize 200：无更多页，后续调用不取页。
        await viewModel.loadMoreIfNeeded()
        #expect(stub.pageCalls.count == callsBefore)
    }

    // ── 搜索/筛选链式拉满与退出截断（TS chain-fetch + slice(0,1) 语义）──

    // 激活搜索：防抖后链式拉满全部页（limit 1000），客户端按文件名过滤。
    @Test func searchChainFetchesWholeSessionThenFilters() async {
        let (viewModel, stub) = makeStubVM()
        // 450 张 → 非搜索态需要 3 页（200/200/50）。
        stub.rows = (0..<450).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        #expect(viewModel.loadedPhotos.count == 200)

        viewModel.search = "p9"
        viewModel.searchChanged()
        // 搜索态 limit=1000：链式一次拉满剩余（首屏 200 + 链拉 250 = 2 次）。
        #expect(await waitUntilAsync { viewModel.loadedPhotos.count == 450 }, "搜索链应拉满 450，实际 \(viewModel.loadedPhotos.count)")
        #expect(stub.pageCalls.count == 2, "搜索链应恰好 2 次取页，实际 \(stub.pageCalls.count) 次")
        #expect(stub.pageCalls[1].limit == GalleryViewModel.chainFetchLimit)
        // 客户端过滤：filename contains 'p9'（p9/p90-99 = 11）。
        #expect(viewModel.filteredPhotos.count == 11)
        #expect(viewModel.filteredPhotos.allSatisfy { $0.filename.contains("p9") })
    }

    // MARK: 深度审查 D08（目标照片定位）

    @Test("D08：目标在第 200 张之后时主动取页定位，不靠用户滚到目标")
    func locateTargetBeyondFirstPage() async {
        let (viewModel, stub) = makeStubVM()
        stub.session = StubGalleryProvider.session("s1")
        stub.rows = (0..<600).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        #expect(viewModel.loadedPhotos.count == 200, "初始只有首屏 200 张（本用例前提）")

        let outcome = await viewModel.locatePendingPhoto(photoId: "p450", photoPath: nil)
        #expect(outcome == .found, "目标在第二页之后必须被主动取页找到")
        #expect(viewModel.loadedPhotos.contains { $0.id == "p450" })
        #expect(viewModel.actionError == nil, "找到时不得报错")
    }

    @Test("D08：只带 filepath 的目标同样能定位（相似度成员行入口）")
    func locateTargetByPath() async {
        let (viewModel, stub) = makeStubVM()
        stub.session = StubGalleryProvider.session("s1")
        stub.rows = (0..<400).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        let target = "/tmp/p350.jpg"
        #expect(!viewModel.loadedPhotos.contains { $0.filepath == target })
        let outcome = await viewModel.locatePendingPhoto(photoId: nil, photoPath: target)
        #expect(outcome == .found, "路径入口必须能定位到首屏之外的目标")
        #expect(viewModel.loadedPhotos.contains { $0.filepath == target })
    }

    @Test("D08：目标不存在时返回 false 并给出明确反馈（不静默等待）")
    func locateMissingTargetReportsFailure() async {
        let (viewModel, stub) = makeStubVM()
        stub.session = StubGalleryProvider.session("s1")
        stub.rows = (0..<300).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        let outcome = await viewModel.locatePendingPhoto(photoId: "does-not-exist", photoPath: nil)
        #expect(outcome == .notFound)
        // 接线断言走真实报告方法（审计 5：测试自己调 setter 等于只测 setter）。
        viewModel.reportPhotoTargetMissing()
        #expect(viewModel.actionError != nil, "找不到目标必须给出可见反馈")
    }

    @Test("D08：取页失败时定位立即停止（不无限拉取）")
    func locateStopsWhenPagingFails() async {
        let (viewModel, stub) = makeStubVM()
        stub.session = StubGalleryProvider.session("s1")
        stub.rows = (0..<600).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        stub.pageError = "boom"
        let outcome = await viewModel.locatePendingPhoto(photoId: "p500", photoPath: nil)
        #expect(outcome == .failed, "取页失败必须与「不存在」区分（审计 2 P2-4）")
        #expect(viewModel.loadedPhotos.count == 200, "失败后不得继续拉取")
    }

    // MARK: 深度审查 D04 / D05 / D07（异步数据边界）

    @Test("D05：链式取页遇到错误立即停止，不得无限重试")
    func chainFetchStopsOnFailure() async {
        let (viewModel, stub) = makeStubVM()
        stub.session = StubGalleryProvider.session("s1")
        stub.rows = (0..<600).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()

        // 激活搜索 → 走链式拉取路径。
        viewModel.search = "p"
        viewModel.searchChanged()
        try? await Task.sleep(for: .milliseconds(500))
        let attemptsAfterChain = stub.pageAttempts

        // 之后每一次请求都失败：链必须在第一个错误处终止。
        stub.pageError = "boom"
        await viewModel.loadMoreIfNeeded()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(
            stub.pageAttempts <= attemptsAfterChain + 1,
            "失败后不得继续自动重试同一页（旧实现忽略返回值，会连发 21+ 次）"
        )
    }

    @Test("D07：普通搜索提交路径也要清空选择集")
    func searchCommitClearsSelection() async {
        let (viewModel, stub) = makeStubVM()
        stub.session = StubGalleryProvider.session("s1")
        stub.rows = (0..<10).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        viewModel.toggleSelection("p1")
        #expect(viewModel.selectedIds.contains("p1"))

        // 普通搜索不经过 reload（旧实现只在 reload 里清选择）。
        viewModel.search = "p9"
        viewModel.searchChanged()
        try? await Task.sleep(for: .milliseconds(500))
        #expect(viewModel.selectedIds.isEmpty, "查询条件变化后不得保留屏幕上已不存在的选择")
    }

    @Test("D04：切变体让在途分页响应作废，不得把旧页写入新数据集")
    func stalePageResponseIsDropped() async {
        let (viewModel, stub) = makeStubVM()
        stub.session = StubGalleryProvider.session("s1")
        stub.rows = (0..<600).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        let firstPageCount = viewModel.filteredPhotos.count
        #expect(firstPageCount == 200, "初始页大小应为 200（本用例前提）")

        // 在途「取下一页」被挂起，随后切换变体（reload 递增数据代数）。
        stub.pageDelay = .milliseconds(200)
        let pending = Task { await viewModel.loadMoreIfNeeded() }
        try? await Task.sleep(for: .milliseconds(20))
        viewModel.expandVariants = true
        viewModel.filterOrVariantChanged()
        await pending.value
        try? await Task.sleep(for: .milliseconds(400))

        // 审计 5（测试有效性）：只断言「张数 == 200」是**假阴性**——旧实现把
        // 旧页 append 进空数组后同样是 200 行（只是内容从 p200 开始）。必须断言
        // 数据集**身份**：首行仍是首页首行，且不含旧页的行。
        #expect(viewModel.filteredPhotos.count == firstPageCount)
        #expect(viewModel.filteredPhotos.first?.id == "p0", "切变体后首屏必须是新首页 p0，而不是旧页 p200")
        #expect(
            !viewModel.filteredPhotos.contains { $0.id == "p200" },
            "旧代数的分页响应不得进入新数据集"
        )
    }

    // 退出搜索：丢弃链式拉取的额外页，仅保留首页（200 行）。
    @Test func exitingSearchDropsChainFetchedPages() async {
        let (viewModel, stub) = makeStubVM()
        stub.rows = (0..<450).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()

        viewModel.search = "p9"
        viewModel.searchChanged()
        #expect(await waitUntilAsync { viewModel.loadedPhotos.count == 450 }, "搜索链应拉满 450，实际 \(viewModel.loadedPhotos.count)")

        viewModel.search = ""
        viewModel.searchChanged()
        #expect(await waitUntilAsync { viewModel.loadedPhotos.count == 200 }, "退出搜索应保留首屏 200，实际 \(viewModel.loadedPhotos.count)")

        // 保留首屏页（TS setQueryData pages.slice(0,1)），哨兵恢复自然分页。
        #expect(viewModel.filteredPhotos.count == 200)
        await viewModel.loadMoreIfNeeded()
        #expect(viewModel.loadedPhotos.count == 400)
        #expect(stub.pageCalls.last?.limit == GalleryViewModel.pageSize)
    }

    // 人脸过滤（TS FILTER_OPTIONS hasFace/noFace，客户端过滤）。
    @Test func faceFilterSelectsByFaceCount() async {
        let (viewModel, stub) = makeStubVM()
        stub.rows = [StubGalleryProvider.photo("with", faceCount: 2), StubGalleryProvider.photo("without", faceCount: 0)]
        await viewModel.load()

        // filterOrVariantChanged → commitSearch 同步写入 committedFilter，
        // filteredPhotos 立即反映新过滤（客户端过滤，不依赖取数落定）。
        viewModel.filter = .hasFace
        viewModel.filterOrVariantChanged()
        #expect(viewModel.filteredPhotos.map(\.id) == ["with"])

        viewModel.filter = .noFace
        viewModel.filterOrVariantChanged()
        #expect(viewModel.filteredPhotos.map(\.id) == ["without"])
    }

    // 变体展开切换：整页重取（TS queryKey 含 expandVariants）。
    @Test func expandVariantsRefetchesFromScratch() async {
        let (viewModel, stub) = makeStubVM()
        stub.rows = (0..<205).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        #expect(viewModel.loadedPhotos.count == 200)

        viewModel.expandVariants = true
        viewModel.filterOrVariantChanged()
        // 等「整页重取已完成」：reload 先清空 pages 再取首页，故条件同时覆盖
        // 取页已发生（expandVariants=true）与首页已重新装载（200 行）。
        #expect(await waitUntilAsync {
            stub.pageCalls.last?.expandVariants == true && viewModel.loadedPhotos.count == 200
        })

        #expect(stub.pageCalls.last?.afterFirstRowid == nil)
        #expect(viewModel.loadedPhotos.count == 200)
    }

    // 选择集合（TS toggleSelect / clearSelection）。
    @Test func selectionTogglesAndClears() async {
        let (viewModel, stub) = makeStubVM()
        stub.rows = [StubGalleryProvider.photo("p1"), StubGalleryProvider.photo("p2")]
        await viewModel.load()

        viewModel.toggleSelection("p1")
        viewModel.toggleSelection("p2")
        viewModel.toggleSelection("p1")
        #expect(viewModel.selectedIds == ["p2"])
        viewModel.clearSelection()
        #expect(viewModel.selectedIds.isEmpty)
    }

    // ── 错误态 ──

    @Test func firstPageFailureSetsFailedPhase() async {
        let (viewModel, stub) = makeStubVM()
        stub.pageError = "PAGE_FAILED"
        await viewModel.load()
        // 统一漏斗：非错误码诊断不再原样透出，经 errorText 回退通用文案。
        // 文案断言与切语言的套件互斥（appLanguage 是进程级全局量）。
        AppLanguageLock.withStableCopy {
            #expect(viewModel.phase == .failed(GatherLocalization.errorText("PAGE_FAILED")))
        }
    }

    @Test func paginationFailureShowsActionError() async {
        let (viewModel, stub) = makeStubVM()
        // 250 行：首屏 200 + 第二页触发（hasNextPage 守卫要求有下一页）。
        stub.rows = (0..<250).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        #expect(viewModel.phase == .loaded)

        // 后续页失败 → actionError（不推翻已加载内容）。
        stub.pageError = "NEXT_PAGE_FAILED"
        await viewModel.loadMoreIfNeeded()
        #expect(viewModel.phase == .loaded)
        AppLanguageLock.withStableCopy {
            #expect(viewModel.actionError == GatherLocalization.errorText("NEXT_PAGE_FAILED"))
        }
    }

    // 回归（审查 A）：码型错误必须被翻译，不得退化成通用文案。
    // 旧漏斗走 NSError.localizedDescription，NativeCommandError/BridgeError 不满足
    // LocalizedError → 桥接后退化为 "The operation couldn't be completed…" → 已知码
    // 也被显示成通用文案。断言逐条钉住「码被正确翻译」。
    @Test func typedCodeErrorsAreTranslated() async {
        let cases: [(label: String, error: Error, code: String)] = [
            ("NativeCommandError 已知码", NativeCommandError.failed("SESSION_NOT_FOUND"), "SESSION_NOT_FOUND"),
            ("BridgeError 已知码（router person.get 同款构造）", BridgeError.notFound("PERSON_NOT_FOUND"), "PERSON_NOT_FOUND"),
        ]
        for item in cases {
            let (viewModel, stub) = makeStubVM()
            stub.thrownError = item.error
            await viewModel.load()
            AppLanguageLock.withStableCopy {
                let generic = GatherLocalization.errorText("NOT_A_CODE")
                #expect(
                    viewModel.phase == .failed(GatherLocalization.errorText(item.code)),
                    Comment(rawValue: item.label)
                )
                if case .failed(let text) = viewModel.phase {
                    #expect(text != generic, Comment(rawValue: item.label + " 不得回退通用文案"))
                } else {
                    Issue.record("应进入 failed 相位：\(item.label)")
                }
            }
        }
    }

    /// 参数化码（单冒号 CODE: 参数 与双冒号 CODE::p1）经漏斗后参数不得丢失。
    @Test func parameterizedCodeErrorsKeepParameters() async {
        let raws = ["XMP_CONFIRM_OTHER_SESSION_PENDING: s1", "FILTER_FIELD_UNKNOWN::rating"]
        let params = ["s1", "rating"]
        for index in raws.indices {
            let (viewModel, stub) = makeStubVM()
            stub.thrownError = NativeCommandError.failed(raws[index])
            await viewModel.load()
            AppLanguageLock.withStableCopy {
                let expected = GatherLocalization.errorText(raws[index])
                #expect(viewModel.phase == .failed(expected))
                #expect(expected.contains(params[index]), Comment(rawValue: raws[index]))
                #expect(viewModel.phase != .failed(GatherLocalization.errorText("NOT_A_CODE")))
            }
        }
    }

    // TS: Gallery.tsx:50-55 —— settings thumbnail_size 分桶（≤320→256、
    // ≤1280→1024、>1280→2048）。边界值各自独立钉住（321/1280/1281）。
    @Test func thumbnailSizeBucketsMatchTS() {
        #expect(LiveGalleryDataProvider.thumbnailBucket(0) == 256)
        #expect(LiveGalleryDataProvider.thumbnailBucket(320) == 256)
        #expect(LiveGalleryDataProvider.thumbnailBucket(321) == 1024)
        #expect(LiveGalleryDataProvider.thumbnailBucket(1280) == 1024)
        #expect(LiveGalleryDataProvider.thumbnailBucket(1281) == 2048)
        #expect(LiveGalleryDataProvider.thumbnailBucket(4096) == 2048)
    }

    // ── 真实服务集成 ──

    // 真实库：变体折叠（expandVariants=false 每资产一行，首选 raw）+ 展开。
    @Test func liveProviderFoldsAndExpandsVariants() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        try insertLinkedAsset(db, sessionId: "s1", rawId: "raw1", jpegId: "jpeg1")
        try insertPhoto(db, id: "solo", sessionId: "s1")

        let collapsed = GalleryViewModel(sessionId: "s1", provider: provider, debounceDelay: .milliseconds(5))
        await collapsed.load()
        // 2 个逻辑资产 → 2 行；raw1 为代表（raw 首选），variantCount 2。
        #expect(collapsed.loadedPhotos.count == 2)
        let assetRow = collapsed.loadedPhotos.first { $0.assetId == "asset-raw1" }
        #expect(assetRow?.id == "raw1")
        #expect(assetRow?.variantCount == 2)
        #expect(assetRow?.variants.count == 2)
        let roles = Set(assetRow?.variants.map(\.role) ?? [])
        #expect(roles == ["raw", "camera_jpeg"])
        let soloRow = collapsed.loadedPhotos.first { $0.id == "solo" }
        // 无资产链接的独立照片：asset_id 键不输出（TS row.asset_id ?? undefined）。
        #expect(soloRow?.assetId == nil)
        #expect(soloRow?.variantCount == 1)

        // 展开：3 行（变体逐行展示）。
        collapsed.expandVariants = true
        collapsed.filterOrVariantChanged()
        #expect(await waitUntilAsync { collapsed.loadedPhotos.count == 3 })
    }

    // 真实库：键集分页（450 张 → 200/200/50，滚动加载三页 + 空页确认）。
    // cursor 语义与 TS photo.repo.ts 一致：满页返回末组 rowid，空页 null；
    // getNextPageParam 在空页后停（TS Gallery.tsx:75 同）。
    @Test func liveProviderKeysetPagination() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        for index in 0..<450 {
            try insertPhoto(db, id: "p\(String(format: "%03d", index))", sessionId: "s1")
        }

        let viewModel = GalleryViewModel(sessionId: "s1", provider: provider, debounceDelay: .milliseconds(5))
        await viewModel.load()
        #expect(viewModel.loadedPhotos.count == 200)
        #expect(viewModel.hasNextPage == true)

        await viewModel.loadMoreIfNeeded()
        #expect(viewModel.loadedPhotos.count == 400)

        await viewModel.loadMoreIfNeeded()
        #expect(viewModel.loadedPhotos.count == 450)
        // 第三页满 50 组仍返回 cursor；下一次空页才结束（TS 语义）。
        #expect(viewModel.hasNextPage == true)

        await viewModel.loadMoreIfNeeded()
        #expect(viewModel.loadedPhotos.count == 450)
        #expect(viewModel.hasNextPage == false)
        // 键集顺序 = rowid 升序（无重复/无遗漏）。
        #expect(Set(viewModel.loadedPhotos.map(\.id)).count == 450)
    }

    // 真实库：faceCount 来自 face_observations 聚合（hasFace 过滤）。
    @Test func liveProviderFaceCountAggregates() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "faced", sessionId: "s1")
        try insertPhoto(db, id: "plain", sessionId: "s1")
        try insertFace(db, photoId: "faced", sessionId: "s1")

        let viewModel = GalleryViewModel(sessionId: "s1", provider: provider, debounceDelay: .milliseconds(5))
        await viewModel.load()
        let faced = viewModel.loadedPhotos.first { $0.id == "faced" }
        #expect(faced?.faceCount == 1)
        let plain = viewModel.loadedPhotos.first { $0.id == "plain" }
        #expect(plain?.faceCount == 0)

        viewModel.filter = .hasFace
        viewModel.filterOrVariantChanged()
        #expect(viewModel.filteredPhotos.map(\.id) == ["faced"])
    }

    // ── 终态事件刷新（P15：保留已加载深度，不回卷首页）──

    // 事件刷新按原已加载深度重新拉取（游标从头起），而不是重置回首页：
    // 450 张已滚到 400 深度 → 重取 200+200 两页就地覆盖。
    @Test func eventRefreshPreservesLoadedDepth() async {
        let (viewModel, stub) = makeStubVM()
        stub.rows = (0..<450).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        await viewModel.loadMoreIfNeeded()
        #expect(viewModel.loadedPhotos.count == 400)

        await viewModel.refreshOnEvent()

        #expect(viewModel.loadedPhotos.count == 400)
        #expect(viewModel.phase == .loaded)
        // 从头重取：最后两次取页游标为 [nil, 200]（覆盖到 400 即停）。
        #expect(Array(stub.pageCalls.suffix(2).map(\.afterFirstRowid)) == [nil, 200])
    }

    // 事件后照片缩水（如重新扫描剔除失效项）：就地收敛到新总数，
    // 不整页失败、不重置回首页。
    @Test func eventRefreshShrinksGridInPlace() async {
        let (viewModel, stub) = makeStubVM()
        stub.rows = (0..<450).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()
        await viewModel.loadMoreIfNeeded()
        #expect(viewModel.loadedPhotos.count == 400)

        stub.rows = (0..<250).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.refreshOnEvent()

        #expect(viewModel.loadedPhotos.count == 250)
        #expect(viewModel.phase == .loaded)
    }

    // 事件刷新同时刷新 workspaceStatus（索引头随之更新）与 session。
    @Test func eventRefreshUpdatesIndexStatus() async {
        let (viewModel, stub) = makeStubVM()
        stub.rows = (0..<10).map { StubGalleryProvider.photo("p\($0)") }
        stub.workspaceStatusValue = WorkspaceStatus(
            sessionId: "s1",
            stage: .created,
            softFlags: WorkspaceSoftFlags(culled: false, exported: false),
            indexing: WorkspaceIndexingProgress(total: 0, done: 0, percent: 0, status: .active),
            staleAnalyses: [],
            xmp: WorkspaceXmpCounts(pending: 0, conflict: 0),
            offlinePhotos: 0,
            failedJobs: [],
            recommendedNext: nil,
            generatedAt: ""
        )
        await viewModel.load()
        #expect(viewModel.workspaceStatus?.indexing.status == .active)

        // 终态事件后 scan job 行终结：workspace.status 派生 idle。
        stub.workspaceStatusValue = WorkspaceStatus(
            sessionId: "s1",
            stage: .imported,
            softFlags: WorkspaceSoftFlags(culled: false, exported: false),
            indexing: WorkspaceIndexingProgress(total: 0, done: 0, percent: 0, status: .idle),
            staleAnalyses: [],
            xmp: WorkspaceXmpCounts(pending: 0, conflict: 0),
            offlinePhotos: 0,
            failedJobs: [],
            recommendedNext: nil,
            generatedAt: ""
        )
        await viewModel.refreshOnEvent()
        #expect(viewModel.workspaceStatus?.indexing.status == .idle)
        #expect(viewModel.workspaceStatus?.stage == .imported)
    }

    // 搜索/筛选激活时事件刷新保持链式拉满（过滤结果全局完整）。
    @Test func eventRefreshKeepsChainFetchWhenSearchActive() async {
        let (viewModel, stub) = makeStubVM()
        stub.rows = (0..<450).map { StubGalleryProvider.photo("p\($0)") }
        await viewModel.load()

        viewModel.search = "p4"
        viewModel.searchChanged()
        #expect(await waitUntilAsync { viewModel.loadedPhotos.count == 450 }, "搜索链应拉满 450，实际 \(viewModel.loadedPhotos.count)")

        await viewModel.refreshOnEvent()
        #expect(viewModel.loadedPhotos.count == 450)
        #expect(viewModel.phase == .loaded)
    }
}
