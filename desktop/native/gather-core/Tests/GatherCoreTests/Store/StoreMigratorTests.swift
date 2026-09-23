// Tests/GatherCoreTests/Store/StoreMigratorTests.swift
// R1：StoreMigrator 的幂等性/回滚/不变量校验（StoreMigrator 已随 Migrations.swift 退役）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/StoreMigrator (R1)")
struct StoreMigratorTests {
    /// 本机真实库 fixture（含用户数据，不入库）；CI 上不存在则跳过依赖它的用例。
    private static let fixturePath = "/private/tmp/gather-fixture/gather-v33.sqlite"


    private func runNew(_ path: String, fallbackDir: String?) async throws {
        let database = try SQLiteDatabase(path: path)
        try await StoreMigrator(databaseFilePath: path, faceThumbnailFallbackDir: fallbackDir).migrate(database)
        await database.close()
    }

    private func readOnly(_ path: String) throws -> SQLiteDatabase {
        try SQLiteDatabase(path: path, configuration: .init(readOnly: true))
    }


    @Test func realWorldFixtureUpgradesIdentically() async throws {
        guard FileManager.default.fileExists(atPath: Self.fixturePath) else { return }
        let legacyPath = storeTempPath("legacy-fixture")
        let newPath = storeTempPath("new-fixture")
        let legacyThumbs = storeTempDir("thumbs-legacy")
        let newThumbs = storeTempDir("thumbs-new")
        defer {
            removeStoreFiles(legacyPath)
            removeStoreFiles(newPath)
            for path in [legacyPath, newPath] {
                try? FileManager.default.removeItem(atPath: path + ".restore-tmp")
            }
            removeStoreDirectory(legacyThumbs)
            removeStoreDirectory(newThumbs)
        }
        try FileManager.default.copyItem(atPath: Self.fixturePath, toPath: legacyPath)
        try FileManager.default.copyItem(atPath: Self.fixturePath, toPath: newPath)
        // StoreMigrator 已随 Migrations.swift 退役：真实库 fixture 现以
        // 「同源双跑」验证升级的确定性与幂等（两次迁移结果必须逐字节一致）。
        try await runNew(legacyPath, fallbackDir: legacyThumbs)
        try await runNew(newPath, fallbackDir: newThumbs)

        let legacy = try readOnly(legacyPath)
        let migrated = try readOnly(newPath)
        let legacySchema = try await storeSchemaFingerprint(legacy)
        let newSchema = try await storeSchemaFingerprint(migrated)
        let legacyData = try await storeDataDigest(legacy)
        let newData = try await storeDataDigest(migrated)
        let newVersion = try await migrated.scalarInt("SELECT MAX(version) FROM schema_version")
        await legacy.close()
        await migrated.close()

        #expect(newVersion == 33)
        #expect(newSchema == legacySchema, "真实库升级后结构与旧执行器不一致")
        #expect(newData == legacyData, "真实库升级后数据与旧执行器不一致")
    }

    @Test func migrationIsIdempotent() async throws {
        let path = storeTempPath("idempotent")
        defer { removeStoreFiles(path) }
        let database = try SQLiteDatabase(path: path)
        try await StoreMigrator(databaseFilePath: path).migrate(database)
        let firstSchema = try await storeSchemaFingerprint(database)
        let firstData = try await storeDataDigest(database)

        try await StoreMigrator(databaseFilePath: path).migrate(database)
        let secondSchema = try await storeSchemaFingerprint(database)
        let secondData = try await storeDataDigest(database)
        let version = try await database.scalarInt("SELECT MAX(version) FROM schema_version")
        await database.close()

        #expect(version == 33)
        #expect(firstSchema == secondSchema)
        #expect(firstData == secondData)
    }

    @Test func afterMigrateHookFailureRestoresBackup() async throws {
        guard FileManager.default.fileExists(atPath: Self.fixturePath) else { return }
        let path = storeTempPath("rollback")
        let thumbnailDir = storeTempDir("thumbs-rollback")
        defer {
            removeStoreFiles(path)
            removeStoreDirectory(thumbnailDir)
        }
        try FileManager.default.copyItem(atPath: Self.fixturePath, toPath: path)

        struct HookFailure: Error {}
        let database = try SQLiteDatabase(path: path)
        let migrator = StoreMigrator(
            databaseFilePath: path,
            faceThumbnailFallbackDir: thumbnailDir,
            afterMigrateHook: { throw HookFailure() }
        )
        await #expect(throws: HookFailure.self) {
            try await migrator.migrate(database)
        }

        // 迁移失败 → 从备份恢复：schema 回到 v32，结构与原始 fixture 一致。
        let version = try await database.scalarInt("SELECT MAX(version) FROM schema_version")
        #expect(version == 32)

        let original = try readOnly(Self.fixturePath)
        let expectedSchema = try await storeSchemaFingerprint(original)
        let actualSchema = try await storeSchemaFingerprint(database)
        await original.close()
        await database.close()
        #expect(actualSchema == expectedSchema, "回滚后结构与原始库不一致")
    }
}
