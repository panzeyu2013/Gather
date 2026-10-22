// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/CullingDecisionRepo.swift
// TS 源: desktop/src/main/db/repositories/culling-decision.repo.ts
//
// ── 单一真相源契约（挑片域，禁止双真相源）─────────────────────────────
// culling_decisions 只拥有「挑片决策本身」：decision(pick/reject/pending)、
// group_id、revision、decision_source。
//
// rating / color_label 两列是**镜像列**：写路径在同一事务里把它们与
// photo_metadata_cache 写成同值（保持数据库可检视、NOT NULL 约束可满足），
// 但**任何读取路径都不得读它们**。星级/色标的唯一真相源是
// photo_metadata_cache（全应用范围的 XMP 投影：导入扫描、写回落盘、外部接受、
// 挑片更新都写它）。读取走 cache、写入走 cache、reset 清 cache，四条路径收敛。
//
// 历史背景：旧实现读路径优先决策行、写路径双写、reset 只删决策行 → reset 后
// 页面仍显示旧值、summary 仍报 rated/labeled。禁止恢复该形态。
import Foundation

/// culling_decisions 表行（列序 = TableColumns.cullingDecisions，见 Schema.swift）。
public struct CullingDecisionRow {
    public let id: Int64
    public let sessionId: String
    public let photoId: String
    public let groupId: String
    public let decision: String
    /// 镜像列：不是真相源，禁止读取（唯一真相源为 photo_metadata_cache.rating）。
    public let rating: Int64
    /// 镜像列：不是真相源，禁止读取（唯一真相源为 photo_metadata_cache.label）。
    public let colorLabel: String
    public let decisionSource: String
    public let revision: Int64
    public let createdAt: String
    public let updatedAt: String

    public init(row: DBRow) {
        id = row[0].intValue ?? 0
        sessionId = row[1].textValue ?? ""
        photoId = row[2].textValue ?? ""
        groupId = row[3].textValue ?? ""
        decision = row[4].textValue ?? ""
        rating = row[5].intValue ?? 0
        colorLabel = row[6].textValue ?? ""
        decisionSource = row[7].textValue ?? ""
        revision = row[8].intValue ?? 0
        createdAt = row[9].textValue ?? ""
        updatedAt = row[10].textValue ?? ""
    }
}

/// 轻量投影（photo_id, decision）。
public struct CullingDecisionLiteRow: Equatable {
    public let photoId: String
    public let decision: String
}

/// upsertState 的状态输入（TS 内联对象）。rating/colorLabel 为镜像值（见文件头注）。
public struct CullingDecisionStateInput {
    public let decision: String
    public let rating: Int64
    public let colorLabel: String
    public let revision: Int64
    public let source: String?

    public init(decision: String, rating: Int64, colorLabel: String, revision: Int64, source: String? = nil) {
        self.decision = decision
        self.rating = rating
        self.colorLabel = colorLabel
        self.revision = revision
        self.source = source
    }
}

