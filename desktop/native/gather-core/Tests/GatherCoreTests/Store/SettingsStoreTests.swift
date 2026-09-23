// Tests/GatherCoreTests/Store/SettingsStoreTests.swift
// R1：SettingsStore 测试（端口自 SettingsRepoTests，oracle 断言保持一致）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/SettingsStore (R1)")
struct SettingsStoreTests {
    private func makeStore() async throws -> (SQLiteSettingsStore, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "settings")
        return (SQLiteSettingsStore(database: database), path)
    }

    @Test func upsertInsertsThenUpdatesOnConflict() async throws {
        let (store, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        #expect(try await store.get("theme") == nil)
        #expect(try await store.all().isEmpty)

        try await store.upsert("theme", value: "dark")
        #expect(try await store.get("theme") == SettingRecord(key: "theme", value: "dark"))
        #expect(try await store.value("theme") == "dark")
        #expect(try await store.all() == [SettingRecord(key: "theme", value: "dark")])

        // ON CONFLICT(key) DO UPDATE：替换值而不是报唯一冲突。
        try await store.upsert("theme", value: "light")
        #expect(try await store.get("theme") == SettingRecord(key: "theme", value: "light"))
        #expect(try await store.all().count == 1)
    }

    @Test func batchUpsertInsertsAndOverwrites() async throws {
        let (store, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsert("existing", value: "old")
        try await store.upsert([
            (key: "existing", value: "new"),
            (key: "lang", value: "zh"),
            (key: "window", value: "maximized"),
        ])

        let all = try await store.all()
        #expect(all.count == 3)
        #expect(all.contains(SettingRecord(key: "existing", value: "new")))
        #expect(all.contains(SettingRecord(key: "lang", value: "zh")))
        #expect(all.contains(SettingRecord(key: "window", value: "maximized")))
    }

    @Test func batchUpsertWithEmptyEntriesIsNoop() async throws {
        let (store, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsert([])
        #expect(try await store.all().isEmpty)
    }
}
