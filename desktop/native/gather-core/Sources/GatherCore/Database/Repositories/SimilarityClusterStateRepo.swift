// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/SimilarityClusterStateRepo.swift
// 增量聚类状态仓库（ROADMAP 1.3）：相似度的簇状态与版本元数据。
// - similarity_cluster_state：每张已哈希照片的分量归属 + 组种子（NULL = 未成组）；
// - similarity_cluster_meta：参数指纹（阈值/组大小/分组模式）+ 版本号 +
//   连续增量次数（定期全局收敛的计数器）。
import Foundation

/// similarity_cluster_meta 行。
public struct SimilarityClusterMetaRow: Equatable, Sendable {
    public let sessionId: String
    public let paramThreshold: Int
    public let paramMinGroupSize: Int
    public let groupingMode: String
    public let memberCount: Int
    public let version: Int
    public let incrementalUpdates: Int
    public let updatedAt: String

    init(row: DBRow) throws {
        guard row.count >= 8 else { throw DBError.message("SimilarityClusterMetaRow 列数不足: \(row.count)") }
        sessionId = row[0].textValue ?? ""
        paramThreshold = Int(row[1].intValue ?? 0)
        paramMinGroupSize = Int(row[2].intValue ?? 0)
        groupingMode = row[3].textValue ?? "global"
        memberCount = Int(row[4].intValue ?? 0)
        version = Int(row[5].intValue ?? 0)
        incrementalUpdates = Int(row[6].intValue ?? 0)
        updatedAt = row[7].textValue ?? ""
    }
}

/// similarity_cluster_state 行。
public struct SimilarityClusterStateRow: Equatable, Sendable {
    public let photoId: String
    public let hashHex: String
    public let componentIndex: Int
    public let groupSeed: String?

    init(row: DBRow) throws {
        guard row.count >= 4 else { throw DBError.message("SimilarityClusterStateRow 列数不足: \(row.count)") }
        photoId = row[0].textValue ?? ""
        hashHex = row[1].textValue ?? ""
        componentIndex = Int(row[2].intValue ?? 0)
        groupSeed = row[3].textValue
    }
}

/// 一次加载的完整状态（元数据 + 成员行）。
public struct SimilarityClusterSnapshot: Equatable, Sendable {
    public let meta: SimilarityClusterMetaRow
    public let rows: [SimilarityClusterStateRow]

    public init(meta: SimilarityClusterMetaRow, rows: [SimilarityClusterStateRow]) {
        self.meta = meta
        self.rows = rows
    }

    /// 还原为算法层状态（分量/组按行序还原，算法层会按当前输入序重新规范化）。
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

public final class SimilarityClusterStateRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func load(sessionId: String) throws -> SimilarityClusterSnapshot? {
        guard let metaRow = try connection.prepare("""
            SELECT session_id, param_threshold, param_min_group_size, grouping_mode,
                   member_count, version, incremental_updates, updated_at
            FROM similarity_cluster_meta WHERE session_id = ?
          """).get([.text(sessionId)]) else {
            return nil
        }
        let meta = try SimilarityClusterMetaRow(row: metaRow)
        let rows = try connection.prepare("""
            SELECT photo_id, hash_hex, component_index, group_seed
            FROM similarity_cluster_state WHERE session_id = ? ORDER BY rowid
          """).query([.text(sessionId)]).map { try SimilarityClusterStateRow(row: $0) }
        return SimilarityClusterSnapshot(meta: meta, rows: rows)
    }

    /// 覆盖写：同一事务内替换元数据与全部成员行（分量写入序即规范序）。
    public func replace(
        sessionId: String,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: String,
        version: Int,
        incrementalUpdates: Int,
        state: ClusterState
    ) throws {
        var groupSeedOf: [String: String] = [:]
        groupSeedOf.reserveCapacity(state.hashes.count)
        for group in state.groups {
            guard let seed = group.first else { continue }
            for photoId in group { groupSeedOf[photoId] = seed }
        }

        try connection.transaction {
            _ = try connection.prepare("DELETE FROM similarity_cluster_state WHERE session_id = ?")
                .run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM similarity_cluster_meta WHERE session_id = ?")
                .run([.text(sessionId)])
            _ = try connection.prepare("""
                INSERT INTO similarity_cluster_meta
                  (session_id, param_threshold, param_min_group_size, grouping_mode,
                   member_count, version, incremental_updates, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              """).run([
                .text(sessionId), .int(Int64(threshold)), .int(Int64(minGroupSize)),
                .text(groupingMode), .int(Int64(state.hashes.count)), .int(Int64(version)),
                .int(Int64(incrementalUpdates)), .text(nowISOString()),
              ])
            let insert = try connection.prepare("""
                INSERT INTO similarity_cluster_state
                  (session_id, photo_id, hash_hex, component_index, group_seed)
                VALUES (?, ?, ?, ?, ?)
              """)
            for (componentIndex, component) in state.components.enumerated() {
                for photoId in component {
                    guard let hash = state.hashes[photoId] else { continue }
                    _ = try insert.run([
                        .text(sessionId), .text(photoId), .text(hash),
                        .int(Int64(componentIndex)),
                        groupSeedOf[photoId].map { DBValue.text($0) } ?? .null,
                    ])
                }
            }
        }
    }

    public func delete(sessionId: String) throws {
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM similarity_cluster_state WHERE session_id = ?")
                .run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM similarity_cluster_meta WHERE session_id = ?")
                .run([.text(sessionId)])
        }
    }
}
