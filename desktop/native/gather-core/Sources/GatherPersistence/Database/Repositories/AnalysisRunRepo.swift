// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/AnalysisRunRepo.swift
// WP3b-2：analysis_runs 写路径下沉（SimilarityService / FaceKwService 的 run 生命周期）。
//
// 两个服务此前各自内联同两条 SQL（INSERT ... created_at 显式写入、UPDATE 终态）。
// 读路径仍在 SessionRepo.latestAnalysisRun（WorkspaceStatus 的过期判定）。
import Foundation

public final class AnalysisRunRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 开始一次分析 run（status='running'）。
    /// V1：params 列名 params_json，created_at NOT NULL —— 显式写入本次 run 的创建时刻
    /// （与 started_at 同值：run 在开始时创建，两者语义一致）。
    @discardableResult
    public func start(
        sessionId: String,
        kind: String,
        photoCount: Int,
        indexSeq: Int,
        paramsJson: String
    ) throws -> Int64 {
        let now = nowISOString()
        // 复审 P2：INSERT 与 lastInsertRowid 必须在同一事务；否则并发 INSERT 可插进
        // 两次取锁之间，拿到别人的 rowid（finish 会标错 run）。
        return try connection.transaction {
            _ = try connection.prepare("""
                INSERT INTO analysis_runs
                  (session_id, kind, photo_count, index_seq, started_at, finished_at, params_json, status, created_at)
                VALUES (?, ?, ?, ?, ?, '', ?, 'running', ?)
              """).run([
                .text(sessionId), .text(kind), .int(Int64(photoCount)), .int(Int64(indexSeq)),
                .text(now), .text(paramsJson), .text(now),
              ])
            return connection.lastInsertRowid
        }
    }

    /// 落 run 终态（ok/failed）；取消态由 analysis_jobs 表达。
    public func finish(runId: Int64, status: String) throws {
        _ = try connection.prepare("UPDATE analysis_runs SET status = ?, finished_at = ? WHERE id = ?")
            .run([.text(status), .text(nowISOString()), .int(runId)])
    }
}
