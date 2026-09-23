// Tests/GatherCoreTests/Store/SQLiteDatabaseTests.swift
// R1 新持久化层基座测试：值/行/键行解码/事务/语句缓存/错误分类/并发串行化。
import Foundation
import Testing
@testable import GatherCore

private func makeTempDBPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-store-test-\(UUID().uuidString).sqlite")
        .path
}

private func removeDatabaseFiles(_ path: String) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
    }
}

private struct PhotoRow: Decodable, Equatable {
    let id: String
    let rating: Int?
    let isPicked: Bool
    let keywords: [String]

    enum CodingKeys: String, CodingKey {
        case id, rating, keywords
        case isPicked = "is_picked"
    }
}

@Suite("Store/SQLiteDatabase (R1)")
struct SQLiteDatabaseTests {
    private func makeDatabase(configuration: SQLiteDatabase.Configuration = .init()) throws -> (SQLiteDatabase, String) {
        let path = makeTempDBPath()
        let database = try SQLiteDatabase(path: path, configuration: configuration)
        return (database, path)
    }

    @Test func executeCreatesSchemaAndRoundTripsValues() async throws {
        let (database, path) = try makeDatabase()
        defer { removeDatabaseFiles(path) }

        try await database.execute("""
            CREATE TABLE photos (
              id TEXT PRIMARY KEY,
              rating INTEGER,
              is_picked INTEGER NOT NULL DEFAULT 0,
              blob_value BLOB
            )
            """)
        try await database.run(
            "INSERT INTO photos (id, rating, is_picked, blob_value) VALUES (?, ?, ?, ?)",
            ["p1", 4, true, .blob(Data([0x01, 0x02, 0x03]))]
        )

        let row = try #require(try await database.queryOne("SELECT * FROM photos WHERE id = ?", ["p1"]))
        #expect(row.text("id") == "p1")
        #expect(row.int("rating") == 4)
        #expect(row.bool("is_picked") == true)
        #expect(row.blob("blob_value") == Data([0x01, 0x02, 0x03]))
        #expect(row.columnOrder.prefix(2).elementsEqual(["id", "rating"]))
    }

    @Test func keyedDecodingHandlesSnakeCaseOptionalsAndJSONColumns() async throws {
        let (database, path) = try makeDatabase()
        defer { removeDatabaseFiles(path) }

        try await database.execute("""
            CREATE TABLE photos (
              id TEXT PRIMARY KEY,
              rating INTEGER,
              is_picked INTEGER NOT NULL DEFAULT 0,
              keywords TEXT NOT NULL DEFAULT '[]'
            )
            """)
        try await database.run(
            "INSERT INTO photos (id, rating, is_picked, keywords) VALUES (?, ?, ?, ?)",
            ["p1", 5, true, "[\"cat\",\"dog\"]"]
        )

        let row = try #require(try await database.queryOne("SELECT * FROM photos"))
        let decoded = try row.decode(PhotoRow.self)
        #expect(decoded == PhotoRow(id: "p1", rating: 5, isPicked: true, keywords: ["cat", "dog"]))

        try await database.run("INSERT INTO photos (id, rating, keywords) VALUES (?, ?, ?)", ["p2", nil, "[]"])
        let optionalRow = try #require(try await database.queryOne("SELECT * FROM photos WHERE id = 'p2'"))
        let optionalDecoded = try optionalRow.decode(PhotoRow.self)
        #expect(optionalDecoded.rating == nil)
        #expect(optionalDecoded.isPicked == false)
    }

    @Test func scalarDecodingFromSingleColumnRow() async throws {
        let (database, path) = try makeDatabase()
        defer { removeDatabaseFiles(path) }

        #expect(try await database.scalarInt("SELECT 42") == 42)
        let row = try #require(try await database.queryOne("SELECT 'hello' AS greeting"))
        #expect(try row.decode(String.self) == "hello")
    }

    @Test func transactionCommits() async throws {
        let (database, path) = try makeDatabase()
        defer { removeDatabaseFiles(path) }
        try await database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

        try await database.transaction { db in
            try db.run("INSERT INTO t (v) VALUES (?)", ["a"])
            try db.run("INSERT INTO t (v) VALUES (?)", ["b"])
        }
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM t") == 2)
        #expect(await database.currentTransactionDepth == 0)
    }

