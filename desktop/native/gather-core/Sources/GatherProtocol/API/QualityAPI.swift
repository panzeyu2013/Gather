// desktop/native/gather-core/Sources/GatherProtocol/API/QualityAPI.swift
// Cut 1 / 阶段 1A：画质域协议（2 个方法）。
//
// 职责：画质分析建 job、画质结果读取。
// 对应命令（2 条）：quality.analyze / quality.get（get -> results）。
// 校验归属：
// - analyze 的 photoIds“提供但为空”在输入类型显式失败（旧 INVALID_PARAM）；
// - 建 job 的状态机与执行器归属 JobService/QualityService；实现可先委托
//   JobAPI.start，本方法保留 job 立即返回的旧形状（AnalysisJobData）。

import Foundation

public protocol QualityAPI: Sendable {
    func analyze(_ input: QualityAnalyzeInput) async throws -> AnalysisJobData
    func results(_ query: QualityGetParams) async throws -> [QualityResult]
}
