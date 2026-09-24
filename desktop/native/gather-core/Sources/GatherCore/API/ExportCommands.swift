// API/ExportCommands.swift
// R5 类型化 async 域协议：export 域。
// 旧实现来源：gather-app 路由层的 export.* 分支（每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、参数与返回只用 Protocol/ 既有 DTO 与基础类型、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// export 域命令（4 条）。
///
/// 旧命令清单：export.preview、export.execute、export.cancel、export.report。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧路由把 export.preview 在同步与异步两个分支各注册了一次（重复分支，
///   语义一致）；本协议只定义一次，消除双分支。
/// - 旧 export.cancel 入参为扁平 sessionId，并同时取消 exportExecute 作用域的
///   作业与请求运行时取消（旧响应 true）；Protocol/Export.swift 的
///   ExportCancelParams 为空 DTO，未承载 sessionId，故本协议保留扁平参数
///   （W5-2 待裁决是否扩展 DTO），返回空。
/// - 旧 export.execute 的确认失败错误码为 EXPORT_CONFIRMATION_REQUIRED，
///   作业结果为空时以 jobFailed 失败。
public protocol ExportCommands: Sendable {
    /// 旧命令：export.preview。
    /// 返回导出预览（Protocol/Export.swift 的 ExportPreview）；对应旧路由的
    /// 同步/异步重复分支，实现只保留一条。
    func preview(_ params: ExportPreviewParams) async throws -> ExportPreview

    /// 旧命令：export.execute（破坏性）。
    /// ExportExecuteParams.confirmed 必须为 true；建可恢复导出作业并等待结果，
    /// 返回 Protocol/Export.swift 的 ExportResult。
    func execute(_ params: ExportExecuteParams) async throws -> ExportResult

    /// 旧命令：export.cancel。
    /// 取消该会话在跑的导出作业与运行时导出；旧响应 true，本协议返回空。
    func cancel(sessionId: String) async throws

    /// 旧命令：export.report。
    /// reportType 缺省 "session_summary"，format 可空；
    /// 返回 Protocol/Export.swift 的 ReportData。
    func report(_ params: ExportReportParams) async throws -> ReportData
}
