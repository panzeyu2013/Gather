// desktop/native/gather-core/Tests/GatherCoreTests/Database/DatabaseFacadeTests.swift
// Cut 2 / B-1：Database facade 的行为门禁（D-035）。
//
// 覆盖四件事：
//   1. `:memory:` 打开即 SchemaV1（43 表 / user_version = 1）；
//   2. 文件库新建 → 关闭 → 重开数据保留（V1 是「一次成型 + 不改 schema」，重开必须直接可用）；
//   3. user_version=99 的旧库（带 -wal/-shm）在显式 resetPolicy=.renameToIncompatible 下
//      被整体改名 `.incompatible-*`，新库回到 V1，旧表不会借残留 WAL 复辟；非 SQLite 文件
//      同样走改名。默认 .failClosed 下抛错、不改文件（见 SchemaMigrationTests）；
//   4. read / write 事务回滚 / 嵌套 SAVEPOINT / close 后一律 `.closed` / async 串行执行器。
//
// 说明：本批不接入 Repo/Service，测试只新增本文件；已存在的 DB.swift / SchemaV1.swift
// 一行未改。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence

// MARK: - 期望值 / 公共辅助

/// SchemaV1 的用户表数量（draft §1/§9.1；与 SchemaV1Tests 的 43 表清单同源）。
private let expectedV1TableCount = 43

private struct TestError: Error {}

/// 每个用例独立的临时目录（避免并行执行的测试互相踩文件）。
private func makeTemporaryDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-database-facade-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func databasePath(in directory: URL) -> String {
    directory.appendingPathComponent("gather.sqlite").path
}

/// 取单行单列的整数标量。
private func scalarInt(_ db: DBConnection, _ sql: String) throws -> Int {
    guard let raw = try db.prepare(sql).get([])?[0].intValue else {
        throw DBError.message("标量查询无结果: \(sql)")
    }
    return Int(raw)
}

/// 全部用户表名（升序，排除 sqlite_ 内部表）。
private func userTables(_ db: DBConnection) throws -> [String] {
    try db.prepare("""
        SELECT name FROM sqlite_master
         WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
         ORDER BY name
        """).query([]).compactMap { $0[0].textValue }
}

/// 全部用户列的列数（逐表 pragma 求和）。
private func userColumnCount(_ db: DBConnection) throws -> Int {
    var total = 0
    for table in try userTables(db) {
        total += try db.prepare("PRAGMA table_info('\(table)');").query([]).count
    }
    return total
}

/// 一张表的列名集合。
private func columnNames(_ db: DBConnection, table: String) throws -> Set<String> {
    Set(try db.prepare("PRAGMA table_info('\(table)');").query([]).compactMap { $0[1].textValue })
}

/// 目录里 `<db>.incompatible-*` 的文件名。
private func incompatibleCopies(in directory: URL, baseName: String = "gather.sqlite") throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix(baseName + ".incompatible-") }
}

/// 写一行满足 V1 约束的 session（其余用例的数据载体）。
private func insertSession(_ db: DBConnection, id: String, name: String = "") throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, created_at, updated_at)
        VALUES (?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(id), .text(name)])
}

/// 执行必须失败的 body，返回 `DatabaseError`（非 DatabaseError 或未抛错返回 nil）。
private func capturedError(_ body: () throws -> Void) -> DatabaseError? {
    do {
        try body()
        return nil
    } catch let error as DatabaseError {
        return error
    } catch {
        return nil
    }
}

// MARK: - 测试

@Suite("DatabaseFacadeTests")
struct DatabaseFacadeTests {

    // MARK: 1. 内存库

    @Test(":memory:：open 直接建 SchemaV1（43 表 / user_version = 1）")
    func memoryOpenBuildsSchemaV1() throws {
        let database = try Database.open(at: Database.inMemoryPath)
        defer { database.close() }

        #expect(database.isInMemory)
        #expect(!database.isClosed)
        #expect(database.outcome == .created(.v1))

        let tables = try database.read { try userTables($0) }
        #expect(tables.count == expectedV1TableCount, "V1 必须是 43 张表，实际 \(tables.count)：\(tables)")
        #expect(tables.contains("sessions"))
        #expect(tables.contains("delivery_intents"))
        #expect(try database.read { try scalarInt($0, "PRAGMA user_version") } == SchemaV1.userVersion)
        // 内存库不落盘：journal_mode 回落 memory 不是错误；checkpoint 也不得抛错。
        #expect(try database.checkpoint() == true)
    }

