// desktop/native/gather-core/Tests/GatherCoreTests/Database/MigrationTests.swift
// SchemaV1 fresh 建库门禁（Cut 2 / S5c-2b-3b-2b-3）：
//   ① SchemaV1.sql 空库一次成型 —— 43 表、user_version = 1、无任何 legacy 表/列；
//   ② 生产入口 Database.open(at:) 建出的库与 ① 同形；
//   ③ Schema.swift 的版本镜像与 SchemaCatalog.production.current 一致（check-docs 入口不漂移）。
//
// 已删除的用例（随 MigrationRunner / SchemaV1Transition 一起，S5c-2b-3b-2b-3）：
//   hybridDatabaseAddsLegacyTablesAndSessionColumns / hybridLegacyForeignKeysCascade
//   以及全部旧迁移链断言（v1…v35 ALTER/重建/备份回滚）。V1 没有 down migration，
//   不兼容库由 Database.open 整体重置（见 DatabaseFacadeTests）。

import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence

private func tableNames(_ db: DBConnection) throws -> [String] {
    let rows = try db.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).query()
    return rows.compactMap { $0[0].textValue }
}

private func userVersion(_ db: DBConnection) throws -> Int {
    Int(try db.prepare("PRAGMA user_version").get()?[0].intValue ?? 0)
}

private func tableColumnNames(_ db: DBConnection, _ table: String) throws -> [String] {
    let rows = try db.prepare("PRAGMA table_info(\(table))").query()
    return rows.compactMap { $0[1].textValue }
}

private func foreignKeyViolations(_ db: DBConnection) throws -> [DBRow] {
    try db.prepare("PRAGMA foreign_key_check").query()
}

/// 旧同步栈的表/列清单（S5c-2b-3b-2b-3 删除；新库一个都不该有）。
private let legacyTables = ["metadata_outbox", "metadata_outbox_sessions", "writeback_items"]
private let legacySessionColumns = ["writeback_status", "import_source", "failed_writeback_count"]

@Suite
struct MigrationTests {
    /// fresh 库：SchemaV1 一次成型，不夹带旧迁移链的产物。
    @Test func freshDatabaseIsSchemaV1Only() throws {
        let db = try DBConnection(path: ":memory:")
        try db.exec(SchemaV1.sql)
        defer { db.close() }

        #expect(try userVersion(db) == SchemaV1.userVersion)
        let tables = try tableNames(db)
        #expect(tables.count == 43, "SchemaV1 应为 43 表，实际 \(tables.count)：\(tables)")
        for table in ["sessions", "photos", "deliveries", "delivery_items", "delivery_intents", "delivery_sessions"] {
            #expect(tables.contains(table), "V1 缺表 \(table)")
        }
        for legacy in legacyTables + ["asset_file_metadata", "schema_version"] {
            #expect(!tables.contains(legacy), "V1 新库不得含旧迁移链的表 \(legacy)")
        }

        // sessions：10 列（V1 删掉 writeback_status / import_source / failed_writeback_count）。
        let sessionColumns = try tableColumnNames(db, "sessions")
        #expect(sessionColumns == [
            "id", "name", "status", "source_path", "truncated_import",
            "reload_acked_at", "index_seq", "photo_count", "created_at", "updated_at",
        ], "V1 sessions 列集合/列序已变，实际：\(sessionColumns)")
        for legacy in legacySessionColumns {
            #expect(!sessionColumns.contains(legacy), "V1 sessions 不得含 legacy 列 \(legacy)")
        }

        #expect(try foreignKeyViolations(db).isEmpty, "V1 建库后不得有悬空外键")
    }

    /// 生产入口（Database.open）建出的内存库与 fresh DDL 同形，版本为当前 V2。
    @Test func databaseOpenCreatesCurrentSchema() throws {
        let database = try Database.open(at: Database.inMemoryPath)
        defer { database.close() }
        let db = database.connection

        #expect(try userVersion(db) == 2)
        #expect(database.outcome == .created(.v2))
        let tables = try tableNames(db)
        #expect(tables.count == 43)
        for legacy in legacyTables {
            #expect(!tables.contains(legacy), "Database.open 不得再建 legacy 表 \(legacy)")
        }
        #expect(try tableColumnNames(db, "sessions").count == 10)
    }

    /// check-docs.sh 读取的版本镜像必须与唯一真相源（catalog.current）一致。
    @Test func schemaVersionMirrorMatchesCurrent() {
        #expect(SchemaSQL.currentSchemaVersion == SchemaCatalog.production.current.rawValue)
        #expect(SchemaSQL.currentSchemaVersion == 2)
        #expect(SchemaV1.userVersion == 1, "V1 快照冻结在 1")
    }
}
