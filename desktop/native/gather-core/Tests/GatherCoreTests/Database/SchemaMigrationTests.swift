// desktop/native/gather-core/Tests/GatherCoreTests/Database/SchemaMigrationTests.swift
// WP6a/WP6b：迁移框架、V1→V2 升级路径与 open 状态机的行为门禁
// （设计 §5.2 的 T1/T2/T3/T5/T6/T8/T9/T10/T12/T13/T14）。
//
// 覆盖：
//   1. V1 文件库 open → 备份 + no-op 迁移 → outcome=.migrated(.v1→.v2)，逐表行数保留；
//   2. 重复 open：outcome=.opened(.v2)、不新增备份、行数不变；
//   3. production 目录：current=.v2、V1→V2 一步、plan(v2) 为空、migrate no-op；
//   4. 迁移注入失败：抛 .migration、user_version 仍为 1、新列不存在、备份保留；
//   5. newer(v3)：默认 .versionUnsupported 且主库字节不变；显式 reset 才改名重建；
//   6. V0 有表（legacyPreV1）/ V1 缺列（370）：默认 .corrupt，不迁移、不产生备份；
//   7. 备份是有效 V1 快照（header / quick_check / user_version / 行数）且最多保留 3 套；
//   8. shape 指纹显式钉死 43/373/69/62 与 7c7e…（V1/V2 同形）；
//   9. transaction(.immediate/.exclusive) 与默认 deferred 语义一致，嵌套仍 SAVEPOINT。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence

private struct MigrationTestError: Error {}

private let expectedV1Fingerprint =
    "7c7e0d143f93951e5c68fa07b962c65f157750f11bd638950c0931e5e0ee44c2"

private let seededTables = ["sessions", "photos", "deliveries", "delivery_items"]

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
        VALUES (?, 'wp6b', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(id)])
}

private func rowCounts(_ db: DBConnection) throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for table in seededTables {
        counts[table] = try scalarInt(db, "SELECT COUNT(*) FROM \(table)")
    }
    return counts
}

/// 造一份完整 V1 文件库并写入 2 session / 1 photo / 1 delivery / 1 delivery_item。
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
        INSERT INTO delivery_items (delivery_id, photo_id, module, created_at, updated_at)
        SELECT id, 'p-1', 'metadata', 't', 't' FROM deliveries;
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

/// 迁移失败注入：先改 DDL 再抛错，证明事务把 DDL 与 user_version 一起回滚。
private struct FailingMigrationV1ToV2: SchemaMigration {
    let from: SchemaVersion = .v1
    let to: SchemaVersion = .v2
    let name = "test-failing-v1-to-v2"

    func apply(_ connection: DBConnection) throws {
        try connection.exec("ALTER TABLE sessions ADD COLUMN migration_probe TEXT;")
        throw MigrationTestError()
    }
}

private func catalog(with migration: any SchemaMigration) -> SchemaCatalog {
    SchemaCatalog(
        current: .v2,
        snapshots: [
            .v1: SchemaSnapshot(version: .v1, ddl: SchemaV1.ddl, shape: SchemaV1.shape),
            .v2: SchemaSnapshot(version: .v2, ddl: SchemaV2.ddl, shape: SchemaV2.shape),
        ],
        migrations: [migration]
    )
}

@Suite("SchemaMigrationTests")
struct SchemaMigrationTests {

