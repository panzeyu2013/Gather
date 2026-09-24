// API/AssetsCommands.swift
// R5 类型化 async 域协议：assets 域。
// 旧实现来源：gather-app 路由层的 assets.* 分支（每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、参数与返回只用 Protocol/ 既有 DTO 与基础类型、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// assets 域命令（5 条）。
///
/// 旧命令清单：assets.candidates、assets.accept_candidate、
/// assets.reject_candidate、assets.volumes、assets.relink_root。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 assets.accept_candidate / assets.reject_candidate 响应为 true；
///   本协议返回空，确认门控错误码分别为 ASSET_LINK_ACCEPT_CONFIRM_REQUIRED /
///   ASSET_LINK_REJECT_CONFIRM_REQUIRED。
/// - 旧 assets.relink_root 响应为 relocatedFiles 计数（number）；Protocol/ 暂无
///   对应结果 DTO，本协议以基础类型 Int 承接（W5-2 待裁决是否补 DTO）；
///   确认失败错误码为 ASSET_RELINK_CONFIRM_REQUIRED。
public protocol AssetsCommands: Sendable {
    /// 旧命令：assets.candidates。
    /// sessionId 为 nil 时返回全部待裁决候选；元素为 Protocol/Assets.swift 的
    /// AssetLinkCandidateData。
    func candidates(_ params: AssetCandidateListParams) async throws -> [AssetLinkCandidateData]

    /// 旧命令：assets.accept_candidate（破坏性）。
    /// AssetCandidateMutationParams.confirmed 必须为 true，否则实现抛
    /// ASSET_LINK_ACCEPT_CONFIRM_REQUIRED。
    func acceptCandidate(_ params: AssetCandidateMutationParams) async throws

    /// 旧命令：assets.reject_candidate（破坏性）。
    /// AssetCandidateMutationParams.confirmed 必须为 true，否则实现抛
    /// ASSET_LINK_REJECT_CONFIRM_REQUIRED。
    func rejectCandidate(_ params: AssetCandidateMutationParams) async throws

    /// 旧命令：assets.volumes。
    /// 返回卷清单，元素为 Protocol/Assets.swift 的 AssetVolumeData。
    func volumes() async throws -> [AssetVolumeData]

    /// 旧命令：assets.relink_root（破坏性）。
    /// AssetRelinkRootParams.confirmed 必须为 true；返回重定位的文件数。
    func relinkRoot(_ params: AssetRelinkRootParams) async throws -> Int
}
