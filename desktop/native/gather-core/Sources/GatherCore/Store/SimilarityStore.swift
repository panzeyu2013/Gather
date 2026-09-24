// Store/SimilarityStore.swift
// R1：相似度结果与增量聚类状态的唯一访问入口
// （取代 旧 SimilarityResultRepo + SimilarityClusterStateRepo.swift）。
//
// 与旧实现的差异（均为修正而非兼容层）：
// - 成员映射缓存从 Repo 的可变字典改为独立 actor（Store 保持 Sendable 无状态），
//   语义不变：容量 32、插入序淘汰、replace 后按会话失效；
// - nowISO 统一走 RepositorySupport.nowISOString()。
import Foundation

/// 成员映射缓存（旧 Repo 的 photoGroupMapCache）：容量 32、插入序 LRU。
public actor SimilarityMembershipCache {
    private let capacity: Int
    private var entries: [String: [String: String]] = [:]
    private var order: [String] = []

    public init(capacity: Int = 32) {
        self.capacity = capacity
    }

    public var count: Int { entries.count }

    func value(for key: String) -> [String: String]? {
        entries[key]
    }

    func store(_ value: [String: String], for key: String) {
        if entries[key] == nil {
            order.append(key)
        }
        entries[key] = value
        while entries.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    func invalidate(sessionId: String) {
        let prefix = "\(sessionId):"
        order.removeAll { $0.hasPrefix(prefix) }
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }
}

public struct SimilarityResultRecord: Decodable, Equatable, Sendable {
    public let id: Int64
    public let sessionId: String
    public let groupsJson: String
    public let statsJson: String
    public let paramThreshold: Int
    public let paramMinGroupSize: Int
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case groupsJson = "groups_json"
        case statsJson = "stats_json"
        case paramThreshold = "param_threshold"
        case paramMinGroupSize = "param_min_group_size"
        case createdAt = "created_at"
    }
}

public struct SimilarityMembership: Equatable, Sendable {
    public let photoId: String
    public let groupIndex: Int

    public init(photoId: String, groupIndex: Int) {
        self.photoId = photoId
        self.groupIndex = groupIndex
    }
}

public struct SimilarityMember: Decodable, Equatable, Sendable {
    public let groupIndex: Int
    public let photoId: String
    public let filepath: String

    enum CodingKeys: String, CodingKey {
        case filepath
        case groupIndex = "group_index"
        case photoId = "photo_id"
    }
}

/// W2c：similarity_hashes 行（analyze 复用判定的既有 hash；file_size/mtime 与当前
/// 源文件 stat 比对后才可复用）。
public struct SimilarityHashRecord: Decodable, Equatable, Sendable {
    public let photoId: String
    public let hashHex: String
    public let fileSize: Int
    public let fileMtimeMs: Double

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case hashHex = "hash_hex"
        case fileSize = "file_size"
        case fileMtimeMs = "file_mtime_ms"
    }
}

/// W2c：按 asset_file_id 批量读的复用候选行（JOIN photos 携带资产文件 id，
/// 复用判定还需比较候选与目标照片的 size/mtime）。
public struct SimilarityHashCandidate: Decodable, Equatable, Sendable {
    public let id: Int64
    public let photoId: String
    public let hashHex: String
    public let fileSize: Int
    public let fileMtimeMs: Double
    public let assetFileId: String

    enum CodingKeys: String, CodingKey {
        case id
        case photoId = "photo_id"
        case hashHex = "hash_hex"
        case fileSize = "file_size"
        case fileMtimeMs = "file_mtime_ms"
        case assetFileId = "asset_file_id"
    }
}

/// W2c：similarity_hashes UPSERT 行（入库前已算出 hash 的落库形态）。
public struct SimilarityHashUpsert: Equatable, Sendable {
    public let photoId: String
    public let hashHex: String
    public let fileSize: Int
    public let fileMtimeMs: Double

    public init(photoId: String, hashHex: String, fileSize: Int, fileMtimeMs: Double) {
        self.photoId = photoId
        self.hashHex = hashHex
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
    }
}

public struct SimilarityClusterMetaRecord: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let paramThreshold: Int
    public let paramMinGroupSize: Int
    public let groupingMode: String
    public let memberCount: Int
    public let version: Int
    public let incrementalUpdates: Int
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case paramThreshold = "param_threshold"
        case paramMinGroupSize = "param_min_group_size"
        case groupingMode = "grouping_mode"
        case memberCount = "member_count"
        case version
        case incrementalUpdates = "incremental_updates"
        case updatedAt = "updated_at"
    }
}

