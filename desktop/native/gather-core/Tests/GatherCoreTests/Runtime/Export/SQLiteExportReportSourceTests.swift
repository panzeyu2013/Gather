// Tests/GatherCoreTests/Runtime/Export/SQLiteExportReportSourceTests.swift
// W2d-4 步骤②：SQLiteExportReportSource 测试（4 条报告查询的列序与行内容）。
//
// 报告输出依赖 ExportAssembler 按 columnOrder 取值（sessionSummary/personReport/
// keywords），因此每条查询都断言 columnOrder 与行值。数据来自真实迁移库
// makeMigratedStoreDatabase；SQL 由 Store/SQLiteExportStore 独占执行。
import Foundation
import Testing
@testable import GatherCore

@Suite("Runtime/Export/SQLiteExportReportSource")
struct SQLiteExportReportSourceTests {
    private struct Fixture {
        let database: SQLiteDatabase
        let path: String
        let source: SQLiteExportReportSource
    }

    private func makeFixture(label: String) async throws -> Fixture {
        let (database, path) = try await makeMigratedStoreDatabase(label: label)
        for sessionId in ["s1", "s2"] {
            try await database.run(
                """
                INSERT INTO sessions (id, name, created_at, updated_at)
                VALUES (?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text(sessionId), .text(sessionId)]
            )
        }
        return Fixture(
            database: database,
            path: path,
            source: SQLiteExportReportSource(store: SQLiteExportStore(database: database))
        )
    }

    @discardableResult
    private func insertPhoto(
        _ database: SQLiteDatabase,
        id: String,
        sessionId: String,
        filename: String,
        status: String
    ) async throws -> String {
        let filepath = "/photos/\(filename)"
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(sessionId), .text(filepath), .text(filename), .text(status)]
        )
        return filepath
    }

    @discardableResult
    private func insertCluster(
        _ database: SQLiteDatabase,
        sessionId: String,
        label: String,
        memberCount: Int64
    ) async throws -> Int64 {
        try await database.run(
            """
            INSERT INTO face_clusters (session_id, label, member_count, created_at, updated_at)
            VALUES (?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(sessionId), .text(label), .int(memberCount)]
        )
        return await database.lastInsertRowID
    }

    private func insertBinding(
        _ database: SQLiteDatabase,
        clusterId: Int64,
        sessionId: String,
        roleName: String,
        keywords: String
    ) async throws {
        try await database.run(
            """
            INSERT INTO role_bindings (cluster_id, session_id, role_name, keywords, created_at, updated_at)
            VALUES (?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.int(clusterId), .text(sessionId), .text(roleName), .text(keywords)]
        )
    }

    private func insertDecision(
        _ database: SQLiteDatabase,
        sessionId: String,
        photoId: String,
        decision: String
    ) async throws {
        try await database.run(
            """
            INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, created_at, updated_at)
            VALUES (?, ?, 'g1', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(sessionId), .text(photoId), .text(decision)]
        )
    }

    // MARK: - 4 条报告查询（各 1 例）

