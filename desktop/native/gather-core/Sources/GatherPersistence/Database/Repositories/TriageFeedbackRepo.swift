// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/TriageFeedbackRepo.swift
// P1 下一波 / §3.11.4：triage_feedback 的写入与校准样本查询。
//
// 边界：
// - 只写 Gather 自己的表；不写 XMP、不动 culling_decisions（决策由 CullingService 写）；
// - 「只保留最后一条」在写入时执行（同一 photo 重复改动先删后插），保证表有界；
//   删除条数经结果返回，调用方可记日志（DDL 无计数字段，不 ALTER 既有表）；
// - 校准样本**只取人工决定**（culling_decisions.decision_source ∈ manual/imported
//   且 revision > 0）：AI 自动应用写入的 feedback 不能被当成"用户同意"，
//   否则精确率恒等于 1，校准失去意义。
import Foundation
import GatherProtocol

/// 一条用户反馈（suggestion × 实际动作）。
public struct TriageFeedbackEntry: Equatable, Sendable {
    /// keep / reject / review（与 triage_suggestions.verdict 同域）。
    public let suggestionVerdict: String
    /// 用户最终动作：keep / reject / review / cleared（清空待定）。
    public let userAction: String
    public let suggestionConfidence: Double
    public let policyVersion: String
    public let photoId: String
    public let sessionId: String
    public let actedAt: String

    public init(
        suggestionVerdict: String,
        userAction: String,
        suggestionConfidence: Double,
        policyVersion: String,
        photoId: String,
        sessionId: String,
        actedAt: String
    ) {
        self.suggestionVerdict = suggestionVerdict
        self.userAction = userAction
        self.suggestionConfidence = suggestionConfidence
        self.policyVersion = policyVersion
        self.photoId = photoId
        self.sessionId = sessionId
        self.actedAt = actedAt
    }

    /// 三档合法值收敛：非法输入不落库（DB 有 CHECK，提前在服务层拒绝更可读）。
    public var isWellFormed: Bool {
        Self.verdicts.contains(suggestionVerdict)
            && Self.actions.contains(userAction)
            && suggestionConfidence.isFinite
            && suggestionConfidence >= 0
            && suggestionConfidence <= 1
            && !photoId.isEmpty
            && !sessionId.isEmpty
    }

    public static let verdicts: Set<String> = ["keep", "reject", "review"]
    public static let actions: Set<String> = ["keep", "reject", "review", "cleared"]
}

public struct TriageFeedbackWriteResult: Equatable, Sendable {
    public let written: Int
    /// 被覆盖掉的旧行数（"同一 photo 只留最后一条"的可见代价）。
    public let replaced: Int

    public init(written: Int, replaced: Int) {
        self.written = written
        self.replaced = replaced
    }
}

/// 校准样本：建议 + 人工决定 + 机型/ISO（分机型可靠性报告用）。
public struct TriageCalibrationSample: Equatable, Sendable {
    public let photoId: String
    public let sessionId: String
    public let suggestionVerdict: String
    public let suggestionConfidence: Double
    public let userAction: String
    public let policyVersion: String
    public let cameraModel: String?
    public let iso: Int?

    public init(
        photoId: String,
        sessionId: String,
        suggestionVerdict: String,
        suggestionConfidence: Double,
        userAction: String,
        policyVersion: String,
        cameraModel: String?,
        iso: Int?
    ) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.suggestionVerdict = suggestionVerdict
        self.suggestionConfidence = suggestionConfidence
        self.userAction = userAction
        self.policyVersion = policyVersion
        self.cameraModel = cameraModel
        self.iso = iso
    }
}

/// 建议快照：写 feedback 时要知道"当时的建议是什么"（verdict/confidence/策略版本）。
public struct TriageSuggestionSnapshot: Equatable, Sendable {
    public let photoId: String
    public let verdict: String
    public let confidence: Double
    public let policyVersion: String

    public init(photoId: String, verdict: String, confidence: Double, policyVersion: String) {
        self.photoId = photoId
        self.verdict = verdict
        self.confidence = confidence
        self.policyVersion = policyVersion
    }
}

