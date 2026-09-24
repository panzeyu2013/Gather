// API/WorkspaceCommands.swift
// R5 类型化 async 域协议：workspace 域。
// 旧实现来源：gather-app/Sources/GatherApp/Host/路由层.swift 的
// workspace.status 分支（每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、只用 Protocol/ 既有 DTO、无同步重载。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// workspace 域命令（1 条）。
///
/// 旧命令清单：`workspace.status`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧响应在会话不存在时抛 SESSION_NOT_FOUND，因此本协议返回非可选
///   WorkspaceStatus，而不是聚合器内部的 Optional。
public protocol WorkspaceCommands: Sendable {
    /// 旧命令：`workspace.status`。
    /// 返回工作区聚合状态（Protocol/Workspace.swift 的 WorkspaceStatus）。
    func status(_ params: WorkspaceStatusParams) async throws -> WorkspaceStatus
}