    @Test func sessionSummaryRowsKeepColumnOrderAndRowidOrder() async throws {
        let fixture = try await makeFixture(label: "export-report-summary")
        defer { removeStoreFiles(fixture.path) }

        try await insertPhoto(fixture.database, id: "p-z", sessionId: "s1", filename: "z.jpg", status: "indexed")
        try await insertPhoto(fixture.database, id: "p-a", sessionId: "s1", filename: "a.jpg", status: "removed")
        try await insertPhoto(fixture.database, id: "p-s2", sessionId: "s2", filename: "other.jpg", status: "pending")

        let rows = try await fixture.source.sessionSummaryRows(sessionId: "s1")

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.columnOrder == ["filename", "filepath", "status"] })
        // 插入序 = rowid 序，且与 filename 字典序相反：证明 ORDER BY rowid 未被替换。
        #expect(rows.map { $0.text("filename") ?? "" } == ["z.jpg", "a.jpg"])
        #expect(rows.map { $0.text("filepath") ?? "" } == ["/photos/z.jpg", "/photos/a.jpg"])
        #expect(rows.map { $0.text("status") ?? "" } == ["indexed", "removed"])
    }

    @Test func personRowsJoinColumnOrderAndRoleNameOrder() async throws {
        let fixture = try await makeFixture(label: "export-report-person")
        defer { removeStoreFiles(fixture.path) }

        let zoeCluster = try await insertCluster(fixture.database, sessionId: "s1", label: "Zoe L", memberCount: 3)
        let annCluster = try await insertCluster(fixture.database, sessionId: "s1", label: "Ann A", memberCount: 7)
        try await insertBinding(fixture.database, clusterId: zoeCluster, sessionId: "s1", roleName: "Zoe", keywords: "[\"travel\"]")
        try await insertBinding(fixture.database, clusterId: annCluster, sessionId: "s1", roleName: "Ann", keywords: "[\"family\",\"sunset\"]")
        // 其他会话的行不得混入（JOIN 两侧都按 session 过滤）。
        let otherCluster = try await insertCluster(fixture.database, sessionId: "s2", label: "Other", memberCount: 9)
        try await insertBinding(fixture.database, clusterId: otherCluster, sessionId: "s2", roleName: "Aaron", keywords: "[]")

        let rows = try await fixture.source.personRows(sessionId: "s1")

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.columnOrder == ["role_name", "keywords", "label", "member_count"] })
        #expect(rows.map { $0.text("role_name") ?? "" } == ["Ann", "Zoe"]) // ORDER BY rb.role_name
        #expect(rows.map { $0.text("keywords") ?? "" } == ["[\"family\",\"sunset\"]", "[\"travel\"]"])
        #expect(rows.map { $0.text("label") ?? "" } == ["Ann A", "Zoe L"]) // JOIN 取 fc.label
        #expect(rows.map { $0.int("member_count") ?? -1 } == [7, 3])
    }

    @Test func keywordRowsDistinctNonEmptyWithinSession() async throws {
        let fixture = try await makeFixture(label: "export-report-keyword")
        defer { removeStoreFiles(fixture.path) }

        let c1 = try await insertCluster(fixture.database, sessionId: "s1", label: "One", memberCount: 1)
        let c2 = try await insertCluster(fixture.database, sessionId: "s1", label: "Two", memberCount: 2)
        let c3 = try await insertCluster(fixture.database, sessionId: "s1", label: "Three", memberCount: 3)
        let c4 = try await insertCluster(fixture.database, sessionId: "s2", label: "Four", memberCount: 4)
        try await insertBinding(fixture.database, clusterId: c1, sessionId: "s1", roleName: "R1", keywords: "[\"travel\",\"sunset\"]")
        try await insertBinding(fixture.database, clusterId: c2, sessionId: "s1", roleName: "R2", keywords: "[\"travel\",\"sunset\"]") // DISTINCT 去重
        try await insertBinding(fixture.database, clusterId: c3, sessionId: "s1", roleName: "R3", keywords: "[]") // 空数组排除
        try await insertBinding(fixture.database, clusterId: c4, sessionId: "s2", roleName: "R4", keywords: "[\"other\"]") // 其他 session 排除

        let rows = try await fixture.source.keywordRows(sessionId: "s1")

        #expect(rows.allSatisfy { $0.columnOrder == ["keywords"] })
        #expect(rows.count == 1)
        #expect(rows.map { $0.text("keywords") ?? "" } == ["[\"travel\",\"sunset\"]"])
    }

    @Test func cullingDecisionRowsDistinctNonPendingWithinSession() async throws {
        let fixture = try await makeFixture(label: "export-report-culling")
        defer { removeStoreFiles(fixture.path) }

        for photoId in ["p1", "p2", "p3", "p4"] {
            try await insertPhoto(fixture.database, id: photoId, sessionId: "s1", filename: "\(photoId).jpg", status: "indexed")
        }
        try await insertPhoto(fixture.database, id: "p5", sessionId: "s2", filename: "p5.jpg", status: "indexed")
        try await insertDecision(fixture.database, sessionId: "s1", photoId: "p1", decision: "keep")
        try await insertDecision(fixture.database, sessionId: "s1", photoId: "p2", decision: "keep") // DISTINCT 去重
        try await insertDecision(fixture.database, sessionId: "s1", photoId: "p3", decision: "reject")
        try await insertDecision(fixture.database, sessionId: "s1", photoId: "p4", decision: "pending") // 排除
        try await insertDecision(fixture.database, sessionId: "s2", photoId: "p5", decision: "keep") // 其他 session 排除

        let rows = try await fixture.source.cullingDecisionRows(sessionId: "s1")

        #expect(rows.allSatisfy { $0.columnOrder == ["decision"] })
        #expect(rows.count == 2)
        #expect(Set(rows.compactMap { $0.text("decision") }) == ["keep", "reject"])
    }

    // MARK: - 边界：未知 session 四路皆空

    @Test func unknownSessionReturnsNoRowsForAllFourQueries() async throws {
        let fixture = try await makeFixture(label: "export-report-empty")
        defer { removeStoreFiles(fixture.path) }

        let summary = try await fixture.source.sessionSummaryRows(sessionId: "missing")
        let persons = try await fixture.source.personRows(sessionId: "missing")
        let keywords = try await fixture.source.keywordRows(sessionId: "missing")
        let decisions = try await fixture.source.cullingDecisionRows(sessionId: "missing")

        #expect(summary.isEmpty)
        #expect(persons.isEmpty)
        #expect(keywords.isEmpty)
        #expect(decisions.isEmpty)
    }
}
