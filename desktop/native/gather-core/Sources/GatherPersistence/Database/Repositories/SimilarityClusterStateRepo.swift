// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/SimilarityClusterStateRepo.swift
// 增量聚类状态仓库（ROADMAP 1.3）：相似度的簇状态与版本元数据。
// - similarity_cluster_state：每张已哈希照片的分量归属 + 组种子（NULL = 未成组）；
// - similarity_cluster_meta：参数指纹（阈值/组大小/分组模式）+ 版本号 +
//   连续增量次数（定期全局收敛的计数器）+ 5b-2b 三列（算法版本/参数签名/状态摘要）。
// - 写入走行级 apply（只 upsert diff 行、只删 removed），不再全表重插。
import Foundation
import GatherProtocol

/// similarity_cluster_meta 行。
///
/// Cut 5 / 5b-2b：+3 列状态版本化（algorithm_version / input_signature /
/// state_digest）。三者与参数一起构成“能否增量复用”的完整判定；空串/版本
/// 不符都是失效态（旧实现落的行不会带真实指纹/摘要）。
public struct SimilarityClusterMetaRow: Equatable, Sendable {
    public let sessionId: String
    public let paramThreshold: Int
    public let paramMinGroupSize: Int
    public let groupingMode: String
    public let memberCount: Int
    public let version: Int
    public let incrementalUpdates: Int
    public let updatedAt: String
    public let algorithmVersion: Int
    public let inputSignature: String
    public let stateDigest: String

    init(row: DBRow) throws {
        guard row.count >= 11 else { throw DBError.message("SimilarityClusterMetaRow 列数不足: \(row.count)") }
        sessionId = row[0].textValue ?? ""
        paramThreshold = Int(row[1].intValue ?? 0)
        paramMinGroupSize = Int(row[2].intValue ?? 0)
        groupingMode = row[3].textValue ?? "global"
        memberCount = Int(row[4].intValue ?? 0)
        version = Int(row[5].intValue ?? 0)
        incrementalUpdates = Int(row[6].intValue ?? 0)
        updatedAt = row[7].textValue ?? ""
        algorithmVersion = Int(row[8].intValue ?? 0)
        inputSignature = row[9].textValue ?? ""
        stateDigest = row[10].textValue ?? ""
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

    /// 状态能否增量复用（Cut 5 / 5b-2b 列级比对）：
    /// 阈值 / 组大小 / 分组模式 / 算法版本 / 参数指纹 / 内容摘要六者全等。
    /// 调用方用当前实现计算后三项（Persistence 不依赖 Analysis 的版本函数）。
    public func matches(
        threshold: Int,
        minGroupSize: Int,
        groupingMode: String,
        algorithmVersion: Int,
        inputSignature: String,
        stateDigest: String
    ) -> Bool {
        meta.paramThreshold == threshold
            && meta.paramMinGroupSize == minGroupSize
            && meta.groupingMode == groupingMode
            && meta.algorithmVersion == algorithmVersion
            && meta.inputSignature == inputSignature
            && meta.stateDigest == stateDigest
    }
}

/// 一行状态写入（apply 的最小单元；与 similarity_cluster_state 的业务列一一对应）。
/// 行级 diff 由调用方（SimilarityService，依赖 Analysis 的 ClusterStateDiff）计算，
/// Persistence 只负责落库——避免反向依赖 Analysis。
public struct SimilarityClusterStateWrite: Equatable, Sendable {
    public let photoId: String
    public let hashHex: String
    public let componentIndex: Int
    public let groupSeed: String?

    public init(photoId: String, hashHex: String, componentIndex: Int, groupSeed: String?) {
        self.photoId = photoId
        self.hashHex = hashHex
        self.componentIndex = componentIndex
        self.groupSeed = groupSeed
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
                   member_count, version, incremental_updates, updated_at,
                   algorithm_version, input_signature, state_digest
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

    /// 行级 apply（Cut 5 / 5b-2b，替代旧的“两表 DELETE 全表重插”）：
    /// - meta 单行 upsert（参数 + 版本 + 算法版本 + 指纹 + 摘要）；
    /// - 只 upsert 调用方 diff 出来的行；SQL 再按列比较一次（相同行零写）；
    /// - 只删调用方给出的 removedPhotoIds。
    public func apply(
        sessionId: String,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: String,
        version: Int,
        incrementalUpdates: Int,
        memberCount: Int,
        algorithmVersion: Int,
        inputSignature: String,
        stateDigest: String,
        upserts: [SimilarityClusterStateWrite],
        removedPhotoIds: [String]
    ) throws {
        try connection.transaction {
            _ = try connection.prepare("""
                INSERT INTO similarity_cluster_meta
                  (session_id, param_threshold, param_min_group_size, grouping_mode,
                   member_count, version, incremental_updates, updated_at,
                   algorithm_version, input_signature, state_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                  param_threshold = excluded.param_threshold,
                  param_min_group_size = excluded.param_min_group_size,
                  grouping_mode = excluded.grouping_mode,
                  member_count = excluded.member_count,
                  version = excluded.version,
                  incremental_updates = excluded.incremental_updates,
                  updated_at = excluded.updated_at,
                  algorithm_version = excluded.algorithm_version,
                  input_signature = excluded.input_signature,
                  state_digest = excluded.state_digest
              """).run([
                .text(sessionId), .int(Int64(threshold)), .int(Int64(minGroupSize)),
                .text(groupingMode), .int(Int64(memberCount)), .int(Int64(version)),
                .int(Int64(incrementalUpdates)), .text(nowISOString()),
                .int(Int64(algorithmVersion)), .text(inputSignature), .text(stateDigest),
              ])

            if !upserts.isEmpty {
                let upsert = try connection.prepare("""
                    INSERT INTO similarity_cluster_state
                      (session_id, photo_id, hash_hex, component_index, group_seed)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(session_id, photo_id) DO UPDATE SET
                      hash_hex = excluded.hash_hex,
                      component_index = excluded.component_index,
                      group_seed = excluded.group_seed
                    WHERE similarity_cluster_state.hash_hex IS NOT excluded.hash_hex
                       OR similarity_cluster_state.component_index IS NOT excluded.component_index
                       OR similarity_cluster_state.group_seed IS NOT excluded.group_seed
                  """)
                for row in upserts {
                    _ = try upsert.run([
                        .text(sessionId), .text(row.photoId), .text(row.hashHex),
                        .int(Int64(row.componentIndex)),
                        row.groupSeed.map { DBValue.text($0) } ?? .null,
                    ])
                }
            }

            if !removedPhotoIds.isEmpty {
                let delete = try connection.prepare("""
                    DELETE FROM similarity_cluster_state
                     WHERE session_id = ? AND photo_id = ?
                  """)
                for photoId in removedPhotoIds {
                    _ = try delete.run([.text(sessionId), .text(photoId)])
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