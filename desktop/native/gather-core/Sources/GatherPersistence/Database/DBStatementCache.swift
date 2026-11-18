// desktop/native/gather-core/Sources/GatherPersistence/Database/DBStatementCache.swift
// 一次调用内的预编译语句缓存（性能审计 R3）。
//
// 背景：100+ 处 `connection.prepare(...)` 位于 per-row/per-chunk 循环内。SQLite 每次
// prepare 都要重新解析/编译 SQL（Linux 实测约 2µs/次；复杂 IN/UPDATE 更贵），并重复
// 经过只读池/连接锁路由。`DBStatement` 的 `query/run/get/queryNamed` 自带 bind+reset
// （DB.swift），因此同一 SQL 的语句可以在循环里安全复用。
//
// ⚠️ 只读池资源边界（重要）：
// - `DBConnection.prepare` 在**事务外**的只读 SELECT 会从只读池借一条连接，该连接由
//   `DBStatement.pooledReturn` 在语句 deinit 时归还；`Database.Options.default.readPoolSize == 2`。
//   因此缓存 N 条不同的 SELECT 语句 = 同时占用最多 N 条池连接：N>2 时多出的语句会退回
//   写连接，**并发 UI 读会被挤到写连接**（正确性不变，但读池被静默绕过）。
// - 所以 `limit` 默认 1（一次同步作用域最多缓存 1 条语句）；分块 IN 循环应只缓存
//   「满块」这条 SQL，末块（占位符数量不同）用 `connection.prepare` 现场编译、随表达式
//   结束释放。需要缓存多条时最多 2 条，并在调用点注释里说明。
// - 写语句/事务内的语句走写连接（非池化，无此限制），可以安全复用；`limit>1` 只
//   允许用于这种「事务内创建、写连接」的场景（如 AssetRepo+Scan 的 per-photo 缓存
//   limit=14），且必须在调用点注释里写明为何不占只读池。
//
// 作用域约束：
// - 只在**单次同步调用的局部作用域**使用：实例是普通 class，不跨线程、不落静态存储；
//   随作用域结束 deinit，语句统一 finalize。
// - **不要跨事务边界**：只读池语句带 scope 守卫（DBStatement.readScopeDepth），事务内
//   创建、事务外复用会被 fail-closed 拒绝。需要跨 transaction 复用时，把缓存建在
//   事务闭包**内部**（每个事务重新 prepare），不要建在闭包外。
// - 按完整 SQL 文本做键：分块 IN 循环里块大小不同会产生不同 SQL（通常只有「满块」与
//   「末块」两种）；只缓存满块即可。
import Foundation

final class DBStatementCache {
    /// 最多缓存的语句数（只读池连接数上限）。默认 1，见文件头「只读池资源边界」。
    private let limit: Int
    private struct Entry {
        let statement: DBStatement
        /// 评审 CORE-05：记录语句所属连接，DEBUG 下拦截跨连接复用（语句绑定原连接）。
        let owner: DBConnection
    }
    private var statements: [String: Entry] = [:]

    init(limit: Int = 1) {
        self.limit = max(1, limit)
    }

    /// 命中则复用；未命中则编译，并在未达 `limit` 时缓存。
    /// 未缓存的语句由调用方持有到表达式/作用域结束，随即释放（只读池连接随之归还）。
    func statement(_ connection: DBConnection, _ sql: String) throws -> DBStatement {
        if let cached = statements[sql] {
            assert(cached.owner === connection, "DBStatementCache 禁止跨连接复用语句")
            return cached.statement
        }
        let fresh = try connection.prepare(sql)
        if statements.count < limit {
            statements[sql] = Entry(statement: fresh, owner: connection)
        }
        return fresh
    }
}
