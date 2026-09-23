// Tests/GatherCoreTests/Store/StoreSchemaTests.swift
// R1：DDL 单一来源的结构漂移门禁。
// 两条建库路径必须逐列一致：
//   ① StoreSchema.ddl（新库快路径，R1 起为唯一 DDL 来源）
//   ② StoreMigrator（正式注册表：DDL 直建与其迁移结果必须一致）
// 指纹覆盖：表、列（类型/NOT NULL/默认值/主键）、索引 SQL、外键、foreign_key_check。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/StoreSchema (R1)")
struct StoreSchemaTests {
    /// 结构变化时更新此常量（review 中可见的显式 diff）。
    private static let expectedFingerprint = "d4b1fe3e5a9da77e"

    @Test func ddlPathAndMigrationPathProduceIdenticalSchema() async throws {
        let legacyPath = storeTempPath("schema")
        let ddlPath = storeTempPath("schema")
        defer {
            removeStoreFiles(legacyPath)
            removeStoreFiles(ddlPath)
        }

        // ① 新库快路径：StoreSchema 是唯一 DDL 来源。
        do {
            let database = try SQLiteDatabase(path: ddlPath)
            try await database.execute(StoreSchema.schemaSQL)
            try await database.execute(StoreSchema.indexSQL)
            try await database.execute(StoreSchema.uniquePhotoPathIndexSQL)
            await database.close()
        }

        // ② 正式迁移链（StoreMigrator）作为 oracle 对照 DDL 直建。
        do {
            let database = try SQLiteDatabase(path: legacyPath)
            try await StoreMigrator().migrate(database)
            await database.close()
        }

        let ddlDatabase = try SQLiteDatabase(path: ddlPath, configuration: .init(readOnly: true))
        let legacyDatabase = try SQLiteDatabase(path: legacyPath, configuration: .init(readOnly: true))
        let ddlLines = try await storeSchemaLines(ddlDatabase)
        let legacyLines = try await storeSchemaLines(legacyDatabase)
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
        let ddlFingerprint = storeFNV1a64(ddlLines.joined(separator: "\n"))
        let legacyFingerprint = storeFNV1a64(legacyLines.joined(separator: "\n"))
        #expect(ddlFingerprint == legacyFingerprint, "DDL 快路径与迁移链结构漂移")
        #expect(ddlFingerprint == Self.expectedFingerprint)
    }

    @Test func everyTableHasPrimaryKeyOrRowIDAndNoForeignKeyViolations() async throws {
        let path = storeTempPath("schema")
        defer { removeStoreFiles(path) }
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
