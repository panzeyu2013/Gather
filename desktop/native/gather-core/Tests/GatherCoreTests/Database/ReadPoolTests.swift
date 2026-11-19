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
        // task-43：统一走 GatherTestSupport.makeTempDir（TempHygiene 登记）。
        try GatherTestSupport.makeTempDir(prefix: "gather-readpool") + "/gather.sqlite"
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
        // 用信号量把「写事务保持打开」变成确定性事件：读到快照后再放行提交，
        // 而不是固定睡 1s（旧实现让本用例独占约 1s，串行批 80% 的时间都在等它）。
        let releaseCommit = DispatchSemaphore(value: 0)
        let hold = Task.detached {
            try conn.transaction {
                entered.lock.withLock { entered.entered = true }
                _ = releaseCommit.wait(timeout: .now() + 5)
                try conn.exec("INSERT INTO t (v) VALUES ('during');")
            }
        }
        // 断言提前抛出时也要放行后台事务，避免 5s 兜底超时拖尾。
        defer { releaseCommit.signal() }
        // 条件等待（共享 helper）：写事务真正进入后再断言，不靠固定 sleep 轮询。
        #expect(
            await waitUntilCondition(timeout: 1) { entered.lock.withLock { entered.entered } },
            "写事务必须已开始")

        let clock = ContinuousClock()
        let started = clock.now
        let row = try conn.prepare("SELECT COUNT(*) FROM t").get()
        let elapsed = clock.now - started
        #expect(row?[0].intValue == 1, "读到事务前的已提交快照")
        // 宽上限：内存库 SELECT 实测亚毫秒；1s 仍能拦住"等写事务释放"的病态
        // 回归（那会等满 5s 兜底），又不会因 CI 满载的调度抖动误报。
        #expect(elapsed < .seconds(1), "SELECT 不应等待写事务（实测 \(elapsed)）")

        // 读路径已经验证完毕，放行写事务提交。
        releaseCommit.signal()
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
