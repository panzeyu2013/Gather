// desktop/native/gather-core/Sources/GatherProtocol/API/JobAPI.swift
// Cut 1 / 阶段 1A：任务域协议（5 个方法）。
//
// 职责：任务列表、取消/重试、清理已完成、建 job（index.scan 与 quality.analyze
// 的“建 job”面统一走 start）。
// 对应命令（5 条）：jobs.list / cancel / retry / clear_completed、index.scan。
// 校验归属：
// - list 的 includeCheckpoint 缺省 true；
// - clearCompleted 使用 Confirmed<ClearCompletedInput>；
// - 任务状态机、lease、去重与执行器归属 JobService，实现只暴露 JobHandle。

import Foundation

public protocol JobAPI: Sendable {
    func list(_ filter: JobListFilter) async throws -> [AnalysisJobData]
    func cancel(_ jobId: String) async throws -> Bool
    func retry(_ jobId: String) async throws -> Bool
    func clearCompleted(_ input: Confirmed<ClearCompletedInput>) async throws -> Int
    /// 建 job 并返回事件流（index.scan / quality.analyze 等不再各自持有建 job 逻辑）。
    func start(_ request: JobRequest) async throws -> JobHandle
}
