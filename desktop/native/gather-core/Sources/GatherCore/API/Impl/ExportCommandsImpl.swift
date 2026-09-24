// API/Impl/ExportCommandsImpl.swift
// R5 命令层接线：export 域实现（批次 B5）。
// 逻辑来源：宿主路由层 export.* 分支；预览/取消/报告复用 ExportRuntime，
// execute 保留旧「建可恢复作业 + 等待结果」形状：
// - preview：ExportRuntime.preview（旧路由的同步/异步重复分支语义一致，只保留一条）；
// - execute（破坏性）：confirmed 非 true → EXPORT_CONFIRMATION_REQUIRED；
//   start → create（dedupeKey 与 checkpoint 逐字沿用旧分支）→ waitForResult；
//   作业结果为空时抛 JobRunnerError.jobFailed（旧语义与消息逐字一致）；
//   作业 executor（含 resume/onPlanned/onPlanReady/onCompleted 断点续作回调）仍由
//   宿主组合根注册到同一 JobRunner，本实现不重复注册；
// - cancel：取消 export.execute 作用域作业 + 运行时取消标记。旧分支立即返回 true、
//   后台异步取消；本实现等待两步完成（错误照旧吞掉、返回空），契约不变；
// - report：ExportRuntime.report；reportType 缺省 "session_summary" 由宿主适配层
//   补齐（DTO 非可选），format 可空原样下传（nil → csv 由运行时归一）。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// export 域命令实现：注入导出运行时与作业运行器。
public actor ExportCommandsImpl: ExportCommands {
    private let export: ExportRuntime
    private let jobs: JobRunner

    public init(export: ExportRuntime, jobs: JobRunner) {
        self.export = export
        self.jobs = jobs
    }

    /// 旧命令：`export.preview`。选项校验/会话归属/预览装配由 ExportRuntime 承担。
    public func preview(_ params: ExportPreviewParams) async throws -> ExportPreview {
        try await export.preview(params)
    }

    /// 旧命令：`export.execute`（破坏性）。确认门控 → 建可恢复作业 → 等结果。
    public func execute(_ params: ExportExecuteParams) async throws -> ExportResult {
        guard params.confirmed else {
            throw ExportCommandsError.confirmationRequired
        }
        // 旧分支注释：宿主可被 CLI/测试直接调用；start 是幂等的，确保不因
        // 宿主忘记启动 job service 而永久 queued。
        _ = await jobs.start()
        let job = try await jobs.create(JobCreateParams(
            type: .exportExecute,
            scopeType: "session",
            scopeId: params.sessionId,
            dedupeKey: "export.execute:\(params.sessionId)",
            checkpoint: ["options": try JobCheckpoint.encoded(params.options)]
        ))
        guard let result: ExportResult = try await jobs.waitForResult(jobId: job.id) else {
            throw JobRunnerError.jobFailed(job.id, "empty export.execute result")
        }
        return result
    }

    /// 旧命令：`export.cancel`。取消该会话在跑的导出作业与运行时导出；
    /// 旧响应 true、本协议返回空，取消失败照旧不抛出。
    public func cancel(sessionId: String) async throws {
        _ = try? await jobs.cancelScope(type: .exportExecute, scopeId: sessionId)
        try? await export.cancel(sessionId)
    }

    /// 旧命令：`export.report`。reportType/format 由 DTO 承载，生成报告数据。
    public func report(_ params: ExportReportParams) async throws -> ReportData {
        try await export.report(params)
    }
}

/// export 域命令边界错误（错误码字符串与旧宿主路由层分支逐字一致）。
public enum ExportCommandsError: Error, Equatable {
    /// 旧响应 error 串：`EXPORT_CONFIRMATION_REQUIRED`。
    case confirmationRequired
}

extension ExportCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .confirmationRequired: "EXPORT_CONFIRMATION_REQUIRED"
        }
    }
}

extension ExportCommandsError {
    /// 桥接层序列化用。
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .confirmationRequired: .EXPORT_CONFIRMATION_REQUIRED
        }
    }
}
