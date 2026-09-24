// Tests/GatherCoreTests/API/AlbumCommandsImplTests.swift
// R5：album 域命令实现直测（批次 B6）。
// 覆盖旧分支语义：create 的 name 校验 / criteria 校验与详情装配（photoCount）、
// list 的损坏行保留（validationError）、get 的 ALBUM_NOT_FOUND、update 的按字段
// 更新与 criteria 校验、delete 的 confirmed 门控、get_photos 的 limit/offset 钳制
// 与全局 total。
import Foundation
import Testing
@testable import GatherCore

// MARK: - 基座

private struct AlbumCommandsHarness {
    let impl: AlbumCommandsImpl
    let db: SQLiteDatabase
    let storePath: String

    func cleanup() { removeStoreFiles(storePath) }
}

/// 种子：1 会话 + 3 照片 + 元数据（rating 5 / 3 / 0）。
private func makeAlbumHarness() async throws -> AlbumCommandsHarness {
    let storePath = storeTempPath("album-commands")
    let db = try await makeMigratedStore(path: storePath)
    let now = "2026-07-30T10:00:00.000Z"
    try await db.run("""
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status,
          import_source, source_path, photo_count, failed_writeback_count, created_at, updated_at)
        VALUES ('s1', 'Albums', 'photos_loaded', 'idle', 'idle',
          'folder', '/photos', 3, 0, ?, ?)
        """, [.text(now), .text(now)])
    let photos: [(id: String, filepath: String, filename: String, dateTaken: String, rating: Int)] = [
        ("p1", "/photos/IMG_0001.JPG", "IMG_0001.JPG", "2026-07-30T10:00:00.000Z", 5),
        ("p2", "/photos/IMG_0002.JPG", "IMG_0002.JPG", "2026-07-30T10:00:01.000Z", 3),
        ("p3", "/photos/sub/IMG_0003.JPG", "IMG_0003.JPG", "2026-07-30T10:00:20.000Z", 0),
    ]
    for photo in photos {
        try await db.run("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
              metadata, result, width, height, created_at, updated_at)
            VALUES (?, 's1', ?, ?, '', 'ready', '{}', '{}', 100, 80, ?, ?)
            """, [.text(photo.id), .text(photo.filepath), .text(photo.filename), .text(now), .text(now)])
        try await db.run("""
            INSERT INTO photo_metadata_cache (photo_id, session_id, date_taken, rating,
              keywords, cached_at, updated_at)
            VALUES (?, 's1', ?, ?, '[]', ?, ?)
            """, [
                .text(photo.id), .text(photo.dateTaken), .int(Int64(photo.rating)),
                .text(now), .text(now),
            ])
    }
    let albums = AlbumsAPI(store: SQLiteSmartAlbumStore(database: db))
    return AlbumCommandsHarness(
        impl: AlbumCommandsImpl(albums: albums, engine: FilterEngine(database: db)),
        db: db,
        storePath: storePath
    )
}

/// 单规则组。
private func group(_ rule: FilterRule) -> FilterGroup {
    FilterGroup(logic: .and, conditions: [.rule(rule)])
}

private func rule(_ field: String, _ operator: FilterOperator, _ value: JSONValue) -> FilterRule {
    FilterRule(field: field, operator: `operator`, value: value)
}

/// 落库 criteria 串（与 SQLiteSmartAlbumStore 同款编码）。
private func criteriaJSON(_ group: FilterGroup) throws -> String {
    String(decoding: try JSONEncoder().encode(group), as: UTF8.self)
}

private func insertRawAlbum(
    _ db: SQLiteDatabase,
    id: String,
    name: String,
    filterCriteria: String,
    sortBy: String = "date_taken",
    sortOrder: String = "desc",
    icon: String = "folder",
    updatedAt: String = "2026-07-30T10:00:00.000Z"
) async throws {
    try await db.run("""
        INSERT INTO smart_albums
          (id, schema_version, name, description, filter_criteria, sort_by, sort_order,
           icon, created_at, updated_at)
        VALUES (?, 1, ?, '', ?, ?, ?, ?, '2026-07-30T09:00:00.000Z', ?)
        """, [
            .text(id), .text(name), .text(filterCriteria), .text(sortBy),
            .text(sortOrder), .text(icon), .text(updatedAt),
        ])
}

private func insertAlbum(
    _ db: SQLiteDatabase,
    id: String,
    name: String,
    criteria: FilterGroup,
    sortBy: String = "date_taken",
    sortOrder: String = "desc",
    icon: String = "folder",
    updatedAt: String = "2026-07-30T10:00:00.000Z"
) async throws {
    try await insertRawAlbum(
        db, id: id, name: name, filterCriteria: try criteriaJSON(criteria),
        sortBy: sortBy, sortOrder: sortOrder, icon: icon, updatedAt: updatedAt)
}

// MARK: - 用例

@Suite("API/AlbumCommandsImpl (R5)")
struct AlbumCommandsImplTests {
    @Test("create trims the name, validates criteria and returns the detail")
    func createReturnsDetail() async throws {
        let harness = try await makeAlbumHarness()
        defer { harness.cleanup() }
        let criteria = group(rule("rating", .gte, .number(3)))

        let detail = try await harness.impl.create(
            name: "  Travel  ", description: "trip", criteria: criteria,
            sortBy: "date_taken", sortOrder: "asc", icon: "star")

        #expect(detail.name == "Travel")
        #expect(detail.description == "trip")
        #expect(detail.filterCriteria == criteria)
        #expect(detail.sortBy == "date_taken")
        #expect(detail.sortOrder == "asc")
        #expect(detail.icon == "star")
        #expect(detail.photoCount == 2)
        #expect(detail.validationError == nil)
        #expect(try await harness.db.scalarInt("SELECT COUNT(*) FROM smart_albums") == 1)
    }

    @Test("create applies the store defaults for omitted optional fields")
    func createUsesDefaults() async throws {
        let harness = try await makeAlbumHarness()
        defer { harness.cleanup() }

        let detail = try await harness.impl.create(
            name: "Recent", description: nil,
            criteria: group(rule("rating", .gte, .number(0))),
            sortBy: nil, sortOrder: nil, icon: nil)

        #expect(detail.description == "")
        #expect(detail.sortBy == "date_taken")
        #expect(detail.sortOrder == "desc")
        #expect(detail.icon == "📁")
        #expect(detail.photoCount == 3)
    }

    @Test("create rejects an invalid name and an unknown criteria field")
    func createValidatesInput() async throws {
        let harness = try await makeAlbumHarness()
        defer { harness.cleanup() }
        let criteria = group(rule("rating", .gte, .number(3)))

        await #expect(throws: AlbumCommandsError.invalidParam("name")) {
            _ = try await harness.impl.create(
                name: "   ", description: nil, criteria: criteria,
                sortBy: nil, sortOrder: nil, icon: nil)
        }
        await #expect(throws: AlbumCommandsError.invalidParam("name")) {
            _ = try await harness.impl.create(
                name: String(repeating: "n", count: 4097), description: nil, criteria: criteria,
                sortBy: nil, sortOrder: nil, icon: nil)
        }
        do {
            _ = try await harness.impl.create(
                name: "Bad", description: nil,
                criteria: group(rule("nope", .eq, .string("x"))),
                sortBy: nil, sortOrder: nil, icon: nil)
            Issue.record("未知字段应抛 FILTER_FIELD_UNKNOWN")
        } catch let error as FilterEngineError {
            #expect(error.description == "FILTER_FIELD_UNKNOWN")
        }
        #expect(try await harness.db.scalarInt("SELECT COUNT(*) FROM smart_albums") == 0)
    }

    @Test("list keeps corrupt rows with validationError and orders by updated_at")
    func listKeepsCorruptRows() async throws {
        let harness = try await makeAlbumHarness()
        defer { harness.cleanup() }
        let ok = group(rule("rating", .gte, .number(3)))
        try await insertAlbum(
            harness.db, id: "a1", name: "Good", criteria: ok,
            updatedAt: "2026-07-30T10:00:02.000Z")
        try await insertRawAlbum(
            harness.db, id: "a2", name: "Broken", filterCriteria: "not-json",
            updatedAt: "2026-07-30T10:00:01.000Z")
        try await insertRawAlbum(
            harness.db, id: "a3", name: "Unknown",
            filterCriteria: try criteriaJSON(group(rule("nope", .eq, .string("x")))),
            updatedAt: "2026-07-30T10:00:00.000Z")

        let rows = try await harness.impl.list()

        #expect(rows.map(\.id) == ["a1", "a2", "a3"])
        #expect(rows[0].validationError == nil)
        #expect(rows[0].filterCriteria == ok)
        #expect(rows[1].validationError == "INVALID_PARAMS")
        #expect(rows[1].filterCriteria == FilterGroup(logic: .and, conditions: []))
        #expect(rows[2].validationError == "FILTER_FIELD_UNKNOWN::nope")
    }

    @Test("get returns the detail and ALBUM_NOT_FOUND for a missing album")
    func getReturnsDetailOrNotFound() async throws {
        let harness = try await makeAlbumHarness()
        defer { harness.cleanup() }
        try await insertAlbum(
            harness.db, id: "a1", name: "Good",
            criteria: group(rule("rating", .gte, .number(3))))

        let detail = try await harness.impl.get(albumId: "a1")
        #expect(detail.name == "Good")
        #expect(detail.photoCount == 2)
        #expect(detail.validationError == nil)

        do {
            _ = try await harness.impl.get(albumId: "missing")
            Issue.record("缺失相册应抛 ALBUM_NOT_FOUND")
        } catch let error as AlbumCommandsError {
            #expect(error == .notFound)
            #expect(error.description == "ALBUM_NOT_FOUND")
            #expect(error.gatherCode == .ALBUM_NOT_FOUND)
        }
    }

    @Test("update writes only provided fields and rejects invalid criteria")
    func updateWritesFields() async throws {
        let harness = try await makeAlbumHarness()
        defer { harness.cleanup() }
        let initial = group(rule("rating", .gte, .number(3)))
        try await insertAlbum(harness.db, id: "a1", name: "Before", criteria: initial, icon: "old")
        let next = group(rule("rating", .gte, .number(5)))

        try await harness.impl.update(
            albumId: "a1", name: " After ", description: "d", criteria: next,
            sortBy: "filename", sortOrder: nil, icon: "new")

        let detail = try await harness.impl.get(albumId: "a1")
        #expect(detail.name == " After ", "update 不做 trim（旧分支 optionalString 语义）")
        #expect(detail.description == "d")
        #expect(detail.filterCriteria == next)
        #expect(detail.sortBy == "filename")
        #expect(detail.sortOrder == "desc", "未传入的 sortOrder 保持不变")
        #expect(detail.icon == "new")
        #expect(detail.photoCount == 1, "rating >= 5 只有 p1")

        do {
            try await harness.impl.update(
                albumId: "a1", name: "Nope", description: nil,
                criteria: group(rule("nope", .eq, .string("x"))),
                sortBy: nil, sortOrder: nil, icon: nil)
            Issue.record("未知字段应抛 FILTER_FIELD_UNKNOWN")
        } catch let error as FilterEngineError {
            #expect(error.description == "FILTER_FIELD_UNKNOWN")
        }
        let unchanged = try await harness.impl.get(albumId: "a1")
        #expect(unchanged.name == " After ", "校验失败不得落库")
    }

    @Test("delete requires confirmation and removes the row when confirmed")
    func deleteGate() async throws {
        let harness = try await makeAlbumHarness()
        defer { harness.cleanup() }
        try await insertAlbum(
            harness.db, id: "a1", name: "Doomed",
            criteria: group(rule("rating", .gte, .number(3))))

        do {
            try await harness.impl.delete(albumId: "a1", confirmed: false)
            Issue.record("confirmed=false 应抛门控消息")
        } catch let error as AlbumCommandsError {
            #expect(error == .deleteConfirmRequired)
            #expect(error.description == "album.delete requires confirmation")
            #expect(error.gatherCode == nil)
        }
        #expect(try await harness.db.scalarInt("SELECT COUNT(*) FROM smart_albums WHERE id = 'a1'") == 1)

        try await harness.impl.delete(albumId: "a1", confirmed: true)
        #expect(try await harness.db.scalarInt("SELECT COUNT(*) FROM smart_albums WHERE id = 'a1'") == 0)
    }

    @Test("getPhotos filters by the stored criteria with clamping and total")
    func getPhotosFiltersAndClamps() async throws {
        let harness = try await makeAlbumHarness()
        defer { harness.cleanup() }
        try await insertAlbum(
            harness.db, id: "a1", name: "Rated",
            criteria: group(rule("rating", .gte, .number(3))))

        let all = try await harness.impl.getPhotos(albumId: "a1", limit: nil, offset: nil)
        #expect(all.photos.map(\.photoId) == ["p2", "p1"], "date_taken 降序")
        #expect(all.total == 2)
        #expect(all.photos[0].sessionName == "Albums")

        let clamped = try await harness.impl.getPhotos(albumId: "a1", limit: 0, offset: -5)
        #expect(clamped.photos.count == 1, "limit 0 → 1；offset -5 → 0")
        #expect(clamped.total == 2)

        let page = try await harness.impl.getPhotos(albumId: "a1", limit: 1, offset: 1)
        #expect(page.photos.map(\.photoId) == ["p1"])
    }

    @Test("getPhotos propagates ALBUM_NOT_FOUND and criteria errors")
    func getPhotosErrors() async throws {
        let harness = try await makeAlbumHarness()
        defer { harness.cleanup() }

        do {
            _ = try await harness.impl.getPhotos(albumId: "missing", limit: nil, offset: nil)
            Issue.record("缺失相册应抛 ALBUM_NOT_FOUND")
        } catch let error as AlbumCommandsError {
            #expect(error == .notFound)
        }

        try await insertRawAlbum(
            harness.db, id: "a2", name: "Unknown",
            filterCriteria: try criteriaJSON(group(rule("nope", .eq, .string("x")))))
        do {
            _ = try await harness.impl.getPhotos(albumId: "a2", limit: nil, offset: nil)
            Issue.record("未知字段应抛 FILTER_FIELD_UNKNOWN")
        } catch let error as FilterEngineError {
            #expect(error.description == "FILTER_FIELD_UNKNOWN")
        }
    }
}
