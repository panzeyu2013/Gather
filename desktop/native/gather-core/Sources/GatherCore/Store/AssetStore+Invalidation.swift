// Store/AssetStore+Invalidation.swift
// R1 / M3：SQLiteAssetStore 的路径相关分析失效面
//（旧 IndexerService.swift 413 调用 → 797-833 + 706-793 私有实现）。
// SQL 逐字搬自 Services/IndexerService.swift；表名 / WHERE / 绑定参数顺序不变；
// 读取与删除同处一个事务（本切片要求单事务内按旧顺序执行）。
import Foundation

extension SQLiteAssetStore {
    /// 旧 PRUNE_LIKE_PREFILTER_CAP=200（IndexAssembler.pruneLikePrefilterCap 的等价常量）。
    private static let pruneLikePrefilterCap = 200

    /// M3：路径/内容变化照片的分析失效。单事务内按旧顺序：查受影响会话（distinct session_id）
    /// → 会话级人脸簇结果（face_cluster_state / face_cluster_members / role_bindings / face_clusters；
    /// 成员先于其引用的观测删除）→ 会话级相似度簇结果（similarity_results）→ 逐照片分析输入
    /// （similarity_hashes / face_observations / face_analysis_state / asset_analysis /
    /// photo_metadata_cache）→ 按成员剪枝自动导航组（navigation_groups）。
    /// 返回受影响照片数（photoIds 中在 photos 表实际存在的去重 id 数）；空输入返回 0。
    public func invalidatePathDependentAnalysis(photoIds: [String]) async throws -> Int {
        guard !photoIds.isEmpty else { return 0 }
        return try await database.transaction { db in
            var affectedSessions = Set<String>()
            for chunk in photoIds.chunked(by: 400) {
                // 旧 IN_CHUNK_SIZE=400（IndexAssembler.chunked 的等价分片）。
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try db.query(
                    "SELECT DISTINCT session_id FROM photos WHERE id IN (\(placeholders))",
                    chunk.map { .text($0) }
                )
                for row in rows {
                    if let sessionId = row.values[row.columnOrder[0]]?.textValue { affectedSessions.insert(sessionId) }
                }
            }
            var photoIdsBySession: [String: [String]] = [:]
            var existingPhotoIds = Set<String>()
            for chunk in photoIds.chunked(by: 400) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try db.query(
                    "SELECT id, session_id FROM photos WHERE id IN (\(placeholders))",
                    chunk.map { .text($0) }
                )
                for row in rows {
                    guard let id = row.values[row.columnOrder[0]]?.textValue,
                          let sessionId = row.values[row.columnOrder[1]]?.textValue else { continue }
                    photoIdsBySession[sessionId, default: []].append(id)
                    existingPhotoIds.insert(id)
                }
            }
            // 会话级簇结果先行：成员行必须先于其引用的观测删除。
            for sessionId in affectedSessions {
                try deleteFaceClusterResults(db, sessionId: sessionId)
                try deleteGlobalClusterResults(db, sessionId: sessionId)
            }
            try deletePhotoInputs(db, photoIds: photoIds)
            for (sessionId, sessionPhotoIds) in photoIdsBySession {
                try pruneAutomaticNavigationGroups(db, sessionId: sessionId, photoIds: sessionPhotoIds)
            }
            return existingPhotoIds.count
        }
    }

    /// TS: deletePhotoInputs —— 逐照片删除分析输入（photo_id 粒度）。
    private func deletePhotoInputs(_ db: isolated SQLiteDatabase, photoIds: [String]) throws {
        if photoIds.isEmpty { return }
        for chunk in photoIds.chunked(by: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try db.run(
                "DELETE FROM similarity_hashes WHERE photo_id IN (\(placeholders))",
                chunk.map { .text($0) }
            )
            _ = try db.run(
                "DELETE FROM face_observations WHERE photo_id IN (\(placeholders))",
                chunk.map { .text($0) }
            )
            _ = try db.run(
                "DELETE FROM face_analysis_state WHERE photo_id IN (\(placeholders))",
                chunk.map { .text($0) }
            )
            _ = try db.run(
                "DELETE FROM asset_analysis WHERE photo_id IN (\(placeholders))",
                chunk.map { .text($0) }
            )
            _ = try db.run(
                "DELETE FROM photo_metadata_cache WHERE photo_id IN (\(placeholders))",
                chunk.map { .text($0) }
            )
        }
    }

    /// TS: pruneAutomaticNavigationGroups —— 只删实际含受影响照片的自动导航组；
    /// JSON 不可读的组保留不删。
    private func pruneAutomaticNavigationGroups(_ db: isolated SQLiteDatabase, sessionId: String, photoIds: [String]) throws {
        let affected = Set(photoIds)
        var groups: [(id: String, photoIdsJSON: String)] = []
        if !photoIds.isEmpty && photoIds.count <= SQLiteAssetStore.pruneLikePrefilterCap {
            let conditions = photoIds.map { _ in "photo_ids_json LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            let patterns = photoIds.map { id -> String in
                let escaped = id
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                return "%\"\(escaped)\"%"
            }
            let rows = try db.query("""
                SELECT id, photo_ids_json FROM navigation_groups
                WHERE session_id = ? AND source = 'automatic' AND (\(conditions))
              """, [.text(sessionId)] + patterns.map { .text($0) })
            for row in rows {
                groups.append((row.values[row.columnOrder[0]]?.textValue ?? "", row.values[row.columnOrder[1]]?.textValue ?? ""))
            }
        } else {
            let rows = try db.query("""
                SELECT id, photo_ids_json FROM navigation_groups
                WHERE session_id = ? AND source = 'automatic'
              """, [.text(sessionId)])
            for row in rows {
                groups.append((row.values[row.columnOrder[0]]?.textValue ?? "", row.values[row.columnOrder[1]]?.textValue ?? ""))
            }
        }
        var doomed: [String] = []
        for group in groups {
            guard let parsed = try? JSONValue.parse(group.photoIdsJSON),
                  case .array(let members) = parsed else { continue }
            let containsAffected = members.contains { member in
                guard case .string(let value) = member else { return false }
                return affected.contains(value)
            }
            if containsAffected { doomed.append(group.id) }
        }
        for chunk in doomed.chunked(by: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try db.run(
                "DELETE FROM navigation_groups WHERE id IN (\(placeholders))",
                chunk.map { .text($0) }
            )
        }
    }

    /// TS: deleteGlobalClusterResults —— 会话级相似度簇结果失效。
    private func deleteGlobalClusterResults(_ db: isolated SQLiteDatabase, sessionId: String) throws {
        _ = try db.run("DELETE FROM similarity_results WHERE session_id = ?", [.text(sessionId)])
    }

    /// TS: deleteFaceClusterResults —— 会话级人脸簇结果失效（成员先于观测删除）。
    private func deleteFaceClusterResults(_ db: isolated SQLiteDatabase, sessionId: String) throws {
        _ = try db.run("DELETE FROM face_cluster_state WHERE session_id = ?", [.text(sessionId)])
        _ = try db.run("DELETE FROM face_cluster_members WHERE session_id = ?", [.text(sessionId)])
        _ = try db.run("DELETE FROM role_bindings WHERE session_id = ?", [.text(sessionId)])
        _ = try db.run("DELETE FROM face_clusters WHERE session_id = ?", [.text(sessionId)])
    }
}