public struct SimilarityClusterStateRecord: Decodable, Equatable, Sendable {
    public let photoId: String
    public let hashHex: String
    public let componentIndex: Int
    public let groupSeed: String?

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case hashHex = "hash_hex"
        case componentIndex = "component_index"
        case groupSeed = "group_seed"
    }
}

/// 一次加载的完整增量状态（元数据 + 成员行）。
public struct SimilarityClusterSnapshotRecord: Equatable, Sendable {
    public let meta: SimilarityClusterMetaRecord
    public let rows: [SimilarityClusterStateRecord]

    public init(meta: SimilarityClusterMetaRecord, rows: [SimilarityClusterStateRecord]) {
        self.meta = meta
        self.rows = rows
    }

    /// 还原算法层状态（分量/组按行序还原，算法层会按当前输入序重新规范化）。
    public var state: ClusterState {
        var hashes: [String: String] = [:]
        var componentMembers: [Int: [String]] = [:]
        var groupMembers: [String: [String]] = [:]
        var componentOrder: [Int] = []
        var groupSeedOrder: [String] = []
        for row in rows {
            hashes[row.photoId] = row.hashHex
            if componentMembers[row.componentIndex] == nil { componentOrder.append(row.componentIndex) }
            componentMembers[row.componentIndex, default: []].append(row.photoId)
            if let seed = row.groupSeed {
                if groupMembers[seed] == nil { groupSeedOrder.append(seed) }
                groupMembers[seed, default: []].append(row.photoId)
            }
        }
        let components = componentOrder.compactMap { componentMembers[$0] }
        let groups = groupSeedOrder.compactMap { seed -> [String]? in
            guard let members = groupMembers[seed], let seedIndex = members.firstIndex(of: seed) else { return nil }
            var ordered = members
            ordered.remove(at: seedIndex)
            return [seed] + ordered
        }
        return ClusterState(components: components, groups: groups, hashes: hashes)
    }

    /// 状态是否覆盖当前参数（阈值/组大小/分组模式三者全等才可增量复用）。
    public func matches(threshold: Int, minGroupSize: Int, groupingMode: String) -> Bool {
        meta.paramThreshold == threshold
            && meta.paramMinGroupSize == minGroupSize
            && meta.groupingMode == groupingMode
    }
}

public protocol SimilarityStore: Sendable {
    // MARK: similarity_results

    func latestResult(sessionId: String) async throws -> SimilarityResultRecord?
    func result(sessionId: String, threshold: Int) async throws -> SimilarityResultRecord?
    func replaceResult(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [SimilarityMembership]
    ) async throws -> Int64
    func replaceResultForThreshold(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [SimilarityMembership]
    ) async throws -> Int64
    func photoGroupMap(sessionId: String, resultId: Int64) async throws -> [String: String]
    func groupMembers(sessionId: String, resultId: Int64) async throws -> [SimilarityMember]?

    // MARK: similarity_hashes（W2c）

    /// 会话全部 hash 行（按 rowid 序）；空会话返回 []。
    func hashes(sessionId: String) async throws -> [SimilarityHashRecord]
    /// 按 asset_file_id 批量读复用候选（JOIN photos；内部 400 分块）；
    /// assetFileIds 为空返回 []。
    func hashCandidates(assetFileIds: [String]) async throws -> [SimilarityHashCandidate]
    /// 批量 UPSERT（单事务，ON CONFLICT(session_id, photo_id)）；空参数为 no-op。
    func upsertHashes(sessionId: String, hashes: [SimilarityHashUpsert]) async throws

    // MARK: similarity_cluster_state / meta

    func loadClusterSnapshot(sessionId: String) async throws -> SimilarityClusterSnapshotRecord?
    func replaceClusterState(
        sessionId: String,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: String,
        version: Int,
        incrementalUpdates: Int,
        state: ClusterState
    ) async throws
    func deleteClusterState(sessionId: String) async throws
}

public struct SQLiteSimilarityStore: SimilarityStore {
    /// TS 常量 PRECOMPUTED_TIER_MARKER：预计算阈值行的 stats_json 标记。
    private static let precomputedTierMarker = "\"precomputed\":true"
    /// TS 常量 REUSE_HASH_CHUNK_SIZE：按 asset_file_id 批量读的分块大小。
    private static let hashCandidateChunkSize = 400

    private let database: SQLiteDatabase
    private let membersCache: SimilarityMembershipCache

    public init(database: SQLiteDatabase, membersCache: SimilarityMembershipCache = SimilarityMembershipCache()) {
        self.database = database
        self.membersCache = membersCache
    }

    // MARK: results