    // MARK: 2. 文件库重开

    @Test("文件库：新建→关闭→重开保留数据；关闭后调用抛 .closed")
    func fileDatabasePersistsAcrossReopen() throws {
        let directory = try makeTemporaryDirectory("reopen")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)

        let first = try Database.open(at: path)
        #expect(!first.isClosed)
        try first.write { try insertSession($0, id: "s-1", name: "keep-me") }
        first.close()
        #expect(first.isClosed)
        #expect(capturedError { _ = try first.read { _ in 1 } }?.kind == .closed)

        let second = try Database.open(at: path)
        defer { second.close() }
        #expect(try second.read { try scalarInt($0, "PRAGMA user_version") } == SchemaV1.userVersion)
        #expect(try second.read { try userTables($0).count } == expectedV1TableCount)
        let name = try second.read { db in
            try db.prepare("SELECT name FROM sessions WHERE id = ?").get([.text("s-1")])?[0].textValue
        }
        #expect(name == "keep-me", "重开必须保留已提交数据（V1 不做迁移）")
    }

    // MARK: 3. 旧库/非 SQLite 重置

    @Test("user_version=99 旧库（含 -wal/-shm）：整体改名 .incompatible-*，新库为 V1")
    func incompatibleDatabaseIsResetWithSidecars() throws {
        let directory = try makeTemporaryDirectory("reset")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)

        do {
            // 造一个「V1 之前」的库：任意表 + user_version=99。
            let legacy = try DBConnection(path: path)
            try legacy.exec("CREATE TABLE legacy_marker (id INTEGER PRIMARY KEY, note TEXT);")
            try legacy.exec("INSERT INTO legacy_marker (note) VALUES ('must-not-survive');")
            try legacy.exec("PRAGMA user_version = 99;")
            legacy.close()
        }

        // 关闭最后一个连接时 SQLite 可能已清理 sidecar；显式放回，确保重置必须处理三件套。
        let staleWAL = Data("stale-wal-must-be-moved".utf8)
        let staleSHM = Data("stale-shm-must-be-moved".utf8)
        try staleWAL.write(to: URL(fileURLWithPath: path + "-wal"))
        try staleSHM.write(to: URL(fileURLWithPath: path + "-shm"))

        let database = try Database.open(
            at: path,
            options: Database.Options(resetPolicy: .renameToIncompatible)
        )
        defer { database.close() }

        // 新库必须是干净的 V1：版本 1、43 表、旧表不存在（WAL 残留不得复辟旧页）。
        #expect(try database.read { try scalarInt($0, "PRAGMA user_version") } == SchemaV1.userVersion)
        let tables = try database.read { try userTables($0) }
        #expect(tables.count == expectedV1TableCount)
        #expect(!tables.contains("legacy_marker"), "旧库的表不得出现在新库里")
        #expect(capturedError {
            _ = try database.read { try scalarInt($0, "SELECT COUNT(*) FROM legacy_marker") }
        } != nil, "旧表必须已随旧库一起移走")

        // 旧文件（主库 + -wal + -shm）必须都被改名，而不是原地覆盖。
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let prefix = "gather.sqlite.incompatible-"
        let renamed = names.filter { $0.hasPrefix(prefix) }
        let renamedMain = renamed.filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        #expect(renamedMain.count == 1, "旧主库必须改名保留：\(renamed)")
        #expect(renamed.filter { $0.hasSuffix("-wal") }.count == 1, "旧 -wal 必须一起移走：\(renamed)")
        #expect(renamed.filter { $0.hasSuffix("-shm") }.count == 1, "旧 -shm 必须一起移走：\(renamed)")

        // 改名后的主库仍是可识别的 SQLite 文件（证明移走的是旧库本身）。
        let renamedPath = directory.appendingPathComponent(try #require(renamedMain.first)).path
        let header = try Data(contentsOf: URL(fileURLWithPath: renamedPath)).prefix(16)
        #expect(header == Data("SQLite format 3\u{0}".utf8))

        // 原路径上的 sidecar 属于新库；旧 sidecar 的字节不得原地留存。
        for (suffix, stale) in [("-wal", staleWAL), ("-shm", staleSHM)] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path + suffix)) {
                #expect(data != stale, "原路径 \(suffix) 不得还是旧库 sidecar")
            }
        }
    }

    @Test("非 SQLite 文件：按不兼容库重置（不抛错、旧文件保留为 .incompatible-*）")
    func nonDatabaseFileIsReset() throws {
        let directory = try makeTemporaryDirectory("not-a-database")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)

        try Data("this is definitely not a sqlite database".utf8)
            .write(to: URL(fileURLWithPath: path))

        let database = try Database.open(
            at: path,
            options: Database.Options(resetPolicy: .renameToIncompatible)
        )
        defer { database.close() }
        #expect(try database.read { try scalarInt($0, "PRAGMA user_version") } == SchemaV1.userVersion)
        #expect(try database.read { try userTables($0).count } == expectedV1TableCount)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("gather.sqlite.incompatible-") })
    }

    // MARK: 3b. user_version=1 但列形不是当前 V1（Cut 5 加列未 bump）

    @Test("同版本旧库缺列（370 列）：重开重置为当前 V1，旧文件保留 .incompatible-*（含 -wal/-shm）")
    func outdatedV1ShapeIsResetWithSidecars() throws {
        let directory = try makeTemporaryDirectory("outdated-v1")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)

        do {
            let legacy = try DBConnection(path: path)
            try legacy.exec(SchemaV1.sql)
            // 模拟 Cut 5 之前的 V1：similarity_cluster_meta 仍是 8 列，user_version 仍为 1。
            try legacy.exec("ALTER TABLE similarity_cluster_meta DROP COLUMN algorithm_version;")
            try legacy.exec("ALTER TABLE similarity_cluster_meta DROP COLUMN input_signature;")
            try legacy.exec("ALTER TABLE similarity_cluster_meta DROP COLUMN state_digest;")
            try insertSession(legacy, id: "legacy-session")
            #expect(try userColumnCount(legacy) == 370, "模拟旧库应为 370 列")
            #expect(try scalarInt(legacy, "PRAGMA user_version") == SchemaV1.userVersion,
                    "旧库版本号仍是 1：这正是只校验 user_version 不够的原因")
            legacy.close()
        }

        let staleWAL = Data("stale-wal-for-outdated-v1".utf8)
        let staleSHM = Data("stale-shm-for-outdated-v1".utf8)
        try staleWAL.write(to: URL(fileURLWithPath: path + "-wal"))
        try staleSHM.write(to: URL(fileURLWithPath: path + "-shm"))

        let database = try Database.open(
            at: path,
            options: Database.Options(resetPolicy: .renameToIncompatible)
        )
        defer { database.close() }

        #expect(try database.read { try scalarInt($0, "PRAGMA user_version") } == SchemaV1.userVersion)
        #expect(try database.read { try userTables($0).count } == expectedV1TableCount)
        #expect(try database.read { try userColumnCount($0) } == 373, "重置后必须是当前 373 列")
        let columns = try database.read { try columnNames($0, table: "similarity_cluster_meta") }
        #expect(columns.isSuperset(of: ["algorithm_version", "input_signature", "state_digest"]),
                "重置后必须带 Cut 5 三列，实际 \(columns.sorted())")
        #expect(try database.read { try scalarInt($0, "SELECT COUNT(*) FROM sessions") } == 0,
                "不兼容库必须整体重置，不得只补列保留旧数据")

        let renamed = try incompatibleCopies(in: directory)
        let mains = renamed.filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        #expect(mains.count == 1, "旧主库必须保留为 .incompatible-*：\(renamed)")
        #expect(renamed.filter { $0.hasSuffix("-wal") }.count == 1, "旧 -wal 必须一起移走：\(renamed)")
        #expect(renamed.filter { $0.hasSuffix("-shm") }.count == 1, "旧 -shm 必须一起移走：\(renamed)")

        let renamedPath = directory.appendingPathComponent(try #require(mains.first)).path
        #expect(try Data(contentsOf: URL(fileURLWithPath: renamedPath)).prefix(16)
                == Data("SQLite format 3\u{0}".utf8), "移走的必须是旧库文件本身")
        for (suffix, stale) in [("-wal", staleWAL), ("-shm", staleSHM)] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path + suffix)) {
                #expect(data != stale, "原路径 \(suffix) 不得还是旧库 sidecar")
            }
        }
    }

    @Test("列形正确的 V1 文件库重开不重置：无 .incompatible-*、数据保留")
    func currentV1ShapeIsNotReset() throws {
        let directory = try makeTemporaryDirectory("current-v1")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)

        do {
            let current = try DBConnection(path: path)
            try current.exec(SchemaV1.sql)
            try insertSession(current, id: "keep-me", name: "current-v1")
            #expect(try userColumnCount(current) == 373)
            current.close()
        }

        let database = try Database.open(at: path)
        defer { database.close() }

        #expect(try database.read { try userColumnCount($0) } == 373)
        #expect(database.outcome == .opened(.v1), "列形正确的 V1 必须走 opened，不得重置")
        #expect(try database.read {
            try $0.prepare("SELECT name FROM sessions WHERE id = ?").get([.text("keep-me")])?[0].textValue
        } == "current-v1", "列形正确的库不得被重置")
        #expect(try incompatibleCopies(in: directory).isEmpty,
                "正确 V1 库不得产生 .incompatible 副本")
    }

    @Test("user_version=99（列形正确）仍按版本重置")
    func higherUserVersionIsResetEvenWithCurrentShape() throws {
        let directory = try makeTemporaryDirectory("v99-current-shape")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = databasePath(in: directory)

        do {
            let newer = try DBConnection(path: path)
            try newer.exec(SchemaV1.sql)
            try insertSession(newer, id: "must-not-survive")
            try newer.exec("PRAGMA user_version = 99;")
            newer.close()
        }

        let database = try Database.open(
            at: path,
            options: Database.Options(resetPolicy: .renameToIncompatible)
        )
        defer { database.close() }

        #expect(try database.read { try scalarInt($0, "PRAGMA user_version") } == SchemaV1.userVersion)
        #expect(try database.read { try userColumnCount($0) } == 373)
        #expect(try database.read { try scalarInt($0, "SELECT COUNT(*) FROM sessions") } == 0)
        let copies = try incompatibleCopies(in: directory)
        let copiedMains = copies.filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        #expect(copiedMains.count == 1, "版本不兼容必须保留旧库副本：\(copies)")
    }

    // MARK: 4. 作用域 / 事务 / close / async

    @Test("write 单事务：body 抛错整体回滚，已提交数据 read 可见")
    func writeRollsBackOnError() throws {
        let database = try Database.open(at: ":memory:")
        defer { database.close() }

        try database.write { try insertSession($0, id: "s-1") }
        #expect(try database.read { try scalarInt($0, "SELECT COUNT(*) FROM sessions") } == 1)

        #expect(throws: TestError.self) {
            try database.write { db in
                try insertSession(db, id: "s-2")
                throw TestError()
            }
        }
        #expect(try database.read { try scalarInt($0, "SELECT COUNT(*) FROM sessions") } == 1)
        let ids = try database.read { db in
            try db.prepare("SELECT id FROM sessions ORDER BY id").query([]).compactMap { $0[0].textValue }
        }
        #expect(ids == ["s-1"])
    }

    @Test("嵌套 write 用 SAVEPOINT：内层失败只回滚内层，外层可继续提交")
    func nestedWriteUsesSavepoints() throws {
        let database = try Database.open(at: ":memory:")
        defer { database.close() }

        try database.write { outer in
            try insertSession(outer, id: "outer")
            do {
                try database.write { inner in
                    try insertSession(inner, id: "inner")
                    throw TestError()
                }
            } catch is TestError {
                // 内层已 ROLLBACK TO SAVEPOINT；外层继续。
            }
            // 同一事务内的 read 走同一连接：看得到外层未提交行，看不到内层已回滚行。
            #expect(try database.read { try scalarInt($0, "SELECT COUNT(*) FROM sessions") } == 1)
            try insertSession(outer, id: "outer-2")
        }

        // 嵌套成功路径：内外层都提交。
        try database.write { outer in
            try insertSession(outer, id: "nested-outer")
            try database.write { inner in try insertSession(inner, id: "nested-inner") }
        }

        let ids = try database.read { db in
            try db.prepare("SELECT id FROM sessions ORDER BY id").query([]).compactMap { $0[0].textValue }
        }
        #expect(ids == ["nested-inner", "nested-outer", "outer", "outer-2"])
    }

    @Test("close：read/write/checkpoint/async 稳定抛 .closed，close 幂等")
    func closedDatabaseRejectsAllScopes() async throws {
        let database = try Database.open(at: ":memory:")
        try database.write { try insertSession($0, id: "s-1") }

        database.close()
        database.close() // 幂等：不得崩溃/重复释放
        #expect(database.isClosed)

        #expect(capturedError { _ = try database.read { _ in 1 } }?.kind == .closed)
        #expect(capturedError { _ = try database.write { _ in 1 } }?.kind == .closed)
        #expect(capturedError { try database.checkpoint() }?.kind == .closed)

        do {
            _ = try await database.async { _ in 1 }
            Issue.record("close 之后 async 必须抛错")
        } catch let error as DatabaseError {
            #expect(error.kind == .closed)
        } catch {
            Issue.record("close 之后 async 必须抛 DatabaseError.closed，实际 \(error)")
        }
    }

    @Test("async：串行队列上返回值/错误透传，并发调用不互相踩事务")
    func asyncExecutorPropagatesAndSerializes() async throws {
        let database = try Database.open(at: ":memory:")
        defer { database.close() }

        let value = try await database.async { db in
            try insertSession(db, id: "async-1")
            return try scalarInt(db, "SELECT COUNT(*) FROM sessions")
        }
        #expect(value == 1)

        do {
            _ = try await database.async { _ in throw TestError() }
            Issue.record("async 必须透传 body 抛出的错误")
        } catch is TestError {
            // 原样透传，不得包装成 .sql。
        }

        // 并发提交 8 个写任务：串行执行器保证每次 write 落在同一连接的事务边界内。
        let results = try await withThrowingTaskGroup(of: Int.self) { group -> [Int] in
            for index in 0..<8 {
                group.addTask {
                    try await database.async { db in
                        try insertSession(db, id: "async-concurrent-\(index)")
                        return index
                    }
                }
            }
            var collected: [Int] = []
            for try await result in group { collected.append(result) }
            return collected
        }
        #expect(Set(results) == Set(0..<8))
        #expect(try database.read { try scalarInt($0, "SELECT COUNT(*) FROM sessions") } == 9)
    }

    @Test("DatabaseError：SQLite 码/errmsg 最小映射，未知错误归 .sql")
    func databaseErrorMappingIsMinimal() {
        #expect(DatabaseError(dbError: .message("database is locked")).kind == .busy)
        #expect(DatabaseError(dbError: .message("UNIQUE constraint failed: sessions.id")).kind == .constraint)
        #expect(DatabaseError(dbError: .message("disk I/O error")).kind == .io)
        #expect(DatabaseError(dbError: .message("database disk image is malformed")).kind == .corrupt)
        #expect(DatabaseError(dbError: .message("数据库已关闭")).kind == .closed)
        #expect(DatabaseError(dbError: .message("SQL 编译失败: no such table: sessions")).kind == .schema)
        #expect(DatabaseError(dbError: .message("some completely unknown failure")).kind == .sql)

        // 结果码优先（19=SQLITE_CONSTRAINT、5=SQLITE_BUSY、11=SQLITE_CORRUPT、9=SQLITE_INTERRUPT）。
        #expect(DatabaseError(sqliteCode: 19, message: "opaque").kind == .constraint)
        #expect(DatabaseError(sqliteCode: 5, message: "opaque").kind == .busy)
        #expect(DatabaseError(sqliteCode: 11, message: "opaque").kind == .corrupt)
        #expect(DatabaseError(sqliteCode: 9, message: "opaque").kind == .interrupted)
        #expect(DatabaseError.map(TestError()).kind == .sql)
    }
}
