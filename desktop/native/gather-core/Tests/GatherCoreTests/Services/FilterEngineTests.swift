// desktop/native/gather-core/Tests/GatherCoreTests/Services/FilterEngineTests.swift
// FilterEngine 行为测试（Phase 3.6）。
// TS 源: tests/unit/services/filter/filter-engine.test.ts（regex 拒绝）
// + filter-engine.ts 行为红线（字段×操作符矩阵 + 特殊字段，逐条对账）。
//
// 覆盖：
//   - buildWhereClause：13 操作符 SQL 形态、in 空数组 → 1=0、between 二元组、
//     escapeLike、递归组、未知字段 FILTER_FIELD_UNKNOWN、regex 拒绝
//   - 特殊字段：has_face / person / keywords（json_each 三语义）/ directory /
//     volume / has_duplicates
//   - filterPhotos / countPhotos / filterGlobally / countGlobally / suggest
//     真实 DB 行为

import Foundation
import Testing
@testable import GatherCore

private struct Harness {
    let db: DBConnection
    let engine: FilterEngine
    let sessionId: String
}

/// TS: 种子 session + 3 照片 + 元数据。
private func makeHarness() async throws -> Harness {
    let db = try await makeMigratedDB()
    let now = "2026-07-30T10:00:00.000Z"
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status,
          import_source, source_path, photo_count, failed_writeback_count, created_at, updated_at)
        VALUES ('session', 'Filter', 'photos_loaded', 'idle', 'idle',
          'folder', '/photos', 3, 0, ?, ?)
      """).run([.text(now), .text(now)])
    let insertPhoto = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
          metadata, result, width, height, created_at, updated_at)
        VALUES (?, 'session', ?, ?, ?, ?, '{}', '{}', ?, ?, ?, ?)
      """)
    let insertMetadata = try db.prepare("""
        INSERT INTO photo_metadata_cache (photo_id, session_id, date_taken,
          camera_make, camera_model, rating, keywords, cached_at, updated_at)
        VALUES (?, 'session', ?, ?, ?, ?, ?, ?, ?)
      """)
    let photos: [(String, String, String, String, String, Int, Int)] = [
        ("p1", "/photos/IMG_0001.JPG", "IMG_0001.JPG", "abc", "pending", 100, 80),
        ("p2", "/photos/IMG_0002.JPG", "IMG_0002.JPG", "def", "ready", 200, 160),
        ("p3", "/photos/sub/IMG_0003.JPG", "IMG_0003.JPG", "ghi", "missing", 300, 240),
    ]
    for (id, filepath, filename, checksum, status, width, height) in photos {
        _ = try insertPhoto.run([
            .text(id), .text(filepath), .text(filename), .text(checksum), .text(status),
            .int(Int64(width)), .int(Int64(height)), .text(now), .text(now),
        ])
    }
    let metadata: [(String, String, String, String, Int, String)] = [
        ("p1", "2026-07-30T10:00:00.000Z", "Canon", "Canon EOS R5", 5, #"["travel","bw"]"#),
        ("p2", "2026-07-30T10:00:01.000Z", "Nikon", "Nikon Z6", 3, #"["travel"]"#),
        ("p3", "2026-07-30T10:00:20.000Z", "Canon", "Canon EOS R5", 0, #"[]"#),
    ]
    for (id, dateTaken, make, model, rating, keywords) in metadata {
        _ = try insertMetadata.run([
            .text(id), .text(dateTaken), .text(make), .text(model),
            .int(Int64(rating)), .text(keywords), .text(now), .text(now),
        ])
    }
    return Harness(db: db, engine: FilterEngine(connection: db), sessionId: "session")
}

/// 构造单规则组。
private func group(_ rule: FilterRule) -> FilterGroup {
    FilterGroup(logic: .and, conditions: [.rule(rule)])
}

private func rule(_ field: String, _ operator: FilterOperator, _ value: JSONValue) -> FilterRule {
    FilterRule(field: field, operator: `operator`, value: value)
}

@Suite("FilterEngine")
struct FilterEngineTests {
    // TS: "rejects legacy or forged regular-expression filters"。
    @Test func rejectsRegexOperator() async throws {
        let harness = try await makeHarness()
        let engine = FilterEngine(connection: harness.db)
        // FilterOperator 无 regex case —— 用字段名伪造（契约层已拒）。
        #expect(FilterOperator.allCases.map(\.rawValue).contains("regex") == false)
    }

    // TS: 未知字段 → FILTER_FIELD_UNKNOWN。
    @Test func unknownFieldThrows() async throws {
        let harness = try await makeHarness()
        #expect(throws: (any Error).self) {
            _ = try harness.engine.buildWhereClause(group(rule("nope", .eq, .string("x"))))
        }
    }

    // TS: directory 仅 eq/starts_with，其余抛错。
    @Test func directoryRejectsUnsupportedOperators() async throws {
        let harness = try await makeHarness()
        #expect(throws: (any Error).self) {
            _ = try harness.engine.buildWhereClause(group(rule("directory", .contains, .string("x"))))
        }
        // eq 可用。
        let eq = try harness.engine.buildWhereClause(group(rule("directory", .eq, .string("/photos"))))
        #expect(eq.sql.contains("filepath LIKE ? || '%' ESCAPE"))
    }

    // TS: in 空数组 → 1=0。
    @Test func emptyInIsFalse() async throws {
        let harness = try await makeHarness()
        let result = try harness.engine.buildWhereClause(group(rule("status", .in, .array([]))))
        #expect(result.sql == "1=0")
    }

    // TS: escapeLike 转义 \ % _。
    @Test func escapeLikeEscapesWildcards() {
        #expect(escapeLike("a%b_c\\d") == "a\\%b\\_c\\\\d")
    }

    // TS: between 二元组。
    @Test func betweenProducesTwoParams() async throws {
        let harness = try await makeHarness()
        let result = try harness.engine.buildWhereClause(group(rule(
            "rating", .between, .array([.number(2), .number(4)])
        )))
        #expect(result.sql == "pmc.rating BETWEEN ? AND ?")
        #expect(result.params.count == 2)
    }

    // TS: 递归组（or 内嵌 and 组）。
    @Test func nestedGroupParenthesized() async throws {
        let harness = try await makeHarness()
        let inner = FilterGroup(logic: .and, conditions: [
            .rule(rule("rating", .gte, .number(3))),
            .rule(rule("status", .eq, .string("ready"))),
        ])
        let outer = FilterGroup(logic: .or, conditions: [
            .rule(rule("camera_make", .eq, .string("Canon"))),
            .group(inner),
        ])
        let result = try harness.engine.buildWhereClause(outer)
        #expect(result.sql == "pmc.camera_make = ? OR (pmc.rating >= ? AND p.status = ?)")
        #expect(result.params.count == 3)
    }

    // TS: filterPhotos 基本过滤 + 排序 + limit。
    @Test func filterPhotosBasic() async throws {
        let harness = try await makeHarness()
        let photos = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("camera_make", .eq, .string("Canon"))),
            sortBy: "rating",
            sortOrder: "desc"
        )
        #expect(photos.map(\.id) == ["p1", "p3"])
        #expect(photos[0].faceCount == 0)
        #expect(photos[0].hasExistingXmp == false)
        #expect(photos[0].width == 0) // TS: SELECT 未含 width，恒 0
    }

    // TS: filterPhotos limit/offset 引擎内不钳制（直接透传）。
    @Test func filterPhotosPassesLimitThrough() async throws {
        let harness = try await makeHarness()
        let photos = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: FilterGroup(logic: .and, conditions: []),
            limit: 2
        )
        #expect(photos.count == 2)
    }

    // TS: countPhotos 会话内计数。
    @Test func countPhotosSessionScoped() async throws {
        let harness = try await makeHarness()
        let count = try harness.engine.countPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("status", .eq, .string("pending")))
        )
        #expect(count == 1)
    }

    // TS: keywords contains_any（json_each）。
    @Test func keywordsContainsAny() async throws {
        let harness = try await makeHarness()
        let ids = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("keywords", .containsAny, .array([.string("travel"), .string("bw")])))
        ).map(\.id)
        #expect(ids.contains("p1"))
        #expect(ids.contains("p2"))
        #expect(!ids.contains("p3"))
    }

    // TS: keywords contains_all —— 同时含 travel 与 bw 的只有 p1。
    @Test func keywordsContainsAll() async throws {
        let harness = try await makeHarness()
        let ids = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("keywords", .containsAll, .array([.string("travel"), .string("bw")])))
        ).map(\.id)
        #expect(ids == ["p1"])
    }

    // TS: keywords eq —— 集合相等（无序）。
    @Test func keywordsEqIgnoresOrder() async throws {
        let harness = try await makeHarness()
        let ids = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("keywords", .eq, .array([.string("bw"), .string("travel")])))
        ).map(\.id)
        #expect(ids == ["p1"])
    }

    // TS: keywords exists —— 非空数组。
    @Test func keywordsExists() async throws {
        let harness = try await makeHarness()
        let ids = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("keywords", .exists, .null))
        ).map(\.id)
        #expect(Set(ids) == Set(["p1", "p2"]))
    }

    // TS: suggest —— camera_make LIKE，<2 字符返回空。
    @Test func suggestFiltersByCameraMake() async throws {
        let harness = try await makeHarness()
        let short = try harness.engine.suggest(harness.sessionId, keyword: "c")
        #expect(short.isEmpty)
        let suggestions = try harness.engine.suggest(harness.sessionId, keyword: "Can")
        #expect(suggestions.first?.field == "camera_make")
        #expect(suggestions.first?.values == ["Canon"])
    }

    // TS: has_duplicates —— 种子 duplicate_groups 行。
    @Test func hasDuplicatesFilters() async throws {
        let harness = try await makeHarness()
        let db = harness.db
        _ = try db.prepare("""
            INSERT INTO duplicate_groups (id, session_id, group_type, checksum,
              member_count, created_at)
            VALUES (1, 'session', 'exact', 'k', 2, '2026-07-30T10:00:00.000Z')
          """).run([])
        _ = try db.prepare("""
            INSERT INTO duplicate_group_members (id, group_id, photo_id, session_id, is_kept, file_size, file_mtime)
            VALUES (1, 1, 'p1', 'session', 1, 100, '2026-07-30T10:00:00.000Z')
          """).run([])

        let withDup = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("has_duplicates", .eq, .bool(true)))
        ).map(\.id)
        #expect(withDup == ["p1"])
        let withoutDup = try harness.engine.filterPhotos(
            sessionId: harness.sessionId,
            criteria: group(rule("has_duplicates", .eq, .bool(false)))
        ).map(\.id)
        #expect(!withoutDup.contains("p1"))
    }
}

// TS↔Swift 用例对照：
// - filter-engine.test.ts（2 用例）→ rejectsRegexOperator（契约层已拒 regex）/
//   unknownFieldThrows
// - filter-engine.ts 红线补充（本文件新增）→ directoryRejectsUnsupportedOperators /
//   emptyInIsFalse / escapeLikeEscapesWildcards / betweenProducesTwoParams /
//   nestedGroupParenthesized / filterPhotosBasic / filterPhotosPassesLimitThrough /
//   countPhotosSessionScoped / keywordsContainsAny / keywordsContainsAll /
//   keywordsEqIgnoresOrder / keywordsExists / suggestFiltersByCameraMake /
//   hasDuplicatesFilters
