// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/SimilarityResultRepo.swift
// TS 源: desktop/src/main/db/repositories/similarity-result.repo.ts
import Foundation

/// similarity_results 表行（列序与表定义一致）。
public struct SimilarityResultRow: Equatable, Sendable {
    public let id: Int64
    public let sessionId: String
    public let groupsJson: String
    public let statsJson: String
    public let paramThreshold: Int
    public let paramMinGroupSize: Int
    public let createdAt: String

    init(row: DBRow) throws {
        guard row.count >= 7 else { throw DBError.message("SimilarityResultRow 列数不足: \(row.count)") }
        id = row[0].intValue ?? 0
        sessionId = row[1].textValue ?? ""
        groupsJson = row[2].textValue ?? ""
        statsJson = row[3].textValue ?? ""
        paramThreshold = Int(row[4].intValue ?? 0)
        paramMinGroupSize = Int(row[5].intValue ?? 0)
        createdAt = row[6].textValue ?? ""
    }
}

/// getGroupMembers 的单行：group_index / photo_id / filepath（JOIN photos）。
public struct SimilarityGroupMember: Equatable, Sendable {
    public let groupIndex: Int
    public let photoId: String
    public let filepath: String
}

public final class SimilarityResultRepo {
    /// TS 常量 PRECOMPUTED_TIER_MARKER：预计算阈值行在 stats_json 中带
    /// `"precomputed":true`，getLatest 据此排除。
    private static let precomputedTierMarker = "\"precomputed\":true"

    private static let photoGroupMapCacheMax = 32
    /// 成员投影缓存（TS: photoGroupMapCache），键为 "sessionId:resultId"。
    /// Swift Dictionary 为值类型，返回时自动拷贝，天然满足 TS 的
    /// "return a copy instead of the cached instance" 约束。
    private var photoGroupMapCache: [String: [String: String]] = [:]
    /// 插入序键列表，用于超限时淘汰最旧条目。
    private var photoGroupMapCacheOrder: [String] = []

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func getLatest(sessionId: String) throws -> SimilarityResultRow? {
        // similarity_results：7 列（TableColumns.similarityResults，列序 = SimilarityResultRow 0-6）
        guard let row = try connection.prepare(
            "SELECT \(TableColumns.sql(TableColumns.similarityResults)) FROM similarity_results WHERE session_id = ? AND stats_json NOT LIKE ? ORDER BY id DESC LIMIT 1"
        ).get([.text(sessionId), .text("%\(Self.precomputedTierMarker)%")]) else {
            return nil
        }
        return try SimilarityResultRow(row: row)
    }

    public func getByThreshold(sessionId: String, threshold: Int) throws -> SimilarityResultRow? {
        // similarity_results：7 列（TableColumns.similarityResults）
        guard let row = try connection.prepare(
            "SELECT \(TableColumns.sql(TableColumns.similarityResults)) FROM similarity_results WHERE session_id = ? AND param_threshold = ? ORDER BY id DESC LIMIT 1"
        ).get([.text(sessionId), .int(Int64(threshold))]) else {
            return nil
        }
        return try SimilarityResultRow(row: row)
    }

    public func replace(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [(photoId: String, groupIndex: Int)]
    ) throws -> Int64 {
        let resultId: Int64 = try connection.transaction {
            _ = try connection.prepare("DELETE FROM similarity_results WHERE session_id = ?").run([.text(sessionId)])
            return try insertRow(
                sessionId: sessionId,
                groupsJson: groupsJson,
                statsJson: statsJson,
                threshold: threshold,
                minGroupSize: minGroupSize,
                memberships: memberships
            )
        }
        invalidateSessionMembersCache(sessionId: sessionId)
        return resultId
    }

    public func replaceForThreshold(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [(photoId: String, groupIndex: Int)]
    ) throws -> Int64 {
        let resultId: Int64 = try connection.transaction {
            _ = try connection.prepare(
                "DELETE FROM similarity_results WHERE session_id = ? AND param_threshold = ?"
            ).run([.text(sessionId), .int(Int64(threshold))])
            return try insertRow(
                sessionId: sessionId,
                groupsJson: groupsJson,
                statsJson: statsJson,
                threshold: threshold,
                minGroupSize: minGroupSize,
                memberships: memberships
            )
        }
        invalidateSessionMembersCache(sessionId: sessionId)
        return resultId
    }

