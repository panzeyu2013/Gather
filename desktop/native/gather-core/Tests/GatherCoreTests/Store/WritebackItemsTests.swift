// Tests/GatherCoreTests/Store/WritebackItemsTests.swift
// R1：WritebackStore 的 writeback_items 部分测试（端口自 WritebackRepoTests）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/WritebackStore items (R1)")
struct WritebackItemsTests {
    private func makeStore() async throws -> (SQLiteWritebackStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "writeback-items")
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        return (SQLiteWritebackStore(database: database), database, path)
    }

    private func insertPhoto(_ database: SQLiteDatabase, id: String, sessionId: String = "s1") async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, created_at, updated_at)
            VALUES (?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(sessionId), .text("/\(id).jpg")]
        )
    }

    private func item(
        _ photoId: String,
        xmpPath: String = "",
        attributes: [String: JSONValue]? = nil
    ) -> WritebackItemInput {
        WritebackItemInput(
            photoId: photoId,
            photoPath: "/photos/\(photoId).jpg",
            module: "culling",
            keywords: ["trip", "family"],
            attributes: attributes,
            xmpPath: xmpPath.isEmpty ? "/xmp/\(photoId).xmp" : xmpPath,
            backupPath: ""
        )
    }

    @Test func saveAndGetItemsPersistsAllFields() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")
        try await insertPhoto(database, id: "p2")

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [
            item("p1", attributes: ["rating": JSONValue.int(4), "label": JSONValue.string("Pick")]),
            item("p2"),
        ])

        let rows = try await store.writebackItems(sessionId: "s1")
        #expect(rows.count == 2)
        #expect(rows[0].id < rows[1].id, "ORDER BY id ASC")
        #expect(rows[0].photoId == "p1")
        #expect(rows[0].photoPath == "/photos/p1.jpg")
        #expect(rows[0].sessionId == "s1")
        #expect(rows[0].module == "culling")
        #expect(rows[0].keywords == "[\"trip\",\"family\"]")
        #expect(rows[0].xmpPath == "/xmp/p1.xmp")
        #expect(rows[0].backupPath == "")
        #expect(rows[0].xmpStatus == "pending")
        #expect(rows[0].errorMessage == "")
        #expect(rows[0].attemptCount == 1)
        #expect(!rows[0].lastAttemptAt.isEmpty)
        #expect(rows[0].attributes?["rating"] == .number(4))
        #expect(rows[0].attributes?["label"] == .string("Pick"))
        #expect(rows[1].attributesJson == "{}")

        #expect(try await store.writebackItems(sessionId: "s1", module: "culling", status: nil).count == 2)
        #expect(try await store.writebackItems(sessionId: "s1", module: "other", status: nil).isEmpty)
        #expect(try await store.writebackItems(sessionId: "s1", module: nil, status: "pending").count == 2)
        #expect(try await store.writebackItems(sessionId: "s1", module: nil, status: "failed").isEmpty)

        #expect(try await store.writebackItem(itemId: rows[0].id) == rows[0])
        #expect(try await store.writebackItem(itemId: 999) == nil)
    }

    @Test func saveItemsReplacesPendingAndFailedButKeepsSynced() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")
        try await insertPhoto(database, id: "p2")

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1"), item("p2")])
        let rows = try await store.writebackItems(sessionId: "s1")
        try await store.updateWritebackStatus(itemId: rows[0].id, status: "synced")
        try await store.updateWritebackStatus(itemId: rows[1].id, status: "failed")

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1")])
        let after = try await store.writebackItems(sessionId: "s1")
        #expect(after.count == 2)
        let synced = after.first { $0.xmpStatus == "synced" }
        let pending = after.first { $0.xmpStatus == "pending" }
        #expect(synced?.id == rows[0].id, "synced 行应保留")
        #expect(pending != nil)
        #expect(pending?.id != rows[1].id, "failed 行应被替换")
    }

    @Test func updateStatusIncrementsAttemptCountAndSetsError() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1")])
        let row = try await store.writebackItems(sessionId: "s1")[0]

        try await store.updateWritebackStatus(itemId: row.id, status: "failed", error: "IO error")
        var after = try await store.writebackItem(itemId: row.id)
        #expect(after?.xmpStatus == "failed")
        #expect(after?.errorMessage == "IO error")
        #expect(after?.attemptCount == 2)

        try await store.updateWritebackStatus(itemId: row.id, status: "failed", error: "retry")
        after = try await store.writebackItem(itemId: row.id)
        #expect(after?.attemptCount == 3)
        #expect(after?.errorMessage == "retry")
    }

    @Test func getFailedCountFiltersByModule() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")
        try await insertPhoto(database, id: "p2")

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1")])
        try await store.saveWritebackItems(sessionId: "s1", module: "face", items: [item("p2")])
        let all = try await store.writebackItems(sessionId: "s1")
        try await store.updateWritebackStatus(itemId: all[0].id, status: "failed")
        try await store.updateWritebackStatus(itemId: all[1].id, status: "failed")

        #expect(try await store.failedWritebackCount(sessionId: "s1") == 2)
        #expect(try await store.failedWritebackCount(sessionId: "s1", module: "culling") == 1)
        #expect(try await store.failedWritebackCount(sessionId: "s1", module: "face") == 1)
        #expect(try await store.failedWritebackCount(sessionId: "empty") == 0)
    }

    @Test func deleteItemsRemovesByModuleOrAll() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")
        try await insertPhoto(database, id: "p2")

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1")])
        try await store.saveWritebackItems(sessionId: "s1", module: "face", items: [item("p2")])

        try await store.deleteWritebackItems(sessionId: "s1", module: "culling")
        #expect(try await store.writebackItems(sessionId: "s1", module: "culling", status: nil).isEmpty)
        #expect(try await store.writebackItems(sessionId: "s1", module: "face", status: nil).count == 1)

        try await store.deleteWritebackItems(sessionId: "s1")
        #expect(try await store.writebackItems(sessionId: "s1").isEmpty)
    }

    @Test func deleteItemsByIdsOnlyDeletesSyncedRows() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        for id in ["p1", "p2", "p3"] { try await insertPhoto(database, id: id) }

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1"), item("p2"), item("p3")])
        let rows = try await store.writebackItems(sessionId: "s1")
        try await store.updateWritebackStatus(itemId: rows[0].id, status: "synced")
        try await store.updateWritebackStatus(itemId: rows[1].id, status: "written")
        try await store.updateWritebackStatus(itemId: rows[2].id, status: "synced")

        try await store.deleteWritebackItems(sessionId: "s1", module: "culling", ids: [rows[0].id, rows[1].id, rows[2].id])
        let remaining = try await store.writebackItems(sessionId: "s1")
        #expect(remaining.count == 1)
        #expect(remaining[0].id == rows[1].id, "written 行不应被清理")
    }

    @Test func deleteItemsByIdsChunkedOver400DeletesLastBlock() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let count = 450

        var items: [WritebackItemInput] = []
        for index in 0..<count {
            let photoId = "p\(String(format: "%04d", index))"
            try await insertPhoto(database, id: photoId)
            items.append(item(photoId))
        }
        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: items)
        let rows = try await store.writebackItems(sessionId: "s1")
        #expect(rows.count == count)
        for row in rows {
            try await store.updateWritebackStatus(itemId: row.id, status: "synced")
        }

        try await store.deleteWritebackItems(sessionId: "s1", module: "culling", ids: rows.map(\.id))
        #expect(try await store.writebackItems(sessionId: "s1").isEmpty, "450 条 synced 行应全部被清理（含末块）")
    }

    @Test func updateBackupPathAttributesKeywords() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1")])
        let row = try await store.writebackItems(sessionId: "s1")[0]

        try await store.updateWritebackBackupPath(itemId: row.id, path: "/backup/xmp.bak")
        try await store.updateWritebackAttributes(
            itemId: row.id, attributes: ["rating": JSONValue.int(5), "label": JSONValue.string("Best")]
        )
        try await store.updateWritebackKeywords(itemId: row.id, keywords: ["only"])

        let updated = try await store.writebackItem(itemId: row.id)
        #expect(updated?.backupPath == "/backup/xmp.bak")
        #expect(updated?.attributes?["rating"] == .number(5))
        #expect(updated?.attributes?["label"] == .string("Best"))
        #expect(updated?.keywords == "[\"only\"]")
    }

    @Test func updateAttributesAndKeywordsMany() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")
        try await insertPhoto(database, id: "p2")

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1"), item("p2")])
        let rows = try await store.writebackItems(sessionId: "s1")

        try await store.updateWritebackAttributes([
            WritebackAttributesUpdate(id: rows[0].id, attributes: ["rating": JSONValue.int(1)]),
            WritebackAttributesUpdate(id: rows[1].id, attributes: ["rating": JSONValue.int(2)]),
        ])
        try await store.updateWritebackKeywords([
            WritebackKeywordsUpdate(id: rows[0].id, keywords: ["k1"]),
            WritebackKeywordsUpdate(id: rows[1].id, keywords: ["k2"]),
        ])

        let after = try await store.writebackItems(sessionId: "s1")
        #expect(after[0].keywords == "[\"k1\"]")
        #expect(after[1].keywords == "[\"k2\"]")
        #expect(after[0].attributes?["rating"] == .number(1))
        #expect(after[1].attributes?["rating"] == .number(2))
    }

    @Test func markWrittenAsSyncedOnlyAffectsWrittenRows() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")
        try await insertPhoto(database, id: "p2")

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1"), item("p2")])
        let rows = try await store.writebackItems(sessionId: "s1")
        try await store.updateWritebackStatus(itemId: rows[0].id, status: "written")

        try await store.markWritebackWrittenAsSynced(sessionId: "s1", module: "culling")
        let after = try await store.writebackItems(sessionId: "s1")
        #expect(after[0].xmpStatus == "synced")
        #expect(after[1].xmpStatus == "pending")
    }

    @Test func updateStatusByXmpPathClearsError() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1", xmpPath: "/x1.xmp")])
        let row = try await store.writebackItems(sessionId: "s1")[0]
        try await store.updateWritebackStatus(itemId: row.id, status: "failed", error: "boom")

        try await store.updateWritebackStatusByXmpPath(
            sessionId: "s1", module: "culling", xmpPath: "/x1.xmp", status: "written"
        )
        let updated = try await store.writebackItem(itemId: row.id)
        #expect(updated?.xmpStatus == "written")
        #expect(updated?.errorMessage == "")
    }

    @Test func hasActiveForXmpPathAndDiscardPending() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")

        #expect(try await store.hasActiveWriteback(xmpPath: "/x1.xmp") == false)

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1", xmpPath: "/x1.xmp")])
        #expect(try await store.hasActiveWriteback(xmpPath: "/x1.xmp"))

        #expect(try await store.discardWritebackPending(xmpPath: "/x1.xmp") == 1)
        #expect(try await store.writebackItems(sessionId: "s1").isEmpty)
        #expect(try await store.hasActiveWriteback(xmpPath: "/x1.xmp") == false)

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1", xmpPath: "/x1.xmp")])
        let failedRow = try await store.writebackItems(sessionId: "s1")[0]
        try await store.updateWritebackStatus(itemId: failedRow.id, status: "failed")
        #expect(try await store.discardWritebackPending(xmpPath: "/x1.xmp") == 1)

        try await store.saveWritebackItems(sessionId: "s1", module: "culling", items: [item("p1", xmpPath: "/x1.xmp")])
        let syncedRow = try await store.writebackItems(sessionId: "s1")[0]
        try await store.updateWritebackStatus(itemId: syncedRow.id, status: "synced")
        #expect(try await store.discardWritebackPending(xmpPath: "/x1.xmp") == 0)
        #expect(try await store.writebackItems(sessionId: "s1").count == 1)
        #expect(try await store.hasActiveWriteback(xmpPath: "/x1.xmp"))
    }
}
