// desktop/native/gather-core/Sources/GatherPersistence/Database/DB.swift
// 数据库层基座（1.2）：系统 SQLite3 C API 的薄包装（Package 目标平台为 macOS 14+，
// 仅作本地 SQLite 绑定、不依赖平台专属 API）。
// 决策（2026-08-09）：计划书原拟 SQLite.swift，但其全部版本携带 Apple 专属
// SQLCipher 二进制 target，Linux SwiftPM 无法解析，故改用 `import CSQLite` 自包装，
// 保持零外部依赖，API 语义对齐 better-sqlite3（TS 侧 db/database.ts 的对应物）。
import Foundation
import os
import CSQLite
import GatherProtocol

public final class DBConnection: @unchecked Sendable {
    /// `PRAGMA mmap_size` 的单连接映射上限（性能审计 R4）。
    ///
    /// 256MB 常量：本地磁盘上让 SQLite 直接 mmap DB 文件页，省掉 page-cache→用户态拷贝。
    /// Linux 合成 20k 库（`scripts/perf-sqlite-bench.py --file-db --pragma-ab mmap_size=…`）
    /// 实测列表/排序/元数据批读快 1.1–1.4x；点查/小结果集无变化。仅本地磁盘语义：
    /// 网络卷上 mmap 可能不可靠，SQLite 会自动回退到普通 pager（PRAGMA 不报错）。
    static let mmapSizeBytes: Int = 256 * 1024 * 1024

    private var handle: OpaquePointer?
    /// 连接代数（D6 深审）：每次 open/close 自增。DBStatement 记录创建时的代数，
    /// reopen 后旧语句（指针属于**旧** SQLite 连接）必须失效，不能在新连接上
    /// 读出 affected-row 数。
    private var connectionGeneration: Int64 = 0
    private let reopenPath: String?
    /// 连接用途（R6）：readOnly 供只读池；默认读写。
    public enum Mode: Sendable {
        case readWrite
        case readOnly
    }

    private let mode: Mode
    /// 只读连接池大小（0 = 关闭；仅 readWrite + 文件库生效，":memory:" 永远不建池）。
    private let readPoolSize: Int
    /// 只在只读池连接上生效的 PRAGMA（继承 Database.Options，避免读路径行为分叉）。
    private let poolBusyTimeoutMilliseconds: Int
    private let poolCacheSizeMB: Int
    /// 事务深度键按**连接实例**隔离：同线程多连接时不会把对方事务误判为嵌套。
    private let transactionDepthKey: String

    private struct ReadPoolState: Sendable {
        var pool: ReadConnectionPool?
        var unavailable = false
    }

    /// 只读池状态（R6）：独立小锁，避免每个 SELECT 去抢写连接的 connectionLock。
    private let readPoolState = OSAllocatedUnfairLock(initialState: ReadPoolState())

    /// 文件库的真实路径；内存库为 nil。跨进程 replay claim 用它做作用域。
    public var storagePath: String? {
        reopenPath == ":memory:" ? nil : reopenPath
    }

    /// path 为 ":memory:" 时使用内存库（测试用）。
    /// mode 为 .readOnly 时用于只读池连接（SQLITE_OPEN_READONLY + query_only）。
    /// readPoolSize 为读写连接可附带的只读池大小（0 = 单连接旧行为）。
    /// busyTimeoutMilliseconds/cacheSizeMB 只作用于池内只读连接（写连接由 Database.Options 单独应用）。
    public init(
        path: String,
        mode: Mode = .readWrite,
        readPoolSize: Int = 0,
        busyTimeoutMilliseconds: Int = 5000,
        cacheSizeMB: Int = 8
    ) throws {
        reopenPath = path
        self.mode = mode
        self.readPoolSize = max(0, readPoolSize)
        self.poolBusyTimeoutMilliseconds = max(0, busyTimeoutMilliseconds)
        self.poolCacheSizeMB = max(1, min(1024, cacheSizeMB))
        self.transactionDepthKey = "com.gather.database.transactionDepth.\(UUID().uuidString)"
        try open()
    }

    /// 备份校验用只读连接（feature B0）：等价于 mode = .readOnly。
    public convenience init(path: String, readOnly: Bool) throws {
        try self.init(path: path, mode: readOnly ? .readOnly : .readWrite)
    }

    deinit { close() }

    /// 关闭后按原路径重新打开（迁移回滚流程需要：TS 侧关闭连接→文件恢复→下次访问
    /// 惰性重开，Swift 侧在 rollback 里显式重开以保持连接可用）。
    public func reopen() throws {
        guard mode == .readWrite else {
            throw DBError.message("只读连接不能重新打开")
        }
        guard reopenPath != nil else {
            throw DBError.message("无法重新打开数据库：该连接没有路径信息（内存库）")
        }
        close()
        try open()
    }

