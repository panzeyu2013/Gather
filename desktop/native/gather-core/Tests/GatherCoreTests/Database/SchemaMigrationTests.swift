// desktop/native/gather-core/Tests/GatherCoreTests/Database/SchemaMigrationTests.swift
// WP6a/WP6b：迁移框架、V1→V2 升级路径与 open 状态机的行为门禁
// （设计 §5.2 的 T1/T2/T3/T5/T6/T8/T9/T10/T12/T13/T14）。
//
// 覆盖：
//   1. V1 文件库 open → 备份 + no-op 迁移 → outcome=.migrated(.v1→.v2)，逐表行数保留；
//   2. 重复 open：outcome=.opened(.v2)、不新增备份、行数不变；
//   3. production 目录：current=.v2、V1→V2 一步、plan(v2) 为空、migrate no-op；
//   4. 迁移注入失败：抛 .migration、user_version 仍为 1、新列不存在、备份保留；
//   4b. 提交前两道 guard 的失败注入：迁移后 FK 违规 / 目标形态不符（catalog 写错或
//       注入 DDL）都整体回滚、旧库可读、备份保留、下次启动可重试；
//   5. newer(v3)：默认 .versionUnsupported 且主库字节不变；显式 reset 才改名重建；
//   6. 已知 370 列旧 V1：走 .migrated，ALTER 补三列且保留数据/备份；V0 有表与
//      未知 V1 列形仍默认 .corrupt，不迁移、不产生备份；
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

/// Cut 5 之前的 370 列旧 V1 指纹（373 canonical 去掉三行列）。
private let expectedLegacyV1Fingerprint =
    "7fb85cbfe010055f23e6dc37f385a1910f446c19e8b3c7bb8a81d9c42be68e91"

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

