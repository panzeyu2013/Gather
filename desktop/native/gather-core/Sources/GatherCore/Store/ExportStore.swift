// Store/ExportStore.swift
// W2d-4 步骤②：Export 报告 4 条只读查询的 Store 端口与 SQLite 实现。
//
// 来源：逐字下沉旧 Services/ExportService.swift 的 generateReport(sessionId:reportType:format:)
// 四条查询（session_summary / person / keyword / culling 决策）。SQL 文本与列序逐字保留：
// Runtime/Export/ExportAssembler 的报告输出按 columnOrder 取值，列序即报告列序。
//
// 为什么不并入既有 Store：
// - 四条查询跨 photos / role_bindings / face_clusters / culling_decisions 四表，
//   属于“导出报告聚合读取”这一独立语义，没有单一既有 Store 覆盖；
// - PhotoStore/FaceStore/CullingStore/MetadataStore 在 Tests 中有协议 conformer
//   （如 RacingCullingStore、MwMetaThrowingMetadataStore），加要求会强迫改动本切片
//   文件范围外的测试支撑文件。故新增 ExportStore 端口，既有 Store 不动。
//
// 门禁：SQL 只出现在本文件（R1：Store 是唯一 SQL 所有者）；Runtime/** 不出现 SQL 文本。
import Foundation

/// 导出报告行读取端口。四个方法一一对应旧 generateReport 的四个分支，
/// 返回值原样交给 Runtime/Export/ExportAssembler 聚合（列序不得调整）。
public protocol ExportStore: Sendable {
    /// 旧 session_summary 分支：
    /// SELECT filename, filepath, status FROM photos WHERE session_id = ? ORDER BY rowid。
    func sessionSummaryRows(sessionId: String) async throws -> [SQLiteRow]

    /// 旧 person 分支：
    /// role_bindings JOIN face_clusters，按 role_name 排序（列序 role_name/keywords/label/member_count）。
    func personRows(sessionId: String) async throws -> [SQLiteRow]

    /// 旧 keyword 分支前半：role_bindings 中非空 keywords（DISTINCT）。
    func keywordRows(sessionId: String) async throws -> [SQLiteRow]

    /// 旧 keyword 分支后半：culling_decisions 中非 pending 决策（DISTINCT）。
    func cullingDecisionRows(sessionId: String) async throws -> [SQLiteRow]
}

public struct SQLiteExportStore: ExportStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func sessionSummaryRows(sessionId: String) async throws -> [SQLiteRow] {
        try await database.query(
            "SELECT filename, filepath, status FROM photos WHERE session_id = ? ORDER BY rowid",
            [.text(sessionId)]
        )
    }

    public func personRows(sessionId: String) async throws -> [SQLiteRow] {
        try await database.query(
            """
            SELECT rb.role_name, rb.keywords, fc.label, fc.member_count
            FROM role_bindings rb
            JOIN face_clusters fc ON rb.cluster_id = fc.id
            WHERE rb.session_id = ? ORDER BY rb.role_name
            """,
            [.text(sessionId)]
        )
    }

    public func keywordRows(sessionId: String) async throws -> [SQLiteRow] {
        try await database.query(
            "SELECT DISTINCT keywords FROM role_bindings WHERE session_id = ? AND keywords != '[]'",
            [.text(sessionId)]
        )
    }

    public func cullingDecisionRows(sessionId: String) async throws -> [SQLiteRow] {
        try await database.query(
            "SELECT DISTINCT decision FROM culling_decisions WHERE session_id = ? AND decision != 'pending'",
            [.text(sessionId)]
        )
    }
}
