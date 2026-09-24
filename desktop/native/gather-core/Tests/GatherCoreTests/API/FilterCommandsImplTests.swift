// Tests/GatherCoreTests/API/FilterCommandsImplTests.swift
// R5：filter 域命令实现直测（批次 B5）。
// 覆盖旧路由分支语义：photos 的行投影（metadata/result JSON 字符串 → 对象、
// 非法 JSON 回退空对象）与 limit/offset 钳制、未知字段错误透传、photos_global
// 的 {photos,total} 投影与缺省 limit、suggest 的 <2 字符短路。
import Foundation
import Testing
@testable import GatherCore

// MARK: - 基座

private struct FilterCommandsHarness {
    let impl: FilterCommandsImpl
    let db: SQLiteDatabase
    let storePath: String

    func cleanup() { removeStoreFiles(storePath) }
}

/// TS: 种子 session + 3 照片 + 元数据（与 FilterEngine 直测同款口径）。
private func makeHarness() async throws -> FilterCommandsHarness {
    let storePath = storeTempPath("filter-commands")
    let db = try await makeMigratedStore(path: storePath)
    let now = "2026-07-30T10:00:00.000Z"
    _ = try await db.run("""
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status,
          import_source, source_path, photo_count, failed_writeback_count, created_at, updated_at)
        VALUES ('s1', 'Filter', 'photos_loaded', 'idle', 'idle',
          'folder', '/photos', 3, 0, ?, ?)
        """, [.text(now), .text(now)])
    let photos: [(String, String, String, String, String, String, String)] = [
        ("p1", "/photos/IMG_0001.JPG", "IMG_0001.JPG", "abc", "pending", #"{"camera":"X"}"#, #"{"flag":true}"#),
        ("p2", "/photos/IMG_0002.JPG", "IMG_0002.JPG", "def", "ready", "not-json", ""),
        ("p3", "/photos/sub/IMG_0003.JPG", "IMG_0003.JPG", "ghi", "missing", "{}", "{}"),
    ]
    for (id, filepath, filename, checksum, status, metadata, result) in photos {
        _ = try await db.run("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
              metadata, result, width, height, created_at, updated_at)
            VALUES (?, 's1', ?, ?, ?, ?, ?, ?, 100, 80, ?, ?)
            """, [
                .text(id), .text(filepath), .text(filename), .text(checksum), .text(status),
                .text(metadata), .text(result), .text(now), .text(now),
            ])
    }
    let metadata: [(String, String, String, String, Int, String)] = [
        ("p1", "2026-07-30T10:00:00.000Z", "Canon", "Canon EOS R5", 5, #"["travel","bw"]"#),
        ("p2", "2026-07-30T10:00:01.000Z", "Nikon", "Nikon Z6", 3, #"["travel"]"#),
        ("p3", "2026-07-30T10:00:20.000Z", "Canon", "Canon EOS R5", 0, #"[]"#),
    ]
    for (id, dateTaken, make, model, rating, keywords) in metadata {
        _ = try await db.run("""
            INSERT INTO photo_metadata_cache (photo_id, session_id, date_taken,
              camera_make, camera_model, rating, keywords, cached_at, updated_at)
            VALUES (?, 's1', ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(id), .text(dateTaken), .text(make), .text(model),
                .int(Int64(rating)), .text(keywords), .text(now), .text(now),
            ])
    }
    return FilterCommandsHarness(
        impl: FilterCommandsImpl(engine: FilterEngine(database: db)),
        db: db,
        storePath: storePath
    )
}

/// 构造单规则组。
private func group(_ rule: FilterRule) -> FilterGroup {
    FilterGroup(logic: .and, conditions: [.rule(rule)])
}

private func rule(_ field: String, _ operator: FilterOperator, _ value: JSONValue) -> FilterRule {
    FilterRule(field: field, operator: `operator`, value: value)
}

// MARK: - 用例

@Suite("API/FilterCommandsImpl (R5)")
struct FilterCommandsImplTests {
    @Test("photos projects rows and parses metadata/result JSON")
    func photosProjectsRows() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let criteria = group(rule("rating", .gte, .number(3)))

        let photos = try await harness.impl.photos(
            FilterPhotosParams(sessionId: "s1", criteria: criteria), limit: 100, offset: 0)

        #expect(photos.map(\.id) == ["p1", "p2"])
        #expect(photos[0].metadata["camera"] == .string("X"))
        #expect(photos[0].result["flag"] == .bool(true))
        #expect(photos[0].checksum == "abc")
        #expect(photos[0].hasExistingXmp == false)
        #expect(photos[0].width == 0)
        #expect(photos[0].height == 0)
        #expect(photos[1].metadata.isEmpty, "非法 JSON 回退空对象")
        #expect(photos[1].result.isEmpty)
    }

    @Test("photos clamps limit to 1...500 and offset to >= 0")
    func photosClampsLimitAndOffset() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let criteria = group(rule("rating", .gte, .number(3)))

        let clamped = try await harness.impl.photos(
            FilterPhotosParams(sessionId: "s1", criteria: criteria), limit: 0, offset: -5)
        #expect(clamped.count == 1, "limit 0 → 1；offset -5 → 0")

        let capped = try await harness.impl.photos(
            FilterPhotosParams(sessionId: "s1", criteria: criteria), limit: 9_999, offset: 0)
        #expect(capped.count == 2, "上限 500 对当前数据无截断")
    }

    @Test("photos propagates FILTER_FIELD_UNKNOWN")
    func photosPropagatesUnknownField() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let criteria = group(rule("nope", .eq, .string("x")))

        do {
            _ = try await harness.impl.photos(
                FilterPhotosParams(sessionId: "s1", criteria: criteria), limit: 100, offset: 0)
            Issue.record("未知字段应抛 FILTER_FIELD_UNKNOWN")
        } catch let error as FilterEngineError {
            #expect(error.description == "FILTER_FIELD_UNKNOWN")
        }
    }

    @Test("photosGlobal returns photos and total with the default limit")
    func photosGlobalReturnsPhotosAndTotal() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let criteria = group(rule("rating", .gte, .number(3)))

        let result = try await harness.impl.photosGlobal(
            FilterPhotosGlobalParams(criteria: criteria))

        #expect(result.total == 2)
        #expect(result.photos.map(\.photoId) == ["p1", "p2"])
        #expect(result.photos[0].rating == 5)
        #expect(result.photos[0].keywords == ["travel", "bw"])
        #expect(result.photos[0].sessionName == "Filter")
    }

    @Test("suggest short-circuits below two characters")
    func suggestShortCircuits() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }

        let suggestions = try await harness.impl.suggest(
            FilterSuggestParams(sessionId: "s1", keyword: "Ca"))
        #expect(suggestions == [FilterSuggestion(field: "camera_make", values: ["Canon"])])

        let empty = try await harness.impl.suggest(
            FilterSuggestParams(sessionId: "s1", keyword: "C"))
        #expect(empty.isEmpty)
    }
}