    public func latestResult(sessionId: String) async throws -> SimilarityResultRecord? {
        try await database.queryOne(
            """
            SELECT * FROM similarity_results
            WHERE session_id = ? AND stats_json NOT LIKE ?
            ORDER BY id DESC LIMIT 1
            """,
            [.text(sessionId), .text("%\(Self.precomputedTierMarker)%")]
        )?.decode(SimilarityResultRecord.self)
    }

    public func result(sessionId: String, threshold: Int) async throws -> SimilarityResultRecord? {
        try await database.queryOne(
            """
            SELECT * FROM similarity_results
            WHERE session_id = ? AND param_threshold = ?
            ORDER BY id DESC LIMIT 1
            """,
            [.text(sessionId), .int(Int64(threshold))]
        )?.decode(SimilarityResultRecord.self)
    }

    public func replaceResult(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [SimilarityMembership]
    ) async throws -> Int64 {
        let resultId = try await database.transaction { db in
            try db.run("DELETE FROM similarity_results WHERE session_id = ?", [.text(sessionId)])
            return try Self.insertResult(
                db,
                sessionId: sessionId,
                groupsJson: groupsJson,
                statsJson: statsJson,
                threshold: threshold,
                minGroupSize: minGroupSize,
                memberships: memberships
            )
        }
        await membersCache.invalidate(sessionId: sessionId)
        return resultId
    }

    public func replaceResultForThreshold(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [SimilarityMembership]
    ) async throws -> Int64 {
        let resultId = try await database.transaction { db in
            try db.run(
                "DELETE FROM similarity_results WHERE session_id = ? AND param_threshold = ?",
                [.text(sessionId), .int(Int64(threshold))]
            )
            return try Self.insertResult(
                db,
                sessionId: sessionId,
                groupsJson: groupsJson,
                statsJson: statsJson,
                threshold: threshold,
                minGroupSize: minGroupSize,
                memberships: memberships
            )
        }
        await membersCache.invalidate(sessionId: sessionId)
        return resultId
    }

