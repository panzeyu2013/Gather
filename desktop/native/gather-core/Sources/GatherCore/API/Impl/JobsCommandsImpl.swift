// API/Impl/JobsCommandsImpl.swift
// R5 命令层接线：jobs 域实现（批次 B2）。
// 逻辑来源：宿主路由层 jobs.* 分支（list / cancel / retry / clear_completed）；
// 错误码与响应形状不变：confirmed 缺失或非 true → JOBS_CLEAR_CONFIRM_REQUIRED。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// jobs 域命令实现：注入作业运行器（actor，串行化命令入口）。
public actor JobsCommandsImpl: JobsCommands {
    private let jobs: JobRunner

    public init(jobs: JobRunner) {
        self.jobs = jobs
    }

    /// 旧命令：`jobs.list`。status 为 nil 时返回全量（旧行为逐字保持）；
    /// 非 nil 时按状态过滤，运行器已有同义参数（协议层赋予的过滤能力）。
    public func list(_ params: JobListParams) async throws -> [AnalysisJobData] {
        try await jobs.list(status: params.status)
    }

    /// 旧命令：`jobs.cancel`。返回是否实际取消（旧响应 bool）。
    public func cancel(_ params: JobCancelParams) async throws -> Bool {
        try await jobs.cancel(params.jobId)
    }

    /// 旧命令：`jobs.retry`。返回是否成功重排队（旧响应 bool）。
    public func retry(_ params: JobRetryParams) async throws -> Bool {
        try await jobs.retry(params.jobId)
    }

    /// 旧命令：`jobs.clear_completed`（破坏性）。confirmed 门控在实现内部
    /// （协议约定），同码拒绝；返回清理条数（旧响应 number 收敛为 Int）。
    public func clearCompleted(_ params: JobClearCompletedParams) async throws -> Int {
        guard params.confirmed else {
            throw JobsCommandsError.clearConfirmRequired
        }
        return try await jobs.clearCompleted()
    }
}

/// jobs 域命令边界错误（错误码与旧宿主路由层分支逐字一致）。
public enum JobsCommandsError: Error, Equatable {
    /// 旧响应 error 串：`JOBS_CLEAR_CONFIRM_REQUIRED`。
    case clearConfirmRequired
}

extension JobsCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .clearConfirmRequired: "JOBS_CLEAR_CONFIRM_REQUIRED"
        }
    }
}

extension JobsCommandsError {
    /// 桥接层序列化用（GatherErrorCode 已有同码 case）。
    public var gatherCode: GatherErrorCode {
        switch self {
        case .clearConfirmRequired: .JOBS_CLEAR_CONFIRM_REQUIRED
        }
    }
}
