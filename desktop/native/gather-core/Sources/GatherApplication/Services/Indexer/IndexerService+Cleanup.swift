// desktop/native/gather-core/Sources/GatherApplication/Services/Indexer/IndexerService+Cleanup.swift
// P1-4 收口：IndexerService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：路径/内容变化后的派生结果失效（分析输入、自动导航组、簇结果、人脸派生）。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension IndexerService {

    // ─────────────────────────── 分析失效 ───────────────────────────

    /// TS: deletePhotoInputs —— 逐照片删除分析输入（photo_id 粒度）。
    /// 人脸段（face_observations / face_analysis_state）不在此处：它必须经
    /// FaceRepo.invalidateDerivedResults 走"先解除成员引用、再删观察、同事务
    /// 清 person_embeddings"的顺序（见 invalidatePathDependentAnalysis）。
    private func deletePhotoInputs(photoIds: [String]) throws {
        try self.indexer.deletePhotoInputs(photoIds: photoIds)
    }

    /// TS: pruneAutomaticNavigationGroups —— 只删实际含受影响照片的自动导航组；
    /// JSON 不可读的组保留不删。
    private func pruneAutomaticNavigationGroups(sessionId: String, photoIds: [String]) throws {
        let affected = Set(photoIds)
        // LIKE 预过滤（含 ESCAPE 转义）与全量分支都在 IndexerRepo。
        let groups: [(id: String, photoIdsJSON: String)] = try self.indexer
            .automaticNavigationGroups(
                sessionId: sessionId,
                photoIds: photoIds,
                prefilterCap: Self.pruneLikePrefilterCap
            )
            .map { (id: $0.id, photoIdsJSON: $0.photoIdsJSON) }
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
        try self.indexer.deleteNavigationGroups(ids: doomed)
    }

    /// TS: deleteGlobalClusterResults —— 会话级相似度簇结果失效。
    private func deleteGlobalClusterResults(sessionId: String) throws {
        try self.indexer.deleteSimilarityResults(sessionId: sessionId)
    }

    /// TS: invalidatePathDependentAnalysis —— 路径/内容变化的照片：逐照片删输入、
    /// 按成员剪自动导航组、会话级丢簇结果；每批调用一次。
    func invalidatePathDependentAnalysis(photoIds: [String]) throws {
        if photoIds.isEmpty { return }
        let affectedSessions = try self.indexer.sessionIds(photoIds: photoIds)
        let photoIdsBySession = try self.indexer.photoIdsBySession(photoIds: photoIds)
        try self.transactions.transaction {
            // 人脸派生结果：只失效本批命中的照片（成员引用先解除，再删观察，
            // 同事务清 person_embeddings）。用户绑定与簇行保留 —— 旧实现整会话
            // DELETE role_bindings/face_clusters 会静默销毁用户标注。
            for (sessionId, sessionPhotoIds) in photoIdsBySession {
                try faceRepo?.invalidateDerivedResults(
                    sessionId: sessionId, photoIds: sessionPhotoIds)
            }
            for sessionId in affectedSessions {
                try deleteGlobalClusterResults(sessionId: sessionId)
            }
            try deletePhotoInputs(photoIds: photoIds)
            for (sessionId, sessionPhotoIds) in photoIdsBySession {
                try pruneAutomaticNavigationGroups(sessionId: sessionId, photoIds: sessionPhotoIds)
            }
        }
    }
}
