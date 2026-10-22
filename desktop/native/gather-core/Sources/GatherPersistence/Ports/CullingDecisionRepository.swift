// desktop/native/gather-core/Sources/GatherPersistence/Ports/CullingDecisionRepository.swift
// P1-1：culling_decisions 端口（只含 Application 实际调用的方法）。
//
// 读取侧：决策行（pick/reject/pending 唯一真相源）与 writeback 计划的
// photo_id/decision 投影；写入侧：upsertState 在调用方事务内同时写决策行与
// photo_metadata_cache 的 rating/label 镜像列（SQL 细节留在 CullingDecisionRepo）。
import Foundation

public protocol CullingDecisionRepository {
    /// TS: getDecisions —— 写回计划的决策输入（photo_id, decision）。
    func getDecisions(_ sessionId: String) throws -> [CullingDecisionLiteRow]
    /// 会话内全部决策行（list/getSummary/applyHistory 的读模型输入）。
    func getBySession(_ sessionId: String) throws -> [CullingDecisionRow]
    /// 仅给定照片子集的决策行（filtered scope 的 summary）。
    func getByPhotoIds(sessionId: String, photoIds: [String]) throws -> [CullingDecisionRow]
    /// 单张决策行（revision 冲突校验 / decide 的当前 revision）。
    func getDecision(sessionId: String, photoId: String) throws -> CullingDecisionRow?
    /// 决策 + rating/label 镜像列的同事务 upsert（调用方事务内）。
    func upsertState(
        sessionId: String,
        photoId: String,
        groupId: String,
        state: CullingDecisionStateInput
    ) throws
    /// reset：删除会话内决策，返回被删 photos（供清理缓存/历史）。
    @discardableResult
    func deleteBySession(_ sessionId: String) throws -> [String]
    /// reset：删除会话内某个相似度组的决策，返回被删 photos。
    @discardableResult
    func deleteBySessionAndGroup(sessionId: String, groupId: String) throws -> [String]
}

extension CullingDecisionRepo: CullingDecisionRepository {}
