// Tests/GatherCoreTests/Store/SmartAlbumStoreTests.swift
// R1：SmartAlbumStore 测试（端口自 SmartAlbumRepoTests）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/SmartAlbumStore (R1)")
struct SmartAlbumStoreTests {
    private func makeStore() async throws -> (SQLiteSmartAlbumStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "smart-album")
        return (SQLiteSmartAlbumStore(database: database), database, path)
    }

    private func insertAlbum(_ database: SQLiteDatabase, id: String, name: String, updatedAt: String) async throws {
        try await database.run(
            "INSERT INTO smart_albums (id, name, filter_criteria, created_at, updated_at) VALUES (?, ?, '{}', ?, ?)",
            [.text(id), .text(name), .text(updatedAt), .text(updatedAt)]
        )
    }

    private func ratingCriteria() -> FilterGroup {
        FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "rating", operator: .gte, value: .number(3))),
            .rule(FilterRule(field: "label", operator: .eq, value: .string("Pick"))),
        ])
    }

    @Test func createAppliesDefaults() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let row = try await store.create(data: SmartAlbumCreateData(name: "Favorites", filterCriteria: ratingCriteria()))

        #expect(!row.id.isEmpty)
        #expect(row.name == "Favorites")
        #expect(row.schemaVersion == 1)
        #expect(row.description == "")
        #expect(row.sortBy == "date_taken")
        #expect(row.sortOrder == "desc")
        #expect(row.icon == "📁")
        #expect(!row.createdAt.isEmpty)
        #expect(!row.updatedAt.isEmpty)

        #expect(try await store.get(id: row.id) == row)
        #expect(try await store.get(id: "missing") == nil)
    }

    @Test func createStoresCustomFields() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let row = try await store.create(data: SmartAlbumCreateData(
            name: "Raw", description: "RAW only", filterCriteria: ratingCriteria(),
            sortBy: "filepath", sortOrder: "asc", icon: "🌟"
        ))

        #expect(row.description == "RAW only")
        #expect(row.sortBy == "filepath")
        #expect(row.sortOrder == "asc")
        #expect(row.icon == "🌟")
    }

    @Test func filterCriteriaJSONMatchesTSSerialization() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let criteria = ratingCriteria()

        let row = try await store.create(data: SmartAlbumCreateData(name: "Favorites", filterCriteria: criteria))

        #expect(row.filterCriteria.contains("\"logic\":\"and\""))
        #expect(row.filterCriteria.contains("\"field\":\"rating\""))
        #expect(row.filterCriteria.contains("\"operator\":\"gte\""))
        #expect(row.filterCriteria.contains("\"value\":3"))
        #expect(row.filterCriteria.contains("\"field\":\"label\""))
        #expect(row.filterCriteria.contains("\"value\":\"Pick\""))

        let decoded = try JSONDecoder().decode(FilterGroup.self, from: Data(row.filterCriteria.utf8))
        #expect(decoded == criteria)
        #expect(row.criteria == criteria, "记录附带解码视图")
    }

    @Test func nestedFilterGroupRoundTrips() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "keywords", operator: .contains, value: .array([.string("trip")]))),
            .group(FilterGroup(logic: .or, conditions: [
                .rule(FilterRule(field: "label", operator: .eq, value: .string("Pick"))),
            ])),
        ])

        let row = try await store.create(data: SmartAlbumCreateData(name: "Nested", filterCriteria: criteria))
        let decoded = try JSONDecoder().decode(FilterGroup.self, from: Data(row.filterCriteria.utf8))
        #expect(decoded == criteria)
    }

    @Test func listOrdersByUpdatedAtDescending() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertAlbum(database, id: "a1", name: "Old", updatedAt: "2026-01-01T00:00:00.000Z")
        try await insertAlbum(database, id: "a2", name: "New", updatedAt: "2026-05-01T00:00:00.000Z")

        #expect(try await store.list().map(\.id) == ["a2", "a1"])
    }

    @Test func updatePartiallyLeavesOtherFields() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let row = try await store.create(data: SmartAlbumCreateData(
            name: "Favorites", description: "desc", filterCriteria: ratingCriteria(),
            sortBy: "date_taken", sortOrder: "desc", icon: "📁"
        ))

        try await store.update(id: row.id, data: SmartAlbumUpdateData(name: "Renamed", sortBy: "filepath"))
        let updated = try await store.get(id: row.id)
        #expect(updated?.name == "Renamed")
        #expect(updated?.sortBy == "filepath")
        #expect(updated?.description == "desc")
        #expect(updated?.sortOrder == "desc")
        #expect(updated?.icon == "📁")
        #expect(updated?.filterCriteria == row.filterCriteria)
    }

    @Test func updateWithEmptyDataIsNoop() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let row = try await store.create(data: SmartAlbumCreateData(name: "Favorites", filterCriteria: ratingCriteria()))

        try await store.update(id: row.id, data: SmartAlbumUpdateData())
        #expect(try await store.get(id: row.id) == row)
    }

    @Test func updateReplacesFilterCriteria() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let row = try await store.create(data: SmartAlbumCreateData(name: "Favorites", filterCriteria: ratingCriteria()))

        let newCriteria = FilterGroup(logic: .or, conditions: [
            .rule(FilterRule(field: "label", operator: .exists, value: .bool(true))),
        ])
        try await store.update(id: row.id, data: SmartAlbumUpdateData(filterCriteria: newCriteria))

        let updated = try await store.get(id: row.id)
        let decoded = try JSONDecoder().decode(FilterGroup.self, from: Data((updated?.filterCriteria ?? "").utf8))
        #expect(decoded == newCriteria)
    }

    @Test func deleteRemovesRow() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let row = try await store.create(data: SmartAlbumCreateData(name: "Favorites", filterCriteria: ratingCriteria()))

        try await store.delete(id: row.id)
        #expect(try await store.get(id: row.id) == nil)
        #expect(try await store.list().isEmpty)
    }
}
