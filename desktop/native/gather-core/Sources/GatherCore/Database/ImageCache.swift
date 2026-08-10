// desktop/native/gather-core/Sources/GatherCore/Database/ImageCache.swift
// 磁盘缩略图缓存（Phase 2 任务 2.1「解码 + 缩略图」磁盘缓存重写）。
// TS 源: desktop/src/main/services/image/disk-cache.ts（547 行，DiskCacheManager）
//       + desktop/src/main/services/image/image.service.ts 的 DiskThumbnailCache 段
//       （文件读写/哈希键/64MB 读上限合并进本类）。
// 计划: NATIVE-DEVELOPMENT-ANALYSIS.md §2.1「重写，SQLite 换 SQLite.swift」；
//       本环境用系统 SQLite3（Database/DB.swift 的 DBConnection，better-sqlite3 语义）。
//
// 能力契约保留（对应 TS 语义）：
//   - 元数据独立 DB 文件 <cacheRootDir>/cache-meta.db（WAL），表 cache_meta 由本类
//     自带建表（CREATE TABLE IF NOT EXISTS），不污染主 schema。
//   - 热路径 onSet/onAccess 纯内存 + 脏集合；持久化 500ms debounce / 256 条阈值
//     批量事务 upsert + delete（对应 TS queuePersist，dirty/pendingDeletes 入队即快照）。
//   - 淘汰：SQLite 每策略索引窗口（ORDER BY <policy> ASC, hash ASC LIMIT limit+|dirty|）
//     与脏集合合并、按内存现值排序取 limit，LRU=lastAccess / FIFO=createdAt /
//     LFU=accessCount，hash 决胜；每轮淘汰前先等待在途持久化完成（避免旧 SQL 视图）；
//     被重新 put 的 hash 跳过 unlink，避免删掉新文件。
//   - 启动对账：readdir(.jpg) 差集——悬挂 DB 行 → pendingDeletes，孤儿文件 →
//     stat(atime/birthtime||mtime/size) 收养（accessCount=0 并标记脏）；删除遗留
//     cache-meta.json。
//   - DB 损坏 → 改名 .corrupt-<ts> 重建；仍失败（只读目录）→ :memory: 纯内存元数据。
//   - 文件写入原子性：临时文件 + rename()（对应 TS tmp + 'wx' + rename）。
// 扩展（TS 无，按任务要求新增，报告列偏差）：
//   - put/get/delete 文件读写层；get 带 64MB 读上限（TS DiskThumbnailCache 的
//     DISK_CACHE_READ_CAP_BYTES），超限视为未命中。
//   - 可选 TTL：createdAt + ttl < now 视为过期，get 与淘汰时清理；默认关闭。
// 结构差异（TS 主线程 + promise 链 → Swift 锁 + 串行任务链）：
//   - load 在 init 同步完成（waitUntilReady 恒立即返回）；TS 的 preReadySets 重放
//     逻辑不再需要。
//   - 持久化/淘汰经 SerialChain（等价 promise 链）串行；跨任务共享的内存状态由
//     NSLock 保护，DB 访问由 dbLock 串行（锁序恒为 lock → dbLock）。

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 磁盘缩略图缓存：`put`/`get`/`delete` + 元数据 SQLite 持久化 + 惰性淘汰。
/// 线程安全：所有可变状态持锁，持久化/淘汰经串行任务链。
public final class ImageCache: @unchecked Sendable {
    public enum EvictionPolicy: String, Sendable {
        case lru = "lru"
        case fifo = "fifo"
        case lfu = "lfu"
    }

    /// 单条元数据（对应 TS CacheEntry）。
    public struct CacheEntry: Sendable, Equatable {
        public var lastAccess: Int64
        public var createdAt: Int64
        public var accessCount: Int64
        public var fileSize: Int64

        public init(lastAccess: Int64, createdAt: Int64, accessCount: Int64, fileSize: Int64) {
            self.lastAccess = lastAccess
            self.createdAt = createdAt
            self.accessCount = accessCount
            self.fileSize = fileSize
        }
    }

