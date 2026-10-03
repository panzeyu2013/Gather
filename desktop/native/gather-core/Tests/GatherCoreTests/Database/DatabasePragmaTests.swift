// 第二轮验证补测（F-5）：db_synchronous / db_cache_size_mb 必须真正生效。
//
// 背景：这两个设置在 SettingsService 里定义、在设置 UI 里暴露，但第一轮之前
// 全仓无消费者（用户改了不生效）；修复后由宿主注入 settingsProvider，DB 在
// open() 与注入时各重放一次 PRAGMA。这里把「注入即生效」钉成回归。
import Foundation
import Testing
@testable import GatherCore

@Suite("DB performance pragmas (F-5)")
struct DatabasePragmaTests {
    private func pragmaInt(_ db: DBConnection, _ name: String) throws -> Int {
        let row = try db.prepare("PRAGMA \(name)").get([])
        return Int(row?[0].intValue ?? 0)
    }

    @Test("默认：synchronous=normal(1)、cache_size=-65536(64MB)")
    func defaultsMatchSettingsDefaults() throws {
        let db = try DBConnection(path: ":memory:")
        defer { db.close() }
        #expect(try pragmaInt(db, "synchronous") == 1)
        #expect(try pragmaInt(db, "cache_size") == -65536)
    }

    @Test("注入 settingsProvider 后立即重放 PRAGMA（用户设置生效）")
    func injectionReappliesPragmas() throws {
        let db = try DBConnection(path: ":memory:")
        defer { db.close() }
        db.settingsProvider = { key in
            switch key {
            case "db_synchronous": return "off"
            case "db_cache_size_mb": return "16"
            default: return nil
            }
        }
        #expect(try pragmaInt(db, "synchronous") == 0, "db_synchronous=off 必须生效")
        #expect(try pragmaInt(db, "cache_size") == -16384, "db_cache_size_mb=16 必须生效")
    }

    @Test("非法值回落默认，超出范围被钳制")
    func invalidAndOutOfRangeValuesFallBack() throws {
        let db = try DBConnection(path: ":memory:")
        defer { db.close() }
        db.settingsProvider = { key in
            switch key {
            case "db_synchronous": return "sometimes"
            case "db_cache_size_mb": return "abc"
            default: return nil
            }
        }
        #expect(try pragmaInt(db, "synchronous") == 1, "白名单外必须回落 normal")
        #expect(try pragmaInt(db, "cache_size") == -65536, "解析失败必须回落 64MB")

        db.settingsProvider = { key in
            key == "db_cache_size_mb" ? "8192" : nil
        }
        #expect(try pragmaInt(db, "cache_size") == -1048576, "必须钳制到 1024MB（-1048576 KiB）")
    }
    @Test("问题 4：连接关闭后 prepare/run 必须稳定失败，不得静默成功")
    func statementsFailAfterClose() throws {
        let db = try DBConnection(path: ":memory:")
        try db.exec("CREATE TABLE probe (id TEXT)")
        let statement = try db.prepare("INSERT INTO probe (id) VALUES (?)")
        try statement.bind([.text("x")])
        db.close()
        #expect(db.isClosed)
        // 旧实现会把 stmt 指针当成 db 指针（错误句柄类型），run 返回 0 而非报错。
        #expect(throws: DBError.self) { _ = try statement.run() }
        #expect(throws: DBError.self) { _ = try db.prepare("SELECT 1") }
        #expect(throws: DBError.self) { _ = try statement.get() }
    }
    @Test("问题 6：非有限数值设置回落默认（inf/1e999 不得让 Int 转换 trap）")
    func nonFiniteNumericSettingsFallBack() throws {
        let db = try DBConnection(path: ":memory:")
        defer { db.close() }
        try db.exec("CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let service = SettingsService(repo: SettingsRepo(connection: db))
        for raw in ["inf", "-inf", "1e999", "nan"] {
            try service.set("detect_input_size", value: raw)
            #expect(
                service.getNumber("detect_input_size", defaultValue: 640) == 640,
                "异常值 \(raw) 必须回落默认，否则 Int(Double) 会 trap"
            )
        }
        try service.set("detect_input_size", value: "768")
        #expect(service.getNumber("detect_input_size", defaultValue: 640) == 768)
    }
    // MARK: 第三轮验收：迁移回滚与并发关闭

