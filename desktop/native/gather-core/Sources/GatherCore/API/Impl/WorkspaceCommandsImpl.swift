// API/Impl/WorkspaceCommandsImpl.swift
// R5 命令层接线：workspace 域实现（批次 B2）。
// 逻辑来源：宿主路由层 workspace.status 分支；响应形状沿用
// Protocol/Workspace.swift 的 WorkspaceStatus，会话不存在时错误码
// SESSION_NOT_FOUND（与 session.get 复用同一会话域错误）。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// workspace 域命令实现：注入工作区聚合命名空间。
///
/// 采用 actor 以串行化命令入口：协议要求 Sendable，WorkspaceAPI 自身为
/// actor，此处再包一层保持三域实现形态一致，并把 nil 收敛放在命令边界。
public actor WorkspaceCommandsImpl: WorkspaceCommands {
    private let workspace: WorkspaceAPI

    public init(workspace: WorkspaceAPI) {
        self.workspace = workspace
    }

    /// 旧命令：`workspace.status`。聚合器对未知 session 返回 nil，旧命令边界
    /// 转为 SESSION_NOT_FOUND；协议返回非可选，故在此完成收敛。
    public func status(_ params: WorkspaceStatusParams) async throws -> WorkspaceStatus {
        guard let status = try await workspace.status(sessionId: params.sessionId) else {
            throw SessionServiceError.sessionNotFound
        }
        return status
    }
}
