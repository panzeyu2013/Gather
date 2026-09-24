// API/JobsCommands.swift
// R5 类型化 async 域协议：jobs 域。
// 旧实现来源：gather-app/Sources/GatherApp/Host/路由层.swift 的 jobs.* 分支
// （每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、只用 Protocol/ 既有 DTO、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// jobs 域命令（4 条）。
///
/// 旧命令清单：`jobs.list`、`jobs.cancel`、`jobs.retry`、`jobs.clear_completed`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 `jobs.list` 未传过滤条件（全量列表）；JobListParams.status 与作业运行器
///   的过滤参数同名同义，是否按 status 过滤由实现裁决。
/// - 旧 `jobs.cancel` / `jobs.retry` 响应为布尔，本协议保留 Bool。
/// - 旧 `jobs.clear_completed` 响应为清理条数（number），本协议返回 Int。
public protocol JobsCommands: Sendable {
    /// 旧命令：`jobs.list`。
    /// status 为 nil 时返回全部作业；元素为 Protocol/Jobs.swift 的 AnalysisJobData。
    func list(_ params: JobListParams) async throws -> [AnalysisJobData]

    /// 旧命令：`jobs.cancel`。
    /// 返回是否实际取消（旧响应 bool）。
    func cancel(_ params: JobCancelParams) async throws -> Bool

    /// 旧命令：`jobs.retry`。
    /// 返回是否成功重排队（旧响应 bool）。
    func retry(_ params: JobRetryParams) async throws -> Bool

    /// 旧命令：`jobs.clear_completed`（破坏性）。
    /// JobClearCompletedParams.confirmed 必须为 true，否则实现抛
    /// JOBS_CLEAR_CONFIRM_REQUIRED；返回清理的作业条数。
    func clearCompleted(_ params: JobClearCompletedParams) async throws -> Int
}
