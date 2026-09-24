// API/DuplicateCommands.swift
// R5 类型化 async 域协议：duplicate 域。
// 旧实现来源：gather-app 的会话命令分发器 dup.* 分支
// （每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、只用 Protocol/ 既有 DTO、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// duplicate 域命令（4 条）。
///
/// 旧命令清单：`dup.scan`、`dup.groups`、`dup.resolve`、`dup.resolve_member`。
public protocol DuplicateCommands: Sendable {
    /// 旧命令：`dup.scan`。
    /// 建 duplicate.scan 作业并等待结果；响应形状见 Protocol/Duplicate.swift 的
    /// DuplicateScanResult（精确组 + 视觉组）。
    func scan(_ params: DupScanParams) async throws -> DuplicateScanResult

    /// 旧命令：`dup.groups`。
    /// 返回该会话的全部重复组，元素为 DuplicateGroup。
    func groups(_ params: DupGroupsParams) async throws -> [DuplicateGroup]

    /// 旧命令：`dup.resolve`（破坏性）。
    /// DupResolveParams.confirmed 必须为 true；resolution 仅 keep_one / keep_all（ADR-017）。
    func resolve(_ params: DupResolveParams) async throws

    /// 旧命令：`dup.resolve_member`（破坏性）。
    /// DupResolveMemberParams.confirmed 必须为 true；旧路由对 isKept 缺省 true，
    /// 本协议要求调用方显式传入。
    func resolveMember(_ params: DupResolveMemberParams) async throws
}
