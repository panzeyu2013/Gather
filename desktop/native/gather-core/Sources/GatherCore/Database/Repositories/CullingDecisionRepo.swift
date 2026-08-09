// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/CullingDecisionRepo.swift
// TS 源: desktop/src/main/db/repositories/culling-decision.repo.ts
import Foundation

/// culling_decisions 表行（列序与 SELECT * 一致，见 Schema.swift）。
public struct CullingDecisionRow {
    public let id: Int64
    public let sessionId: String
    public let photoId: String
    public let groupId: String
    public let decision: String
    public let rating: Int64
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

/// 计数投影（decision, cnt）。
public struct CullingDecisionCountRow: Equatable {
    public let decision: String
    public let cnt: Int64
}

/// upsertState 的状态输入（TS 内联对象）。
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

    public func getDecisionsFull(_ sessionId: String) throws -> [CullingDecisionRow] {
        try getBySession(sessionId)
    }

    public func getBySession(_ sessionId: String) throws -> [CullingDecisionRow] {
        let rows = try connection.prepare("SELECT * FROM culling_decisions WHERE session_id = ?")
            .query([.text(sessionId)])
        return rows.map { CullingDecisionRow(row: $0) }
    }

    public func getDecision(sessionId: String, photoId: String) throws -> CullingDecisionRow? {
        guard let row = try connection.prepare(
            "SELECT * FROM culling_decisions WHERE session_id = ? AND photo_id = ?"
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
            let rows = try connection.prepare("""
                SELECT *
                FROM culling_decisions
                WHERE session_id = ? AND photo_id IN (\(placeholders))
              """).query(values)
            result.append(contentsOf: rows.map { CullingDecisionRow(row: $0) })
        }
        return result
    }

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

    public struct DecisionInput: Equatable {
        public let photoId: String
        public let groupId: String
        public let decision: String

        public init(photoId: String, groupId: String, decision: String) {
            self.photoId = photoId
            self.groupId = groupId
            self.decision = decision
        }
    }

    public func upsertMany(sessionId: String, decisions: [DecisionInput]) throws {
        let statement = try connection.prepare("""
            INSERT INTO culling_decisions
              (session_id, photo_id, group_id, decision, updated_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, photo_id) DO UPDATE SET
              group_id = excluded.group_id,
              decision = excluded.decision,
              decision_source = 'manual',
              updated_at = excluded.updated_at
          """)
        try connection.transaction {
            let now = nowISOString()
            for item in decisions {
                _ = try statement.run([
                    .text(sessionId), .text(item.photoId), .text(item.groupId),
                    .text(item.decision), .text(now), .text(now),
                ])
            }
        }
    }

    public func getByResultPrefix(sessionId: String, resultId: Int64) throws -> [CullingDecisionLiteRow] {
        let rows = try connection.prepare(
            "SELECT photo_id, decision FROM culling_decisions WHERE session_id = ? AND group_id LIKE ?"
        ).query([.text(sessionId), .text("\(resultId):%")])
        return rows.map {
            CullingDecisionLiteRow(photoId: $0[0].textValue ?? "", decision: $0[1].textValue ?? "")
        }
    }

    public func getCountsByResultPrefix(sessionId: String, resultId: Int64) throws -> [CullingDecisionCountRow] {
        let rows = try connection.prepare("""
            SELECT decision, COUNT(*) AS cnt
            FROM culling_decisions
            WHERE session_id = ? AND group_id LIKE ?
            GROUP BY decision
          """).query([.text(sessionId), .text("\(resultId):%")])
        return rows.map {
            CullingDecisionCountRow(decision: $0[0].textValue ?? "", cnt: $0[1].intValue ?? 0)
        }
    }

    public func getDecisionCounts(_ sessionId: String) throws -> [CullingDecisionCountRow] {
        let rows = try connection.prepare(
            "SELECT decision, COUNT(*) as cnt FROM culling_decisions WHERE session_id = ? GROUP BY decision"
        ).query([.text(sessionId)])
        return rows.map {
            CullingDecisionCountRow(decision: $0[0].textValue ?? "", cnt: $0[1].intValue ?? 0)
        }
    }

    public func deleteBySession(_ sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM culling_decisions WHERE session_id = ?").run([.text(sessionId)])
    }

    public func deleteBySessionAndGroup(sessionId: String, groupId: String) throws {
        _ = try connection.prepare("DELETE FROM culling_decisions WHERE session_id = ? AND group_id = ?")
            .run([.text(sessionId), .text(groupId)])
    }

    public struct RestoreDecisionInput: Equatable {
        public let sessionId: String
        public let photoId: String
        public let decision: String

        public init(sessionId: String, photoId: String, decision: String) {
            self.sessionId = sessionId
            self.photoId = photoId
            self.decision = decision
        }
    }

    public func batchRestoreDecisions(decisions: [RestoreDecisionInput]) throws {
        try connection.transaction {
            for d in decisions {
                _ = try connection.prepare(
                    "UPDATE culling_decisions SET decision = ? WHERE session_id = ? AND photo_id = ?"
                ).run([.text(d.decision), .text(d.sessionId), .text(d.photoId)])
            }
        }
    }
}

extension Array {
    /// 与 TS 分批循环等价的切片（每批 `size` 个）。
    func chunked(by size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
