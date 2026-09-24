// API/Impl/QualityCommandsImpl.swift
// R5 命令层接线：quality 域实现（批次 B3）。
// 逻辑来源：宿主路由层 quality.get / quality.analyze 分支；错误码与返回形状不变：
// - get 走 QualityRuntime.get（photoIds 可选；nil 取会话全量）；
// - analyze 建 quality.score 作业后立即返回 AnalysisJobData（不等作业完成），
//   dedupeKey 与 checkpoint 逐字沿用旧分支，photoIds 提供但为空按
//   INVALID_PARAM:photoIds 拒绝（门控保留）。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// quality 域命令实现：注入质量运行时与作业运行器。
public actor QualityCommandsImpl: QualityCommands {
    private let quality: QualityRuntime
    private let jobs: JobRunner

    public init(quality: QualityRuntime, jobs: JobRunner) {
        self.quality = quality
        self.jobs = jobs
    }

    /// 旧命令：`quality.get`。photoIds 为 nil 取该会话全部评分结果；
    /// 不在会话内的 id 由运行时过滤。
    public func get(_ params: QualityGetParams) async throws -> [QualityResult] {
        try await quality.get(sessionId: params.sessionId, photoIds: params.photoIds)
    }

    /// 旧命令：`quality.analyze`。photoIds 提供但为空 → INVALID_PARAM:photoIds；
    /// 否则按旧分支的 dedupeKey / checkpoint 建作业并返回作业数据。
    public func analyze(_ params: QualityAnalyzeParams) async throws -> AnalysisJobData {
        let photoIds = params.photoIds
        if let photoIds, photoIds.isEmpty {
            throw QualityCommandsError.invalidParam("photoIds")
        }
        return try await jobs.create(JobCreateParams(
            type: .qualityScore,
            scopeType: "session",
            scopeId: params.sessionId,
            dedupeKey: "quality.score:\(params.sessionId):\(photoIds?.sorted().joined(separator: ",") ?? "all")",
            checkpoint: [
                "photoIds": photoIds.map { .array($0.map(JSONValue.string)) } ?? .null,
            ]
        ))
    }
}

/// quality 域命令边界错误（错误码与旧宿主路由层分支逐字一致）。
public enum QualityCommandsError: Error, Equatable {
    /// 旧分支参数校验拒绝：`INVALID_PARAM:<key>`。
    case invalidParam(String)
}

extension QualityCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidParam(let key): "INVALID_PARAM:\(key)"
        }
    }
}

extension QualityCommandsError {
    /// 桥接层序列化用；参数化 INVALID_PARAM 无 GatherErrorCode 同码 case。
    public var gatherCode: GatherErrorCode? { nil }
}
