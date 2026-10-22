// desktop/native/gather-app/Sources/GatherHost/APIs/LiveAssetAPI.swift
// Cut 1 / B2：AssetAPI 的 Live 实现（5 个方法）。
//
// 对应命令（5 条）：assets.candidates / volumes / accept_candidate /
// reject_candidate / relink_root。
//
// 校验归属：
// - accept/reject/relinkRoot 的 Confirmed<T> 由输入类型保证；API 实现不再接收
//   裸 confirmed:Bool，也不自行“补”确认；
// - candidateId / oldRoot / newRoot 的非空/长度校验由 AssetInputs 完成；
// - 候选存在性（ASSET_LINK_CANDIDATE_NOT_FOUND）与根目录关系（ASSET_RELINK_*）
//   仍由 AssetRepo 负责；本实现只把 DBError.message 中已经是错误码的值收敛成
//   GatherError，未知数据库错误原样抛出（D-030 的非域错误兜底约定）；
// - candidates 的 sessionId 可选（nil = 全部会话）。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain

public final class LiveAssetAPI: AssetAPI, @unchecked Sendable {
    private let assetRepo: AssetRepo

    /// @unchecked Sendable 依据：assetRepo 为构造后不可变的 let，底层连接由
    /// DBConnection 的递归锁串行化。
    public init(assetRepo: AssetRepo) {
        self.assetRepo = assetRepo
    }

    // MARK: - AssetAPI

    public func candidates(_ query: AssetCandidatesQuery) async throws -> [AssetLinkCandidateData] {
        try candidatesSync(query.sessionId)
    }

    public func volumes() async throws -> [AssetVolumeData] {
        try volumesSync()
    }

    public func accept(_ input: Confirmed<AssetCandidateReference>) async throws -> Bool {
        try acceptSync(input.value.candidateId)
    }

    public func reject(_ input: Confirmed<AssetCandidateReference>) async throws -> Bool {
        try rejectSync(input.value.candidateId)
    }

    public func relinkRoot(_ input: Confirmed<AssetRelinkInput>) async throws -> Int {
        try relinkRootSync(oldRoot: input.value.oldRoot, newRoot: input.value.newRoot)
    }

    // MARK: - 同步核心（LiveLibraryDataProvider 的测试接缝；生产 UI 走协议）

    func candidatesSync(_ sessionId: String?) throws -> [AssetLinkCandidateData] {
        try LiveAPIErrorMapping.map {
            try assetRepo.listCandidates(sessionId: sessionId)
        }
    }

    func volumesSync() throws -> [AssetVolumeData] {
        try LiveAPIErrorMapping.map {
            try assetRepo.listVolumes()
        }
    }

    func acceptSync(_ candidateId: String) throws -> Bool {
        try LiveAPIErrorMapping.map {
            try assetRepo.acceptCandidate(candidateId)
            return true
        }
    }

    func rejectSync(_ candidateId: String) throws -> Bool {
        try LiveAPIErrorMapping.map {
            try assetRepo.rejectCandidate(candidateId)
            return true
        }
    }

    func relinkRootSync(oldRoot: String, newRoot: String) throws -> Int {
        try LiveAPIErrorMapping.map {
            try assetRepo.relinkRoot(oldRoot: oldRoot, newRoot: newRoot)
        }
    }
}
