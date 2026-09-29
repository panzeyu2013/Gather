// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/WritebackRepoTests.swift
// WritebackRepo 测试：saveItems 替换语义、查询过滤、状态流转、批量更新、
// synced-only 清理、hasActive/discardPendingByXmpPath。

import Foundation
import Testing
@testable import GatherCore

private func makeDB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    return db
}

private func insertSession(_ db: DBConnection, id: String) throws {
    _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')")
        .run([.text(id)])
}

private func insertPhoto(_ db: DBConnection, id: String, sessionId: String) throws {
    _ = try db.prepare("INSERT INTO photos (id, session_id, filepath, created_at, updated_at) VALUES (?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')")
        .run([.text(id), .text(sessionId), .text("/\(id).jpg")])
}

private func item(_ photoId: String, xmpPath: String = "", attributes: [String: Any]? = nil) -> WritebackItemInput {
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

@Suite(.serialized)
struct WritebackRepoTests {
    @Test func saveAndGetItemsPersistsAllFields() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        let repo = WritebackRepo(connection: db)

        try repo.saveItems(sessionId: "s1", module: "culling", items: [
            item("p1", attributes: ["rating": 4, "label": "Pick"]),
            item("p2"),
        ])

        let rows = try repo.getItems(sessionId: "s1")
        #expect(rows.count == 2)
        // ORDER BY id ASC。
        #expect(rows[0].id < rows[1].id)
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

        // 属性 JSON（key 原样 camelCase）。
        let parsed = try JSONSerialization.jsonObject(with: Data(rows[0].attributesJson.utf8)) as? [String: Any]
        #expect(parsed?["rating"] as? Int == 4)
        #expect(parsed?["label"] as? String == "Pick")
        #expect(rows[1].attributesJson == "{}")

        // 过滤查询。
        #expect(try repo.getItems(sessionId: "s1", module: "culling").count == 2)
        #expect(try repo.getItems(sessionId: "s1", module: "other").isEmpty)
        #expect(try repo.getItems(sessionId: "s1", status: "pending").count == 2)
        #expect(try repo.getItems(sessionId: "s1", status: "failed").isEmpty)
    }

    @Test func saveItemsReplacesPendingAndFailedButKeepsSynced() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        let repo = WritebackRepo(connection: db)

        try repo.saveItems(sessionId: "s1", module: "culling", items: [item("p1"), item("p2")])
        let rows = try repo.getItems(sessionId: "s1")
        try repo.updateStatus(itemId: rows[0].id, status: "synced")
        try repo.updateStatus(itemId: rows[1].id, status: "failed")

        // 新一轮：pending/failed 被替换，synced 保留。
        try repo.saveItems(sessionId: "s1", module: "culling", items: [item("p1")])
        let after = try repo.getItems(sessionId: "s1")
        #expect(after.count == 2)
        let synced = after.first { $0.xmpStatus == "synced" }
        let pending = after.first { $0.xmpStatus == "pending" }
        #expect(synced?.id == rows[0].id, "synced 行应保留")
        #expect(pending != nil)
        #expect(pending?.id != rows[1].id, "failed 行应被替换")
    }

    @Test func updateStatusIncrementsAttemptCountAndSetsError() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        let repo = WritebackRepo(connection: db)

        try repo.saveItems(sessionId: "s1", module: "culling", items: [item("p1")])
        let row = try repo.getItems(sessionId: "s1")[0]

        try repo.updateStatus(itemId: row.id, status: "failed", error: "IO error")
        var after = try repo.getItems(sessionId: "s1").first { $0.id == row.id }
        #expect(after?.xmpStatus == "failed")
        #expect(after?.errorMessage == "IO error")
        #expect(after?.attemptCount == 2)

        // 再次失败：attempt_count 继续 +1，error 可覆盖。
        try repo.updateStatus(itemId: row.id, status: "failed", error: "retry")
        after = try repo.getItems(sessionId: "s1").first { $0.id == row.id }
        #expect(after?.attemptCount == 3)
        #expect(after?.errorMessage == "retry")
    }

    @Test func getFailedCountFiltersByModule() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        let repo = WritebackRepo(connection: db)

        try repo.saveItems(sessionId: "s1", module: "culling", items: [item("p1")])
        try repo.saveItems(sessionId: "s1", module: "face", items: [item("p2")])
        let all = try repo.getItems(sessionId: "s1")
        try repo.updateStatus(itemId: all[0].id, status: "failed")
        try repo.updateStatus(itemId: all[1].id, status: "failed")

        #expect(try repo.getFailedCount(sessionId: "s1") == 2)
        #expect(try repo.getFailedCount(sessionId: "s1", module: "culling") == 1)
        #expect(try repo.getFailedCount(sessionId: "s1", module: "face") == 1)
        #expect(try repo.getFailedCount(sessionId: "empty") == 0)
    }

    @Test func deleteItemsByIdsOnlyDeletesSyncedRows() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        try insertPhoto(db, id: "p3", sessionId: "s1")
        let repo = WritebackRepo(connection: db)

        try repo.saveItems(sessionId: "s1", module: "culling", items: [item("p1"), item("p2"), item("p3")])
        let rows = try repo.getItems(sessionId: "s1")
        try repo.updateStatus(itemId: rows[0].id, status: "synced")
        try repo.updateStatus(itemId: rows[1].id, status: "written")
        try repo.updateStatus(itemId: rows[2].id, status: "synced")

        try repo.deleteItemsByIds(sessionId: "s1", module: "culling", ids: [rows[0].id, rows[1].id, rows[2].id])
        let remaining = try repo.getItems(sessionId: "s1")
        #expect(remaining.count == 1)
        #expect(remaining[0].id == rows[1].id, "written 行不应被清理")
    }

    @Test func deleteItemsByIdsChunkedOver400DeletesLastBlock() throws {
        // 审计 P1：分块（400/批）路径的末块回归——此前末块可能残留。
        let db = try makeDB()
        try insertSession(db, id: "s1")
        let repo = WritebackRepo(connection: db)
        let count = 450

        // 分批 save（每次 saveItems 全量替换，需一次写入全部）。
        var items: [WritebackItemInput] = []
        for i in 0..<count {
            let photoId = "p\(String(format: "%04d", i))"
            try insertPhoto(db, id: photoId, sessionId: "s1")
            items.append(item(photoId))
        }
        try repo.saveItems(sessionId: "s1", module: "culling", items: items)
        let rows = try repo.getItems(sessionId: "s1")
        #expect(rows.count == count)
        for row in rows {
            try repo.updateStatus(itemId: row.id, status: "synced")
        }

        // 全部删除：跨 400 边界（450 = 400 + 50 末块）。
        try repo.deleteItemsByIds(sessionId: "s1", module: "culling", ids: rows.map(\.id))
        #expect(try repo.getItems(sessionId: "s1").isEmpty, "450 条 synced 行应全部被清理（含末块）")
    }

    @Test func updateAttributesAndKeywordsMany() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        let repo = WritebackRepo(connection: db)

        try repo.saveItems(sessionId: "s1", module: "culling", items: [item("p1"), item("p2")])
        let rows = try repo.getItems(sessionId: "s1")

        try repo.updateAttributesMany(items: [
            (id: rows[0].id, attributes: ["rating": 1]),
            (id: rows[1].id, attributes: ["rating": 2]),
        ])
        try repo.updateKeywordsMany(items: [
            (id: rows[0].id, keywords: ["k1"]),
            (id: rows[1].id, keywords: ["k2"]),
        ])

        let after = try repo.getItems(sessionId: "s1")
        #expect(after[0].keywords == "[\"k1\"]")
        #expect(after[1].keywords == "[\"k2\"]")
        let a0 = try JSONSerialization.jsonObject(with: Data(after[0].attributesJson.utf8)) as? [String: Any]
        let a1 = try JSONSerialization.jsonObject(with: Data(after[1].attributesJson.utf8)) as? [String: Any]
        #expect(a0?["rating"] as? Int == 1)
        #expect(a1?["rating"] as? Int == 2)
    }

    @Test func markWrittenAsSyncedOnlyAffectsWrittenRows() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        let repo = WritebackRepo(connection: db)

        try repo.saveItems(sessionId: "s1", module: "culling", items: [item("p1"), item("p2")])
        let rows = try repo.getItems(sessionId: "s1")
        try repo.updateStatus(itemId: rows[0].id, status: "written")
        // rows[1] 保持 pending。

        try repo.markWrittenAsSynced(sessionId: "s1", module: "culling")
        let after = try repo.getItems(sessionId: "s1")
        #expect(after[0].xmpStatus == "synced")
        #expect(after[1].xmpStatus == "pending")
    }

    @Test func discardPendingByXmpPathRemovesOnlyPendingAndFailed() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        let repo = WritebackRepo(connection: db)

        #expect(try repo.getItems(sessionId: "s1").isEmpty)

        try repo.saveItems(sessionId: "s1", module: "culling", items: [item("p1", xmpPath: "/x1.xmp")])
        #expect(try repo.getItems(sessionId: "s1").count == 1)

        // pending 被丢弃，返回删除行数。
        #expect(try repo.discardPendingByXmpPath(xmpPath: "/x1.xmp") == 1)
        #expect(try repo.getItems(sessionId: "s1").isEmpty)

        // failed 同样可丢弃。
        try repo.saveItems(sessionId: "s1", module: "culling", items: [item("p1", xmpPath: "/x1.xmp")])
        let failedRow = try repo.getItems(sessionId: "s1")[0]
        try repo.updateStatus(itemId: failedRow.id, status: "failed")
        #expect(try repo.discardPendingByXmpPath(xmpPath: "/x1.xmp") == 1)

        // synced 行不可丢弃（不在 pending/failed 集合）。
        try repo.saveItems(sessionId: "s1", module: "culling", items: [item("p1", xmpPath: "/x1.xmp")])
        let syncedRow = try repo.getItems(sessionId: "s1")[0]
        try repo.updateStatus(itemId: syncedRow.id, status: "synced")
        #expect(try repo.discardPendingByXmpPath(xmpPath: "/x1.xmp") == 0)
        #expect(try repo.getItems(sessionId: "s1").count == 1)
    }
}
