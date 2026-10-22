// desktop/native/gather-core/Sources/GatherProtocol/API/AssetAPI.swift
// Cut 1 / 阶段 1A：资产链接域协议（5 个方法）。
//
// 职责：候选列表/卷列表、接受/拒绝候选、根目录重链接。
// 对应命令（5 条）：assets.candidates / volumes / accept_candidate /
// reject_candidate / relink_root。
// 校验归属：
// - accept/reject/relinkRoot 使用 Confirmed<T>；
// - 候选存在性（ASSET_LINK_CANDIDATE_NOT_FOUND）与根目录关系
//   （ASSET_RELINK_*）由 AssetRepo/PhotoAssetResolver 负责；
// - candidates 的 sessionId 可选（nil = 全部会话）。

import Foundation

public protocol AssetAPI: Sendable {
    func candidates(_ query: AssetCandidatesQuery) async throws -> [AssetLinkCandidateData]
    func volumes() async throws -> [AssetVolumeData]
    func accept(_ input: Confirmed<AssetCandidateReference>) async throws -> Bool
    func reject(_ input: Confirmed<AssetCandidateReference>) async throws -> Bool
    func relinkRoot(_ input: Confirmed<AssetRelinkInput>) async throws -> Int
}
