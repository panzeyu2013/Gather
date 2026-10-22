// desktop/native/gather-app/Tests/GatherAppTests/APIPhotoTests.swift
// Cut 1 / B2：LivePhotoAPI / LiveAssetAPI / LiveAlbumAPI / LiveNavigationAPI
// 以及 LivePhotoPathPolicy 的行为测试。
//
// 覆盖：
// - PhotoAPI 的 7 个方法（分页/全局查询/建议/尺寸/缩略图优先/批量预加载）；
// - 路径授权的两条路径（单路径 PHOTO_NOT_FOUND、批量过滤未登记项）；
// - AssetAPI 的候选/卷读取与三个确认型写入口的错误收敛；
// - AlbumAPI 的 CRUD + 分页查询 + 参数校验；
// - NavigationAPI 的列表/默认参数/NAV_* 错误映射。
// 全部使用内存 SQLite + 临时目录，不触碰用户数据；破坏性入口一律显式
// Confirmed<T>（D-011）。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost
import GatherTestSupport

private struct PhotoAPIFixture {
    let db: DBConnection
    let photoRepo: PhotoRepo
    let sessionRepo: SessionRepo
    let settingsService: SettingsService
    let jobService: JobService
    let photoAPI: LivePhotoAPI
    let assetAPI: LiveAssetAPI
    let albumAPI: LiveAlbumAPI
    let navigationAPI: LiveNavigationAPI

    init() throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let faceRepo = FaceRepo(connection: db)
        let personRepo = PersonRepo(connection: db)
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        let assetRepo = AssetRepo(connection: db)
        let filterEngine = FilterEngine(connection: db)
        let faceKwService = FaceKwService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            faceRepo: faceRepo,
            personRepo: personRepo,
            connection: db
        )
        let jobAPI = LiveJobAPI(jobService: jobService)

        self.db = db
        self.photoRepo = photoRepo
        self.sessionRepo = sessionRepo
        self.settingsService = settingsService
        self.jobService = jobService
        self.photoAPI = LivePhotoAPI(
            photoRepo: photoRepo,
            assetRepo: assetRepo,
            faceKwService: faceKwService,
            filterEngine: filterEngine,
            imagePreloadService: ImagePreloadService(),
            settingsService: settingsService,
            jobAPI: jobAPI
        )
        self.assetAPI = LiveAssetAPI(assetRepo: assetRepo)
        self.albumAPI = LiveAlbumAPI(
            albumRepo: SmartAlbumRepo(connection: db),
            filterEngine: filterEngine
        )
        self.navigationAPI = LiveNavigationAPI(
            navigationService: NavigationService(connection: db)
        )
    }

    func makeSession(_ name: String = "B2") throws -> String {
        try sessionRepo.create(name: name, source: "test").id
    }

    @discardableResult
    func addPhotos(_ sessionId: String, _ paths: [String]) throws -> Int {
        try photoRepo.addPhotos(
            sessionId: sessionId,
            filepaths: paths.map { PhotoAddInput(filepath: $0, width: 10, height: 20) },
            "test"
        ).added
    }
}

private func makeTempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gather-b2-api-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 1x1 PNG：用于让 RAWDecoder.getDimensions 走真实 ImageIO 路径。
private let onePixelPNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
)!

private func makePNG(in directory: URL, name: String = "pixel.png") throws -> String {
    let url = directory.appendingPathComponent(name)
    try onePixelPNG.write(to: url)
    return url.path
}

private func gatherError<T>(_ body: () async throws -> T) async -> GatherError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

@Suite("B2 Live API")
struct APIPhotoTests {
    // MARK: - Photo

    @Test("photo.page：键集分页 + PhotoData 形状")
    func photoPageAssemblesRows() async throws {
        let fixture = try PhotoAPIFixture()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionId = try fixture.makeSession()
        let first = try makePNG(in: directory, name: "a.png")
        let second = try makePNG(in: directory, name: "b.png")
        #expect(try fixture.addPhotos(sessionId, [first, second]) == 2)

        let page = try await fixture.photoAPI.page(
            try PhotoPageQuery(sessionId: sessionId, limit: 1)
        )
        #expect(page.rows.count == 1)
        #expect(page.rows[0].sessionId == sessionId)
        #expect(page.rows[0].variantCount == 1)
        #expect(page.rows[0].variants?.count == 1)
        #expect(page.cursor != nil)

        let next = try await fixture.photoAPI.page(
            try PhotoPageQuery(sessionId: sessionId, limit: 1, afterFirstRowid: page.cursor)
        )
        #expect(next.rows.count == 1)
        #expect(next.rows[0].id != page.rows[0].id)

        let empty = try await fixture.photoAPI.page(
            try PhotoPageQuery(sessionId: sessionId, limit: 1, afterFirstRowid: next.cursor)
        )
        #expect(empty.rows.isEmpty)
        #expect(empty.cursor == nil)
    }