    private func open() throws {
        let path = reopenPath ?? ":memory:"
        var db: OpaquePointer?
        let flags: Int32
        switch mode {
        case .readWrite:
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        case .readOnly:
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        }
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            throw DBError.message("无法打开数据库 \(path): \(String(cString: sqlite3_errstr(rc)))")
        }
        handle = db
        connectionGeneration &+= 1
        readPoolState.withLock { $0 = ReadPoolState() }
        if mode == .readWrite {
            try exec("PRAGMA journal_mode = WAL;")
        }
        try exec("PRAGMA foreign_keys = ON;")
        if mode == .readOnly {
            // R6 批 2：池读连接继承 Database.Options 的 busy/cache 预算（只跳过
            // synchronous 与 journal_mode，二者在只读连接上无意义/会被拒绝）。
            try exec("PRAGMA busy_timeout = \(poolBusyTimeoutMilliseconds);")
            try exec("PRAGMA cache_size = -\(poolCacheSizeMB * 1024);")
            try exec("PRAGMA temp_store = MEMORY;")
            // 池连接只读；任何写语句都会显式失败而不是悄悄改库。
            try exec("PRAGMA query_only = ON;")
        } else {
            // 审计 P1-1：多线程共用单连接（JobService worker/协调器/主线程 UI），
            // 无 busy_timeout 时并发写立即 SQLITE_BUSY 冒泡到 UI。5s 等待让
            // 短暂写锁竞争（WAL 单写者）退化为排队而非报错。
            try exec("PRAGMA busy_timeout = 5000;")
            // F-5（性能审计的移植遗漏）：SettingsService 定义了 db_synchronous /
            // db_cache_size_mb 并暴露在设置 UI，但全仓无消费者——用户改了不生效。
            // 这里在打开连接时读取设置并落成 PRAGMA（缺省 normal / 64MB，与 TS 一致）。
            applyPerformancePragmas()
        }
        // 性能审计 R4：mmap_size 对读写连接与只读池连接一致（每连接独立设置）。
        // :memory: 无文件可映射，跳过以免无意义；失败由 applyPragma 记 warn 并保留 SQLite 值。
        if path != ":memory:" {
            applyPragma("PRAGMA mmap_size = \(Self.mmapSizeBytes);")
        }
    }

    /// 性能相关 PRAGMA（F-5）。open() 与 settingsReader 注入后各调用一次：
    /// 首次打开时宿主还没注入设置端口，注入后必须重放，否则用户改的
    /// db_synchronous / db_cache_size_mb 仍不生效。
    ///
    /// #9：改为经 SettingsReading 读（原先是 (String) -> String? 裸闭包）。
    /// 语义逐条保留：白名单外回落 normal；解析失败/非有限值回落 64；钳制 1..1024MB。
    private func applyPerformancePragmas() {
        let allowedSync = ["off", "normal", "full", "extra"]
        let rawSync = (settingsReader?.storedValue(for: .dbSynchronous) ?? "").lowercased()
        let syncValue = allowedSync.contains(rawSync) ? rawSync : "normal"
        applyPragma("PRAGMA synchronous = \(syncValue);")
        let cacheMB = min(1024, max(1, settingsReader?.int(.dbCacheSizeMB) ?? 64))
        applyPragma("PRAGMA cache_size = -\(cacheMB * 1024);")
    }

    /// 性能 PRAGMA 是尽力而为：失败时保留 SQLite 当前值（不影响打开/查询），
    /// 但不能静默吞掉——典型场景是连接已关闭或只读库，需要留诊断日志。
    private func applyPragma(_ sql: String) {
        do {
            try exec(sql)
        } catch {
            GatherLogger.log("PRAGMA 应用失败（保留 SQLite 当前值）: \(error)", level: .warn)
        }
    }

    /// 设置读取端口（由宿主注入；nil = 用键自带默认值）。
    ///
    /// DB 层只依赖 GatherProtocol 的 SettingsReading 协议，不依赖 SettingsService，
    /// Database → Services 的反向依赖依然不存在；端口本身在 Protocol（最底层），
    /// 因此这里不需要任何字符串键。注入时立即重放 PRAGMA（F-5）。
    public var settingsReader: (any SettingsReading)? {
        didSet { applyPerformancePragmas() }
    }

    /// 连接级串行化锁（审计 P1-1）：同一连接上所有 SQL 执行（事务与非事务）
    /// 互斥，对齐 better-sqlite3 单线程语义——防止线程 B 的 autocommit 语句
    /// 插入线程 A 的 BEGIN…COMMIT 之间随其回滚静默丢失，以及
    /// sqlite3_changes/last_insert_rowid 的跨线程错乱。NSRecursiveLock 支持
    /// transaction() 内嵌套的 exec/prepare 重入。
    private let connectionLock = NSRecursiveLock()

    /// 供 DBStatement 执行期持有连接锁（fileprivate：仅数据库层内部使用）。
    fileprivate func withConnectionLock<T>(_ body: () throws -> T) rethrows -> T {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return try body()
    }

    public func close() {
        // R6：先关只读池（每条连接自带锁，不会与写连接锁形成环）。
        let pool = readPoolState.withLock { state -> ReadConnectionPool? in
            let current = state.pool
            state.pool = nil
            // 关闭后不再重建池：prepare 落到 makeStatement，由句柄为空稳定报错。
            state.unavailable = true
            return current
        }
        pool?.close()
        // 问题 4（第三轮审查）：close 原先不取连接锁 —— 与 SQL 执行并发时会出现
        // 「句柄已释放但语句还在用」的窗口。这里纳入同一把锁（重入安全）。
        withConnectionLock {
            if let handle {
                sqlite3_close_v2(handle)
                self.handle = nil
            }
            connectionGeneration &+= 1
        }
    }

    /// 连接是否已关闭（供 DBStatement 校验；问题 4）。
    public var isClosed: Bool {
        withConnectionLock { handle == nil }
    }

    /// 当前连接代数（D6；供 DBStatement 校验创建时的代数）。
    fileprivate var currentGeneration: Int64 {
        withConnectionLock { connectionGeneration }
    }

    /// 供数据库层内部（如 sqlite3_backup 迁移备份）访问原始句柄。
    var rawHandle: OpaquePointer? { handle }

    public var lastInsertRowid: Int64 {
        withConnectionLock {
            guard let handle else { return 0 }
            return sqlite3_last_insert_rowid(handle)
        }
    }

    public var changes: Int {
        withConnectionLock {
            guard let handle else { return 0 }
            return Int(sqlite3_changes(handle))
        }
    }

    /// 执行无返回值的 SQL（连接级锁内执行，见 withConnectionLock）。
    @discardableResult
    public func exec(_ sql: String) throws -> Int {
        try withConnectionLock {
            guard let handle else { throw DBError.message("数据库已关闭") }
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "sqlite3_exec 失败"
                sqlite3_free(err)
                throw DBError.message("\(msg)（SQL: \(sql.prefix(200))）")
            }
            return Int(sqlite3_changes(handle))
        }
    }

    /// 预编译语句。
    ///
    /// R6：**无事务**的只读查询（SELECT / WITH / VALUES）从只读池借连接执行
    /// （不参与写连接锁）；事务内/写语句/PRAGMA 仍走本连接，语义与旧实现一致。
    /// P1-2：WITH 原先被保守排除，现按词法判定（见 isReadOnlyQuery）后可走只读池。
    public func prepare(_ sql: String) throws -> DBStatement {
        let depth = threadTransactionDepth
        // P2：池关闭（readPoolSize == 0；:memory: 默认 0）时不做 O(字节) 词法扫描，换不来路由。
        if depth == 0, mode == .readWrite, readPoolSize > 0, Self.isReadOnlyQuery(sql),
           let pool = ensureReadPool(), let reader = pool.acquire() {
            do {
                return try reader.makeStatement(
                    sql,
                    pooledReturn: { [weak pool] in pool?.release(reader) },
                    readScopeDepth: { [weak self] in self?.threadTransactionDepth ?? 0 },
                    createdScopeDepth: depth
                )
            } catch {
                pool.release(reader)
                throw error
            }
        }
        return try makeStatement(sql, pooledReturn: nil)
    }

    /// 语句工厂（本连接）：池化语句在 deinit 时归还连接。
    private func makeStatement(
        _ sql: String,
        pooledReturn: (() -> Void)?,
        readScopeDepth: (() -> Int)? = nil,
        createdScopeDepth: Int = 0
    ) throws -> DBStatement {
        try withConnectionLock {
            guard let handle else { throw DBError.message("数据库已关闭") }
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
            guard rc == SQLITE_OK, let stmt else {
                throw DBError.message("SQL 编译失败: \(String(cString: sqlite3_errmsg(handle)))")
            }
            return DBStatement(
                handle: stmt, owner: self, generation: connectionGeneration,
                pooledReturn: pooledReturn,
                readScopeDepth: readScopeDepth,
                createdScopeDepth: createdScopeDepth
            )
        }
    }

    /// 只读语句判定（保守）：**首个记号**须为关键字且 ∈ {SELECT, WITH, VALUES}，
    /// 且全文不含写动词。
    ///
    /// P1-2（08-search §P1「修只读池路由」）：旧实现只认 trim 后以 `SELECT` 开头，
    /// 于是 PhotoFilterQuery / FacetQuery / TriageRepo 里 5 条 `WITH …` 热查询全部
    /// 绕过只读池，长写事务期间仍排在同一把连接锁上。这里改为按 SQLite 词法扫描：
    /// **跳过行注释 `-- …`、块注释 `/* … */`、字符串字面量与引用标识符
    /// （`'…'` / `"…"` / 反引号 / `[…]`，双写引号为转义）与绑定参数
    /// （`?1` / `:name` / `@name` / `$name`）**，只看剩下的「裸单词」。因此
    /// `-- DELETE` 注释、字符串 `'DELETE'` 不会把只读语句误判成写语句；而
    /// `WITH … DELETE FROM … RETURNING` 这类「CTE + 顶层写」仍会被拒绝。
    ///
    /// 兜底（双保险）：只读池连接在 `open()` 里带 `PRAGMA query_only = ON;`（见 :123），
    /// 即使这里把写语句误判成只读，SQLite 也会显式报错而不是悄悄改库；其余误判方向
    /// 只会让语句退回写连接（旧行为）。本判定不改变池大小/生命周期，也不改变
    /// `transaction` 语义：路由仍要求事务深度 0，池化语句仍受 readScopeDepth 守卫。
    ///
    /// 唯一函数名例外：SQLite 标量函数 `replace(a, b, c)` 与 REPLACE 动词同名，故仅当
    /// `replace` 后面（跳过空白与注释后）紧跟 `(` 时按函数名放行（`normalizedDateTaken`
    /// 等归一/排序片段在用）；其它写动词没有函数形态，不做例外。
    static func isReadOnlyQuery(_ sql: String) -> Bool {
        let bytes = Array(sql.utf8)
        var index = 0
        var foundLeadingKeyword = false
        while index < bytes.count {
            let byte = bytes[index]
            // 空白
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
                || byte == 0x0B || byte == 0x0C {
                index += 1
                continue
            }
            // 行注释 `-- …`：读到行尾（EOF 也终止）
            if byte == 0x2D, index + 1 < bytes.count, bytes[index + 1] == 0x2D {
                index += 2
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                continue
            }
            // 块注释 `/* … */`：SQLite 不嵌套；未闭合时按到 EOF 处理（与 SQLite 一致）
            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                index += 2
                while index + 1 < bytes.count,
                      !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) {
                    index += 1
                }
                index = index + 1 < bytes.count ? index + 2 : bytes.count
                continue
            }
            // 字符串字面量 / 引用标识符：单引号与双引号用「双写」转义，反引号同理
            if byte == 0x27 || byte == 0x22 || byte == 0x60 {
                let quote = byte
                index += 1
                while index < bytes.count {
                    if bytes[index] == quote {
                        if index + 1 < bytes.count, bytes[index + 1] == quote {
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }
            // 方括号引用标识符 `[name]`
            if byte == 0x5B {
                index += 1
                while index < bytes.count, bytes[index] != 0x5D { index += 1 }
                if index < bytes.count { index += 1 }
                continue
            }
            // 绑定参数 `?1` / `:name` / `@name` / `$name`：整段跳过（参数名不是关键字）
            if byte == 0x3F || byte == 0x3A || byte == 0x40 || byte == 0x24,
               index + 1 < bytes.count, Self.isSQLWordByte(bytes[index + 1]) {
                index += 1
                while index < bytes.count, Self.isSQLWordByte(bytes[index]) { index += 1 }
                continue
            }
            // 单词（关键字 / 标识符 / 数字字面量）
            if Self.isSQLWordByte(byte) {
                let start = index
                while index < bytes.count, Self.isSQLWordByte(bytes[index]) { index += 1 }
                if !foundLeadingKeyword {
                    // 第一个单词必须是只读首关键字，否则整个语句不路由（保守）。
                    guard Self.isReadOnlyLeadingKeyword(bytes, start: start, end: index) else {
                        return false
                    }
                    foundLeadingKeyword = true
                }
                if Self.isWriteVerb(bytes, start: start, end: index) {
                    let isReplaceCall = Self.sqlWord(bytes, start: start, end: index, equals: "replace")
                        && Self.nextSignificantByte(bytes, from: index) == 0x28
                    if !isReplaceCall { return false }
                }
                continue
            }
            // 其余字节（运算符 / 标点 / 转义残片）：首关键字之前出现别的记号
            // （`(`、`;`、`EXPLAIN` 等）即不路由——「首个记号是关键字」是硬条件。
            if !foundLeadingKeyword { return false }
            index += 1
        }
        return foundLeadingKeyword
    }

    /// SQL 单词字节：ASCII 字母/数字/下划线，以及非 ASCII（UTF-8 多字节续字节）。
    /// 后者按「单词的一部分」处理，保证多字节标识符不会被切成两半误判成关键字。
    private static func isSQLWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte >= 0x80
    }

    /// 大小写不敏感（仅 ASCII 折叠）的单词比较：`bytes[start..<end]` 是否等于 `literal`。
    /// 逐字节走字面量的 UTF8 视图，不分配临时字符串。
    private static func sqlWord(
        _ bytes: [UInt8], start: Int, end: Int, equals literal: String
    ) -> Bool {
        var iterator = literal.utf8.makeIterator()
        var index = start
        while index < end {
            guard var expected = iterator.next() else { return false }
            if expected >= 0x41, expected <= 0x5A { expected += 0x20 }
            var actual = bytes[index]
            if actual >= 0x41, actual <= 0x5A { actual += 0x20 }
            if actual != expected { return false }
            index += 1
        }
        return iterator.next() == nil
    }

    /// 只读首关键字：SELECT / WITH / VALUES。
    private static func isReadOnlyLeadingKeyword(
        _ bytes: [UInt8], start: Int, end: Int
    ) -> Bool {
        sqlWord(bytes, start: start, end: end, equals: "select")
            || sqlWord(bytes, start: start, end: end, equals: "with")
            || sqlWord(bytes, start: start, end: end, equals: "values")
    }

    /// 写动词：出现在任何位置都拒绝（含 `WITH … DELETE` 这类顶层写）。
    private static func isWriteVerb(_ bytes: [UInt8], start: Int, end: Int) -> Bool {
        sqlWord(bytes, start: start, end: end, equals: "insert")
            || sqlWord(bytes, start: start, end: end, equals: "update")
            || sqlWord(bytes, start: start, end: end, equals: "delete")
            || sqlWord(bytes, start: start, end: end, equals: "replace")
            || sqlWord(bytes, start: start, end: end, equals: "pragma")
            || sqlWord(bytes, start: start, end: end, equals: "attach")
            || sqlWord(bytes, start: start, end: end, equals: "detach")
            || sqlWord(bytes, start: start, end: end, equals: "create")
            || sqlWord(bytes, start: start, end: end, equals: "drop")
            || sqlWord(bytes, start: start, end: end, equals: "alter")
    }

    /// 下一个非空白 / 非注释字节（区分 `replace(` 函数调用与 `REPLACE INTO` 动词）。
    /// 注释不是记号：`replace /* c */ (` / `replace -- c\n(` 仍是函数调用（P2）。
    private static func nextSignificantByte(_ bytes: [UInt8], from index: Int) -> UInt8? {
        var cursor = index
        while cursor < bytes.count {
            switch bytes[cursor] {
            case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C: cursor += 1
            case 0x2D where cursor + 1 < bytes.count && bytes[cursor + 1] == 0x2D:
                cursor += 2
                while cursor < bytes.count, bytes[cursor] != 0x0A { cursor += 1 }
            case 0x2F where cursor + 1 < bytes.count && bytes[cursor + 1] == 0x2A:
                cursor += 2
                while cursor + 1 < bytes.count,
                      !(bytes[cursor] == 0x2A && bytes[cursor + 1] == 0x2F) { cursor += 1 }
                cursor = cursor + 1 < bytes.count ? cursor + 2 : bytes.count
            default:
                return bytes[cursor]
            }
        }
        return nil
    }

    /// 懒建只读池：首次 SELECT 时创建（此时 schema 已就绪）；失败后退化为单连接。
    ///
    /// R6：状态用独立小锁（readPoolState），**不取写连接锁**——否则长事务期间
    /// 每个 SELECT 仍会在建池检查处排队，读池失去意义。
    private func ensureReadPool() -> ReadConnectionPool? {
        guard readPoolSize > 0, mode == .readWrite,
              let path = reopenPath, path != ":memory:" else { return nil }
        if let pool = readPoolState.withLock({ $0.pool }) { return pool }
        return readPoolState.withLock { state -> ReadConnectionPool? in
            if let pool = state.pool { return pool }
            guard !state.unavailable else { return nil }
            do {
                let pool = try ReadConnectionPool(
                    path: path,
                    size: readPoolSize,
                    busyTimeoutMilliseconds: poolBusyTimeoutMilliseconds,
                    cacheSizeMB: poolCacheSizeMB
                )
                state.pool = pool
                return pool
            } catch {
                state.unavailable = true
                GatherLogger.log("只读连接池创建失败，退化为单连接：\(error)", level: .warn)
                return nil
            }
        }
    }

    // ── 事务 ──
    /// 事务开启模式（WP6a / 设计 §4.4）。默认 deferred 保持既有 30+ 调用点行为；
    /// 迁移器用 immediate：WAL 下先拿写锁，避免 deferred 读→写升级撞 SQLITE_BUSY_SNAPSHOT。
    /// 嵌套事务仍退化为 SAVEPOINT，模式参数只影响最外层。
    public enum TransactionMode: String, Sendable {
        case deferred = "DEFERRED"
        case immediate = "IMMEDIATE"
        case exclusive = "EXCLUSIVE"
    }

    public func begin() throws { try exec("BEGIN") }
    public func commit() throws { try exec("COMMIT") }
    public func rollback() throws { try exec("ROLLBACK") }

    /// 嵌套事务计数改为线程局部（R6）：同一线程的嵌套仍退化为 SAVEPOINT
    /// （better-sqlite3 语义），但其它线程看不到该深度，可从只读池读；
    /// 事务本身仍持连接级锁（同一连接上的事务严格串行）。
    ///
    /// R6 批 2：键必须带**连接身份**（transactionDepthKey）。否则同线程上第二个
    /// DBConnection 会把对方事务误判为嵌套，只发 SAVEPOINT 而丢掉 BEGIN IMMEDIATE。
    private var threadTransactionDepth: Int {
        get { (Thread.current.threadDictionary[transactionDepthKey] as? Int) ?? 0 }
        set { Thread.current.threadDictionary[transactionDepthKey] = newValue }
    }

    /// 默认 deferred（TransactionRunner 端口要求的就是这个签名）。
    public func transaction<T>(
        _ body: () throws -> T,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) throws -> T {
        try transaction(.deferred, body, file: file, line: line, function: function)
    }

    /// R6-a：慢事务诊断阈值（毫秒；0 = 关闭）。
    /// 开启优先级：静态阈值 > 环境变量 GATHER_SLOW_TX_MS（生产诊断入口）。
    /// **不读 SettingsService**：阈值检查发生在每个最外层事务的收尾路径上，
    /// 走 settingsReader 会变成每次事务一次设置查询；需要动态开关时用环境变量
    /// 或显式设置静态阈值。只影响日志，不改变事务语义。
    nonisolated(unsafe) public static var slowTransactionThresholdMilliseconds: Int = 0

    /// 环境变量只读一次（避免每次最外层事务都复制整个 environment 字典）。
    private static let environmentSlowThreshold: Int =
        Int(ProcessInfo.processInfo.environment["GATHER_SLOW_TX_MS"] ?? "") ?? 0

    private func slowThreshold() -> Int {
        if Self.slowTransactionThresholdMilliseconds > 0 {
            return Self.slowTransactionThresholdMilliseconds
        }
        return max(0, Self.environmentSlowThreshold)
    }

    private func logIfSlow(
        queuedAt: Date,
        startedAt: Date,
        file: String,
        line: Int,
        function: String
    ) {
        let threshold = slowThreshold()
        guard threshold > 0 else { return }
        let queueMs = Int(startedAt.timeIntervalSince(queuedAt) * 1000)
        let execMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard execMs + queueMs >= threshold else { return }
        GatherLogger.log(
            "slow transaction: exec=\(execMs)ms queue=\(queueMs)ms threshold=\(threshold)ms "
                + "at \(file):\(line) \(function)",
            level: .warn)
    }

    /// 显式指定最外层开启模式；嵌套调用仍退化为 SAVEPOINT。
    ///
    /// R6：深度改为**线程局部**——事务期间其它线程的 SELECT 可走只读池，
    /// 不再被写连接的锁串行化；事务线程内部的语句仍走写连接（读己写）。
    public func transaction<T>(
        _ mode: TransactionMode,
        _ body: () throws -> T,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) throws -> T {
        // R6-a：queuedAt 用于区分「锁排队」与「事务执行」，避免并发写被误报为慢事务。
        let queuedAt = Date()
        var startedAt = queuedAt
        var appliedDepth = 0
        defer {
            if appliedDepth == 1 {
                logIfSlow(
                    queuedAt: queuedAt, startedAt: startedAt,
                    file: file, line: line, function: function)
            }
        }
        return try withConnectionLock {
            startedAt = Date()
            let depth = threadTransactionDepth + 1
            appliedDepth = depth
            threadTransactionDepth = depth
            defer { threadTransactionDepth = depth - 1 }
            let isNested = depth > 1
            if isNested {
                try exec("SAVEPOINT gather_tx_\(depth)")
            } else {
                try exec("BEGIN \(mode.rawValue)")
            }
            do {
                let result = try body()
                if isNested {
                    try exec("RELEASE SAVEPOINT gather_tx_\(depth)")
                } else {
                    try commit()
                }
                return result
            } catch {
                if isNested {
                    _ = try? exec("ROLLBACK TO SAVEPOINT gather_tx_\(depth)")
                    _ = try? exec("RELEASE SAVEPOINT gather_tx_\(depth)")
                } else {
                    _ = try? rollback()
                }
                throw error
            }
        }
    }
}

