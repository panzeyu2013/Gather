// Store/CullingStore.swift
// R1：culling_decisions / culling_history 的唯一访问入口
// （取代 Database/Repositories/CullingDecisionRepo.swift + CullingHistoryRepo.swift）。
import Foundation

/// applyDecisionStates 事务内 CAS 失败的回滚信号（仅本文件使用，不得逃出该方法）。
private struct CullingStoreRevisionConflictRollback: Error {}

public enum CullingStoreError: Error, Equatable, Sendable {
    case undoNotLatest
    case redoOutOfOrder
    case historyStale
    case historyCorrupt
}

public struct CullingDecisionRecord: Decodable, Equatable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case id, decision, rating, revision
        case sessionId = "session_id"
        case photoId = "photo_id"
        case groupId = "group_id"
        case colorLabel = "color_label"
        case decisionSource = "decision_source"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct CullingDecisionLite: Decodable, Equatable, Sendable {
    public let photoId: String
    public let decision: String

    public init(photoId: String, decision: String) {
        self.photoId = photoId
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case decision
    }
}

public struct CullingDecisionCount: Decodable, Equatable, Sendable {
    public let decision: String
    public let cnt: Int64

    public init(decision: String, cnt: Int64) {
        self.decision = decision
        self.cnt = cnt
    }
}

public struct CullingDecisionState: Sendable {
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

public struct CullingDecisionInput: Equatable, Sendable {
    public let photoId: String
    public let groupId: String
    public let decision: String

    public init(photoId: String, groupId: String, decision: String) {
        self.photoId = photoId
        self.groupId = groupId
        self.decision = decision
    }
}

public struct CullingRestoreInput: Equatable, Sendable {
    public let sessionId: String
    public let photoId: String
    public let decision: String

    public init(sessionId: String, photoId: String, decision: String) {
        self.sessionId = sessionId
        self.photoId = photoId
        self.decision = decision
    }
}

public protocol CullingStore: Sendable {
    // MARK: culling_decisions

    func decisions(sessionId: String) async throws -> [CullingDecisionLite]
    func decisionsFull(sessionId: String) async throws -> [CullingDecisionRecord]
    func decision(sessionId: String, photoId: String) async throws -> CullingDecisionRecord?
    func decisions(sessionId: String, photoIds: [String]) async throws -> [CullingDecisionRecord]
    func upsertDecision(sessionId: String, photoId: String, groupId: String, decision: String) async throws
    func upsertDecisionState(sessionId: String, photoId: String, groupId: String, state: CullingDecisionState) async throws
    func upsertDecisions(sessionId: String, decisions: [CullingDecisionInput]) async throws
    func decisionsByResultPrefix(sessionId: String, resultId: Int64) async throws -> [CullingDecisionLite]
    func decisionCountsByResultPrefix(sessionId: String, resultId: Int64) async throws -> [CullingDecisionCount]
    func decisionCounts(sessionId: String) async throws -> [CullingDecisionCount]
    func deleteDecisions(sessionId: String) async throws
    func deleteDecisions(sessionId: String, groupId: String) async throws
    func restoreDecisions(_ decisions: [CullingRestoreInput]) async throws

    // MARK: 单事务 CAS 决策写入（W2b）

    /// 单事务 CAS 落库决策行写入（消除 update 的 TOCTOU）。
    ///
    /// 每条写入以 `WHERE session_id = ? AND photo_id = ? AND revision = ?` 命中既有行
    /// （新 revision 取 `write.state.revision`）；任一 changes == 0 即整批回滚并返回
    /// false（并发点击同一 revision 恰一个成功）。`expectedRevision == 0` 且行不存在时
    /// 允许 INSERT（首次决策，保持 upsertDecisionState 语义）。
    /// `writes` 必须全部属于 `sessionId`，否则返回 false 且不落库。
    func applyDecisionStates(
        sessionId: String,
        writes: [CullingDecisionWrite],
        expectedRevision: Int
    ) async throws -> Bool

    // MARK: culling_history