    @Test("photo.search / suggestions：全局投影与 total")
    func photoSearchAndSuggestions() async throws {
        let fixture = try PhotoAPIFixture()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionId = try fixture.makeSession()
        let a = try makePNG(in: directory, name: "a.png")
        let b = try makePNG(in: directory, name: "b.png")
        try fixture.addPhotos(sessionId, [a, b])

        let criteria = FilterGroup(logic: .and, conditions: [])
        let global = try await fixture.photoAPI.search(
            try PhotoQuery(criteria: criteria, limit: 10)
        )
        #expect(global.photos.count == 2)
        #expect(global.total == 2)

        let scoped = try await fixture.photoAPI.search(
            try PhotoQuery(criteria: criteria, sessionId: sessionId, limit: 10)
        )
        #expect(scoped.photos.count == 2)
        #expect(scoped.total == 2)

        let suggestions = try await fixture.photoAPI.suggestions(
            try PhotoSuggestionQuery(sessionId: sessionId, keyword: "Ca")
        )
        // 空库时 FilterEngine 仍返回固定字段（values 为空），与旧 filter.suggest 一致。
        #expect(suggestions.flatMap(\.values).isEmpty)

        let blankSession = await gatherError {
            _ = try await fixture.photoAPI.search(
                PhotoQuery(criteria: criteria, sessionId: "  ")
            )
        }
        #expect(blankSession?.code == .INVALID_PARAM)
        #expect(blankSession?.params["field"] == "sessionId")
    }

    @Test("photo 路径授权：未登记路径 PHOTO_NOT_FOUND / 批量过滤")
    func photoPathAuthorization() async throws {
        let fixture = try PhotoAPIFixture()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionId = try fixture.makeSession()
        let known = try makePNG(in: directory, name: "known.png")
        let unknown = try makePNG(in: directory, name: "not-in-db.png")
        try fixture.addPhotos(sessionId, [known])

        let dimensions = try await fixture.photoAPI.dimensions(
            try PhotoDimensionsInput(paths: [known])
        )
        #expect(dimensions[known]?.width == 1)
        #expect(dimensions[known]?.height == 1)

        let unknownDimensions = await gatherError {
            _ = try await fixture.photoAPI.dimensions(
                try PhotoDimensionsInput(paths: [unknown])
            )
        }
        #expect(unknownDimensions?.code == .PHOTO_NOT_FOUND)

        let unknownPrioritize = await gatherError {
            try await fixture.photoAPI.prioritizeThumbnail(
                try ThumbnailPrioritizeInput(path: unknown, size: 256)
            )
        }
        #expect(unknownPrioritize?.code == .PHOTO_NOT_FOUND)

        // 批量预加载只接受已登记路径；全部未登记 => 不建 job、直接返回 nil。
        let none = try await fixture.photoAPI.preloadThumbnails(
            try ThumbnailPreloadInput(paths: [unknown], size: 256)
        )
        #expect(none == nil)
        #expect(try fixture.jobService.list(includeCheckpoint: false).isEmpty)

        let handle = try await fixture.photoAPI.preloadThumbnails(
            try ThumbnailPreloadInput(paths: [known, unknown], size: 256)
        )
        let created = try #require(handle)
        #expect(try fixture.jobService.list(includeCheckpoint: false).contains { $0.id == created.id })

        // 预览预加载同样是 best-effort：未登记路径不会触碰文件系统。
        try await fixture.photoAPI.preloadPreviews(
            try PreviewPreloadInput(paths: [unknown], maxDimension: 512)
        )
    }

    // MARK: - Album

    @Test("album：create / list / photos / update / delete")
    func albumCRUDAndPhotos() async throws {
        let fixture = try PhotoAPIFixture()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionId = try fixture.makeSession()
        let a = try makePNG(in: directory, name: "a.png")
        let b = try makePNG(in: directory, name: "b.png")
        try fixture.addPhotos(sessionId, [a, b])

        // 空条件 = 全部照片；rating 走 photo_metadata_cache，测试夹具未写缓存行，
        // 用空条件验证 detail.photoCount 与分页 total 的同一计数路径。
        let criteria = FilterGroup(logic: .and, conditions: [])
        let created = try await fixture.albumAPI.create(
            AlbumCreateParams(name: "  测试相册  ", criteria: criteria)
        )
        #expect(created.name == "测试相册")
        #expect(created.photoCount == 2)

        let albums = try await fixture.albumAPI.list()
        #expect(albums.map(\.id) == [created.id])

        let page = try await fixture.albumAPI.photos(
            try AlbumPhotosQuery(albumId: created.id, limit: 10, offset: 0)
        )
        #expect(page.photos.count == 2)
        #expect(page.total == 2)

        try await fixture.albumAPI.update(AlbumUpdateParams(
            albumId: created.id,
            name: "改名",
            criteria: FilterGroup(logic: .and, conditions: [])
        ))
        let updated = try await fixture.albumAPI.list()
        #expect(updated.first?.name == "改名")

        try await fixture.albumAPI.delete(
            Confirmed(try AlbumDeleteInput(albumId: created.id))
        )
        #expect(try await fixture.albumAPI.list().isEmpty)
    }

