// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/ProofFeedbackRepo.swift
// P1 下一波：客户校样反馈（client_proof_feedback）持久化层。
//
// 这张表是**原始反馈的审计账本**：导入即落库（含被跳过/冲突的项），应用与否
// 记录在 applied_at。约束与语义：
// - 幂等键 (batch_id, photo_id)：同一份 selection.json 重复导入不会产生第二行，
//   也不会重复应用（ProofFeedbackService 用 batchExists 短路）；
// - pick_state 的取值与 culling_decisions.decision 同一套（unreviewed/picked/rejected），
//   由调用方把 pick=true/false 映射好再传；
// - rating NULL = "客户没打分"，与 0（明确打 0 星）区分；
// - comment 只落库，不写 XMP（不覆盖 dc:description）；
// - 全部写路径用 ? 绑定、显式列清单，行映射按列名取值。

import Foundation
import GatherProtocol

/// client_proof_feedback 行。
public struct ProofFeedbackRow: Equatable, Sendable {
    public let id: Int64
    public let batchId: String
    public let sessionId: String
    public let photoId: String
    public let pickState: String
    public let rating: Int?
    public let label: String
    public let comment: String
    public let submittedAt: String
    public let importedAt: String
    public let appliedAt: String

    public init(row: DBRow) {
        id = row[0].intValue ?? 0
        batchId = row[1].textValue ?? ""
        sessionId = row[2].textValue ?? ""
        photoId = row[3].textValue ?? ""
        pickState = row[4].textValue ?? "unreviewed"
        rating = row[5].intValue.map { Int($0) }
        label = row[6].textValue ?? ""
        comment = row[7].textValue ?? ""
        submittedAt = row[8].textValue ?? ""
        importedAt = row[9].textValue ?? ""
        appliedAt = row[10].textValue ?? ""
    }

    public var isApplied: Bool { !appliedAt.isEmpty }
    public var pick: PickState { PickState(rawValue: pickState) ?? .unreviewed }

    /// 显式列清单（行映射序 = 这里；禁止 SELECT *）。
    static let columns =
        "id, batch_id, session_id, photo_id, pick_state, rating, label, comment, "
        + "submitted_at, imported_at, applied_at"
}

/// 导入单条（应用前的原始值）。
public struct ProofFeedbackInsert: Equatable, Sendable {
    public var photoId: String
    public var pickState: String
    public var rating: Int?
    public var label: String
    public var comment: String
    public var submittedAt: String

    public init(
        photoId: String,
        pickState: String = PickState.unreviewed.rawValue,
        rating: Int? = nil,
        label: String = "",
        comment: String = "",
        submittedAt: String = ""
    ) {
        self.photoId = photoId
        self.pickState = pickState
        self.rating = rating
        self.label = label
        self.comment = comment
        self.submittedAt = submittedAt
    }
}

/// 本地星级/色标现状（冲突判定用；真相源 = photo_metadata_cache）。
public struct LocalRatingState: Equatable, Sendable {
    public let rating: Int
    public let label: String
    public let updatedAt: String

    public init(rating: Int, label: String, updatedAt: String) {
        self.rating = rating
        self.label = label
        self.updatedAt = updatedAt
    }
}

