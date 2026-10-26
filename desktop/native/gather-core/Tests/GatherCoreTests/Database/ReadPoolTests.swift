// desktop/native/gather-core/Tests/GatherCoreTests/Database/ReadPoolTests.swift
// R6：只读连接池（SELECT 路由）与慢事务诊断的回归锚点。
//
// 覆盖：① 长写事务期间 SELECT 不被写连接锁阻塞且看到已提交快照；
// ② 事务线程内 SELECT 仍读己写；③ 内存库永不建池；
// ④ close 关闭池后读稳定报错；⑤ 慢事务按阈值记 warn。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

@Suite("R6 只读连接池与慢事务", .serialized)
struct ReadPoolTests {
    private struct Flag { var entered = false }
    private struct LogState { var messages: [String] = [] }

    private func makeTempPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-readpool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gather.sqlite").path
    }

    private func cleanup(_ path: String) {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("长写事务期间 SELECT 走只读池：不阻塞且读已提交快照")
    func readDoesNotBlockOnLongWriteTransaction() async throws {
        let path = try makeTempPath()
        defer { cleanup(path) }
        let conn = try DBConnection(path: path, readPoolSize: 2)
        defer { conn.close() }
        try conn.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")
        try conn.exec("INSERT INTO t (v) VALUES ('seed');")

        let entered = LockedBox(Flag())
        let hold = Task.detached {
            try conn.transaction {
                entered.lock.withLock { entered.entered = true }
                Thread.sleep(forTimeInterval: 1.0)
                try conn.exec("INSERT INTO t (v) VALUES ('during');")
            }
        }
        for _ in 0..<200 where !(entered.lock.withLock { entered.entered }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(entered.lock.withLock { entered.entered }, "写事务必须已开始")

        let started = Date()
        let row = try conn.prepare("SELECT COUNT(*) FROM t").get()
        let elapsed = Date().timeIntervalSince(started)
        #expect(row?[0].intValue == 1, "读到事务前的已提交快照")
        #expect(elapsed < 0.6, "SELECT 不应等待写事务（实测 \(Int(elapsed * 1000))ms）")

        try await hold.value
        let after = try conn.prepare("SELECT COUNT(*) FROM t").get()
        #expect(after?[0].intValue == 2, "提交后池读可见")
    }

    @Test("事务线程内 SELECT 仍读己写（走写连接）")
    func inTransactionReadSeesOwnWrite() throws {
        let conn = try DBConnection(path: ":memory:")
        defer { conn.close() }
        try conn.exec("CREATE TABLE t (v TEXT);")
        try conn.transaction {
            try conn.exec("INSERT INTO t (v) VALUES ('x');")
            let row = try conn.prepare("SELECT COUNT(*) FROM t").get()
            #expect(row?[0].intValue == 1)
        }
    }

    @Test("事务外 prepare 的池化 SELECT 在事务内执行必须 fail-closed")
    func pooledStatementRejectsCrossScopeExecution() throws {
        let path = try makeTempPath()
        defer { cleanup(path) }
        let conn = try DBConnection(path: path, readPoolSize: 1)
        defer { conn.close() }
        try conn.exec("CREATE TABLE t (v TEXT);")

        // 事务外 prepare → 池连接；事务内执行会丢掉读己写语义，必须拒绝。
        let statement = try conn.prepare("SELECT COUNT(*) FROM t")
        #expect(throws: DBError.self) {
            try conn.transaction {
                _ = try statement.get()
            }
        }
    }

    @Test("内存库永不建池（否则读会看不到写）")
    func memoryDatabaseNeverUsesPool() throws {
        let conn = try DBConnection(path: ":memory:", readPoolSize: 2)
        defer { conn.close() }
        try conn.exec("CREATE TABLE t (v TEXT);")
        try conn.exec("INSERT INTO t (v) VALUES ('x');")
        let row = try conn.prepare("SELECT COUNT(*) FROM t").get()
        #expect(row?[0].intValue == 1)
    }

    @Test("close 关闭只读池：之后读稳定报错")
    func closeClosesPool() throws {
        let path = try makeTempPath()
        defer { cleanup(path) }
        let conn = try DBConnection(path: path, readPoolSize: 1)
        try conn.exec("CREATE TABLE t (v TEXT);")
        _ = try conn.prepare("SELECT COUNT(*) FROM t").get()
        conn.close()
        #expect(throws: DBError.self) {
            _ = try conn.prepare("SELECT COUNT(*) FROM t")
        }
    }

    @Test("慢事务按阈值记 warn（R6-a）")
    func slowTransactionLogs() throws {
        let conn = try DBConnection(path: ":memory:")
        defer { conn.close() }
        let originalLevel = GatherLogger.minimumLevel
        let originalOutput = GatherLogger.output
        let captured = LockedBox(LogState())
        GatherLogger.minimumLevel = .warn
        GatherLogger.output = { message in
            captured.lock.withLock {
                var messages = captured.messages
                messages.append(message)
                captured.messages = messages
            }
        }
        DBConnection.slowTransactionThresholdMilliseconds = 1
        defer {
            DBConnection.slowTransactionThresholdMilliseconds = 0
            GatherLogger.output = originalOutput
            GatherLogger.minimumLevel = originalLevel
        }

        try conn.transaction {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let hit = captured.lock.withLock {
            captured.messages.contains { $0.contains("slow transaction") }
        }
        #expect(hit, "超过阈值的事务必须留下 warn")
    }
}
