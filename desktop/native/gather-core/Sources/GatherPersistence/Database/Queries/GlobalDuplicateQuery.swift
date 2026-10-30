// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/GlobalDuplicateQuery.swift
// P1 下一波 §3.8.3：跨工作区重复/相似（**只读**）。
//
// 为什么能跨会话比较：duplicate_groups / similarity_hashes 的 session_id 是"归属"，
// 但 checksum 与感知哈希是**内容属性**——同一个字节流在任何工作区都同 checksum，
// 同一张图在任何会话都同 hash。于是跨工作区判定不需要新表：
//   精确重复 = GROUP BY checksum HAVING COUNT(DISTINCT session_id) > 1
//   视觉近似 = 先按 hash 前缀桶聚合，桶内两两汉明距离 ≤ 阈值（并查集聚类）
//
// 三条边界：
// 1. **只读**：本文件只有 SELECT；跨工作区删除不做（删除语义涉及两个工作区的
//    可见性，风险高于价值，§3.8.3 明确记录）。
// 2. **懒计算**：photos.checksum 为空表示"还没算"，不参与精确分组；数目单独
//    统计出来给 UI 显示"未计算"，不静默当成不同文件。
// 3. **性能**：精确分组走 idx_photos_checksum（schema 已有）；视觉桶的成对比较
//    在 Swift 侧做，单桶上限 64 张（超出降级为精确哈希分组并标记 degraded）。
import Foundation

/// 精确重复候选（checksum 组）。
public struct GlobalDuplicateExactRow: Equatable, Sendable {
    public let checksum: String
    public let photoCount: Int
    public let sessionCount: Int

    public init(checksum: String, photoCount: Int, sessionCount: Int) {
        self.checksum = checksum
        self.photoCount = photoCount
        self.sessionCount = sessionCount
    }
}

/// 跨工作区重复组的成员（读侧投影；不含绝对路径以外的东西）。
public struct GlobalDuplicatePhotoRow: Equatable, Sendable {
    public let photoId: String
    public let sessionId: String
    public let sessionName: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    /// 计算 checksum 时记录的文件大小；0 = 未知。
    public let checksumFileSize: Int64
    /// 感知哈希（多行时取 MIN(hash_hex) 保证确定性）；空 = 未计算。
    public let hashHex: String

    public init(
        photoId: String,
        sessionId: String,
        sessionName: String,
        filepath: String,
        filename: String,
        checksum: String,
        checksumFileSize: Int64,
        hashHex: String
    ) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.filepath = filepath
        self.filename = filename
        self.checksum = checksum
        self.checksumFileSize = checksumFileSize
        self.hashHex = hashHex
    }
}