/// 造一份 Cut 5 之前的 370 列旧 V1（user_version=1，similarity_cluster_meta 缺
/// 状态版本化三列），并写入一个 session + 一行 8 列 meta。
private func seedLegacyV1Database(at path: String) throws {
    let db = try DBConnection(path: path)
    defer { db.close() }
    try db.exec(SchemaV1.sql)
    try db.exec("""
        ALTER TABLE similarity_cluster_meta DROP COLUMN algorithm_version;
        ALTER TABLE similarity_cluster_meta DROP COLUMN input_signature;
        ALTER TABLE similarity_cluster_meta DROP COLUMN state_digest;
        """)
    try insertSession(db, id: "legacy-session")
    try db.exec("""
        INSERT INTO similarity_cluster_meta
            (session_id, param_threshold, grouping_mode, updated_at)
        VALUES ('legacy-session', 32, 'sequential', 't');
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

/// 370 列旧 V1 的补列失败注入：先补第一列再抛错，证明 ALTER 与 user_version
/// 一起回滚，库仍停在 8 列的旧 V1。
private struct PartialLegacyMigrationV1ToV2: SchemaMigration {
    let from: SchemaVersion = .v1
    let to: SchemaVersion = .v2
    let name = "test-partial-legacy-v1-to-v2"

    func apply(_ connection: DBConnection) throws {
        try connection.exec("""
            ALTER TABLE similarity_cluster_meta
            ADD COLUMN algorithm_version INTEGER NOT NULL DEFAULT 1 CHECK (algorithm_version >= 1);
            """)
        throw MigrationTestError()
    }
}

/// 迁移后 FK 违规注入：迁移器在 BEGIN 前已把 foreign_keys 置 OFF，事务内插入孤儿
/// 照片能成功；提交前的 `PRAGMA foreign_key_check` 是唯一拦截点。
private struct ForeignKeyViolatingMigration: SchemaMigration {
    let from: SchemaVersion = .v1
    let to: SchemaVersion = .v2
    let name = "test-fk-violating-v1-to-v2"

    func apply(_ connection: DBConnection) throws {
        try connection.exec("""
            INSERT INTO photos (id, session_id, filepath, created_at, updated_at)
            VALUES ('orphan-photo', 'missing-session', '/photos/orphan.NEF', 't', 't');
            """)
    }
}

/// 迁移后形态不符注入：真实加一列（373→374），目标快照仍按生产 V2 校验。
private struct ExtraColumnMigration: SchemaMigration {
    let from: SchemaVersion = .v1
    let to: SchemaVersion = .v2
    let name = "test-extra-column-v1-to-v2"

    func apply(_ connection: DBConnection) throws {
        try connection.exec("ALTER TABLE sessions ADD COLUMN migration_extra TEXT;")
    }
}

/// 故意写错的目标形态（列数 +1）：证明迁移器用 catalog 的 expectation 校验，
/// 而不是只看 user_version。
private let mismatchedV2Shape = SchemaShapeExpectation(
    tableCount: SchemaV1.expectedTableCount,
    columnCount: SchemaV1.expectedColumnCount + 1,
    explicitIndexCount: SchemaV1.expectedExplicitIndexCount,
    foreignKeyCount: SchemaV1.expectedForeignKeyCount,
    requiredColumns: SchemaV1.requiredTableColumns,
    fingerprint: SchemaV1.expectedShapeFingerprint
)

private func catalog(
    with migration: any SchemaMigration,
    targetShape: SchemaShapeExpectation = SchemaV2.shape
) -> SchemaCatalog {
    SchemaCatalog(
        current: .v2,
        snapshots: [
            .v1: SchemaSnapshot(version: .v1, ddl: SchemaV1.ddl, shape: SchemaV1.shape),
            .v2: SchemaSnapshot(version: .v2, ddl: SchemaV2.ddl, shape: targetShape),
        ],
        migrations: [migration]
    )
}

/// 断言文件仍是 SQLite 库（备份/改名副本的 header 校验；不打开文件，避免 sidecar）。
private func expectSQLiteFile(_ path: String) throws {
    #expect(FileManager.default.fileExists(atPath: path))
    let prefix = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(16)
    #expect(prefix == Data("SQLite format 3\u{0}".utf8), "不是 SQLite 文件：\(path)")
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
        // 成功路径也要从迁移后的用户库侧确认两道 guard 的前置条件成立：
        // FK 开关已恢复、foreign_key_check 为空、目标形态无 issue。
        #expect(try database.read { try scalarInt($0, "PRAGMA foreign_keys") } == 1,
                "迁移后必须恢复连接级 foreign_keys=ON")
        #expect(try database.read { try $0.prepare("PRAGMA foreign_key_check;").query([]).isEmpty },
                "迁移成功后 foreign_key_check 必须为空")
        #expect(try SchemaV2.shape.issues(against: SchemaShapeReader.read(database.connection)).isEmpty,
                "迁移成功后列形必须与 V2 快照一致")
        #expect(try migrationBackups(in: directory).count == 1, "一次迁移只产生一套备份")
        #expect(try incompatibleCopies(in: directory).isEmpty, "迁移不是 reset，不得产生 incompatible 副本")
    }

    @Test("370 列旧 V1（Cut 5 之前）→ 备份 + ALTER 三列 → V2，session 与默认值保留")
    func legacyV1With370ColumnsMigratesAndRetainsData() throws {
        let directory = try makeTemporaryDirectory("legacy-v1-migrate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedLegacyV1Database(at: path)

        do {
            let raw = try DBConnection(path: path)
            defer { raw.close() }
            #expect(try userVersion(raw) == 1)
            #expect(try tableColumnCount(raw, table: "similarity_cluster_meta") == 8)
            let shape = try SchemaShapeReader.read(raw)
            #expect(shape.columnCount == 370)
            #expect(shape.fingerprint == expectedLegacyV1Fingerprint)
            #expect(HistoricalV1Shape.shape.issues(against: shape).isEmpty,
                    "370 列旧 V1 必须被识别为已知旧形")
            #expect(try SchemaInspector.inspect(raw, catalog: .production, path: path) == .older(.v1),
                    "370 列旧 V1 必须判 .older(.v1)，而不是 corrupt")
            #expect(SchemaV1.shape.issues(against: shape).contains { $0.contains("列数 370") })
        }

        let database = try Database.open(at: path)
        defer { database.close() }

        guard case .migrated(let from, let to, let backup) = database.outcome else {
            Issue.record("370 列旧 V1 必须走 .migrated，实际 \(database.outcome)")
            return
        }
        #expect(from == .v1)
        #expect(to == .v2)
        #expect(backup != nil, "迁移前必须有备份")
        #expect(try userVersion(database.connection) == 2)
        #expect(try tableColumnCount(database.connection, table: "similarity_cluster_meta") == 11)
        #expect(try SchemaV1.shape.issues(against: SchemaShapeReader.read(database.connection)).isEmpty,
                "补列后必须回到 373 列 V2 形态")
        #expect(try scalarInt(database.connection, "SELECT COUNT(*) FROM sessions") == 1,
                "迁移必须保留 session 数据")
        #expect(try scalarInt(database.connection, "SELECT COUNT(*) FROM similarity_cluster_meta") == 1)

        let meta = try database.connection.prepare("""
            SELECT algorithm_version, input_signature, state_digest
              FROM similarity_cluster_meta WHERE session_id = 'legacy-session'
            """).get([])
        #expect(meta?[0].intValue == 1, "algorithm_version 默认值必须为 1")
        #expect(meta?[1].textValue == "", "input_signature 默认值必须为空串")
        #expect(meta?[2].textValue == "", "state_digest 默认值必须为空串")

        // CHECK 随 ALTER 一起生效（默认值/约束与 SchemaV1 一致）。
        do {
            try database.write { db in
                _ = try db.prepare("""
                    UPDATE similarity_cluster_meta SET algorithm_version = 0
                     WHERE session_id = 'legacy-session'
                    """).run([])
            }
            Issue.record("algorithm_version >= 1 CHECK 必须在 ALTER 后生效")
        } catch {
            // 期望的约束失败（具体错误码由 Database.write 映射，这里只钉行为）。
        }

        #expect(try migrationBackups(in: directory).count == 1, "370 列旧 V1 也必须留迁移备份")
        #expect(try incompatibleCopies(in: directory).isEmpty, "迁移不是 reset")
    }

    @Test("370 列旧 V1 迁移失败：回滚保持 370/user_version=1、备份保留、可重试")
    func legacyV1FailedMigrationRollsBackAndKeepsBackup() throws {
        let directory = try makeTemporaryDirectory("legacy-v1-fail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedLegacyV1Database(at: path)

        do {
            _ = try Database.open(
                at: path,
                options: Database.Options(catalog: catalog(with: PartialLegacyMigrationV1ToV2()))
            )
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
            #expect(try tableColumnCount(raw, table: "similarity_cluster_meta") == 8,
                    "补列 ALTER 必须随事务回滚")
            #expect(try scalarInt(raw, "SELECT COUNT(*) FROM sessions") == 1)
            #expect(try scalarInt(raw, "SELECT COUNT(*) FROM similarity_cluster_meta") == 1)
        }

        // 失败后下次启动仍可重试：production 目录补列成功并保留数据。
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
        #expect(try tableColumnCount(retried.connection, table: "similarity_cluster_meta") == 11)
        #expect(try scalarInt(retried.connection, "SELECT COUNT(*) FROM sessions") == 1)
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
        #expect(migration.name == "v2-version-and-legacy-v1")
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

    @Test("迁移后 foreign_key_check 违规：抛 .migration、回滚到 V1、备份保留、可重试")
    func foreignKeyViolationAfterMigrationRollsBack() throws {
        let directory = try makeTemporaryDirectory("v1-fk-violation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)
        let expectedRows = ["sessions": 2, "photos": 1, "deliveries": 1, "delivery_items": 1]

        do {
            _ = try Database.open(
                at: path,
                options: Database.Options(catalog: catalog(with: ForeignKeyViolatingMigration()))
            )
            Issue.record("迁移后 foreign_key_check 非空必须抛 .migration")
        } catch let error as DatabaseError {
            #expect(error.kind == .migration)
            #expect(error.message.contains("迁移后 foreign_key_check 发现 1 条违规"),
                    "错误必须明确指出 FK guard，实际：\(error.message)")
        }

        #expect(try incompatibleCopies(in: directory).isEmpty, "迁移失败不得 reset 用户库")
        let backups = try migrationBackups(in: directory)
            .filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        #expect(backups.count == 1, "FK guard 失败也必须保留迁移前备份：\(backups)")
        try expectSQLiteFile(directory.appendingPathComponent(try #require(backups.first)).path)

        do {
            let raw = try DBConnection(path: path)
            defer { raw.close() }
            #expect(try userVersion(raw) == 1, "FK guard 失败后库必须仍停在 V1")
            #expect(try rowCounts(raw) == expectedRows, "回滚不得丢数据")
            #expect(try scalarInt(raw, "SELECT COUNT(*) FROM photos WHERE id = 'orphan-photo'") == 0,
                    "注入的孤儿照片必须随事务回滚")
            #expect(try raw.prepare("PRAGMA foreign_key_check;").query([]).isEmpty,
                    "回滚后的旧库不得留下 FK 违规")
            #expect(try SchemaV1.shape.issues(against: SchemaShapeReader.read(raw)).isEmpty)
        }

        // 失败后下次启动仍可重试：production 目录迁移成功，数据与 FK 都正确。
        let retried = try Database.open(at: path)
        defer { retried.close() }
        guard case .migrated(let from, let to, let backup) = retried.outcome else {
            Issue.record("FK guard 失败后的重试必须成功迁移，实际 \(retried.outcome)")
            return
        }
        #expect(from == .v1)
        #expect(to == .v2)
        #expect(backup != nil)
        #expect(try userVersion(retried.connection) == 2)
        #expect(try rowCounts(retried.connection) == expectedRows)
        #expect(try retried.read { try $0.prepare("PRAGMA foreign_key_check;").query([]).isEmpty })
        #expect(try scalarInt(retried.connection, "SELECT COUNT(*) FROM photos WHERE id = 'orphan-photo'") == 0)
    }

    @Test("迁移后形态与 catalog 不符：抛 .migration、issue 可读、回滚、旧库可重试")
    func catalogShapeMismatchRollsBack() throws {
        let directory = try makeTemporaryDirectory("v2-wrong-shape")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)
        let expectedRows = ["sessions": 2, "photos": 1, "deliveries": 1, "delivery_items": 1]

        do {
            _ = try Database.open(
                at: path,
                options: Database.Options(
                    catalog: catalog(with: MigrationV1ToV2(), targetShape: mismatchedV2Shape)
                )
            )
            Issue.record("迁移后形态与 catalog 不符必须抛 .migration")
        } catch let error as DatabaseError {
            #expect(error.kind == .migration)
            #expect(error.message.contains("迁移后列形与 v2 不符"), "实际：\(error.message)")
            #expect(error.message.contains("列数 373，期望 374"), "issue 必须可读：\(error.message)")
        }

        #expect(try incompatibleCopies(in: directory).isEmpty, "形态 guard 失败不得 reset 用户库")
        let backups = try migrationBackups(in: directory)
            .filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        #expect(backups.count == 1, "形态 guard 失败也必须保留迁移前备份：\(backups)")
        try expectSQLiteFile(directory.appendingPathComponent(try #require(backups.first)).path)

        do {
            let raw = try DBConnection(path: path)
            defer { raw.close() }
            #expect(try userVersion(raw) == 1, "形态 guard 失败后库必须仍停在 V1")
            #expect(try rowCounts(raw) == expectedRows, "回滚不得丢数据")
            #expect(try SchemaV1.shape.issues(against: SchemaShapeReader.read(raw)).isEmpty)
            #expect(try raw.prepare("PRAGMA foreign_key_check;").query([]).isEmpty)
        }

        // 旧库仍可用：换回 production 目录即可完成迁移。
        let retried = try Database.open(at: path)
        defer { retried.close() }
        guard case .migrated(let from, let to, _) = retried.outcome else {
            Issue.record("形态 guard 失败后的重试必须成功迁移，实际 \(retried.outcome)")
            return
        }
        #expect(from == .v1)
        #expect(to == .v2)
        #expect(try userVersion(retried.connection) == 2)
        #expect(try rowCounts(retried.connection) == expectedRows)
        #expect(try SchemaV2.shape.issues(against: SchemaShapeReader.read(retried.connection)).isEmpty)
    }

    @Test("迁移注入额外列导致形态不符：回滚该列、user_version 仍 1、备份保留、可重试")
    func injectedDDLShapeMismatchRollsBack() throws {
        let directory = try makeTemporaryDirectory("v1-extra-column")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        try seedV1Database(at: path)
        let expectedRows = ["sessions": 2, "photos": 1, "deliveries": 1, "delivery_items": 1]

        do {
            _ = try Database.open(
                at: path,
                options: Database.Options(catalog: catalog(with: ExtraColumnMigration()))
            )
            Issue.record("迁移注入额外列必须被目标形态 guard 拦下")
        } catch let error as DatabaseError {
            #expect(error.kind == .migration)
            #expect(error.message.contains("迁移后列形与 v2 不符"), "实际：\(error.message)")
            #expect(error.message.contains("列数 374，期望 373"), "issue 必须可读：\(error.message)")
            #expect(error.message.contains("列形指纹"), "issue 必须包含指纹差异：\(error.message)")
        }

        #expect(try incompatibleCopies(in: directory).isEmpty, "形态 guard 失败不得 reset 用户库")
        let backups = try migrationBackups(in: directory)
            .filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        #expect(backups.count == 1, "形态 guard 失败也必须保留迁移前备份：\(backups)")
        try expectSQLiteFile(directory.appendingPathComponent(try #require(backups.first)).path)

        do {
            let raw = try DBConnection(path: path)
            defer { raw.close() }
            #expect(try userVersion(raw) == 1, "形态 guard 失败后库必须仍停在 V1")
            #expect(try tableColumnCount(raw, table: "sessions") == 10, "注入的列必须随事务回滚")
            let columns = try raw.prepare("PRAGMA table_info('sessions');").query([])
                .compactMap { $0[1].textValue }
            #expect(!columns.contains("migration_extra"))
            #expect(try rowCounts(raw) == expectedRows, "回滚不得丢数据")
            #expect(try SchemaV1.shape.issues(against: SchemaShapeReader.read(raw)).isEmpty)
            #expect(try raw.prepare("PRAGMA foreign_key_check;").query([]).isEmpty)
        }

        // 失败后下次启动仍可重试：production 目录迁移成功，注入列不复活。
        let retried = try Database.open(at: path)
        defer { retried.close() }
        guard case .migrated(let from, let to, _) = retried.outcome else {
            Issue.record("形态 guard 失败后的重试必须成功迁移，实际 \(retried.outcome)")
            return
        }
        #expect(from == .v1)
        #expect(to == .v2)
        #expect(try userVersion(retried.connection) == 2)
        #expect(try tableColumnCount(retried.connection, table: "sessions") == 10)
        #expect(try rowCounts(retried.connection) == expectedRows)
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

    @Test("未知 V1 列形（370 旧形 + 额外列）：默认 .corrupt 且不迁移；显式 reset 保留旧副本")
    func unknownV1ShapeFailsClosedAndReportsIssue() throws {
        let directory = try makeTemporaryDirectory("shape")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)
        do {
            let legacy = try DBConnection(path: path)
            try legacy.exec(SchemaV1.sql)
            try legacy.exec("ALTER TABLE similarity_cluster_meta DROP COLUMN algorithm_version;")
            try legacy.exec("ALTER TABLE similarity_cluster_meta DROP COLUMN input_signature;")
            try legacy.exec("ALTER TABLE similarity_cluster_meta DROP COLUMN state_digest;")
            // 370 的已知旧形之外再加一列未知列：既不是 373，也不是可迁移的 370。
            try legacy.exec("ALTER TABLE sessions ADD COLUMN legacy_unknown_column TEXT;")
            try insertSession(legacy, id: "legacy-session")
            legacy.close()
        }

        do {
            let raw = try DBConnection(path: path)
            defer { raw.close() }
            #expect(try tableColumnCount(raw, table: "similarity_cluster_meta") == 8)
            let snapshot = try SchemaShapeReader.read(raw)
            #expect(snapshot.columnCount == 371)
            #expect(!HistoricalV1Shape.shape.issues(against: snapshot).isEmpty,
                    "额外列必须让 370 旧形识别失败")
            let issues = SchemaV1.shape.issues(against: snapshot)
            #expect(issues.contains { $0.contains("列数 371，期望 373") })
            #expect(issues.contains { $0.contains("similarity_cluster_meta") && $0.contains("缺列") })
            #expect(issues.contains { $0.contains("列形指纹") && $0.contains(expectedV1Fingerprint) })
        }

        do {
            _ = try Database.open(at: path)
            Issue.record("未知形态默认必须抛 .corrupt")
        } catch let error as DatabaseError {
            #expect(error.kind == .corrupt)
            #expect(error.message.contains("列形") || error.message.contains("列数"))
        }
        #expect(try incompatibleCopies(in: directory).isEmpty)
        #expect(try migrationBackups(in: directory).isEmpty, "未知形态不得迁移/备份")
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
        #expect(HistoricalV1Shape.fingerprint == expectedLegacyV1Fingerprint)
        #expect(HistoricalV1Shape.shape.columnCount == 370)
        #expect(HistoricalV1Shape.shape.tableCount == 43)
        #expect(HistoricalV1Shape.shape.fingerprint == expectedLegacyV1Fingerprint)
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