    @Test func transactionRollsBackOnThrow() async throws {
        let (database, path) = try makeDatabase()
        defer { removeDatabaseFiles(path) }
        try await database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)")

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await database.transaction { db in
                try db.run("INSERT INTO t (v) VALUES (?)", ["keep-me-out"])
                throw Boom()
            }
        }
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM t") == 0)
        #expect(await database.currentTransactionDepth == 0)
    }

    @Test func nestedSavepointRollsBackInnerOnly() async throws {
        let (database, path) = try makeDatabase()
        defer { removeDatabaseFiles(path) }
        try await database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)")

        struct InnerBoom: Error {}
        try await database.transaction { db in
            try db.run("INSERT INTO t (v) VALUES (?)", ["outer"])
            do {
                try db.transaction { inner in
                    try inner.run("INSERT INTO t (v) VALUES (?)", ["inner"])
                    throw InnerBoom()
                }
            } catch is InnerBoom {
                // 内层已回滚，外层继续提交。
            }
        }
        let values = try await database.query("SELECT v FROM t ORDER BY id").compactMap { $0.text("v") }
        #expect(values == ["outer"])
        #expect(await database.currentTransactionDepth == 0)
    }

    @Test func uniqueConstraintRaisesStructuredFailure() async throws {
        let (database, path) = try makeDatabase()
        defer { removeDatabaseFiles(path) }
        try await database.execute("CREATE TABLE t (id TEXT PRIMARY KEY)")
        try await database.run("INSERT INTO t (id) VALUES (?)", ["dup"])

        do {
            try await database.run("INSERT INTO t (id) VALUES (?)", ["dup"])
            Issue.record("expected a unique constraint failure")
        } catch let failure as SQLiteFailure {
            #expect(failure.isConstraintViolation)
            #expect(failure.isUniqueViolation)
            #expect(failure.sql?.contains("INSERT INTO t") == true)
        }
    }

    @Test func statementCacheReusesAndEvicts() async throws {
        let (database, path) = try makeDatabase(configuration: .init(statementCacheCapacity: 3))
        defer { removeDatabaseFiles(path) }

        // execute/DDL 走 sqlite3_exec，不进入语句缓存。
        try await database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        #expect(await database.cachedStatementCount == 0)

        // 同一 SQL 重复执行只保留一条预编译语句。
        for index in 0..<5 {
            try await database.run("INSERT INTO t (v) VALUES (?)", [.text("v\(index)")])
        }
        #expect(await database.cachedStatementCount == 1)

        _ = try await database.query("SELECT COUNT(*) FROM t")
        _ = try await database.query("SELECT COUNT(*) FROM t")
        #expect(await database.cachedStatementCount == 2)

        // 超出容量（3）后按 LRU 淘汰，容量保持上限。
        _ = try await database.query("SELECT MAX(id) FROM t")
        _ = try await database.query("SELECT MIN(id) FROM t")
        #expect(await database.cachedStatementCount == 3)
    }

    @Test func closeRejectsFurtherUse() async throws {
        let (database, path) = try makeDatabase()
        defer { removeDatabaseFiles(path) }
        try await database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        await database.close()

        do {
            try await database.run("INSERT INTO t (id) VALUES (1)")
            Issue.record("expected misuse error after close")
        } catch let failure as SQLiteFailure {
            #expect(failure.isMisuse)
        }
        #expect(await database.isOpen == false)
    }

    @Test func concurrentWritesAreSerializedByActor() async throws {
        let (database, path) = try makeDatabase()
        defer { removeDatabaseFiles(path) }
        try await database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")

        await withTaskGroup(of: Void.self) { group in
            for value in 0..<50 {
                group.addTask {
                    try? await database.run("INSERT INTO t (v) VALUES (?)", [.int(Int64(value))])
                }
            }
        }
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM t") == 50)
    }

    @Test func busyTimeoutSurfacesAsBusyFailure() async throws {
        let path = makeTempDBPath()
        let writer = try SQLiteDatabase(path: path)
        let contender = try SQLiteDatabase(path: path, configuration: .init(busyTimeoutMs: 50, journalMode: "WAL"))
        defer { removeDatabaseFiles(path) }

        try await writer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        try await writer.execute("BEGIN IMMEDIATE")
        try await writer.run("INSERT INTO t (v) VALUES ('held')")

        do {
            try await contender.run("INSERT INTO t (v) VALUES ('blocked')")
            Issue.record("expected SQLITE_BUSY while writer holds the lock")
        } catch let failure as SQLiteFailure {
            #expect(failure.isBusy)
        }
        try await writer.execute("ROLLBACK")
        #expect(try await writer.scalarInt("SELECT COUNT(*) FROM t") == 0)
        await writer.close()
        await contender.close()
    }
}
