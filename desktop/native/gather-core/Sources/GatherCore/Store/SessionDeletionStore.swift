// Store/SessionDeletionStore.swift
// R4：会话删除的跨域清理端口（旧 Services/SessionService.swift 内联 SQL 的逐字下沉）。
// 会话删除跨 photos / 人脸 / 元数据缓存 / 写回 / 作业多个域，且必须与旧行为一样
// 按依赖顺序在同一连接上执行，故以独立 Store 承载，不并入单一领域 Store。
import Foundation

/// 会话删除清理的 Store 端口。
public protocol SessionDeletionStore: Sendable {
    /// 删除会话在其余领域内的引用行（SQL 逐字来自旧 SessionService）。
    /// 顺序满足 foreign_keys = ON 的约束：先于人脸 Store 的观测/簇删除之后、
    /// 照片行删除之前执行。
    func deleteSessionDependencyRows(sessionId: String) async throws

    /// 把不再被任何会话引用的资产标记为 orphan（单事务）。
    func markOrphanAssets(now: String) async throws
}

public struct SQLiteSessionDeletionStore: SessionDeletionStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func deleteSessionDependencyRows(sessionId: String) async throws {
        _ = try await database.run("DELETE FROM person_embeddings WHERE session_id = ?", [.text(sessionId)])
        _ = try await database.run("DELETE FROM person_photos WHERE session_id = ?", [.text(sessionId)])
        _ = try await database.run("DELETE FROM photo_metadata_cache WHERE session_id = ?", [.text(sessionId)])
        _ = try await database.run("DELETE FROM writeback_items WHERE session_id = ?", [.text(sessionId)])
        // 审计 P2：analysis_jobs 无 FK，会话删除后残留僵尸行（状态查询/
        // 任务中心会一直看到幽灵任务）。
        _ = try await database.run(
            "DELETE FROM analysis_jobs WHERE scope_type = 'session' AND scope_id = ?",
            [.text(sessionId)]
        )
    }

    public func markOrphanAssets(now: String) async throws {
        try await database.transaction { db in
            _ = try db.run("""
                UPDATE assets SET status = 'orphan', updated_at = ?
                WHERE status != 'orphan'
                  AND NOT EXISTS (
                    SELECT 1 FROM session_assets sa WHERE sa.asset_id = assets.id
                  )
              """, [.text(now)])
        }
    }
}