    @Test("V1 文件库 → 备份 + no-op 迁移：outcome=.migrated(v1→v2)，逐表行数保留")
    func v1OpenMigratesAndRetainsData() throws {
        let directory = try makeTemporaryDirectory("v1-migrate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)

        let source = try DBConnection(path: path)
        let before = try rowCounts(source)
        #expect(try userVersion(source) == 1)
        source.close()

        let database = try Database.open(at: path)
        defer { database.close() }

        guard case .migrated(let from, let to, let backup) = database.outcome else {
            Issue.record("V1 文件库必须走 .migrated，实际 \(database.outcome)")
            return
        }
        #expect(from == .v1)
        #expect(to == .v2)
        let backupPath = try #require(backup, "V1→V2 必须留下迁移前备份")
        #expect(FileManager.default.fileExists(atPath: backupPath))
        #expect(try userVersion(database.connection) == 2)
        #expect(try rowCounts(database.connection) == before, "迁移必须保留全部行")
        #expect(try tableCount(database.connection) == 43)
        #expect(try migrationBackups(in: directory).count == 1, "一次迁移只产生一套备份")
        #expect(try incompatibleCopies(in: directory).isEmpty, "迁移不是 reset，不得产生 incompatible 副本")
    }

    @Test("V1→V2 幂等：重复 open 为 opened(.v2)，不新增备份，行数不变")
    func repeatedOpenAfterMigrationIsIdempotent() throws {
        let directory = try makeTemporaryDirectory("v2-reopen")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)

        let first = try Database.open(at: path)
        first.close()
        let backupsAfterMigration = try migrationBackups(in: directory)
        #expect(backupsAfterMigration.count == 1)

        let second = try Database.open(at: path)
        defer { second.close() }
        #expect(second.outcome == .opened(.v2))
        #expect(try userVersion(second.connection) == 2)
        #expect(try rowCounts(second.connection) == [
            "sessions": 2, "photos": 1, "deliveries": 1, "delivery_items": 1,
        ])
        #expect(try migrationBackups(in: directory) == backupsAfterMigration, "重复 open 不得新增备份")

        let third = try Database.open(at: path)
        third.close()
        #expect(try migrationBackups(in: directory) == backupsAfterMigration)
    }

    @Test("production 目录：current=.v2、V1→V2 一步、plan(v2) 为空、migrate no-op")
    func productionCatalogRegistersVersionOnlyV2() throws {
        let catalog = SchemaCatalog.production
        #expect(catalog.current == .v2)
        #expect(SchemaSQL.currentSchemaVersion == catalog.current.rawValue)
        #expect(SchemaV1.userVersion == 1, "V1 快照必须停在 1")
        #expect(SchemaV2.version == .v2)
        #expect(SchemaV2.ddl == SchemaV1.ddl, "V2 是纯版本位，DDL 必须与 V1 逐字相同")
        #expect(SchemaV2.shape == SchemaV1.shape)
        #expect(catalog.migrations.count == 1)
        let migration = try #require(catalog.migrations.first)
        #expect(migration.from == .v1)
        #expect(migration.to == .v2)
        #expect(migration.name == "v2-version-only")
        #expect(catalog.currentSnapshot.version == .v2)
        #expect(catalog.currentSnapshot.shape == SchemaV1.shape)
        try catalog.validate()
        #expect(try catalog.plan(from: .v1).count == 1)
        #expect(try catalog.plan(from: .v2).isEmpty)

        do {
            _ = try catalog.plan(from: SchemaVersion(3))
            Issue.record("plan(from: v3) 必须抛 .migration")
        } catch let error as DatabaseError {
            #expect(error.kind == .migration)
        }

        let database = try Database.openInMemory()
        defer { database.close() }
        #expect(database.outcome == .created(.v2))
        #expect(try userVersion(database.connection) == 2)
        #expect(try tableCount(database.connection) == 43)
        let target = try SchemaMigrator(catalog: catalog)
            .migrate(database.connection, from: .v2, path: Database.inMemoryPath)
        #expect(target == .v2)
        #expect(try userVersion(database.connection) == 2)
    }

    @Test("迁移失败回滚：抛 .migration、user_version 仍 1、新列不存在、备份保留")
    func failedMigrationRollsBackAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory("v1-fail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)

        do {
            _ = try Database.open(at: path, options: Database.Options(catalog: catalog(with: FailingMigrationV1ToV2())))
            Issue.record("失败迁移必须抛错")
        } catch let error as DatabaseError {
            #expect(error.kind == .migration)
        }

        #expect(try migrationBackups(in: directory).count == 1, "失败迁移也必须保留备份")
        #expect(try incompatibleCopies(in: directory).isEmpty, "迁移失败不得 reset 用户库")

        do {
            let raw = try DBConnection(path: path)
            defer { raw.close() }
            #expect(try userVersion(raw) == 1, "事务回滚后库必须仍停在 V1")
            #expect(try tableColumnCount(raw, table: "sessions") == 10, "注入的列必须随事务回滚")
            #expect(try rowCounts(raw) == [
                "sessions": 2, "photos": 1, "deliveries": 1, "delivery_items": 1,
            ])
            #expect(try SchemaV1.shape.issues(against: SchemaShapeReader.read(raw)).isEmpty)
        }

        // 失败后下次启动仍可重试：production 目录迁移成功并保留数据。
        let retried = try Database.open(at: path)
        defer { retried.close() }
        guard case .migrated(let retryFrom, let retryTo, let retryBackup) = retried.outcome else {
            Issue.record("失败后的重试必须成功迁移，实际 \(retried.outcome)")
            return
        }
        #expect(retryFrom == .v1)
        #expect(retryTo == .v2)
        #expect(retryBackup != nil)
        #expect(try userVersion(retried.connection) == 2)
        #expect(try rowCounts(retried.connection)["sessions"] == 2)
    }

    @Test("user_version=3：默认 .versionUnsupported 且主库字节不变；显式 reset 才改名重建")
    func newerVersionFailsClosedWithoutTouchingFiles() throws {
        let directory = try makeTemporaryDirectory("newer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)
        do {
            let db = try DBConnection(path: path)
            try db.exec("PRAGMA user_version = 3;")
            db.close()
        }
        let before = try dataOfFile(path)

        do {
            _ = try Database.open(at: path)
            Issue.record("v3 默认必须 fail closed")
        } catch let error as DatabaseError {
            #expect(error.kind == .versionUnsupported)
        }
        #expect(try dataOfFile(path) == before, "默认路径不得改动主库字节")
        #expect(try incompatibleCopies(in: directory).isEmpty, "默认路径不得改名")
        #expect(try migrationBackups(in: directory).isEmpty, "版本更高不得迁移/备份")

        // 文件仍是 v3 且数据还在（用裸连接只读确认）。
        do {
            let raw = try DBConnection(path: path)
            defer { raw.close() }
            #expect(try userVersion(raw) == 3)
            #expect(try scalarInt(raw, "SELECT COUNT(*) FROM sessions") == 2)
        }

        let database = try Database.open(
            at: path,
            options: Database.Options(resetPolicy: .renameToIncompatible)
        )
        defer { database.close() }
        #expect(try userVersion(database.connection) == 2)
        #expect(try tableCount(database.connection) == 43)
        #expect(try scalarInt(database.connection, "SELECT COUNT(*) FROM sessions") == 0)
        guard case .reset(let reason, let previousVersion, let backup) = database.outcome else {
            Issue.record("显式 reset 必须报告 .reset，实际 \(database.outcome)")
            return
        }
        #expect(reason == .newerVersion(3))
        #expect(previousVersion == 3)
        #expect(FileManager.default.fileExists(atPath: backup))
        let renamed = try incompatibleCopies(in: directory)
            .filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        #expect(renamed.count == 1, "旧库必须改名保留：\(renamed)")
    }

    @Test("V0 有表：默认 .corrupt 不改文件、不迁移；显式 reset 才改名重建")
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
        #expect(try migrationBackups(in: directory).isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))

        let database = try Database.open(
            at: path,
            options: Database.Options(resetPolicy: .renameToIncompatible)
        )
        defer { database.close() }
        #expect(try tableCount(database.connection) == 43)
        #expect(try userVersion(database.connection) == 2)
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

    @Test("v1 缺 3 列（370）：默认 .corrupt 且不迁移；显式 reset 保留旧副本")
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
        #expect(try migrationBackups(in: directory).isEmpty, "形态不符不得迁移/备份")
        #expect(try dataOfFile(path).count > 0)

        let database = try Database.open(
            at: path,
            options: Database.Options(resetPolicy: .renameToIncompatible)
        )
        defer { database.close() }
        #expect(try tableCount(database.connection) == 43)
        #expect(try tableColumnCount(database.connection, table: "similarity_cluster_meta") == 11)
        #expect(try userVersion(database.connection) == 2)
        #expect(try scalarInt(database.connection, "SELECT COUNT(*) FROM sessions") == 0)
        guard case .reset(let reason, let previousVersion, let backup) = database.outcome else {
            Issue.record("显式 reset 必须报告 .reset，实际 \(database.outcome)")
            return
        }
        #expect(reason == .shapeMismatch(version: 1))
        #expect(previousVersion == 1)
        #expect(FileManager.default.fileExists(atPath: backup))
    }

    @Test("迁移备份是有效 V1 快照：header / quick_check / user_version / 行数")
    func migrationBackupIsValidV1Snapshot() throws {
        let directory = try makeTemporaryDirectory("backup-valid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)
        let source = try DBConnection(path: path)
        let before = try rowCounts(source)
        source.close()

        let database = try Database.open(at: path)
        guard case .migrated(_, _, let backup?) = database.outcome else {
            Issue.record("必须产生迁移备份，实际 \(database.outcome)")
            database.close()
            return
        }
        database.close()

        #expect(try Data(contentsOf: URL(fileURLWithPath: backup)).prefix(16)
                == Data("SQLite format 3\u{0}".utf8))
        let raw = try DBConnection(path: backup)
        defer { raw.close() }
        #expect(try userVersion(raw) == 1, "备份必须是迁移前 V1")
        #expect(try rowCounts(raw) == before)
        let quickCheck = try raw.prepare("PRAGMA quick_check;").get([])?[0].textValue
        #expect(quickCheck == "ok")
    }

    @Test("迁移备份最多保留 3 套（反复降级→迁移）")
    func migrationBackupsRetainThreeCopies() throws {
        let directory = try makeTemporaryDirectory("backup-retain")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)

        for _ in 0..<4 {
            let database = try Database.open(at: path)
            guard case .migrated = database.outcome else {
                Issue.record("每轮都必须迁移，实际 \(database.outcome)")
                database.close()
                return
            }
            database.close()
            let raw = try DBConnection(path: path)
            try raw.exec("PRAGMA user_version = 1;")
            raw.close()
        }

        let backups = try migrationBackups(in: directory)
            .filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        #expect(backups.count == 3, "retainMigrationBackups 默认 3，实际 \(backups)")
    }

    @Test("shape 指纹显式钉死：V1/V2 同为 43/373/69/62 与 7c7e…")
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
        #expect(SchemaV2.shape.fingerprint == expectedV1Fingerprint)
        #expect(SchemaCatalog.production.currentSnapshot.shape.fingerprint == expectedV1Fingerprint)
        #expect(SchemaV1.shape.issues(against: snapshot).isEmpty)

        // V1 夹具（SchemaV1.sql）形态必须与 V2 完全相同：只有 user_version 不同。
        let v1 = try DBConnection(path: ":memory:")
        defer { v1.close() }
        try v1.exec(SchemaV1.sql)
        let v1Snapshot = try SchemaShapeReader.read(v1)
        #expect(SchemaV1.shape.issues(against: v1Snapshot).isEmpty)
        #expect(try userVersion(v1) == 1)
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