/// 预编译语句（对应 better-sqlite3 Statement）。
public final class DBStatement {
    private let stmt: OpaquePointer
    private let owner: DBConnection
    /// 创建该语句时的连接代数（D6）。reopen/close 之后与 owner 的当前代数不符即失效。
    private let generation: Int64
    /// R6：只读池语句在释放时归还连接（非池化语句为 nil）。
    private let pooledReturn: (() -> Void)?
    /// 复审 P2：池化语句创建时主连接的事务深度；执行时再取一次，不一致即 fail-closed。
    /// 防止“事务外 prepare、事务内执行”静默落到只读连接而丢掉读己写。
    private let readScopeDepth: (() -> Int)?
    private let createdScopeDepth: Int

    fileprivate init(
        handle: OpaquePointer,
        owner: DBConnection,
        generation: Int64,
        pooledReturn: (() -> Void)? = nil,
        readScopeDepth: (() -> Int)? = nil,
        createdScopeDepth: Int = 0
    ) {
        self.stmt = handle
        self.owner = owner
        self.generation = generation
        self.pooledReturn = pooledReturn
        self.readScopeDepth = readScopeDepth
        self.createdScopeDepth = createdScopeDepth
    }

    deinit {
        // finalize 必须与同一连接的其它语句互斥（池化连接会被不同线程复用）。
        _ = owner.withConnectionLock { sqlite3_finalize(stmt) }
        pooledReturn?()
    }

