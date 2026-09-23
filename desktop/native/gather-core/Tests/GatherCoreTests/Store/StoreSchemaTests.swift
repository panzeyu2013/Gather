// Tests/GatherCoreTests/Store/StoreSchemaTests.swift
// R1：DDL 单一来源的结构漂移门禁。
// 两条建库路径必须逐列一致：
//   ① StoreSchema.ddl（新库快路径，R1 起为唯一 DDL 来源）
//   ② MigrationRunner（旧迁移链，R1 结束前作为 oracle；StoreMigrator 落地后替换）
// 指纹覆盖：表、列（类型/NOT NULL/默认值/主键）、索引 SQL、外键、foreign_key_check。
import Foundation
import Testing
@testable import GatherCore

private func makeTempSchemaPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-schema-test-\(UUID().uuidString).sqlite")
        .path
}

private func removeSchemaFiles(_ path: String) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
    }
}

private func fnv1a64(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
}

private func schemaLines(_ database: SQLiteDatabase) async throws -> [String] {
    let tables = try await database.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).compactMap { $0.text("name") }

    var lines: [String] = []
    for table in tables {
        lines.append("TABLE \(table)")
        let columns = try await database.query("PRAGMA table_info(\(table))")
            .sorted { ($0.int("cid") ?? 0) < ($1.int("cid") ?? 0) }
        for column in columns {
            lines.append("  COL \(column.text("name") ?? "?") type=\(column.text("type") ?? "") notnull=\(column.int("notnull") ?? 0) pk=\(column.int("pk") ?? 0) default=\(column.text("dflt_value") ?? "<nil>")")
        }
        let indexes = try await database.query(
            "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? ORDER BY name",
            [.text(table)]
        )
        for index in indexes {
            let normalizedSQL = (index.text("sql") ?? "")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            lines.append("  IDX \(index.text("name") ?? "?") \(normalizedSQL)")
        }
        let foreignKeys = try await database.query("PRAGMA foreign_key_list(\(table))")
            .sorted { left, right in
                let leftID = left.int("id") ?? 0
                let rightID = right.int("id") ?? 0
                if leftID != rightID { return leftID < rightID }
                return (left.int("seq") ?? 0) < (right.int("seq") ?? 0)
            }
        for foreignKey in foreignKeys {
            lines.append("  FK \(foreignKey.int("id") ?? 0).\(foreignKey.int("seq") ?? 0) -> \(foreignKey.text("table") ?? "?") from=\(foreignKey.text("from") ?? "?") to=\(foreignKey.text("to") ?? "?") onDelete=\(foreignKey.text("on_delete") ?? "?")")
        }
    }
    let foreignKeyViolations = try await database.query("PRAGMA foreign_key_check")
    lines.append("FK_CHECK rows=\(foreignKeyViolations.count)")
    return lines
}

private func schemaFingerprint(_ database: SQLiteDatabase) async throws -> String {
    fnv1a64(try await schemaLines(database).joined(separator: "\n"))
}

@Suite("Store/StoreSchema (R1)")
struct StoreSchemaTests {
    /// 结构变化时更新此常量（review 中可见的显式 diff）。
    private static let expectedFingerprint = "d4b1fe3e5a9da77e"

    @Test func ddlPathAndMigrationPathProduceIdenticalSchema() async throws {
        let legacyPath = makeTempSchemaPath()
        let ddlPath = makeTempSchemaPath()
        defer {
            removeSchemaFiles(legacyPath)
            removeSchemaFiles(ddlPath)
        }

        // ① 新库快路径：StoreSchema 是唯一 DDL 来源。
        do {
            let database = try SQLiteDatabase(path: ddlPath)
            try await database.execute(StoreSchema.schemaSQL)
            try await database.execute(StoreSchema.indexSQL)
            try await database.execute(StoreSchema.uniquePhotoPathIndexSQL)
            await database.close()
        }

        // ② 旧迁移链（R1 期间作为 oracle）。
        do {
            let connection = try DBConnection(path: legacyPath)
            try MigrationRunner(databaseFilePath: nil).migrate(connection)
            connection.close()
        }

        let ddlDatabase = try SQLiteDatabase(path: ddlPath, configuration: .init(readOnly: true))
        let legacyDatabase = try SQLiteDatabase(path: legacyPath, configuration: .init(readOnly: true))
        let ddlLines = try await schemaLines(ddlDatabase)
        let legacyLines = try await schemaLines(legacyDatabase)
        await ddlDatabase.close()
        await legacyDatabase.close()

        if ddlLines != legacyLines {
            let shared = min(ddlLines.count, legacyLines.count)
            var printed = 0
            for index in 0..<shared where ddlLines[index] != legacyLines[index] {
                print("DIFF@\(index) DDL=[\(ddlLines[index])] LEGACY=[\(legacyLines[index])]")
                printed += 1
                if printed >= 25 { break }
            }
            if ddlLines.count != legacyLines.count {
                print("LINE_COUNT DDL=\(ddlLines.count) LEGACY=\(legacyLines.count)")
            }
        }
        let ddlFingerprint = fnv1a64(ddlLines.joined(separator: "\n"))
        let legacyFingerprint = fnv1a64(legacyLines.joined(separator: "\n"))
        #expect(ddlFingerprint == legacyFingerprint, "DDL 快路径与迁移链结构漂移")
        #expect(ddlFingerprint == Self.expectedFingerprint)
    }

    @Test func everyTableHasPrimaryKeyOrRowIDAndNoForeignKeyViolations() async throws {
        let path = makeTempSchemaPath()
        defer { removeSchemaFiles(path) }
        let database = try SQLiteDatabase(path: path)
        try await database.execute(StoreSchema.schemaSQL)
        try await database.execute(StoreSchema.indexSQL)
        try await database.execute(StoreSchema.uniquePhotoPathIndexSQL)
        defer { Task { await database.close() } }

        let tableCount = try await database.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
        #expect(tableCount == 43)
        #expect(try await database.query("PRAGMA foreign_key_check").isEmpty)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'") ?? 0 > 50)
    }
}
