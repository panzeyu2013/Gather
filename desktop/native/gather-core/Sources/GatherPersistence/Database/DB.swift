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
        try open()
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
    }

    /// 性能相关 PRAGMA（F-5）。open() 与 settingsProvider 注入后各调用一次：
    /// 首次打开时宿主还没注入设置钩子，注入后必须重放，否则用户改的
    /// db_synchronous / db_cache_size_mb 仍不生效。
    private func applyPerformancePragmas() {
        let storedSync = settingsProvider?("db_synchronous")
        let allowedSync = ["off", "normal", "full", "extra"]
        let syncValue = (storedSync ?? "normal").lowercased()
        applyPragma("PRAGMA synchronous = \(allowedSync.contains(syncValue) ? syncValue : "normal");")
        let storedCache = Int(settingsProvider?("db_cache_size_mb") ?? "64") ?? 64
        applyPragma("PRAGMA cache_size = -\(max(1, min(1024, storedCache)) * 1024);")
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

    /// 设置读取钩子（由宿主注入；nil = 用默认值）。DB 层不直接依赖 SettingsService，
    /// 避免 Database → Services 的反向依赖。注入时立即重放 PRAGMA（F-5）。
    public var settingsProvider: ((String) -> String?)? {
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
    /// R6：**无事务**的 SELECT 从只读池借连接执行（不参与写连接锁）；
    /// 事务内/写语句/PRAGMA/WITH 仍走本连接，语义与旧实现完全一致。
    public func prepare(_ sql: String) throws -> DBStatement {
        let depth = threadTransactionDepth
        if depth == 0, mode == .readWrite, Self.isReadOnlyQuery(sql),
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

    /// 只读语句判定（保守）：仅 trim 后以 SELECT 开头；WITH/RETURNING/PRAGMA 不路由。
    static func isReadOnlyQuery(_ sql: String) -> Bool {
        var slice = Substring(sql)
        while let first = slice.first,
              first == " " || first == "\n" || first == "\t" || first == "\r" {
            slice = slice.dropFirst()
        }
        let lowered = slice.lowercased()
        guard lowered.hasPrefix("select") else { return false }
        let rest = lowered.dropFirst(6)
        guard let next = rest.first else { return true }
        return next == " " || next == "\n" || next == "\t" || next == "\r" || next == "("
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
    /// 走 settingsProvider 会变成每次事务一次设置查询；需要动态开关时用环境变量
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
        owner.withConnectionLock { sqlite3_finalize(stmt) }
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
