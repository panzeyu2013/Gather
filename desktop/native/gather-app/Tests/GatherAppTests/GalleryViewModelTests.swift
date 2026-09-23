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

/// 轮询等待条件成立（async 版本：Task.sleep 不阻塞 MainActor，viewModel 的
/// debounceTask/commitSearch 才能推进；swift-testing 并行时调度延迟明显）。
@discardableResult
private func waitUntilAsync(
    timeout: TimeInterval = 5,
    interval: TimeInterval = 0.01,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(interval * 1000))
    }
    return condition()
}

private final class StubGalleryProvider: GalleryDataProvider {
    var session: SessionData?
    /// 模拟库中全部照片（键集语义：cursor = 已取行数，按序切片）。
    var rows: [GalleryPhotoData] = []
    var pageError: String?
    var sessionError: String?
    /// workspace.status 桩（索引头数据源）。
    var workspaceStatusValue: WorkspaceStatus?
    var workspaceStatusError: String?
    private(set) var pageCalls: [(afterFirstRowid: Int64?, limit: Int, expandVariants: Bool)] = []

    func getSession(_ sessionId: String) throws -> SessionData? {
        if let sessionError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: sessionError])
        }
        return session
    }

    func photoPage(sessionId: String, afterFirstRowid: Int64?, limit: Int, expandVariants: Bool) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        if let pageError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: pageError])
        }
        pageCalls.append((afterFirstRowid, limit, expandVariants))
        let startIndex = Int(afterFirstRowid ?? 0)
        guard startIndex < rows.count else { return ([], nil) }
        let end = min(startIndex + limit, rows.count)
        let slice = Array(rows[startIndex..<end])
        return (slice, end < rows.count ? Int64(end) : nil)
    }

    func workspaceStatus(_ sessionId: String) async throws -> WorkspaceStatus? {
        if let workspaceStatusError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: workspaceStatusError])
        }
        return workspaceStatusValue
    }

    func retryIndex(sessionId: String) async throws {
        if let workspaceStatusError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: workspaceStatusError])
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
    let settings = try makeTestSettings()
    let router = SessionCommandRouter.makeDefault(
        db: db, settings: settings.snapshot, settingsAPI: settings.api)
    return (LiveGalleryDataProvider(router: router), db)
}

private func insertSession(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, '工作区', 'photos_loaded', 'idle', 'idle', 'folder', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
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

        viewModel.filter = .hasFace
        viewModel.filterOrVariantChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.filteredPhotos.map(\.id) == ["with"])

        viewModel.filter = .noFace
        viewModel.filterOrVariantChanged()
        try? await Task.sleep(for: .milliseconds(200))
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
        try? await Task.sleep(for: .milliseconds(200))

        #expect(stub.pageCalls.last?.expandVariants == true)
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
        #expect(viewModel.phase == .failed("PAGE_FAILED"))
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
        #expect(viewModel.actionError == "NEXT_PAGE_FAILED")
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
        try? await Task.sleep(for: .milliseconds(200))
        #expect(collapsed.loadedPhotos.count == 3)
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
        try? await Task.sleep(for: .milliseconds(200))
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
