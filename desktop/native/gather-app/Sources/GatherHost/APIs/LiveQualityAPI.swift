// desktop/native/gather-app/Sources/GatherHost/APIs/LiveQualityAPI.swift
// Cut 1 / B5a：QualityAPI 的 Live 实现（2 个方法）。
//
// 对应命令（2 条）：quality.analyze / quality.get（get -> results）。
//
// 校验归属：
// - QualityAnalyzeInput 已在输入类型完成 sessionId 非空白、photoIds 允许
//   nil（整会话）但“提供且为空”显式失败（INVALID_PARAM:photoIds）、逐项
//   非空白与 10000 上限；本实现不重复解析 JSON，也不把空数组当“全部”；
// - results 的裸参数在这里补 sessionId 非空白/长度上限与 photoIds 逐项
//   非空白/上限校验（对齐 QualityAnalyzeInput 的边界），失败统一
//   GatherError.invalidParameter；旧 quality.get 对空数组仍返回空结果
//   （服务层 ids.isEmpty 早退），本实现保持该语义。
//
// 任务语义（沿用旧命令面 的 quality.* 分支）：
// - analyze：JobService.create(.qualityScore) 后立即返回 AnalysisJobData
//   （旧命令成功即返回 job，不等待执行）；dedupeKey 与 checkpoint 逐字保留
//   （photoIds 排序后入键、原始顺序入 checkpoint；缺省写 null）；
// - results：直接委托 QualityService.get（每照片最新一条 technical_quality
//   结果、会话过滤、相对排名仍由服务负责）；
// - job 状态机、执行器（photoIds 从 checkpoint 还原）与取消归属
//   JobService/QualityService，本文件不提前改语义。
//
// 错误映射：QualityServiceError 有专用码（QUALITY_NO_ASSET_FILE）时收敛成
// GatherError；executor 失败落库的 message 若本身就是错误码，由
// JobServiceError.jobFailed 还原；其余错误原样抛出（D-030）。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LiveQualityAPI: QualityAPI {
    private let qualityService: QualityService
    private let jobService: JobService

    /// Sendable 由协议继承显式声明，且类为 final、两个依赖都是构造后不再
    /// 变更的 Sendable let（QualityService / JobService 的可变状态由各自内部
    /// 锁串行化），故无需 @unchecked；此点由编译器检查。
    public init(qualityService: QualityService, jobService: JobService) {
        self.qualityService = qualityService
        self.jobService = jobService
    }

    // MARK: - 分析建单

    /// quality.analyze：建 quality.score job 后立即返回（旧命令不等执行）。
    public func analyze(_ input: QualityAnalyzeInput) async throws -> AnalysisJobData {
        let photoIds = input.photoIds
        // 旧命令面：photoIds?.sorted().joined(separator: ",") ?? "all"。
        let keySuffix = photoIds?.sorted().joined(separator: ",") ?? "all"
        return try map {
            try jobService.create(JobCreateParams(
                type: .qualityScore,
                scopeType: "session",
                scopeId: input.sessionId,
                dedupeKey: "quality.score:\(input.sessionId):\(keySuffix)",
                checkpoint: [
                    // 原始顺序（非排序）入 checkpoint：executor 按该顺序分析。
                    "photoIds": photoIds.map { .array($0.map { .string($0) }) } ?? .null,
                ]
            ))
        }
    }

    // MARK: - 结果读取

    /// quality.get：每照片最新一条 technical_quality 结果（服务层会话过滤）。
    public func results(_ query: QualityGetParams) async throws -> [QualityResult] {
        let sessionId = try requireNonBlank(query.sessionId, field: "sessionId", maxLength: 128)
        let photoIds = try validatePhotoIds(query.photoIds)
        return try map {
            try qualityService.get(sessionId: sessionId, photoIds: photoIds)
        }
    }

    // MARK: - 校验与错误映射

    private func validatePhotoIds(_ photoIds: [String]?) throws -> [String]? {
        guard let photoIds else { return nil }
        guard photoIds.count <= 10_000 else {
            throw GatherError.invalidParameter(
                field: "photoIds",
                reason: "count must be at most 10000"
            )
        }
        for (index, photoId) in photoIds.enumerated() {
            _ = try requireNonBlank(
                photoId,
                field: "photoIds[\(index)]",
                maxLength: 128
            )
        }
        return photoIds
    }

    private func requireNonBlank(
        _ value: String,
        field: String,
        maxLength: Int
    ) throws -> String {
        guard value.count <= maxLength else {
            throw GatherError.invalidParameter(
                field: field,
                reason: "length must be at most \(maxLength)"
            )
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must not be blank")
        }
        return value
    }

    private func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw Self.translate(error)
        }
    }

    /// 域臂：QualityServiceError；通用臂见 translateCommon。
    private static func translate(_ error: Error) -> Error {
        if let common = LiveAPIErrorMapping.translateCommon(error) { return common }
        guard let quality = error as? QualityServiceError else { return error }
        return GatherError(code: quality.gatherCode, underlying: quality.description)
    }
}