    private static func insertResult(
        _ db: isolated SQLiteDatabase,
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [SimilarityMembership]
    ) throws -> Int64 {
        try db.run(
            """
            INSERT INTO similarity_results
              (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .text(sessionId), .text(groupsJson), .text(statsJson),
                .int(Int64(threshold)), .int(Int64(minGroupSize)), .text(nowISOString()),
            ]
        )
        let resultId = db.lastInsertRowID
        for membership in memberships {
            try db.run(
                """
                INSERT INTO similarity_result_members (result_id, session_id, group_index, photo_id)
                VALUES (?, ?, ?, ?)
                """,
                [.int(resultId), .text(sessionId), .int(Int64(membership.groupIndex)), .text(membership.photoId)]
            )
        }
        return resultId
    }

    /// photo_id → "resultId:groupIndex" 映射（缓存命中直接返回；值类型天然拷贝）。
    public func photoGroupMap(sessionId: String, resultId: Int64) async throws -> [String: String] {
        let key = "\(sessionId):\(resultId)"
        if let cached = await membersCache.value(for: key) {
            return cached
        }
        let rows = try await database.query(
            "SELECT photo_id, group_index FROM similarity_result_members WHERE session_id = ? AND result_id = ?",
            [.text(sessionId), .int(resultId)]
        )
        var map: [String: String] = [:]
        for row in rows {
            guard let photoId = row.text("photo_id") else { continue }
            map[photoId] = "\(resultId):\(row.int("group_index") ?? 0)"
        }
        await membersCache.store(map, for: key)
        return map
    }

    /// 组成员行（JOIN photos 带 filepath），按成员表隐式 rowid 排序；
    /// 无成员行返回 nil（老数据仅 groups_json）。
    public func groupMembers(sessionId: String, resultId: Int64) async throws -> [SimilarityMember]? {
        let rows = try await database.query(
            """
            SELECT m.group_index, m.photo_id, p.filepath
            FROM similarity_result_members m JOIN photos p ON p.id = m.photo_id
            WHERE m.result_id = ? AND m.session_id = ?
            ORDER BY m.rowid
            """,
            [.int(resultId), .text(sessionId)]
        )
        if rows.isEmpty { return nil }
        return try rows.map { try $0.decode(SimilarityMember.self) }
    }

    // MARK: similarity_hashes（W2c：原 SimilarityService/DuplicateService 内联 SQL 下沉）

    /// 会话全部 hash 行（按 rowid 序；无行返回 []）。
    public func hashes(sessionId: String) async throws -> [SimilarityHashRecord] {
        try await database.query(
            """
            SELECT photo_id, hash_hex, file_size, file_mtime_ms
            FROM similarity_hashes WHERE session_id = ? ORDER BY rowid
            """,
            [.text(sessionId)]
        ).map { try $0.decode(SimilarityHashRecord.self) }
    }

    /// 复用候选：shared asset file 的全部 hash 行（按 hash id 升序，跨块拼接序确定）；
    /// 每块 400 个 asset_file_id，规避 SQLite 变量上限。
    public func hashCandidates(assetFileIds: [String]) async throws -> [SimilarityHashCandidate] {
        guard !assetFileIds.isEmpty else { return [] }
        var candidates: [SimilarityHashCandidate] = []
        for chunk in assetFileIds.chunked(by: Self.hashCandidateChunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try await database.query(
                """
                SELECT h.id AS id, h.photo_id, h.hash_hex, h.file_size, h.file_mtime_ms, p.asset_file_id
                FROM similarity_hashes h
                JOIN photos p ON h.photo_id = p.id
                WHERE p.asset_file_id IN (\(placeholders))
                ORDER BY h.id
                """,
                chunk.map { .text($0) }
            )
            candidates.append(contentsOf: try rows.map { try $0.decode(SimilarityHashCandidate.self) })
        }
        return candidates
    }

    /// 批量 UPSERT（单事务：任一行失败整批回滚）。
    public func upsertHashes(sessionId: String, hashes: [SimilarityHashUpsert]) async throws {
        guard !hashes.isEmpty else { return }
        try await database.transaction { db in
            for hash in hashes {
                try db.run(
                    """
                    INSERT INTO similarity_hashes
                      (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(session_id, photo_id) DO UPDATE SET
                      hash_hex = excluded.hash_hex,
                      file_size = excluded.file_size,
                      file_mtime_ms = excluded.file_mtime_ms
                    """,
                    [
                        .text(sessionId), .text(hash.photoId), .text(hash.hashHex),
                        .int(Int64(hash.fileSize)), .real(hash.fileMtimeMs),
                    ]
                )
            }
        }
    }

    // MARK: cluster state

    public func loadClusterSnapshot(sessionId: String) async throws -> SimilarityClusterSnapshotRecord? {
        guard let metaRow = try await database.queryOne(
            """
            SELECT session_id, param_threshold, param_min_group_size, grouping_mode,
                   member_count, version, incremental_updates, updated_at
            FROM similarity_cluster_meta WHERE session_id = ?
            """,
            [.text(sessionId)]
        ) else { return nil }
        let meta = try metaRow.decode(SimilarityClusterMetaRecord.self)
        let rows = try await database.query(
            """
            SELECT photo_id, hash_hex, component_index, group_seed
            FROM similarity_cluster_state WHERE session_id = ? ORDER BY rowid
            """,
            [.text(sessionId)]
        ).map { try $0.decode(SimilarityClusterStateRecord.self) }
        return SimilarityClusterSnapshotRecord(meta: meta, rows: rows)
    }

    public func replaceClusterState(
        sessionId: String,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: String,
        version: Int,
        incrementalUpdates: Int,
        state: ClusterState
    ) async throws {
        var groupSeedOf: [String: String] = [:]
        groupSeedOf.reserveCapacity(state.hashes.count)
        for group in state.groups {
            guard let seed = group.first else { continue }
            for photoId in group { groupSeedOf[photoId] = seed }
        }

        try await database.transaction { db in
            try db.run("DELETE FROM similarity_cluster_state WHERE session_id = ?", [.text(sessionId)])
            try db.run("DELETE FROM similarity_cluster_meta WHERE session_id = ?", [.text(sessionId)])
            try db.run(
                """
                INSERT INTO similarity_cluster_meta
                  (session_id, param_threshold, param_min_group_size, grouping_mode,
                   member_count, version, incremental_updates, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(sessionId), .int(Int64(threshold)), .int(Int64(minGroupSize)),
                    .text(groupingMode), .int(Int64(state.hashes.count)), .int(Int64(version)),
                    .int(Int64(incrementalUpdates)), .text(nowISOString()),
                ]
            )
            for (componentIndex, component) in state.components.enumerated() {
                for photoId in component {
                    guard let hash = state.hashes[photoId] else { continue }
                    try db.run(
                        """
                        INSERT INTO similarity_cluster_state
                          (session_id, photo_id, hash_hex, component_index, group_seed)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        [
                            .text(sessionId), .text(photoId), .text(hash), .int(Int64(componentIndex)),
                            groupSeedOf[photoId].map { SQLiteValue.text($0) } ?? .null,
                        ]
                    )
                }
            }
        }
    }

    public func deleteClusterState(sessionId: String) async throws {
        try await database.transaction { db in
            try db.run("DELETE FROM similarity_cluster_state WHERE session_id = ?", [.text(sessionId)])
            try db.run("DELETE FROM similarity_cluster_meta WHERE session_id = ?", [.text(sessionId)])
        }
    }
}
