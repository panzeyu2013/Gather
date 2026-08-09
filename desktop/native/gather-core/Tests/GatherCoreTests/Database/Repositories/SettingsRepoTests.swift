// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/SettingsRepoTests.swift
// SettingsRepo 测试：getAll/get/upsert（INSERT + ON CONFLICT 更新）/batchUpsert。

import Foundation
import Testing
@testable import GatherCore

private func makeDB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    return db
}

@Suite(.serialized)
struct SettingsRepoTests {
    @Test func upsertInsertsThenUpdatesOnConflict() throws {
        let db = try makeDB()
        let repo = SettingsRepo(connection: db)

        #expect(try repo.get(key: "theme") == nil)
        #expect(try repo.getAll().isEmpty)

        try repo.upsert(key: "theme", value: "dark")
        #expect(try repo.get(key: "theme") == SettingsRow(key: "theme", value: "dark"))
        #expect(try repo.getAll() == [SettingsRow(key: "theme", value: "dark")])

        // ON CONFLICT(key) DO UPDATE：替换值而不是报唯一冲突。
        try repo.upsert(key: "theme", value: "light")
        #expect(try repo.get(key: "theme") == SettingsRow(key: "theme", value: "light"))
        #expect(try repo.getAll().count == 1)
    }

    @Test func batchUpsertInsertsAndOverwrites() throws {
        let db = try makeDB()
        let repo = SettingsRepo(connection: db)

        try repo.upsert(key: "existing", value: "old")
        try repo.batchUpsert(entries: [
            (key: "existing", value: "new"),
            (key: "lang", value: "zh"),
            (key: "window", value: "maximized"),
        ])

        let all = try repo.getAll()
        #expect(all.count == 3)
        #expect(all.contains(SettingsRow(key: "existing", value: "new")))
        #expect(all.contains(SettingsRow(key: "lang", value: "zh")))
        #expect(all.contains(SettingsRow(key: "window", value: "maximized")))
    }

    @Test func batchUpsertWithEmptyEntriesIsNoop() throws {
        let db = try makeDB()
        let repo = SettingsRepo(connection: db)

        try repo.batchUpsert(entries: [])
        #expect(try repo.getAll().isEmpty)
    }
}
