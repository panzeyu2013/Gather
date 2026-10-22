// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/ExportReportRepo.swift
// WP3b-1：ExportService 报告只读查询（person / keyword 两个报告）。
//
// session_summary 走 PhotoRepo.reportRows（photos 属主）；本仓储只负责
// role_bindings / culling_decisions 的聚合投影。
import Foundation

public struct ExportPersonBindingRow: Equatable, Sendable {
    public let roleName: String
    public let keywordsJSON: String
    public let label: String
    public let memberCount: Int

    public init(roleName: String, keywordsJSON: String, label: String, memberCount: Int) {
        self.roleName = roleName
        self.keywordsJSON = keywordsJSON
        self.label = label
        self.memberCount = memberCount
    }
}

public final class ExportReportRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 成员数唯一真相 = COUNT(face_cluster_members)（旧 SQL 逐字保留）。
    public func personBindingRows(sessionId: String) throws -> [ExportPersonBindingRow] {
        let rows = try connection.prepare("""
            SELECT rb.role_name, rb.keywords, fc.label,
                   (SELECT COUNT(*) FROM face_cluster_members m WHERE m.cluster_id = fc.id) AS member_count
            FROM role_bindings rb
            JOIN face_clusters fc ON rb.cluster_id = fc.id
            WHERE rb.session_id = ? ORDER BY rb.role_name
            """).query([.text(sessionId)])
        return rows.map {
            ExportPersonBindingRow(
                roleName: $0[0].textValue ?? "",
                keywordsJSON: $0[1].textValue ?? "[]",
                label: $0[2].textValue ?? "",
                memberCount: Int($0[3].intValue ?? 0)
            )
        }
    }

    /// keyword 报告：role_bindings 的非空 keywords JSON 列。
    public func keywordRows(sessionId: String) throws -> [String] {
        try connection.prepare(
            "SELECT DISTINCT keywords FROM role_bindings WHERE session_id = ? AND keywords != '[]'"
        ).query([.text(sessionId)]).compactMap { $0[0].textValue }
    }

    /// filtered scope：本会话已 keep 的照片 id（原 CullingDecisionRepo.getDecisions 的
    /// 导出侧唯一用途；不把整个 Culling 仓储带进 ExportService）。
    public func keptPhotoIds(sessionId: String) throws -> Set<String> {
        let rows = try connection.prepare(
            "SELECT photo_id FROM culling_decisions WHERE session_id = ? AND decision = 'keep'"
        ).query([.text(sessionId)])
        return Set(rows.compactMap { $0[0].textValue })
    }

    /// keyword 报告：culling_decisions 的非 pending 决策。
    public func cullingDecisionRows(sessionId: String) throws -> [String] {
        try connection.prepare(
            "SELECT DISTINCT decision FROM culling_decisions WHERE session_id = ? AND decision != 'pending'"
        ).query([.text(sessionId)]).compactMap { $0[0].textValue }
    }
}