    @Test("album：参数错误与 ALBUM_NOT_FOUND")
    func albumErrors() async throws {
        let fixture = try PhotoAPIFixture()
        let criteria = FilterGroup(logic: .and, conditions: [])

        let blankName = await gatherError {
            _ = try await fixture.albumAPI.create(AlbumCreateParams(name: "  ", criteria: criteria))
        }
        #expect(blankName?.code == .INVALID_PARAM)
        #expect(blankName?.params["field"] == "name")

        let missing = await gatherError {
            _ = try await fixture.albumAPI.photos(
                try AlbumPhotosQuery(albumId: "missing", limit: 10)
            )
        }
        #expect(missing?.code == .ALBUM_NOT_FOUND)
    }

    // MARK: - Asset

    @Test("assets：空读路径 + 确认型写入口的错误收敛")
    func assetAPIConfirmationsAndErrors() async throws {
        let fixture = try PhotoAPIFixture()
        #expect(try await fixture.assetAPI.candidates(AssetCandidatesQuery()).isEmpty)
        #expect(try await fixture.assetAPI.volumes().isEmpty)

        let missingAccept = await gatherError {
            _ = try await fixture.assetAPI.accept(
                Confirmed(try AssetCandidateReference(candidateId: "missing"))
            )
        }
        #expect(missingAccept?.code == .ASSET_LINK_CANDIDATE_NOT_FOUND)

        let missingReject = await gatherError {
            _ = try await fixture.assetAPI.reject(
                Confirmed(try AssetCandidateReference(candidateId: "missing"))
            )
        }
        #expect(missingReject?.code == .ASSET_LINK_CANDIDATE_NOT_FOUND)

        do {
            _ = try AssetCandidateReference(candidateId: "  ")
            Issue.record("空白 candidateId 必须抛错")
        } catch let error as GatherError {
            #expect(error.code == .INVALID_PARAM)
            #expect(error.params["field"] == "candidateId")
        }

        let sameRoot = await gatherError {
            _ = try await fixture.assetAPI.relinkRoot(
                Confirmed(try AssetRelinkInput(oldRoot: "/tmp/a", newRoot: "/tmp/a"))
            )
        }
        #expect(sameRoot?.code == .ASSET_RELINK_SAME_ROOT)
    }

    // MARK: - 调用方错误漏斗

    @Test("迁移调用方：GatherError 必须走 API 码值漏斗")
    @MainActor
    func gatherErrorPresentation() {
        let expected = L10n(language: .zhCN).errorText("ALBUM_NOT_FOUND")
        let error = GatherError(code: .ALBUM_NOT_FOUND)
        // Cut 4 / 4a-3b-2b：VM 不再有文案漏斗，统一 CommandError + 渲染期解析。
        let l10n = L10n(language: .zhCN)
        #expect(CommandErrorText.resolve(CommandError(error), with: l10n) == expected)
        #expect(CommandError(error).code == "ALBUM_NOT_FOUND")
    }

    // MARK: - Navigation

    @Test("navigation：list / analyze 默认值 / NAV_* 错误映射")
    func navigationDefaultsAndErrors() async throws {
        let fixture = try PhotoAPIFixture()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionId = try fixture.makeSession()
        try fixture.addPhotos(sessionId, [try makePNG(in: directory)])

        #expect(try await fixture.navigationAPI.list(sessionId).isEmpty)

        // 空库/无拍摄时间：analyze 返回空组，但仍校验 burst/scene 范围。
        #expect(try await fixture.navigationAPI.analyze(
            NavigationAnalyzeParams(sessionId: sessionId, dryRun: true)
        ).isEmpty)

        let burstGap = await gatherError {
            _ = try await fixture.navigationAPI.analyze(
                NavigationAnalyzeParams(sessionId: sessionId, burstGapSeconds: 0)
            )
        }
        #expect(burstGap?.code == .NAV_BURST_GAP_INVALID)

        let missingGroup = await gatherError {
            _ = try await fixture.navigationAPI.split(
                NavigationSplitParams(
                    sessionId: sessionId,
                    groupId: "missing",
                    beforePhotoId: "missing"
                )
            )
        }
        #expect(missingGroup?.code == .NAV_GROUP_NOT_FOUND)

        let mergeMinTwo = await gatherError {
            _ = try await fixture.navigationAPI.merge(
                NavigationMergeParams(sessionId: sessionId, groupIds: ["g1"])
            )
        }
        #expect(mergeMinTwo?.code == .NAV_MERGE_MIN_TWO)

        let blankSession = await gatherError {
            _ = try await fixture.navigationAPI.list("  ")
        }
        #expect(blankSession?.code == .INVALID_PARAM)
        #expect(blankSession?.params["field"] == "sessionId")
    }
}