    private func insertRow(
        sessionId: String,
        groupsJson: String,
        statsJson: String,
        threshold: Int,
        minGroupSize: Int,
        memberships: [(photoId: String, groupIndex: Int)]
    ) throws -> Int64 {
        _ = try connection.prepare(
            "INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at) VALUES (?, ?, ?, ?, ?, ?)"
        ).run([
            .text(sessionId),
            .text(groupsJson),
            .text(statsJson),
            .int(Int64(threshold)),
            .int(Int64(minGroupSize)),
            .text(nowISOString()),
        ])
        let resultId = connection.lastInsertRowid
        let insertMember = try connection.prepare(
            "INSERT INTO similarity_result_members (result_id, session_id, group_index, photo_id) VALUES (?, ?, ?, ?)"
        )
        for membership in memberships {
            _ = try insertMember.run([
                .int(resultId),
                .text(sessionId),
                .int(Int64(membership.groupIndex)),
                .text(membership.photoId),
            ])
        }
        return resultId
    }

    /// photo_id → "resultId:groupIndex" 映射（带缓存，值类型拷贝返回）。
    public func getPhotoGroupMap(sessionId: String, resultId: Int64) throws -> [String: String] {
        let key = "\(sessionId):\(resultId)"
        if let cached = photoGroupMapCache[key] {
            return cached
        }
        let rows = try connection.prepare(
            "SELECT photo_id, group_index FROM similarity_result_members WHERE session_id = ? AND result_id = ?"
        ).query([.text(sessionId), .int(resultId)])
        var map: [String: String] = [:]
        for row in rows {
            guard let photoId = row[0].textValue else { continue }
            map[photoId] = "\(resultId):\(row[1].intValue ?? 0)"
        }
        photoGroupMapCache[key] = map
        photoGroupMapCacheOrder.append(key)
        if photoGroupMapCache.count > Self.photoGroupMapCacheMax {
            let oldest = photoGroupMapCacheOrder.removeFirst()
            photoGroupMapCache.removeValue(forKey: oldest)
        }
        return map
    }

    /// TS: invalidateSessionMembersCache —— 清除该会话的全部缓存条目。
    private func invalidateSessionMembersCache(sessionId: String) {
        let prefix = "\(sessionId):"
        photoGroupMapCacheOrder = photoGroupMapCacheOrder.filter { !$0.hasPrefix(prefix) }
        photoGroupMapCache = photoGroupMapCache.filter { !$0.key.hasPrefix(prefix) }
    }

    /// 每个组的原始成员数（未过滤归档）：区分"组本来只有 1 张"与"归档后只剩 1 张"。
    public func groupMemberCounts(sessionId: String, resultId: Int64) throws -> [Int: Int] {
        let rows = try connection.prepare("""
            SELECT group_index, COUNT(*) FROM similarity_result_members
            WHERE result_id = ? AND session_id = ?
            GROUP BY group_index
          """).query([.int(resultId), .text(sessionId)])
        var counts: [Int: Int] = [:]
        for row in rows {
            counts[Int(row[0].intValue ?? 0)] = Int(row[1].intValue ?? 0)
        }
        return counts
    }

    public func countFullyArchivedGroups(sessionId: String, resultId: Int64) throws -> Int {
        let row = try connection.prepare("""
            SELECT COUNT(*) FROM (
              SELECT m.group_index
              FROM similarity_result_members m
              JOIN photos p ON p.id = m.photo_id
              WHERE m.result_id = ? AND m.session_id = ?
              GROUP BY m.group_index
              HAVING SUM(CASE WHEN \(PhotoVisibility.visiblePredicate(alias: "p")) THEN 1 ELSE 0 END) = 0
            )
          """).get([.int(resultId), .text(sessionId)])
        return Int(row?[0].intValue ?? 0)
    }

    /// 组成员行（JOIN photos 带 filepath），按成员表隐式 rowid 排序；
    /// 无成员行时返回 nil（老数据仅 groups_json 一种来源）。
    public func getGroupMembers(sessionId: String, resultId: Int64) throws -> [SimilarityGroupMember]? {
        // nil = 该结果完全没有成员行（旧数据，只有 groups_json）；
        // 有成员行但全部归档时返回 []（不能再回退 groups_json，否则归档成员又出现）。
        let total = try connection.prepare("""
            SELECT COUNT(*) FROM similarity_result_members
            WHERE result_id = ? AND session_id = ?
          """).get([.int(resultId), .text(sessionId)])?[0].intValue ?? 0
        guard total > 0 else { return nil }
        let rows = try connection.prepare(
            "SELECT m.group_index, m.photo_id, p.filepath FROM similarity_result_members m JOIN photos p ON p.id = m.photo_id WHERE m.result_id = ? AND m.session_id = ? AND \(PhotoVisibility.visiblePredicate(alias: "p")) ORDER BY m.rowid"
        ).query([.int(resultId), .text(sessionId)])
        if rows.isEmpty { return [] }
        return rows.map { row in
            SimilarityGroupMember(
                groupIndex: Int(row[0].intValue ?? 0),
                photoId: row[1].textValue ?? "",
                filepath: row[2].textValue ?? ""
            )
        }
    }
}


