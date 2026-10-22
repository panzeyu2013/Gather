// desktop/native/gather-core/Tests/GatherCoreTests/Database/SchemaMigrationTests.swift
// WP6a：迁移框架与 open 状态机的行为门禁（设计 §5.2 的 T2/T5/T6/T7/T8/T11/T14 子集）。
//
// 覆盖：
//   1. V1 文件库 open 保留数据、outcome=.opened(.v1)、重复 open 幂等且不产生备份；
//   2. production 目录 current=.v1 / 迁移表为空 / plan 为空 / migrate 是 no-op；
//   3. newer(v99) 默认 .versionUnsupported，主库字节不变、不改名；显式 reset 才改名；
//   4. V0 有表（legacyPreV1）默认 .corrupt，显式 reset 才改名重建；
//   5. v1 缺列（370）默认 .corrupt 且报列形原因；显式 reset 保留旧副本；
//   6. shape 指纹显式钉死 43/373/69/62 与 7c7e…（失败信息带 expected/actual）；
//   7. transaction(.immediate/.exclusive) 与默认 deferred 语义一致，嵌套仍 SAVEPOINT。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence

private struct MigrationTestError: Error {}

private let expectedV1Fingerprint =
    "7c7e0d143f93951e5c68fa07b962c65f157750f11bd638950c0931e5e0ee44c2"

private func makeTemporaryDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-schema-migration-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func databasePath(in directory: URL) -> String {
    directory.appendingPathComponent("gather.sqlite").path
}

private func scalarInt(_ db: DBConnection, _ sql: String) throws -> Int {
    guard let raw = try db.prepare(sql).get([])?[0].intValue else {
        throw DBError.message("标量查询无结果: \(sql)")
    }
    return Int(raw)
}

private func userVersion(_ db: DBConnection) throws -> Int {
    try scalarInt(db, "PRAGMA user_version")
}

private func tableCount(_ db: DBConnection) throws -> Int {
    try scalarInt(db, """
        SELECT COUNT(*) FROM sqlite_master
         WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        """)
}

private func tableColumnCount(_ db: DBConnection, table: String) throws -> Int {
    try db.prepare("PRAGMA table_info('\(table)');").query([]).count
}

private func insertSession(_ db: DBConnection, id: String) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, created_at, updated_at)
        VALUES (?, 'wp6a', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(id)])
}

/// 造一份完整 V1 文件库并写入 2 session / 1 photo / 1 delivery。
private func seedV1Database(at path: String) throws {
    let db = try DBConnection(path: path)
    defer { db.close() }
    try db.exec(SchemaV1.sql)
    try insertSession(db, id: "s-1")
    try insertSession(db, id: "s-2")
    try db.exec("""
        INSERT INTO photos (id, session_id, filepath, created_at, updated_at)
        VALUES ('p-1', 's-1', '/photos/p-1.NEF', 't', 't');
        INSERT INTO deliveries (xmp_path, created_at, updated_at)
        VALUES ('/photos/p-1.xmp', 't', 't');
        """)
}

private func incompatibleCopies(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("gather.sqlite.incompatible-") }
}

private func migrationBackups(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("gather.sqlite.pre-v") }
}