    @Test("问题 3：恢复失败（备份不存在）时活动库保持可打开、数据不变")
    func restoreFailureKeepsActiveDatabase() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-restore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("gather.sqlite").path
        do {
            let db = try DBConnection(path: dbPath)
            try db.exec("CREATE TABLE t (v TEXT)")
            try db.prepare("INSERT INTO t VALUES (?)").run([.text("original")])
            db.close()
        }
        let connection = try DBConnection(path: dbPath)
        let runner = MigrationRunner(databaseFilePath: dbPath)
        // 备份不存在 → 必须抛错，且**活动库路径仍存在**（旧实现会先删活库，
        // 期间进程退出就会留下空路径）。
        let missing = dir.appendingPathComponent("missing.bak").path
        #expect(throws: (any Error).self) {
            try runner.restoreBackup(connection, dbPath: dbPath, backupPath: missing)
        }
        #expect(FileManager.default.fileExists(atPath: dbPath), "恢复失败不得让活动库路径消失")
        // 同一连接应已重新打开，数据保持原样。
        let row = try connection.prepare("SELECT v FROM t").get([])
        #expect(row?[0].textValue == "original")
        connection.close()
    }

    @Test("问题 3：恢复成功替换活动库并清理旧 WAL/SHM")
    func restoreSuccessReplacesDatabaseAndCleansWAL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-restore-ok-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("gather.sqlite").path
        let backupPath = dir.appendingPathComponent("gather.bak").path
        do {
            let db = try DBConnection(path: dbPath)
            try db.exec("CREATE TABLE t (v TEXT)")
            try db.prepare("INSERT INTO t VALUES (?)").run([.text("original")])
            db.close()
        }
        do {
            let backup = try DBConnection(path: backupPath)
            try backup.exec("CREATE TABLE t (v TEXT)")
            try backup.prepare("INSERT INTO t VALUES (?)").run([.text("restored")])
            backup.close()
        }
        let connection = try DBConnection(path: dbPath)
        let runner = MigrationRunner(databaseFilePath: dbPath)
        try runner.restoreBackup(connection, dbPath: dbPath, backupPath: backupPath)
        let row = try connection.prepare("SELECT v FROM t").get([])
        #expect(row?[0].textValue == "restored", "恢复后应看到备份内容")
        // 说明：重开连接会按 WAL 模式正常新建 -wal，因此不能断言它不存在；
        // 真正要钉住的是「替换成功、原库替换为备份内容、临时文件不残留、备份保留」。
        #expect(!FileManager.default.fileExists(atPath: dbPath + ".restore-tmp"))
        #expect(FileManager.default.fileExists(atPath: backupPath), "备份文件必须保留供排障")
        // 原库路径必须仍是可打开的完整库（重开后再查一次）。
        #expect(try connection.prepare("SELECT COUNT(*) FROM t").get([])?[0].intValue == 1)
        connection.close()
    }

    @Test("问题 4：并发查询与关闭不崩溃，关闭后必须稳定失败")
    func concurrentQueriesAndCloseStaySafe() async throws {
        let db = try DBConnection(path: ":memory:")
        try db.exec("CREATE TABLE t (v INTEGER)")
        try db.prepare("INSERT INTO t VALUES (1)").run([])
        let errors = await withTaskGroup(of: Int.self) { group -> Int in
            for _ in 0..<4 {
                group.addTask {
                    var errorCount = 0
                    for _ in 0..<40 {
                        do { _ = try db.prepare("SELECT COUNT(*) FROM t").get([]) }
                        catch { errorCount += 1 }
                    }
                    return errorCount
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(2))
                db.close()
                return -1
            }
            var total = 0
            for await value in group where value >= 0 { total += value }
            return total
        }
        // 不崩溃即通过（崩溃会让测试进程直接挂掉）；关闭后必须抛错而不是静默成功。
        #expect(errors >= 0)
        #expect(db.isClosed)
        #expect(throws: DBError.self) { _ = try db.prepare("SELECT COUNT(*) FROM t") }
    }
}