    func appendHistory(sessionId: String, entries: [CullingHistoryEntry]) async throws -> CullingHistoryOperation
    func setHistoryUndone(sessionId: String, operationId: Int, undone: Bool) async throws
    func historyOperation(sessionId: String, operationId: Int) async throws -> CullingHistoryOperation?
    func historyList(sessionId: String, limit: Int) async throws -> [CullingHistoryOperation]
}

public extension CullingStore {
    func historyList(sessionId: String) async throws -> [CullingHistoryOperation] {
        try await historyList(sessionId: sessionId, limit: 100)
    }
}

public struct SQLiteCullingStore: CullingStore {
    private static let upsertDecisionSQL = """
        INSERT INTO culling_decisions
          (session_id, photo_id, group_id, decision, updated_at, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_id, photo_id) DO UPDATE SET
          group_id = excluded.group_id,
          decision = excluded.decision,
          decision_source = 'manual',
          updated_at = excluded.updated_at
        """

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: decisions

    public func decisions(sessionId: String) async throws -> [CullingDecisionLite] {
        try await database.query(
            "SELECT photo_id, decision FROM culling_decisions WHERE session_id = ?",
            [.text(sessionId)]
        ).map { try $0.decode(CullingDecisionLite.self) }
    }

    public func decisionsFull(sessionId: String) async throws -> [CullingDecisionRecord] {
        try await database.query("SELECT * FROM culling_decisions WHERE session_id = ?", [.text(sessionId)])
            .map { try $0.decode(CullingDecisionRecord.self) }
    }

    public func decision(sessionId: String, photoId: String) async throws -> CullingDecisionRecord? {
        try await database.queryOne(
            "SELECT * FROM culling_decisions WHERE session_id = ? AND photo_id = ?",
            [.text(sessionId), .text(photoId)]
        )?.decode(CullingDecisionRecord.self)
    }

