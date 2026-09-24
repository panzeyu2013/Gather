// desktop/native/gather-core/Sources/GatherCore/Store/AnalysisRunStore.swift
// R1：analysis_runs 写路径（INSERT/UPDATE）的 Store 入口。
//
// 来源：Services/FaceKeywordingRuntime.swift 的 startAnalysisRun / finalizeAnalysisRun
// 内联 SQL 逐字下沉（列序/WHERE/参数顺序不变：status 固定 'running'、
// finished_at 固定空串，started_at/finished_at 取 nowISOString()，插入返回
// runId）。插入与 lastInsertRowID 读取在同一事务内，与 Store/JobStore.swift
// 的同类实现一致（避免并发交错取错 id；SQL 文本与参数序不变）。
//
// 边界：只承载 FaceKeywording 写路径所需的两条语句；读路径（latestAnalysisRun
// 等）仍由 Store/JobStore.swift 与 Store/WorkspaceStore.swift 承担，本文件不
// 重复。SQLiteJobStore 的同类实现属 W2c 既有范围，本轮未改动。

import Foundation

/// analysis_runs 写路径（分析 run 的插入与终态落库）。
public protocol AnalysisRunStore: Sendable {
    /// 插入分析 run（status='running'，started_at=now，finished_at=''）；返回 runId。
    func insertAnalysisRun(_ insert: AnalysisRunInsert) async throws -> Int64
    /// run 终态（status + finished_at=now）；未知 runId 返回 false。
    @discardableResult
    func finishAnalysisRun(runId: Int64, status: String) async throws -> Bool
}

public struct SQLiteAnalysisRunStore: AnalysisRunStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func insertAnalysisRun(_ insert: AnalysisRunInsert) async throws -> Int64 {
        try await database.transaction { db in
            try db.run(
                """
                INSERT INTO analysis_runs (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
                VALUES (?, ?, ?, ?, ?, '', ?, 'running')
                """,
                [
                    .text(insert.sessionId), .text(insert.kind), .int(Int64(insert.photoCount)),
                    .int(Int64(insert.indexSeq)), .text(nowISOString()), .text(insert.params),
                ]
            )
            return db.lastInsertRowID
        }
    }

    public func finishAnalysisRun(runId: Int64, status: String) async throws -> Bool {
        try await database.run(
            "UPDATE analysis_runs SET status = ?, finished_at = ? WHERE id = ?",
            [.text(status), .text(nowISOString()), .int(runId)]
        ) == 1
    }
}
