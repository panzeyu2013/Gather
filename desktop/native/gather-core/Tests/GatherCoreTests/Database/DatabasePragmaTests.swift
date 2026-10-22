// 第二轮验证补测（F-5）：db_synchronous / db_cache_size_mb 必须真正生效。
//
// 背景：这两个设置在 SettingsService 里定义、在设置 UI 里暴露，但第一轮之前
// 全仓无消费者（用户改了不生效）；修复后由宿主注入 settingsProvider，DB 在
// open() 与注入时各重放一次 PRAGMA。这里把「注入即生效」钉成回归。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherDomain

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

    // MARK: 第三轮验收：并发关闭（迁移回滚用例随 MigrationRunner 删除）

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