/// 反馈存储端口（TriageService 写入、TriageCalibrationService 读样本）。
public protocol TriageFeedbackStore {
    /// 覆盖写：同一 (photo_id, session_id) 只留最后一条。
    func record(_ entries: [TriageFeedbackEntry]) throws -> TriageFeedbackWriteResult
    /// 单条建议快照（无建议 = nil）。与 feedback 同表组，避免为一次查找再开端口。
    func suggestionSnapshot(photoId: String) throws -> TriageSuggestionSnapshot?
    /// 校准样本；sessionId == nil 表示全库（跨会话校准）。
    func loadCalibrationSamples(sessionId: String?) throws -> [TriageCalibrationSample]
    /// 已记录的反馈行数（不叠加人工决定过滤，仅用于"有没有反馈"）。
    func count(sessionId: String?) throws -> Int
    func deleteAll() throws -> Int
}

public final class TriageFeedbackRepo: TriageFeedbackStore {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func record(_ entries: [TriageFeedbackEntry]) throws -> TriageFeedbackWriteResult {
        let valid = entries.filter(\.isWellFormed)
        guard !valid.isEmpty else { return TriageFeedbackWriteResult(written: 0, replaced: 0) }
        var replaced = 0
        try connection.transaction {
            let delete = try connection.prepare(
                "DELETE FROM triage_feedback WHERE photo_id = ? AND session_id = ?")
            let insert = try connection.prepare("""
                INSERT INTO triage_feedback (
                  photo_id, session_id, suggestion_verdict, suggestion_confidence,
                  user_action, policy_version, acted_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            for entry in valid {
                replaced += try delete.run([.text(entry.photoId), .text(entry.sessionId)])
                _ = try insert.run([
                    .text(entry.photoId),
                    .text(entry.sessionId),
                    .text(entry.suggestionVerdict),
                    .real(entry.suggestionConfidence),
                    .text(entry.userAction),
                    .text(entry.policyVersion),
                    .text(entry.actedAt),
                ])
            }
        }
        return TriageFeedbackWriteResult(written: valid.count, replaced: replaced)
    }

    public func suggestionSnapshot(photoId: String) throws -> TriageSuggestionSnapshot? {
        let row = try connection.prepare("""
            SELECT photo_id, verdict, confidence, policy_version
            FROM triage_suggestions
            WHERE photo_id = ?
            """).get([.text(photoId)])
        guard let row else { return nil }
        return TriageSuggestionSnapshot(
            photoId: row[0].textValue ?? "",
            verdict: row[1].textValue ?? "",
            confidence: row[2].doubleValue ?? 0,
            policyVersion: row[3].textValue ?? "")
    }

    public func loadCalibrationSamples(sessionId: String?) throws -> [TriageCalibrationSample] {
        // 每 (photo, session) 只取最后一条；再与当前人工决定 JOIN 过滤。
        // 人工决定口径直接用 CullingDecisionSource.humanDecisionSQLList（单一来源）。
        var sql = """
            SELECT f.photo_id, f.session_id, f.suggestion_verdict, f.suggestion_confidence,
                   f.user_action, f.policy_version, mc.camera_model, mc.iso
            FROM triage_feedback f
            JOIN culling_decisions cd
              ON cd.photo_id = f.photo_id AND cd.session_id = f.session_id
            LEFT JOIN photo_metadata_cache mc ON mc.photo_id = f.photo_id
            WHERE f.id = (
                    SELECT MAX(f2.id) FROM triage_feedback f2
                    WHERE f2.photo_id = f.photo_id AND f2.session_id = f.session_id
                  )
              AND cd.decision_source IN \(CullingDecisionSource.humanDecisionSQLList)
              AND cd.revision > 0
            """
        var params: [DBValue?] = []
        if let sessionId {
            sql += "\n  AND f.session_id = ?"
            params.append(.text(sessionId))
        }
        sql += "\nORDER BY f.photo_id ASC"
        return try connection.prepare(sql).query(params).map { row in
            TriageCalibrationSample(
                photoId: row[0].textValue ?? "",
                sessionId: row[1].textValue ?? "",
                suggestionVerdict: row[2].textValue ?? "",
                suggestionConfidence: row[3].doubleValue ?? 0,
                userAction: row[4].textValue ?? "",
                policyVersion: row[5].textValue ?? "",
                cameraModel: row[6].textValue,
                iso: Int(row[7].intValue ?? 0)
            )
        }
    }

    public func count(sessionId: String?) throws -> Int {
        let row: DBRow?
        if let sessionId {
            row = try connection.prepare(
                "SELECT COUNT(*) FROM triage_feedback WHERE session_id = ?"
            ).get([.text(sessionId)])
        } else {
            row = try connection.prepare("SELECT COUNT(*) FROM triage_feedback").get([])
        }
        return Int(row?[0].intValue ?? 0)
    }

    public func deleteAll() throws -> Int {
        try connection.prepare("DELETE FROM triage_feedback").run([])
    }
}