    /// 统计（对应 TS getStats()）。
    public struct Stats: Sendable, Equatable {
        public var totalSize: Int64
        public var fileCount: Int
        public var maxSize: Int64
        public var policy: EvictionPolicy
        public var ttlMilliseconds: Int64?

        public init(totalSize: Int64, fileCount: Int, maxSize: Int64, policy: EvictionPolicy, ttlMilliseconds: Int64?) {
            self.totalSize = totalSize
            self.fileCount = fileCount
            self.maxSize = maxSize
            self.policy = policy
            self.ttlMilliseconds = ttlMilliseconds
        }
    }

    /// 时钟注入（毫秒时间戳），默认墙钟；测试注入可控时钟验证 TTL。
    public typealias Clock = () -> Int64

    private enum ImageCacheError: Error {
        case renameFailed
    }

    private struct EvictionCandidate {
        let hash: String
        let val: Int64
        let size: Int64
    }

    private static let persistDebounceNanos: UInt64 = 500_000_000
    private static let persistFlushThreshold = 256
    private static let minEvictionBatch = 100

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS cache_meta (
      hash TEXT PRIMARY KEY,
      last_access INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      access_count INTEGER NOT NULL,
      file_size INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_cache_meta_last_access ON cache_meta (last_access);
    CREATE INDEX IF NOT EXISTS idx_cache_meta_created_at ON cache_meta (created_at);
    CREATE INDEX IF NOT EXISTS idx_cache_meta_access_count ON cache_meta (access_count);
    """

    private let cacheRootDir: String
    private let maxSizeBytes: Int64
    private let policy: EvictionPolicy
    private let ttlMilliseconds: Int64?
    private let readCapBytes: Int64
    private let clock: Clock

    private let lock = NSLock()
    private let dbLock = NSLock()
    private let db: DBConnection

    private var entries: [String: CacheEntry] = [:]
    private var totalSize: Int64 = 0
    private var fileCount: Int = 0
    private var dirty = Set<String>()
    private var pendingDeletes = Set<String>()
    private var debounceTask: Task<Void, Never>?

    private let persistChain = SerialChain()
    private let evictionChain = SerialChain()

    public init(
        cacheRootDir: String,
        maxSizeBytes: Int64,
        policy: EvictionPolicy = .lru,
        ttlMilliseconds: Int64? = nil,
        readCapBytes: Int64 = 64 * 1024 * 1024,
        clock: @escaping Clock = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.cacheRootDir = cacheRootDir
        self.maxSizeBytes = maxSizeBytes
        self.policy = policy
        self.ttlMilliseconds = ttlMilliseconds
        self.readCapBytes = readCapBytes
        self.clock = clock
        do {
            try FileManager.default.createDirectory(atPath: cacheRootDir, withIntermediateDirectories: true)
        } catch {
            GatherLogger.log("ImageCache: 无法创建缓存目录，继续运行（元数据库将退化为内存）: \(error)", level: .warn)
        }
        self.db = Self.openMetadataDatabase(in: cacheRootDir)
        load()
    }

    deinit {
        debounceTask?.cancel()
    }

    /// 键 → 文件名哈希：sha256(key) 的 hex 前 16 字符（TS image.service.ts hashKey）。
    public static func hashKey(_ key: String) -> String {
        let digest = SHA256.hash(Data(key.utf8))
        let digits: [Character] = Array("0123456789abcdef")
        var hex = ""
        hex.reserveCapacity(16)
        for byte in digest.prefix(8) {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0f)])
        }
        return hex
    }

    /// load 在 init 同步完成，恒立即返回（保留 TS waitUntilReady 契约）。
    public func waitUntilReady() async {}

    /// 写入缓存：临时文件 + 原子 rename，随后记录元数据并触发惰性淘汰。
    /// 磁盘写入失败时静默跳过（TS 语义）；缓存文件 = <dir>/<hashKey(key)>.jpg。
    public func put(_ data: Data, forKey key: String) async {
        await waitUntilReady()
        let hash = Self.hashKey(key)
        let fileURL = fileURL(for: hash)
        let tmpURL = tmpURL(for: hash)
        do {
            try data.write(to: tmpURL)
            let rc = tmpURL.path.withCString { tmp in
                fileURL.path.withCString { dest in rename(tmp, dest) }
            }
            guard rc == 0 else { throw ImageCacheError.renameFailed }
            onSet(hash: hash, fileSize: Int64(data.count), at: clock())
            await evictIfNeeded()
        } catch {
            GatherLogger.log("ImageCache: 缓存文件写入失败，静默跳过 \(key): \(error)", level: .warn)
        }
        try? FileManager.default.removeItem(at: tmpURL)
    }

    /// 读取缓存：先 TTL 检查（扩展），再按 64MB 读上限校验文件大小（超限视为未命中，
    /// 对应 TS DISK_CACHE_READ_CAP_BYTES），命中后刷新 lastAccess/accessCount。
    public func get(_ key: String) async -> Data? {
        await waitUntilReady()
        let hash = Self.hashKey(key)
        let now = clock()

        let expired = withLock { () -> Bool in
            guard let entry = entries[hash], isExpiredLocked(entry, now: now) else { return false }
            removeEntryLocked(hash, entry)
            return true
        }
        if expired {
            try? FileManager.default.removeItem(at: fileURL(for: hash))
            enqueuePersist()
            return nil
        }

        let fileURL = fileURL(for: hash)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size <= readCapBytes else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        onAccess(hash: hash, at: now)
        return data
    }

    /// 删除缓存条目（内存元数据 + 磁盘文件 + 待持久化删除）。TS DiskCacheManager 无
    /// 公开 delete，此为任务要求的扩展；删除不存在的键为空操作。
    public func delete(_ key: String) async {
        await waitUntilReady()
        let hash = Self.hashKey(key)
        let existed = withLock { () -> Bool in
            guard let entry = entries[hash] else { return false }
            removeEntryLocked(hash, entry)
            return true
        }
        try? FileManager.default.removeItem(at: fileURL(for: hash))
        if existed {
            enqueuePersist()
        }
    }

    /// 惰性淘汰：超出容量上限时按策略淘汰并删除文件；串行化，重复调用安全。
    public func evictIfNeeded() async {
        await waitUntilReady()
        let task = evictionChain.enqueue { await self.performEviction() }
        await task.value
    }

    /// 立即落盘挂起的元数据变更；等待此方法返回后，同一目录新建的缓存实例
    /// 能观察到之前的所有变更（对应 TS flush 契约）。
    public func flush() async {
        await waitUntilReady()
        clearDebounce()
        enqueuePersist()
        await persistChain.waitUntilIdle()
    }

    /// 统计（对应 TS getStats()；额外带 ttl 字段）。
    public func stats() -> Stats {
        withLock {
            Stats(
                totalSize: totalSize,
                fileCount: fileCount,
                maxSize: maxSizeBytes,
                policy: policy,
                ttlMilliseconds: ttlMilliseconds
            )
        }
    }

    /// 全部内存元数据快照（对应 TS getMetadata()）。
    public func metadata() -> [String: CacheEntry] {
        withLock { entries }
    }

    // ── 内存元数据热路径 ──

    private func onSet(hash: String, fileSize: Int64, at: Int64) {
        var persistNow = false
        withLock {
            if let old = entries[hash] {
                totalSize -= old.fileSize
            } else {
                fileCount += 1
            }
            entries[hash] = CacheEntry(lastAccess: at, createdAt: at, accessCount: 1, fileSize: fileSize)
            totalSize += fileSize
            markDirtyLocked(hash)
            persistNow = dirty.count >= Self.persistFlushThreshold
        }
        if persistNow {
            clearDebounce()
            enqueuePersist()
        } else {
            scheduleDebounce()
        }
    }

    private func onAccess(hash: String, at: Int64) {
        var persistNow = false
        withLock {
            guard var entry = entries[hash] else { return }
            entry.lastAccess = at
            entry.accessCount += 1
            entries[hash] = entry
            markDirtyLocked(hash)
            persistNow = dirty.count >= Self.persistFlushThreshold
        }
        if persistNow {
            clearDebounce()
            enqueuePersist()
        } else {
            scheduleDebounce()
        }
    }

    private func markDirtyLocked(_ hash: String) {
        pendingDeletes.remove(hash)
        dirty.insert(hash)
    }

    private func removeEntryLocked(_ hash: String, _ entry: CacheEntry) {
        entries[hash] = nil
        totalSize -= entry.fileSize
        fileCount -= 1
        dirty.remove(hash)
        pendingDeletes.insert(hash)
    }

    private func isExpiredLocked(_ entry: CacheEntry, now: Int64) -> Bool {
        guard let ttl = ttlMilliseconds, now > entry.createdAt else { return false }
        return now - entry.createdAt > ttl
    }

    // ── 持久化（debounce + 阈值批量事务，对应 TS queuePersist） ──

    private func enqueuePersist() {
        let snapshot = withLock { () -> (rows: [(String, CacheEntry)], deletes: [String]) in
            let deletes = Array(pendingDeletes)
            pendingDeletes.removeAll()
            let dirtyCopy = dirty
            dirty.removeAll()
            var rows: [(String, CacheEntry)] = []
            rows.reserveCapacity(dirtyCopy.count)
            for hash in dirtyCopy {
                if let entry = entries[hash] {
                    rows.append((hash, entry))
                }
            }
            return (rows, deletes)
        }
        guard !snapshot.rows.isEmpty || !snapshot.deletes.isEmpty else { return }
        let rows = snapshot.rows
        let deletes = snapshot.deletes
        _ = persistChain.enqueue {
            self.persistBatch(rows: rows, deletes: deletes)
        }
    }

    private func persistBatch(rows: [(String, CacheEntry)], deletes: [String]) {
        dbLock.lock()
        defer { dbLock.unlock() }
        do {
            try db.transaction {
                let upsert = try db.prepare("""
                    INSERT INTO cache_meta (hash, last_access, created_at, access_count, file_size)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(hash) DO UPDATE SET
                      last_access = excluded.last_access,
                      created_at = excluded.created_at,
                      access_count = excluded.access_count,
                      file_size = excluded.file_size
                """)
                for (hash, entry) in rows {
                    _ = try upsert.run([.text(hash), .int(entry.lastAccess), .int(entry.createdAt), .int(entry.accessCount), .int(entry.fileSize)])
                }
                let deleteStmt = try db.prepare("DELETE FROM cache_meta WHERE hash = ?")
                for hash in deletes {
                    _ = try deleteStmt.run([.text(hash)])
                }
            }
        } catch {
            GatherLogger.log("ImageCache: 元数据写入失败: \(error)", level: .warn)
        }
    }

    private func scheduleDebounce() {
        withLock {
            guard debounceTask == nil else { return }
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.persistDebounceNanos)
                guard let self else { return }
                self.clearDebounce()
                self.enqueuePersist()
            }
        }
    }

    private func clearDebounce() {
        withLock {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    // ── 淘汰（对应 TS performEviction + selectEvictionBatch） ──

    private func performEviction() async {
        // 先等待在途持久化：SQLite 行必须反映最新内存值，索引窗口排序才正确
        //（TS 同款先 await persistQueue）。
        await persistChain.waitUntilIdle()

        var evicted = 0
        var limit = Self.minEvictionBatch

        // TTL 扩展：先扫掉过期条目，避免它们占据预算却永不被 LRU 淘汰。
        if ttlMilliseconds != nil {
            let removed = withLock { () -> [String] in
                let now = clock()
                var removed: [String] = []
                for (hash, entry) in entries where isExpiredLocked(entry, now: now) {
                    removeEntryLocked(hash, entry)
                    removed.append(hash)
                }
                return removed
            }
            if !removed.isEmpty {
                evicted += removed.count
                for hash in removed {
                    try? FileManager.default.removeItem(at: fileURL(for: hash))
                }
            }
        }

        while true {
            let pass = withLock { () -> [String]? in
                guard totalSize > maxSizeBytes, fileCount > 0 else { return nil }
                let avgSize = Double(totalSize) / Double(fileCount)
                let needed = totalSize - maxSizeBytes
                let byEstimate = Int((Double(needed) / avgSize).rounded(.up)) + 1
                limit = min(fileCount, max(limit * 2, Self.minEvictionBatch, byEstimate))

                let candidates = selectEvictionBatchLocked(limit: limit)
                var toRemove: [String] = []
                for candidate in candidates {
                    if totalSize <= maxSizeBytes { break }
                    guard let entry = entries[candidate.hash] else { continue }
                    removeEntryLocked(candidate.hash, entry)
                    evicted += 1
                    toRemove.append(candidate.hash)
                }
                return toRemove.isEmpty ? nil : toRemove
            }
            guard let toRemove = pass else { break }
            // 内存/元数据已一致，unlink 失败无碍后续轮次；被重新 put 的 hash
            //（已回到内存）必须跳过，不能删掉新文件（TS 同款过滤）。
            let fresh = withLock { toRemove.filter { entries[$0] == nil } }
            for hash in fresh {
                try? FileManager.default.removeItem(at: fileURL(for: hash))
            }
        }

        if evicted > 0 {
            enqueuePersist()
        }
    }

    /// 每策略窗口（limit + |dirty| 行）与脏集合合并，按内存现值升序 + hash 决胜
    /// 取 limit 个候选——与全量扫描严格等价（TS selectEvictionBatch 同款论证）。
    /// 前置：调用方持有 lock；内部按锁序获取 dbLock。
    private func selectEvictionBatchLocked(limit: Int) -> [EvictionCandidate] {
        let windowSize = limit + dirty.count
        let orderBy: String
        switch policy {
        case .fifo:
            orderBy = "created_at ASC, hash ASC"
        case .lfu:
            orderBy = "access_count ASC, hash ASC"
        case .lru:
            orderBy = "last_access ASC, hash ASC"
        }
        var rows: [DBRow] = []
        dbLock.lock()
        defer { dbLock.unlock() }
        do {
            rows = try db.prepare(
                "SELECT hash, last_access, created_at, access_count, file_size FROM cache_meta ORDER BY \(orderBy) LIMIT ?"
            ).query([.int(Int64(windowSize))])
        } catch {
            rows = []
        }

        var seen = Set<String>()
        var candidates: [EvictionCandidate] = []
        for row in rows {
            guard let hash = row[0].textValue else { continue }
            // 行可能过期（内存已淘汰未落盘，或被脏更新取代）；内存条目为准。
            guard let live = entries[hash] else { continue }
            seen.insert(hash)
            candidates.append(EvictionCandidate(hash: hash, val: policyValue(live), size: live.fileSize))
        }
        // 未落盘的脏条目（全新写入或 debounce 窗口内的访问突发）合并进来。
        for hash in dirty {
            if seen.contains(hash) { continue }
            guard let entry = entries[hash] else { continue }
            seen.insert(hash)
            candidates.append(EvictionCandidate(hash: hash, val: policyValue(entry), size: entry.fileSize))
        }
        candidates.sort { a, b in
            if a.val != b.val { return a.val < b.val }
            return a.hash < b.hash
        }
        return Array(candidates.prefix(limit))
    }

    private func policyValue(_ entry: CacheEntry) -> Int64 {
        switch policy {
        case .fifo: return entry.createdAt
        case .lfu: return entry.accessCount
        case .lru: return entry.lastAccess
        }
    }

    // ── 加载与对账（对应 TS load()） ──

    private func load() {
        // 遗留 JSON 元数据不再维护，删除以免在缓存目录累积。
        for legacyPath in ["cache-meta.json", "cache-meta.json.tmp"] {
            try? FileManager.default.removeItem(atPath: cacheRootDir + "/" + legacyPath)
        }

        dbLock.lock()
        defer { dbLock.unlock() }
        do {
            // 单次按 hash 排序全量读取（TS 分块读取是为了主线程 50ms 预算；
            // Swift 侧 init 由调用方决定线程，无需分块）。
            let rows = try db.prepare(
                "SELECT hash, last_access, created_at, access_count, file_size FROM cache_meta ORDER BY hash"
            ).query()
            for row in rows {
                guard let hash = row[0].textValue,
                      let lastAccess = row[1].intValue,
                      let createdAt = row[2].intValue,
                      let accessCount = row[3].intValue,
                      let fileSize = row[4].intValue else { continue }
                entries[hash] = CacheEntry(lastAccess: lastAccess, createdAt: createdAt, accessCount: accessCount, fileSize: fileSize)
                fileCount += 1
                totalSize += fileSize
            }
        } catch {
            GatherLogger.log("ImageCache: 元数据库读取失败，按目录扫描重建: \(error)", level: .warn)
            entries.removeAll()
            totalSize = 0
            fileCount = 0
        }

        // 与文件系统对账（TS 同款差集策略）：
        //  - DB 行无对应文件 → 悬挂（淘汰残留/运行期被手动删除），计入待删并扣计数；
        //  - 文件无 DB 行 → 孤儿（崩溃残留），仅这些需要 stat 获取大小/时间戳。
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: cacheRootDir)
            var diskHashes = Set<String>()
            for file in files where file.hasSuffix(".jpg") {
                diskHashes.insert(String(file.dropLast(4)))
            }
            let dangling = entries.filter { !diskHashes.contains($0.key) }.map(\.key)
            for hash in dangling {
                guard let entry = entries[hash] else { continue }
                entries[hash] = nil
                pendingDeletes.insert(hash)
                fileCount -= 1
                totalSize -= entry.fileSize
            }
            for hash in diskHashes where entries[hash] == nil {
                let path = cacheRootDir + "/" + hash + ".jpg"
                guard let info = Self.fileInfo(at: path) else { continue }
                let createdAt = info.birthMs > 0 ? info.birthMs : info.mtimeMs
                entries[hash] = CacheEntry(lastAccess: info.atimeMs, createdAt: createdAt, accessCount: 0, fileSize: info.size)
                fileCount += 1
                totalSize += info.size
                dirty.insert(hash)
            }
        } catch {
            GatherLogger.log("ImageCache: 缓存目录读取失败: \(error)", level: .warn)
        }

        enqueuePersist()
    }

    // ── 基础设施 ──

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func fileURL(for hash: String) -> URL {
        URL(fileURLWithPath: cacheRootDir).appendingPathComponent(hash + ".jpg")
    }

    private func tmpURL(for hash: String) -> URL {
        let pid = ProcessInfo.processInfo.processIdentifier
        let suffix = UUID().uuidString.prefix(8)
        return URL(fileURLWithPath: cacheRootDir).appendingPathComponent("\(hash).\(pid).\(suffix).tmp")
    }

    /// 打开元数据库：损坏 → 改名 .corrupt-<ts> 重建；仍失败 → :memory: 纯内存模式
    ///（TS openDb 的降级不变量）。
    private static func openMetadataDatabase(in dir: String) -> DBConnection {
        let dbPath = dir + "/cache-meta.db"
        if let db = tryOpen(dbPath: dbPath) {
            return db
        }
        GatherLogger.log("ImageCache: 元数据库不可读，隔离并重建", level: .warn)
        let corruptPath = "\(dbPath).corrupt-\(Int64(Date().timeIntervalSince1970 * 1000))"
        try? FileManager.default.moveItem(atPath: dbPath, toPath: corruptPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        if let db = tryOpen(dbPath: dbPath) {
            return db
        }
        GatherLogger.log("ImageCache: 无法持久化元数据（只读目录？），退化为内存模式", level: .warn)
        if let db = tryOpen(dbPath: ":memory:") {
            return db
        }
        fatalError("ImageCache: 无法创建内存元数据库")
    }

    private static func tryOpen(dbPath: String) -> DBConnection? {
        do {
            let db = try DBConnection(path: dbPath)
            try db.exec("PRAGMA busy_timeout = 5000;")
            try db.exec("PRAGMA synchronous = NORMAL;")
            try db.exec(Self.schemaSQL)
            return db
        } catch {
            return nil
        }
    }

    /// C stat：atime/birthtime/mtime（毫秒）+ 大小。Linux 无 birthtime，用 mtime
    /// 兜底（对应 TS `birthtimeMs || mtimeMs`；node 在 Linux 经 statx 可取 btime，
    /// 影响面仅为孤儿文件收养的 createdAt，属可接受偏差）。
    private static func fileInfo(at path: String) -> (atimeMs: Int64, birthMs: Int64, mtimeMs: Int64, size: Int64)? {
        var s = stat()
        let rc = path.withCString { stat($0, &s) }
        guard rc == 0 else { return nil }
        #if canImport(Darwin)
        let atimeMs = Int64(s.st_atimespec.tv_sec) * 1000 + Int64(s.st_atimespec.tv_nsec / 1_000_000)
        let birthMs = Int64(s.st_birthtimespec.tv_sec) * 1000 + Int64(s.st_birthtimespec.tv_nsec / 1_000_000)
        let mtimeMs = Int64(s.st_mtimespec.tv_sec) * 1000 + Int64(s.st_mtimespec.tv_nsec / 1_000_000)
        #else
        let atimeMs = Int64(s.st_atim.tv_sec) * 1000 + Int64(s.st_atim.tv_nsec / 1_000_000)
        let birthMs: Int64 = 0
        let mtimeMs = Int64(s.st_mtim.tv_sec) * 1000 + Int64(s.st_mtim.tv_nsec / 1_000_000)
        #endif
        return (atimeMs, birthMs, mtimeMs, Int64(s.st_size))
    }
}

/// 串行任务链：后一个任务等待前一个完成后执行（等价 TS 的 promise 链）。
private final class SerialChain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Task<Void, Never> {}

    /// 追加任务到链尾，返回的 task 完成即代表 body 已执行完。
    func enqueue(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock()
        let previous = tail
        let next = Task<Void, Never> {
            await previous.value
            await body()
        }
        tail = next
        lock.unlock()
        return next
    }

    /// 等待链上全部在途任务完成。
    func waitUntilIdle() async {
        await currentTail.value
    }

    /// 当前链尾（同步读取，避免在 async 上下文直接拿 NSLock）。
    private var currentTail: Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}

/// 纯 Swift SHA-256（FIPS 180-4）。Linux 无 CryptoKit，零依赖实现，
/// 供 hashKey 使用（TS `crypto.createHash('sha256')` 的对应物）。
public struct SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var msg = [UInt8](data)
        let bitLength = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 {
            msg.append(0)
        }
        msg.append(contentsOf: bitLength.bigEndianBytes)

        var w = [UInt32](repeating: 0, count: 64)
        for blockStart in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let base = blockStart + i * 4
                w[i] = UInt32(msg[base]) << 24
                    | UInt32(msg[base + 1]) << 16
                    | UInt32(msg[base + 2]) << 8
                    | UInt32(msg[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ sum1 &+ ch &+ k[i] &+ w[i]
                let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h[0] &+= a
            h[1] &+= b
            h[2] &+= c
            h[3] &+= d
            h[4] &+= e
            h[5] &+= f
            h[6] &+= g
            h[7] &+= hh
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for value in h {
            out.append(UInt8((value >> 24) & 0xff))
            out.append(UInt8((value >> 16) & 0xff))
            out.append(UInt8((value >> 8) & 0xff))
            out.append(UInt8(value & 0xff))
        }
        return out
    }

    private static func rotateRight(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 56) & 0xff), UInt8((self >> 48) & 0xff), UInt8((self >> 40) & 0xff), UInt8((self >> 32) & 0xff),
            UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 8) & 0xff), UInt8(self & 0xff),
        ]
    }
}
