// API/Impl/AssetsCommandsImpl.swift
// R5 命令层接线：assets 域实现（批次 B6）。
// 逻辑来源：宿主路由层的 assets.* 分支；错误码、门控与返回形状保持不变。
// W5-2 待裁决项按已冻结协议落地：relink_root 的旧计数响应以基础类型 Int 承接，
// 不新增结果 DTO。
// 边界语义：
// - candidates：sessionId 为 nil 时返回全部待裁决候选（可选过滤透传给存储）；
// - accept_candidate / reject_candidate：confirmed 不为 true 时分别抛
//   ASSET_LINK_ACCEPT_CONFIRM_REQUIRED / ASSET_LINK_REJECT_CONFIRM_REQUIRED
//   （旧响应为 true，本协议返回空）；
// - volumes：返回卷清单；
// - relink_root：confirmed 不为 true 时抛 ASSET_RELINK_CONFIRM_REQUIRED，
//   成功返回重定位文件数（旧 number 计数）。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// assets 域命令实现：注入资产存储；actor 隔离满足协议 Sendable。
public actor AssetsCommandsImpl: AssetsCommands {
    private let assets: any AssetStore

    public init(assets: any AssetStore) {
        self.assets = assets
    }

    // MARK: AssetsCommands

    /// 旧命令：`assets.candidates`。sessionId 为 nil 取全部待裁决候选。
    public func candidates(_ params: AssetCandidateListParams) async throws -> [AssetLinkCandidateData] {
        try await assets.listCandidates(sessionId: params.sessionId)
    }

    /// 旧命令：`assets.accept_candidate`（破坏性）。confirmed 门控 →
    /// ASSET_LINK_ACCEPT_CONFIRM_REQUIRED。
    public func acceptCandidate(_ params: AssetCandidateMutationParams) async throws {
        guard params.confirmed else {
            throw AssetsCommandsError.acceptConfirmRequired
        }
        try await assets.acceptCandidate(params.candidateId)
    }

    /// 旧命令：`assets.reject_candidate`（破坏性）。confirmed 门控 →
    /// ASSET_LINK_REJECT_CONFIRM_REQUIRED。
    public func rejectCandidate(_ params: AssetCandidateMutationParams) async throws {
        guard params.confirmed else {
            throw AssetsCommandsError.rejectConfirmRequired
        }
        try await assets.rejectCandidate(params.candidateId)
    }

    /// 旧命令：`assets.volumes`。返回卷清单。
    public func volumes() async throws -> [AssetVolumeData] {
        try await assets.listVolumes()
    }

    /// 旧命令：`assets.relink_root`（破坏性）。confirmed 门控 →
    /// ASSET_RELINK_CONFIRM_REQUIRED；成功返回重定位文件数。
    public func relinkRoot(_ params: AssetRelinkRootParams) async throws -> Int {
        guard params.confirmed else {
            throw AssetsCommandsError.relinkConfirmRequired
        }
        let result = try await assets.relinkRoot(oldRoot: params.oldRoot, newRoot: params.newRoot)
        return result.relocatedFiles
    }
}

/// assets 域命令边界错误（错误码字符串与旧宿主路由层分支逐字一致）。
public enum AssetsCommandsError: Error, Equatable {
    /// 旧响应 error 串：`ASSET_LINK_ACCEPT_CONFIRM_REQUIRED`。
    case acceptConfirmRequired
    /// 旧响应 error 串：`ASSET_LINK_REJECT_CONFIRM_REQUIRED`。
    case rejectConfirmRequired
    /// 旧响应 error 串：`ASSET_RELINK_CONFIRM_REQUIRED`。
    case relinkConfirmRequired
}

extension AssetsCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .acceptConfirmRequired: "ASSET_LINK_ACCEPT_CONFIRM_REQUIRED"
        case .rejectConfirmRequired: "ASSET_LINK_REJECT_CONFIRM_REQUIRED"
        case .relinkConfirmRequired: "ASSET_RELINK_CONFIRM_REQUIRED"
        }
    }
}

extension AssetsCommandsError {
    /// 桥接层序列化用；三个门控错误均有 GatherErrorCode 同码 case。
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .acceptConfirmRequired: .ASSET_LINK_ACCEPT_CONFIRM_REQUIRED
        case .rejectConfirmRequired: .ASSET_LINK_REJECT_CONFIRM_REQUIRED
        case .relinkConfirmRequired: .ASSET_RELINK_CONFIRM_REQUIRED
        }
    }
}