    /// 连接已关闭即拒绝（问题 4：旧实现会把 stmt 指针当成 db 指针去做
    /// sqlite3_errmsg/sqlite3_changes，句柄类型错误；关闭后 prepare/run/query
    /// 必须稳定失败而不是静默返回 0）。
    private func requireOpenConnection() throws {
        if owner.isClosed { throw DBError.message("数据库已关闭") }
        // D6：连接代数不一致 = 语句属于已被 close/reopen 替换掉的旧连接。
        guard owner.currentGeneration == generation else {
            throw DBError.message("数据库连接已重开，语句已失效")
        }
        // P2（复审）：池化语句不得跨事务作用域执行（否则读己写/隔离语义静默丢失）。
        if let readScopeDepth, readScopeDepth() != createdScopeDepth {
            throw DBError.message("只读池语句不得跨事务作用域执行（创建深度 \(createdScopeDepth)）")
        }
    }

    /// 按顺序绑定位置参数（1-based，对应 SQL 中的 `?`）。
    public func bind(_ index: Int, _ value: DBValue?) throws {
        try owner.withConnectionLock {
            try requireOpenConnection()
            let rc: Int32
        switch value ?? .null {
        case .null:
            rc = sqlite3_bind_null(stmt, Int32(index))
        case .int(let v):
            rc = sqlite3_bind_int64(stmt, Int32(index), v)
        case .real(let v):
            rc = sqlite3_bind_double(stmt, Int32(index), v)
        case .text(let v):
            rc = sqlite3_bind_text(stmt, Int32(index), v, -1, SQLITE_TRANSIENT_PTR)
        case .blob(let v):
            rc = v.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, Int32(index), buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT_PTR)
            }
        }
            guard rc == SQLITE_OK else { throw DBError.message("绑定参数失败: \(sqlite3_errcode(stmt))") }
        }
    }

    public func bind(_ values: [DBValue?]) throws {
        for (i, v) in values.enumerated() {
            try bind(i + 1, v)
        }
    }

    public func reset() {
        owner.withConnectionLock {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
    }

    /// 执行并取回全部行（连接级锁内执行，见 withConnectionLock）。
    public func query(_ values: [DBValue?] = []) throws -> [DBRow] {
        try owner.withConnectionLock {
            try requireOpenConnection()
            try bind(values)
            defer { reset() }
            var rows: [DBRow] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    rows.append(columns())
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    try throwQueryFailure("查询失败")
                }
            }
            return rows
        }
    }

    /// 执行并返回受影响行数（连接级锁内执行，见 withConnectionLock）。
    public func run(_ values: [DBValue?] = []) throws -> Int {
        try owner.withConnectionLock {
            try requireOpenConnection()
            try bind(values)
            defer { reset() }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                try throwQueryFailure("执行失败")
            }
            try requireOpenConnection()
            guard let dbHandle = owner.handlePublic else { throw DBError.message("数据库已关闭") }
            return Int(sqlite3_changes(dbHandle))
        }
    }

    /// 取单行（无行返回 nil；连接级锁内执行，见 withConnectionLock）。
    public func get(_ values: [DBValue?] = []) throws -> DBRow? {
        try owner.withConnectionLock {
            try requireOpenConnection()
            try bind(values)
            defer { reset() }
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { return columns() }
            if rc == SQLITE_DONE { return nil }
            try throwQueryFailure("查询失败")
        }
    }

    /// 执行并取回带列名的全部行（R1-09；列序无关映射的入口）。
    ///
    /// 列名在首次 step 前由 sqlite3_column_name 读取；同名重复列会被 `NamedRow`
    /// 拒绝（JOIN 必须显式 AS 别名）。SQL 本身仍应写显式列清单，禁止 SELECT *。
    public func queryNamed(_ values: [DBValue?] = []) throws -> [NamedRow] {
        try owner.withConnectionLock {
            try requireOpenConnection()
            try bind(values)
            defer { reset() }
            let names = columnNames()
            var rows: [NamedRow] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    rows.append(try NamedRow(columns: names, values: columns()))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    try throwQueryFailure("查询失败")
                }
            }
            return rows
        }
    }

    /// 取单行（带列名；无行返回 nil）。语义与 `get` 一致，仅多保留列名。
    public func getNamed(_ values: [DBValue?] = []) throws -> NamedRow? {
        try owner.withConnectionLock {
            try requireOpenConnection()
            try bind(values)
            defer { reset() }
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                return try NamedRow(columns: columnNames(), values: columns())
            }
            if rc == SQLITE_DONE { return nil }
            try throwQueryFailure("查询失败")
        }
    }

    /// 结果集列名（与 `columns()` 等长、同序）。
    private func columnNames() -> [String] {
        let count = Int(sqlite3_column_count(stmt))
        return (0..<count).map { col in
            sqlite3_column_name(stmt, Int32(col)).map { String(cString: $0) } ?? ""
        }
    }

    private func columns() -> DBRow {
        let count = Int(sqlite3_column_count(stmt))
        return (0..<count).map { col -> DBValue in
            switch sqlite3_column_type(stmt, Int32(col)) {
            case SQLITE_NULL:
                return .null
            case SQLITE_INTEGER:
                return .int(sqlite3_column_int64(stmt, Int32(col)))
            case SQLITE_FLOAT:
                return .real(sqlite3_column_double(stmt, Int32(col)))
            case SQLITE_TEXT:
                guard let c = sqlite3_column_text(stmt, Int32(col)) else { return .null }
                return .text(String(cString: c))
            case SQLITE_BLOB:
                guard let p = sqlite3_column_blob(stmt, Int32(col)) else { return .null }
                let n = Int(sqlite3_column_bytes(stmt, Int32(col)))
                return .blob(Data(bytes: p, count: n))
            default:
                return .null
            }
        }
    }

    /// 错误消息辅助：连接已关闭时不触碰任何句柄（问题 4），直接抛「数据库已关闭」。
    private func throwQueryFailure(_ prefix: String) throws -> Never {
        if owner.isClosed { throw DBError.message("数据库已关闭") }
        guard let handle = owner.handlePublic else { throw DBError.message("数据库已关闭") }
        throw DBError.message("\(prefix): \(String(cString: sqlite3_errmsg(handle)))")
    }

}

// SQLITE_TRANSIENT 是宏，模块映射不导出，用标准等价写法：
// 通知 SQLite 复制传入的字符串/字节（-1 值被安全转为 destructor 类型）。
private let SQLITE_TRANSIENT_PTR: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? =
    unsafeBitCast(-1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?.self)

extension DBConnection {
    /// 供 DBStatement 读取错误消息（内部使用）。
    fileprivate var handlePublic: OpaquePointer? { withConnectionLock { handle } }

}

extension DBValue {
    /// SQLite 存储类名（错误消息用）。
    public var typeName: String {
        switch self {
        case .null: return "NULL"
        case .int: return "INTEGER"
        case .real: return "REAL"
        case .text: return "TEXT"
        case .blob: return "BLOB"
        }
    }

    /// 便捷取整数值。
    public var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    public var textValue: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    public var doubleValue: Double? {
        if case .real(let v) = self { return v }
        return nil
    }
}