    public func decisions(sessionId: String, photoIds: [String]) async throws -> [CullingDecisionRecord] {
        guard !photoIds.isEmpty else { return [] }
        var result: [CullingDecisionRecord] = []
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                "SELECT * FROM culling_decisions WHERE session_id = ? AND photo_id IN (\(placeholders))",
                [.text(sessionId)] + chunk.map { .text($0) }
            )
            result.append(contentsOf: try rows.map { try $0.decode(CullingDecisionRecord.self) })
        }
        return result
    }

    public func upsertDecision(sessionId: String, photoId: String, groupId: String, decision: String) async throws {
        let now = nowISOString()
        try await database.run(
            Self.upsertDecisionSQL,
            [.text(sessionId), .text(photoId), .text(groupId), .text(decision), .text(now), .text(now)]
        )
    }

    public func upsertDecisionState(
        sessionId: String,
        photoId: String,
        groupId: String,
        state: CullingDecisionState
    ) async throws {
        let now = nowISOString()
        try await database.run(
            """
            INSERT INTO culling_decisions
              (session_id, photo_id, group_id, decision, rating, color_label,
               decision_source, revision, updated_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, photo_id) DO UPDATE SET
              group_id = excluded.group_id,
              decision = excluded.decision,
              rating = excluded.rating,
              color_label = excluded.color_label,
              decision_source = excluded.decision_source,
              revision = excluded.revision,
              updated_at = excluded.updated_at
            """,
            [
                .text(sessionId), .text(photoId), .text(groupId), .text(state.decision),
                .int(state.rating), .text(state.colorLabel), .text(state.source ?? "manual"),
                .int(state.revision), .text(now), .text(now),
            ]
        )
    }

    public func upsertDecisions(sessionId: String, decisions: [CullingDecisionInput]) async throws {
        guard !decisions.isEmpty else { return }
        try await database.transaction { db in
            let now = nowISOString()
            for item in decisions {
                try db.run(
                    Self.upsertDecisionSQL,
                    [.text(sessionId), .text(item.photoId), .text(item.groupId), .text(item.decision), .text(now), .text(now)]
                )
            }
        }
    }

    public func decisionsByResultPrefix(sessionId: String, resultId: Int64) async throws -> [CullingDecisionLite] {
        try await database.query(
            "SELECT photo_id, decision FROM culling_decisions WHERE session_id = ? AND group_id LIKE ?",
            [.text(sessionId), .text("\(resultId):%")]
        ).map { try $0.decode(CullingDecisionLite.self) }
    }

    public func decisionCountsByResultPrefix(sessionId: String, resultId: Int64) async throws -> [CullingDecisionCount] {
        try await database.query(
            """
            SELECT decision, COUNT(*) AS cnt
            FROM culling_decisions
            WHERE session_id = ? AND group_id LIKE ?
            GROUP BY decision
            """,
            [.text(sessionId), .text("\(resultId):%")]
        ).map { try $0.decode(CullingDecisionCount.self) }
    }

    public func decisionCounts(sessionId: String) async throws -> [CullingDecisionCount] {
        try await database.query(
            "SELECT decision, COUNT(*) AS cnt FROM culling_decisions WHERE session_id = ? GROUP BY decision",
            [.text(sessionId)]
        ).map { try $0.decode(CullingDecisionCount.self) }
    }

    public func deleteDecisions(sessionId: String) async throws {
        try await database.run("DELETE FROM culling_decisions WHERE session_id = ?", [.text(sessionId)])
    }

    public func deleteDecisions(sessionId: String, groupId: String) async throws {
        try await database.run(
            "DELETE FROM culling_decisions WHERE session_id = ? AND group_id = ?",
            [.text(sessionId), .text(groupId)]
        )
    }

    public func restoreDecisions(_ decisions: [CullingRestoreInput]) async throws {
        guard !decisions.isEmpty else { return }
        try await database.transaction { db in
            for item in decisions {
                try db.run(
                    "UPDATE culling_decisions SET decision = ? WHERE session_id = ? AND photo_id = ?",
                    [.text(item.decision), .text(item.sessionId), .text(item.photoId)]
                )
            }
        }
    }

    // MARK: 单事务 CAS 决策写入（W2b）

    /// 命中既有行的 CAS 更新（WHERE revision = expectedRevision；0 changes = 冲突）。
    private static let applyDecisionStateSQL = """
        UPDATE culling_decisions
        SET group_id = ?, decision = ?, rating = ?, color_label = ?,
            decision_source = ?, revision = ?, updated_at = ?
        WHERE session_id = ? AND photo_id = ? AND revision = ?
        """

    /// 首次决策（expectedRevision == 0）允许插入；既有行仍要求 revision 匹配
    /// （ON CONFLICT DO UPDATE 的 WHERE 不满足时 changes == 0）。
    private static let insertFirstDecisionStateSQL = """
        INSERT INTO culling_decisions
          (session_id, photo_id, group_id, decision, rating, color_label,
           decision_source, revision, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_id, photo_id) DO UPDATE SET
          group_id = excluded.group_id,
          decision = excluded.decision,
          rating = excluded.rating,
          color_label = excluded.color_label,
          decision_source = excluded.decision_source,
          revision = excluded.revision,
          updated_at = excluded.updated_at
        WHERE culling_decisions.revision = ?
        """

    public func applyDecisionStates(
        sessionId: String,
        writes: [CullingDecisionWrite],
        expectedRevision: Int
    ) async throws -> Bool {
        guard writes.allSatisfy({ $0.sessionId == sessionId }) else { return false }
        guard !writes.isEmpty else { return true }
        do {
            try await database.transaction { db in
                let now = nowISOString()
                let baseline = Int64(expectedRevision)
                for write in writes {
                    let state = write.state
                    let changed: Int
                    if expectedRevision == 0 {
                        changed = try db.run(Self.insertFirstDecisionStateSQL, [
                            .text(write.sessionId), .text(write.photoId), .text(write.groupId),
                            .text(state.decision), .int(state.rating), .text(state.colorLabel),
                            .text(state.source ?? "manual"), .int(state.revision),
                            .text(now), .text(now), .int(baseline),
                        ])
                    } else {
                        changed = try db.run(Self.applyDecisionStateSQL, [
                            .text(write.groupId), .text(state.decision), .int(state.rating),
                            .text(state.colorLabel), .text(state.source ?? "manual"),
                            .int(state.revision), .text(now),
                            .text(write.sessionId), .text(write.photoId), .int(baseline),
                        ])
                    }
                    // 冲突：整批回滚（transaction 抛错回滚），对外映射为 false。
                    if changed == 0 { throw CullingStoreRevisionConflictRollback() }
                }
            }
            return true
        } catch is CullingStoreRevisionConflictRollback {
            return false
        }
    }

    // MARK: history

    public func appendHistory(sessionId: String, entries: [CullingHistoryEntry]) async throws -> CullingHistoryOperation {
        let createdAt = nowISOString()
        let encoded = try JSONEncoder().encode(entries)
        let operationJSON = String(data: encoded, encoding: .utf8) ?? "[]"
        let id: Int64 = try await database.transaction { db in
            try db.run("DELETE FROM culling_history WHERE session_id = ? AND undone = 1", [.text(sessionId)])
            try db.run(
                """
                INSERT INTO culling_history (session_id, operation_json, undone, created_at)
                VALUES (?, ?, 0, ?)
                """,
                [.text(sessionId), .text(operationJSON), .text(createdAt)]
            )
            return db.lastInsertRowID
        }
        return CullingHistoryOperation(
            id: Int(id),
            sessionId: sessionId,
            entries: entries,
            undone: false,
            createdAt: createdAt
        )
    }

    public func setHistoryUndone(sessionId: String, operationId: Int, undone: Bool) async throws {
        try await database.transaction { db in
            let boundary = try db.queryOne(
                """
                SELECT \(undone ? "MAX" : "MIN")(id) AS id
                FROM culling_history WHERE session_id = ? AND undone = ?
                """,
                [.text(sessionId), .int(undone ? 0 : 1)]
            )
            let boundaryId = boundary?.int("id")
            if boundaryId != Int64(operationId) {
                throw undone ? CullingStoreError.undoNotLatest : CullingStoreError.redoOutOfOrder
            }
            let changed = try db.run(
                """
                UPDATE culling_history SET undone = ?
                WHERE id = ? AND session_id = ? AND undone = ?
                """,
                [.int(undone ? 1 : 0), .int(Int64(operationId)), .text(sessionId), .int(undone ? 0 : 1)]
            )
            if changed != 1 { throw CullingStoreError.historyStale }
        }
    }

    public func historyOperation(sessionId: String, operationId: Int) async throws -> CullingHistoryOperation? {
        guard let row = try await database.queryOne(
            """
            SELECT id, session_id, operation_json, undone, created_at
            FROM culling_history WHERE id = ? AND session_id = ?
            """,
            [.int(Int64(operationId)), .text(sessionId)]
        ) else { return nil }
        return try Self.makeOperation(row)
    }

    public func historyList(sessionId: String, limit: Int = 100) async throws -> [CullingHistoryOperation] {
        let clamped = Swift.min(Swift.max(1, limit), 500)
        let rows = try await database.query(
            """
            SELECT id, session_id, operation_json, undone, created_at
            FROM culling_history WHERE session_id = ? ORDER BY id DESC LIMIT ?
            """,
            [.text(sessionId), .int(Int64(clamped))]
        )
        var result: [CullingHistoryOperation] = []
        for row in rows {
            if let operation = try? Self.makeOperation(row) {
                result.append(operation)
            }
        }
        return result
    }

    private static func makeOperation(_ row: SQLiteRow) throws -> CullingHistoryOperation {
        let operationJSON = row.text("operation_json") ?? ""
        do {
            let entries = try JSONDecoder().decode([CullingHistoryEntry].self, from: Data(operationJSON.utf8))
            return CullingHistoryOperation(
                id: Int(row.int("id") ?? 0),
                sessionId: row.text("session_id") ?? "",
                entries: entries,
                undone: (row.int("undone") ?? 0) != 0,
                createdAt: row.text("created_at") ?? ""
            )
        } catch {
            throw CullingStoreError.historyCorrupt
        }
    }
}
