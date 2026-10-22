// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/SmartAlbumRepoTests.swift
// SmartAlbumRepo 测试：create 默认值/自定义值、filter_criteria JSON 往返、
// list 排序、update 部分更新、delete。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

private func makeDB() throws -> DBConnection {
    let db = try makeTestDB()
    return db
}

private func insertAlbum(_ db: DBConnection, id: String, name: String, updatedAt: String) throws {
    _ = try db.prepare(
        "INSERT INTO smart_albums (id, name, filter_criteria, created_at, updated_at) VALUES (?, ?, '{}', ?, ?)"
    ).run([.text(id), .text(name), .text(updatedAt), .text(updatedAt)])
}

private func ratingCriteria() -> FilterGroup {
    FilterGroup(logic: .and, conditions: [
        .rule(FilterRule(field: "rating", operator: .gte, value: .number(3))),
        .rule(FilterRule(field: "label", operator: .eq, value: .string("Pick"))),
    ])
}

@Suite(.serialized)
struct SmartAlbumRepoTests {
    @Test func createAppliesDefaults() throws {
        let db = try makeDB()
        let repo = SmartAlbumRepo(connection: db)

        let row = try repo.create(data: SmartAlbumCreateData(name: "Favorites", filterCriteria: ratingCriteria()))

        #expect(!row.id.isEmpty)
        #expect(row.name == "Favorites")
        #expect(row.schemaVersion == 1)
        #expect(row.description == "")
        #expect(row.sortBy == "date_taken")
        #expect(row.sortOrder == "desc")
        #expect(row.icon == "📁")
        #expect(!row.createdAt.isEmpty)
        #expect(!row.updatedAt.isEmpty)

        let fetched = try repo.get(id: row.id)
        #expect(fetched == row)
        #expect(try repo.get(id: "missing") == nil)
    }

    @Test func createStoresCustomFields() throws {
        let db = try makeDB()
        let repo = SmartAlbumRepo(connection: db)

        let row = try repo.create(data: SmartAlbumCreateData(
            name: "Raw", description: "RAW only", filterCriteria: ratingCriteria(),
            sortBy: "filepath", sortOrder: "asc", icon: "🌟"
        ))

        #expect(row.description == "RAW only")
        #expect(row.sortBy == "filepath")
        #expect(row.sortOrder == "asc")
        #expect(row.icon == "🌟")
    }

    @Test func filterCriteriaJSONMatchesTSSerialization() throws {
        let db = try makeDB()
        let repo = SmartAlbumRepo(connection: db)
        let criteria = ratingCriteria()

        let row = try repo.create(data: SmartAlbumCreateData(name: "Favorites", filterCriteria: criteria))

        // JSON key 与 TS JSON.stringify 一致（camelCase 原样）。
        #expect(row.filterCriteria.contains("\"logic\":\"and\""))
        #expect(row.filterCriteria.contains("\"field\":\"rating\""))
        #expect(row.filterCriteria.contains("\"operator\":\"gte\""))
        #expect(row.filterCriteria.contains("\"value\":3"))
        #expect(row.filterCriteria.contains("\"field\":\"label\""))
        #expect(row.filterCriteria.contains("\"value\":\"Pick\""))

        // 往返解码等于输入。
        let decoded = try JSONDecoder().decode(FilterGroup.self, from: Data(row.filterCriteria.utf8))
        #expect(decoded == criteria)
    }

    @Test func nestedFilterGroupRoundTrips() throws {
        let db = try makeDB()
        let repo = SmartAlbumRepo(connection: db)
        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "keywords", operator: .contains, value: .array([.string("trip")]))),
            .group(FilterGroup(logic: .or, conditions: [
                .rule(FilterRule(field: "label", operator: .eq, value: .string("Pick"))),
            ])),
        ])

        let row = try repo.create(data: SmartAlbumCreateData(name: "Nested", filterCriteria: criteria))
        let decoded = try JSONDecoder().decode(FilterGroup.self, from: Data(row.filterCriteria.utf8))
        #expect(decoded == criteria)
    }

    @Test func listOrdersByUpdatedAtDescending() throws {
        let db = try makeDB()
        try insertAlbum(db, id: "a1", name: "Old", updatedAt: "2026-01-01T00:00:00.000Z")
        try insertAlbum(db, id: "a2", name: "New", updatedAt: "2026-05-01T00:00:00.000Z")
        let repo = SmartAlbumRepo(connection: db)

        let rows = try repo.list()
        #expect(rows.map(\.id) == ["a2", "a1"])
    }

    @Test func updatePartiallyLeavesOtherFields() throws {
        let db = try makeDB()
        let repo = SmartAlbumRepo(connection: db)
        let row = try repo.create(data: SmartAlbumCreateData(
            name: "Favorites", description: "desc", filterCriteria: ratingCriteria(),
            sortBy: "date_taken", sortOrder: "desc", icon: "📁"
        ))

        try repo.update(id: row.id, data: SmartAlbumUpdateData(name: "Renamed", sortBy: "filepath"))
        let updated = try repo.get(id: row.id)
        #expect(updated?.name == "Renamed")
        #expect(updated?.sortBy == "filepath")
        #expect(updated?.description == "desc")
        #expect(updated?.sortOrder == "desc")
        #expect(updated?.icon == "📁")

        // filter_criteria 未动时保持原 JSON。
        #expect(updated?.filterCriteria == row.filterCriteria)
    }

    @Test func updateWithEmptyDataIsNoop() throws {
        let db = try makeDB()
        let repo = SmartAlbumRepo(connection: db)
        let row = try repo.create(data: SmartAlbumCreateData(name: "Favorites", filterCriteria: ratingCriteria()))

        try repo.update(id: row.id, data: SmartAlbumUpdateData())
        #expect(try repo.get(id: row.id) == row)
    }

    @Test func updateReplacesFilterCriteria() throws {
        let db = try makeDB()
        let repo = SmartAlbumRepo(connection: db)
        let row = try repo.create(data: SmartAlbumCreateData(name: "Favorites", filterCriteria: ratingCriteria()))

        let newCriteria = FilterGroup(logic: .or, conditions: [
            .rule(FilterRule(field: "label", operator: .exists, value: .bool(true))),
        ])
        try repo.update(id: row.id, data: SmartAlbumUpdateData(filterCriteria: newCriteria))

        let updated = try repo.get(id: row.id)
        let decoded = try JSONDecoder().decode(FilterGroup.self, from: Data((updated?.filterCriteria ?? "").utf8))
        #expect(decoded == newCriteria)
    }

    @Test func deleteRemovesRow() throws {
        let db = try makeDB()
        let repo = SmartAlbumRepo(connection: db)
        let row = try repo.create(data: SmartAlbumCreateData(name: "Favorites", filterCriteria: ratingCriteria()))

        try repo.delete(id: row.id)
        #expect(try repo.get(id: row.id) == nil)
        #expect(try repo.list().isEmpty)
    }
}