private func dataOfFile(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

@Suite("SchemaMigrationTests")
struct SchemaMigrationTests {

    @Test("V1 文件库 open 保留数据：outcome=.opened(.v1)，重复 open 幂等且无迁移备份")
    func v1OpenRetainsDataAndIsIdempotent() throws {
        let directory = try makeTemporaryDirectory("v1-retain")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)

        let first = try Database.open(at: path)
        #expect(first.outcome == .opened(.v1))
        #expect(try userVersion(first.connection) == 1)
        #expect(try scalarInt(first.connection, "SELECT COUNT(*) FROM sessions") == 2)
        #expect(try scalarInt(first.connection, "SELECT COUNT(*) FROM photos") == 1)
        #expect(try scalarInt(first.connection, "SELECT COUNT(*) FROM deliveries") == 1)
        #expect(try incompatibleCopies(in: directory).isEmpty)
        #expect(try migrationBackups(in: directory).isEmpty)
        first.close()

        let second = try Database.open(at: path)
        defer { second.close() }
        #expect(second.outcome == .opened(.v1), "已迁移/已就绪的库重开必须是 opened")
        #expect(try scalarInt(second.connection, "SELECT COUNT(*) FROM sessions") == 2)
        #expect(try scalarInt(second.connection, "SELECT COUNT(*) FROM photos") == 1)
        #expect(try migrationBackups(in: directory).isEmpty, "重复 open 不得新增备份")
    }

    @Test("production 目录：current=.v1、迁移表为空、plan 为空、migrate 是 no-op")
    func productionCatalogHasEmptyMigrationPlan() throws {
        let catalog = SchemaCatalog.production
        #expect(catalog.current == .v1)
        #expect(SchemaSQL.currentSchemaVersion == catalog.current.rawValue)
        #expect(SchemaV1.userVersion == catalog.current.rawValue)
        #expect(catalog.migrations.isEmpty)
        #expect(catalog.currentSnapshot.version == .v1)
        #expect(catalog.currentSnapshot.shape == SchemaV1.shape)
        try catalog.validate()
        #expect(try catalog.plan(from: .v1).isEmpty)

        do {
            _ = try catalog.plan(from: .v2)
            Issue.record("plan(from: v2) 必须抛 .migration")
        } catch let error as DatabaseError {
            #expect(error.kind == .migration)
        }

        let database = try Database.openInMemory()
        defer { database.close() }
        let target = try SchemaMigrator(catalog: catalog)
            .migrate(database.connection, from: .v1, path: Database.inMemoryPath)
        #expect(target == .v1)
        #expect(try userVersion(database.connection) == 1)
        #expect(try tableCount(database.connection) == 43)
    }

    @Test("user_version=99：默认 .versionUnsupported 且主库字节不变；显式 reset 才改名重建")
    func newerVersionFailsClosedWithoutTouchingFiles() throws {
        let directory = try makeTemporaryDirectory("newer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)
        do {
            let db = try DBConnection(path: path)
            try db.exec("PRAGMA user_version = 99;")
            db.close()
        }
        let before = try dataOfFile(path)

        do {
            _ = try Database.open(at: path)
            Issue.record("v99 默认必须 fail closed")
        } catch let error as DatabaseError {
            #expect(error.kind == .versionUnsupported)
        }
        #expect(try dataOfFile(path) == before, "默认路径不得改动主库字节")
        #expect(try incompatibleCopies(in: directory).isEmpty, "默认路径不得改名")

        // 文件仍是 v99 且数据还在（用裸连接只读确认）。
        do {
            let raw = try DBConnection(path: path)
            defer { raw.close() }
            #expect(try userVersion(raw) == 99)
            #expect(try scalarInt(raw, "SELECT COUNT(*) FROM sessions") == 2)
        }

        let database = try Database.open(
            at: path,
            options: Database.Options(resetPolicy: .renameToIncompatible)
        )
        defer { database.close() }
        #expect(try userVersion(database.connection) == 1)
        #expect(try tableCount(database.connection) == 43)
        #expect(try scalarInt(database.connection, "SELECT COUNT(*) FROM sessions") == 0)
        guard case .reset(let reason, let previousVersion, let backup) = database.outcome else {
            Issue.record("显式 reset 必须报告 .reset，实际 \(database.outcome)")
            return
        }
        #expect(reason == .newerVersion(99))
        #expect(previousVersion == 99)
        #expect(FileManager.default.fileExists(atPath: backup))
        let renamed = try incompatibleCopies(in: directory)
            .filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        #expect(renamed.count == 1, "旧库必须改名保留：\(renamed)")
    }

    @Test("V0 有表：默认 .corrupt 不改文件；显式 reset 才改名重建（旧表不复活）")
    func legacyPreV1FailsClosedByDefault() throws {
        let directory = try makeTemporaryDirectory("legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        do {
            let legacy = try DBConnection(path: path)
            try legacy.exec("CREATE TABLE legacy_marker (id INTEGER PRIMARY KEY, note TEXT);")
            try legacy.exec("INSERT INTO legacy_marker (note) VALUES ('must-not-survive');")
            legacy.close()
        }

        do {
            _ = try Database.open(at: path)
            Issue.record("V0 有表默认必须抛 .corrupt")
        } catch let error as DatabaseError {
            #expect(error.kind == .corrupt)
        }
        #expect(try incompatibleCopies(in: directory).isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))

        let database = try Database.open(
            at: path,
            options: Database.Options(resetPolicy: .renameToIncompatible)
        )
        defer { database.close() }
        #expect(try tableCount(database.connection) == 43)
        #expect(try scalarInt(database.connection, """
            SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'legacy_marker'
            """) == 0, "旧表不得复活")
        guard case .reset(let reason, let previousVersion, let backup) = database.outcome else {
            Issue.record("显式 reset 必须报告 .reset，实际 \(database.outcome)")
            return
        }
        #expect(reason == .legacyPreV1)
        #expect(previousVersion == 0)
        #expect(FileManager.default.fileExists(atPath: backup))
    }

    @Test("v1 缺 3 列（370）：默认 .corrupt 且 issue 可读；显式 reset 保留旧副本")
    func v1ShapeMismatchFailsClosedAndReportsIssue() throws {
        let directory = try makeTemporaryDirectory("shape")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        do {
            let legacy = try DBConnection(path: path)
            try legacy.exec(SchemaV1.sql)
            try legacy.exec("ALTER TABLE similarity_cluster_meta DROP COLUMN algorithm_version;")
            try legacy.exec("ALTER TABLE similarity_cluster_meta DROP COLUMN input_signature;")
            try legacy.exec("ALTER TABLE similarity_cluster_meta DROP COLUMN state_digest;")
            try insertSession(legacy, id: "legacy-session")
            legacy.close()
        }

        do {
            let raw = try DBConnection(path: path)
            defer { raw.close() }
            #expect(try tableColumnCount(raw, table: "similarity_cluster_meta") == 8)
            let snapshot = try SchemaShapeReader.read(raw)
            #expect(snapshot.columnCount == 370)
            #expect(snapshot.fingerprint != expectedV1Fingerprint)
            let issues = SchemaV1.shape.issues(against: snapshot)
            #expect(issues.contains { $0.contains("列数 370，期望 373") })
            #expect(issues.contains { $0.contains("similarity_cluster_meta") && $0.contains("缺列") })
            #expect(issues.contains { $0.contains("列形指纹") && $0.contains(expectedV1Fingerprint) })
        }

        do {
            _ = try Database.open(at: path)
            Issue.record("形态不符默认必须抛 .corrupt")
        } catch let error as DatabaseError {
            #expect(error.kind == .corrupt)
            #expect(error.message.contains("列形") || error.message.contains("列数"))
        }
        #expect(try incompatibleCopies(in: directory).isEmpty)
        #expect(try dataOfFile(path).count > 0)

        let database = try Database.open(
            at: path,
            options: Database.Options(resetPolicy: .renameToIncompatible)
        )
        defer { database.close() }
        #expect(try tableCount(database.connection) == 43)
        #expect(try tableColumnCount(database.connection, table: "similarity_cluster_meta") == 11)
        #expect(try scalarInt(database.connection, "SELECT COUNT(*) FROM sessions") == 0)
        guard case .reset(let reason, let previousVersion, let backup) = database.outcome else {
            Issue.record("显式 reset 必须报告 .reset，实际 \(database.outcome)")
            return
        }
        #expect(reason == .shapeMismatch(version: 1))
        #expect(previousVersion == 1)
        #expect(FileManager.default.fileExists(atPath: backup))
    }

    @Test("shape 指纹显式钉死：43/373/69/62 与 7c7e… 完全一致")
    func shapeFingerprintIsPinned() throws {
        let database = try Database.openInMemory()
        defer { database.close() }
        let snapshot = try SchemaShapeReader.read(database.connection)

        #expect(snapshot.tableCount == 43)
        #expect(snapshot.columnCount == 373)
        #expect(snapshot.explicitIndexCount == 69)
        #expect(snapshot.foreignKeyCount == 62)
        #expect(snapshot.fingerprint == expectedV1Fingerprint)
        #expect(SchemaV1.shape.fingerprint == expectedV1Fingerprint)
        #expect(SchemaCatalog.production.currentSnapshot.shape.fingerprint == expectedV1Fingerprint)
        #expect(SchemaV1.shape.issues(against: snapshot).isEmpty)
    }

    @Test("transaction(.immediate/.exclusive)：提交/回滚与默认 deferred 一致，嵌套仍 SAVEPOINT")
    func transactionModesPreserveSemantics() throws {
        let db = try DBConnection(path: ":memory:")
        defer { db.close() }
        try db.exec(SchemaV1.sql)

        try db.transaction(.immediate) { try insertSession(db, id: "immediate") }
        try db.transaction(.exclusive) { try insertSession(db, id: "exclusive") }
        try db.transaction { try insertSession(db, id: "deferred") }

        do {
            try db.transaction(.immediate) {
                try insertSession(db, id: "rolled-back")
                throw MigrationTestError()
            }
            Issue.record("immediate 事务体内抛错必须回滚")
        } catch is MigrationTestError {}
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM sessions") == 3)

        try db.transaction(.immediate) {
            try insertSession(db, id: "outer")
            do {
                try db.transaction {
                    try insertSession(db, id: "inner-rolled-back")
                    throw MigrationTestError()
                }
            } catch is MigrationTestError {
                // 内层 SAVEPOINT 已回滚；外层继续。
            }
            try insertSession(db, id: "outer-2")
        }
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM sessions") == 5)
        #expect(try db.prepare("SELECT id FROM sessions WHERE id = 'inner-rolled-back'").get([]) == nil)
    }
}