public struct ProofFeedbackRepo: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 落一批原始反馈。返回**真正新增**的行数（已存在的 (batch, photo) 被忽略）。
    @discardableResult
    public func insertBatch(
        batchId: String,
        sessionId: String,
        items: [ProofFeedbackInsert],
        importedAt: String
    ) throws -> Int {
        guard !batchId.isEmpty, !sessionId.isEmpty, !items.isEmpty else { return 0 }
        var inserted = 0
        try connection.transaction {
            let statement = try connection.prepare("""
                INSERT OR IGNORE INTO client_proof_feedback
                  (batch_id, session_id, photo_id, pick_state, rating, label, comment,
                   submitted_at, imported_at, applied_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, '')
                """)
            for item in items {
                guard !item.photoId.isEmpty else { continue }
                let changed = try statement.run([
                    .text(batchId), .text(sessionId), .text(item.photoId),
                    .text(item.pickState), optDB(item.rating.map { Int64($0) }),
                    .text(item.label), .text(item.comment),
                    .text(item.submittedAt), .text(importedAt),
                ])
                inserted += changed
            }
        }
        return inserted
    }

    /// 这个 batch 之前导入过吗（幂等短路；不推断内容是否相同——batch_id 就是内容哈希）。
    public func batchExists(batchId: String) throws -> Bool {
        guard !batchId.isEmpty else { return false }
        let row = try connection.prepare(
            "SELECT 1 FROM client_proof_feedback WHERE batch_id = ? LIMIT 1"
        ).get([.text(batchId)])
        return row != nil
    }

    public func rows(batchId: String) throws -> [ProofFeedbackRow] {
        guard !batchId.isEmpty else { return [] }
        let rows = try connection.prepare("""
            SELECT \(ProofFeedbackRow.columns)
            FROM client_proof_feedback
            WHERE batch_id = ?
            ORDER BY photo_id
            """).query([.text(batchId)])
        return rows.map { ProofFeedbackRow(row: $0) }
    }

    /// 该会话最近的反馈（检查器徽章用；默认按导入时间倒序）。
    public func rows(sessionId: String, limit: Int = 200) throws -> [ProofFeedbackRow] {
        guard !sessionId.isEmpty else { return [] }
        let rows = try connection.prepare("""
            SELECT \(ProofFeedbackRow.columns)
            FROM client_proof_feedback
            WHERE session_id = ?
            ORDER BY imported_at DESC, id DESC
            LIMIT ?
            """).query([.text(sessionId), .int(Int64(max(1, limit)))])
        return rows.map { ProofFeedbackRow(row: $0) }
    }

    /// 该会话全部带评论的反馈（聚合用；不设 LIMIT，避免把 200 行当全量）。
    public func commentRows(sessionId: String) throws -> [ProofFeedbackRow] {
        guard !sessionId.isEmpty else { return [] }
        let rows = try connection.prepare("""
            SELECT \(ProofFeedbackRow.columns)
            FROM client_proof_feedback
            WHERE session_id = ? AND comment <> ''
            ORDER BY imported_at DESC, id DESC
            """).query([.text(sessionId)])
        return rows.map { ProofFeedbackRow(row: $0) }
    }

    /// 该会话已导入的批次数（COUNT(DISTINCT)，不经过限量列表）。
    public func batchCount(sessionId: String) throws -> Int {
        guard !sessionId.isEmpty else { return 0 }
        return Int(try connection.prepare("""
            SELECT COUNT(DISTINCT batch_id) FROM client_proof_feedback
            WHERE session_id = ?
            """).get([.text(sessionId)])?[0].intValue ?? 0)
    }

    /// 某张照片最近一条带评论的反馈（只读气泡）。
    public func latestComment(sessionId: String, photoId: String) throws -> ProofFeedbackRow? {
        let row = try connection.prepare("""
            SELECT \(ProofFeedbackRow.columns)
            FROM client_proof_feedback
            WHERE session_id = ? AND photo_id = ? AND comment <> ''
            ORDER BY imported_at DESC, id DESC
            LIMIT 1
            """).get([.text(sessionId), .text(photoId)])
        return row.map { ProofFeedbackRow(row: $0) }
    }

    /// 标记已应用（幂等：只更新 applied_at 为空的行；返回更新行数）。
    @discardableResult
    public func markApplied(
        batchId: String, photoIds: [String], at appliedAt: String
    ) throws -> Int {
        guard !batchId.isEmpty, !photoIds.isEmpty else { return 0 }
        var updated = 0
        try connection.transaction {
            let statement = try connection.prepare("""
                UPDATE client_proof_feedback
                SET applied_at = ?
                WHERE batch_id = ? AND photo_id = ? AND applied_at = ''
                """)
            for photoId in photoIds {
                updated += try statement.run([
                    .text(appliedAt), .text(batchId), .text(photoId),
                ])
            }
        }
        return updated
    }

    /// 这些 photoId 里哪些属于该会话（未知 id 必须能被数出来，不能静默丢）。
    public func existingPhotoIds(
        sessionId: String, photoIds: [String]
    ) throws -> Set<String> {
        guard !sessionId.isEmpty, !photoIds.isEmpty else { return [] }
        var result = Set<String>()
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var values: [DBValue?] = [.text(sessionId)]
            values.append(contentsOf: chunk.map { .text($0) })
            let rows = try connection.prepare("""
                SELECT id FROM photos
                WHERE session_id = ? AND id IN (\(placeholders))
                """).query(values)
            for row in rows {
                if let photoId = row[0].textValue { result.insert(photoId) }
            }
        }
        return result
    }

    /// 本地星级/色标现状（一次查询；缺缓存行的照片不返回）。
    public func localRatingStates(
        sessionId: String, photoIds: [String]
    ) throws -> [String: LocalRatingState] {
        guard !sessionId.isEmpty, !photoIds.isEmpty else { return [:] }
        var result: [String: LocalRatingState] = [:]
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var values: [DBValue?] = [.text(sessionId)]
            values.append(contentsOf: chunk.map { .text($0) })
            let rows = try connection.prepare("""
                SELECT photo_id, COALESCE(rating, 0), COALESCE(label, ''), COALESCE(updated_at, '')
                FROM photo_metadata_cache
                WHERE session_id = ? AND photo_id IN (\(placeholders))
                """).query(values)
            for row in rows {
                guard let photoId = row[0].textValue else { continue }
                result[photoId] = LocalRatingState(
                    rating: Int(row[1].intValue ?? 0),
                    label: row[2].textValue ?? "",
                    updatedAt: row[3].textValue ?? "")
            }
        }
        return result
    }
}