/// culling_decisions 仓库（TS CullingDecisionRepository）。
public final class CullingDecisionRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func getDecisions(_ sessionId: String) throws -> [CullingDecisionLiteRow] {
        let rows = try connection.prepare(
            "SELECT photo_id, decision FROM culling_decisions WHERE session_id = ?"
        ).query([.text(sessionId)])
        return rows.map {
            CullingDecisionLiteRow(photoId: $0[0].textValue ?? "", decision: $0[1].textValue ?? "")
        }
    }

    public func getBySession(_ sessionId: String) throws -> [CullingDecisionRow] {
        // culling_decisions：11 列（TableColumns.cullingDecisions，列序 = CullingDecisionRow 0-10）
        let rows = try connection.prepare("SELECT \(TableColumns.sql(TableColumns.cullingDecisions)) FROM culling_decisions WHERE session_id = ?")
            .query([.text(sessionId)])
        return rows.map { CullingDecisionRow(row: $0) }
    }

    public func getDecision(sessionId: String, photoId: String) throws -> CullingDecisionRow? {
        // culling_decisions：11 列（TableColumns.cullingDecisions）
        guard let row = try connection.prepare(
            "SELECT \(TableColumns.sql(TableColumns.cullingDecisions)) FROM culling_decisions WHERE session_id = ? AND photo_id = ?"
        ).get([.text(sessionId), .text(photoId)]) else { return nil }
        return CullingDecisionRow(row: row)
    }

    public func upsert(sessionId: String, photoId: String, groupId: String, decision: String) throws {
        let now = nowISOString()
        _ = try connection.prepare("""
            INSERT INTO culling_decisions
              (session_id, photo_id, group_id, decision, updated_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, photo_id) DO UPDATE SET
              group_id = excluded.group_id,
              decision = excluded.decision,
              decision_source = 'manual',
              updated_at = excluded.updated_at
          """).run([.text(sessionId), .text(photoId), .text(groupId), .text(decision), .text(now), .text(now)])
    }

    public func getByPhotoIds(sessionId: String, photoIds: [String]) throws -> [CullingDecisionRow] {
        if photoIds.isEmpty { return [] }
        var result: [CullingDecisionRow] = []
        // Stay below SQLite's parameter limit while allowing large batches.
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var values: [DBValue?] = [.text(sessionId)]
            values.append(contentsOf: chunk.map { .text($0) })
            // culling_decisions：11 列（TableColumns.cullingDecisions）
            let rows = try connection.prepare("""
                SELECT \(TableColumns.sql(TableColumns.cullingDecisions))
                FROM culling_decisions
                WHERE session_id = ? AND photo_id IN (\(placeholders))
              """).query(values)
            result.append(contentsOf: rows.map { CullingDecisionRow(row: $0) })
        }
        return result
    }

    /// 决策行 upsert（TS upsertState）。rating/colorLabel 是镜像列：调用方必须传入
    /// 与 photo_metadata_cache 同事务同值的快照（见文件头注）。
    public func upsertState(
        sessionId: String,
        photoId: String,
        groupId: String,
        state: CullingDecisionStateInput
    ) throws {
        let now = nowISOString()
        _ = try connection.prepare("""
            INSERT INTO culling_decisions
              (
                session_id, photo_id, group_id, decision, rating, color_label,
                decision_source, revision, updated_at, created_at
              )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, photo_id) DO UPDATE SET
              group_id = excluded.group_id,
              decision = excluded.decision,
              rating = excluded.rating,
              color_label = excluded.color_label,
              decision_source = excluded.decision_source,
              revision = excluded.revision,
              updated_at = excluded.updated_at
          """).run([
            .text(sessionId), .text(photoId), .text(groupId), .text(state.decision),
            .int(state.rating), .text(state.colorLabel), .text(state.source ?? "manual"),
            .int(state.revision), .text(now), .text(now),
        ])
    }

    /// 删除整会话决策行，返回被删除决策覆盖的 photo_id（reset 需要据此撤回
    /// photo_metadata_cache 投影与历史操作）。SELECT+DELETE 在事务内原子完成。
    @discardableResult
    public func deleteBySession(_ sessionId: String) throws -> [String] {
        try connection.transaction {
            let ids = try photoIdsForDeletion(sessionId: sessionId, groupId: nil)
            _ = try connection.prepare("DELETE FROM culling_decisions WHERE session_id = ?")
                .run([.text(sessionId)])
            return ids
        }
    }

    /// 删除会话内单组决策行，返回被删除决策覆盖的 photo_id（语义同上）。
    @discardableResult
    public func deleteBySessionAndGroup(sessionId: String, groupId: String) throws -> [String] {
        try connection.transaction {
            let ids = try photoIdsForDeletion(sessionId: sessionId, groupId: groupId)
            _ = try connection.prepare("DELETE FROM culling_decisions WHERE session_id = ? AND group_id = ?")
                .run([.text(sessionId), .text(groupId)])
            return ids
        }
    }

    private func photoIdsForDeletion(sessionId: String, groupId: String?) throws -> [String] {
        let rows: [DBRow]
        if let groupId {
            rows = try connection.prepare(
                "SELECT photo_id FROM culling_decisions WHERE session_id = ? AND group_id = ?"
            ).query([.text(sessionId), .text(groupId)])
        } else {
            rows = try connection.prepare(
                "SELECT photo_id FROM culling_decisions WHERE session_id = ?"
            ).query([.text(sessionId)])
        }
        return rows.compactMap { $0[0].textValue }
    }



}

extension Array {
    /// 与 TS 分批循环等价的切片（每批 `size` 个）。
    public func chunked(by size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