public struct GlobalDuplicateQuery: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 计数

    /// 参与扫描的照片总数（未归档、有 checksum 或待补算都算）。
    public func totalPhotoCount() throws -> Int {
        let row = try connection.prepare("""
            SELECT COUNT(*) FROM photos p WHERE \(PhotoVisibility.visiblePredicate())
            """).get()
        return Int(row?[0].intValue ?? 0)
    }

    /// checksum 为空（懒计算未补齐）的照片数——UI 据此显示"未计算"。
    public func missingChecksumCount() throws -> Int {
        let row = try connection.prepare("""
            SELECT COUNT(*) FROM photos p
            WHERE \(PhotoVisibility.visiblePredicate()) AND p.checksum = ''
            """).get()
        return Int(row?[0].intValue ?? 0)
    }

    // MARK: - 精确分组

    /// 跨 ≥ minSessionCount 个工作区的 checksum 组（组内 ≥2 张）。
    ///
    /// 走 idx_photos_checksum：20 个会话 × 2k 张的规模是单次索引扫描（<100ms）。
    public func exactGroups(minSessionCount: Int = 2, limit: Int = 500) throws -> [GlobalDuplicateExactRow] {
        let boundedLimit = max(1, min(limit, 5_000))
        let rows = try connection.prepare("""
            SELECT checksum, COUNT(*) AS photo_count, COUNT(DISTINCT session_id) AS session_count
            FROM photos p
            WHERE \(PhotoVisibility.visiblePredicate()) AND p.checksum <> ''
            GROUP BY p.checksum
            HAVING COUNT(*) > 1 AND COUNT(DISTINCT p.session_id) >= ?
            ORDER BY photo_count DESC, p.checksum
            LIMIT ?
            """).query([.int(Int64(max(1, minSessionCount))), .int(Int64(boundedLimit))])
        return rows.map { row in
            GlobalDuplicateExactRow(
                checksum: row[0].textValue ?? "",
                photoCount: Int(row[1].intValue ?? 0),
                sessionCount: Int(row[2].intValue ?? 0)
            )
        }
    }

    /// 按 checksum 批量取成员（分块 IN，避免超过 SQLite 变量上限）。
    public func photos(checksums: [String]) throws -> [GlobalDuplicatePhotoRow] {
        let unique = Array(Set(checksums.filter { !$0.isEmpty })).sorted()
        guard !unique.isEmpty else { return [] }
        var result: [GlobalDuplicatePhotoRow] = []
        for chunk in unique.chunked(maxSize: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT p.id, p.session_id, COALESCE(s.name, ''), p.filepath, p.filename,
                       p.checksum, p.checksum_file_size,
                       COALESCE((SELECT MIN(sh.hash_hex) FROM similarity_hashes sh
                                 WHERE sh.photo_id = p.id), '')
                FROM photos p
                LEFT JOIN sessions s ON s.id = p.session_id
                WHERE \(PhotoVisibility.visiblePredicate()) AND p.checksum IN (\(placeholders))
                ORDER BY p.checksum, p.session_id, p.id
                """).query(chunk.map(DBValue.text))
            result.append(contentsOf: rows.map(Self.mapPhotoRow))
        }
        return result.sorted { ($0.checksum, $0.photoId) < ($1.checksum, $1.photoId) }
    }

    // MARK: - 视觉近似

    /// 视觉聚类输入：有感知哈希的可见照片（上限 limit，防 50k 行以上拖垮内存）。
    ///
    /// 返回行按 (hash_hex, photo_id) 排序：桶代表 hash 的选取因此是确定性的。
    public func visualHashRows(limit: Int = 50_000) throws -> [GlobalDuplicatePhotoRow] {
        let boundedLimit = max(1, min(limit, 200_000))
        let rows = try connection.prepare("""
            SELECT p.id, p.session_id, COALESCE(s.name, ''), p.filepath, p.filename,
                   p.checksum, p.checksum_file_size,
                   COALESCE((SELECT MIN(sh.hash_hex) FROM similarity_hashes sh
                             WHERE sh.photo_id = p.id), '')
            FROM photos p
            LEFT JOIN sessions s ON s.id = p.session_id
            WHERE \(PhotoVisibility.visiblePredicate())
              AND EXISTS (SELECT 1 FROM similarity_hashes sh2 WHERE sh2.photo_id = p.id)
            ORDER BY 8, p.id
            LIMIT ?
            """).query([.int(Int64(boundedLimit))])
        return rows.map(Self.mapPhotoRow)
    }

    private static func mapPhotoRow(_ row: DBRow) -> GlobalDuplicatePhotoRow {
        GlobalDuplicatePhotoRow(
            photoId: row[0].textValue ?? "",
            sessionId: row[1].textValue ?? "",
            sessionName: row[2].textValue ?? "",
            filepath: row[3].textValue ?? "",
            filename: row[4].textValue ?? "",
            checksum: row[5].textValue ?? "",
            checksumFileSize: row[6].intValue ?? 0,
            hashHex: (row[7].textValue ?? "").lowercased()
        )
    }
}

// MARK: - 视觉近似的纯函数（金样可测，无 IO）

/// hash 桶内汉明聚类的纯实现。
///
/// 算法（§3.8.3）：
/// 1. 只保留合法十六进制 hash（非空、等长、全 hex）；
/// 2. 按**前缀桶**（默认前 8 个 hex 字符 = 32 bit）分组，桶内才做两两比较；
/// 3. 桶内成员数 > maxBucketSize（默认 64）时降级：只按完整 hash 精确分组，
///    并把该桶标记 degraded（UI 提示"仅精确重复"）；
/// 4. 两两汉明距离 ≤ threshold 的边做并查集，簇内 ≥2 张才保留；
/// 5. 代表 hash 取簇内字典序最小者（确定性），簇按代表 hash 排序。
public enum VisualHashBuckets {
    /// 桶前缀长度（hex 字符数）。
    public static let defaultPrefixLength = 8
    /// 单桶成对比较上限：64 × 63 / 2 ≈ 2k 次比较，20 桶量级仍是毫秒级。
    public static let defaultMaxBucketSize = 64

    /// 一个视觉近似簇。
    public struct Cluster: Equatable, Sendable {
        public let representativeHash: String
        public let photoIds: [String]
        public let sessionIds: [String]
        /// true = 该桶超出上限，只做了精确哈希分组（可能漏掉近似对）。
        public let degraded: Bool

        public init(
            representativeHash: String,
            photoIds: [String],
            sessionIds: [String],
            degraded: Bool = false
        ) {
            self.representativeHash = representativeHash
            self.photoIds = photoIds
            self.sessionIds = sessionIds
            self.degraded = degraded
        }
    }

    /// 两个等长十六进制串的汉明距离（按位计）；非法输入返回 nil。
    public static func hammingDistance(_ lhs: String, _ rhs: String) -> Int? {
        let left = Array(lhs.lowercased())
        let right = Array(rhs.lowercased())
        guard !left.isEmpty, left.count == right.count else { return nil }
        var distance = 0
        for index in 0..<left.count {
            guard let a = left[index].hexDigitValue, let b = right[index].hexDigitValue else {
                return nil
            }
            distance += (a ^ b).nonzeroBitCount
        }
        return distance
    }

    /// 聚类入口（纯函数：相同输入相同输出）。
    public static func clusters(
        rows: [GlobalDuplicatePhotoRow],
        threshold: Int,
        maxBucketSize: Int = defaultMaxBucketSize,
        prefixLength: Int = defaultPrefixLength
    ) throws -> [Cluster] {
        let boundedThreshold = max(0, min(threshold, 64))
        let boundedPrefix = max(1, prefixLength)
        var buckets: [String: [GlobalDuplicatePhotoRow]] = [:]
        for row in rows {
            let hash = row.hashHex.lowercased()
            guard isHex(hash) else { continue }
            let prefix = String(hash.prefix(boundedPrefix))
            buckets[prefix, default: []].append(row)
        }
        var result: [Cluster] = []
        for prefix in buckets.keys.sorted() {
            guard let members = buckets[prefix], members.count >= 2 else { continue }
            if members.count > maxBucketSize {
                result.append(contentsOf: exactHashClusters(members, degraded: true))
                continue
            }
            result.append(contentsOf: unionFindClusters(members, threshold: boundedThreshold))
        }
        return result.sorted { $0.representativeHash < $1.representativeHash }
    }

    /// 合法十六进制串：非空、偶数长度不限、全 hex（长度必须 ≥2 才有意义）。
    static func isHex(_ value: String) -> Bool {
        guard value.count >= 2, value.count % 2 == 0 else { return false }
        return value.allSatisfy { $0.isHexDigit }
    }

    /// 降级路径：同完整 hash 的成员成簇（不做近似扩张）。
    private static func exactHashClusters(
        _ members: [GlobalDuplicatePhotoRow],
        degraded: Bool
    ) -> [Cluster] {
        var byHash: [String: [GlobalDuplicatePhotoRow]] = [:]
        for member in members {
            byHash[member.hashHex.lowercased(), default: []].append(member)
        }
        return byHash.compactMap { hash, group in
            guard group.count >= 2 else { return nil }
            let sorted = group.sorted { $0.photoId < $1.photoId }
            return Cluster(
                representativeHash: hash,
                photoIds: sorted.map(\.photoId),
                sessionIds: Array(Set(sorted.map(\.sessionId))).sorted(),
                degraded: degraded
            )
        }
    }

    /// 并查集聚类（桶内两两比较）。
    private static func unionFindClusters(
        _ members: [GlobalDuplicatePhotoRow],
        threshold: Int
    ) -> [Cluster] {
        let sorted = members.sorted { $0.photoId < $1.photoId }
        var parent = Array(0..<sorted.count)
        func find(_ index: Int) -> Int {
            var current = index
            while parent[current] != current { current = parent[current] }
            return current
        }
        func union(_ lhs: Int, _ rhs: Int) {
            let a = find(lhs)
            let b = find(rhs)
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                guard let distance = hammingDistance(sorted[i].hashHex, sorted[j].hashHex) else {
                    continue
                }
                if distance <= threshold { union(i, j) }
            }
        }
        var groups: [Int: [GlobalDuplicatePhotoRow]] = [:]
        for (index, row) in sorted.enumerated() {
            groups[find(index), default: []].append(row)
        }
        return groups.values.compactMap { group in
            guard group.count >= 2 else { return nil }
            let hashes = group.map { $0.hashHex.lowercased() }.sorted()
            return Cluster(
                representativeHash: hashes.first ?? "",
                photoIds: group.map(\.photoId).sorted(),
                sessionIds: Array(Set(group.map(\.sessionId))).sorted()
            )
        }
    }
}

// MARK: - 分块

private extension Array {
    /// 按固定大小切块（IN 子句的变量数上限保护）。
    func chunked(maxSize: Int) -> [[Element]] {
        guard maxSize > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: maxSize).map {
            Array(self[$0..<Swift.min($0 + maxSize, count)])
        }
    }
}
