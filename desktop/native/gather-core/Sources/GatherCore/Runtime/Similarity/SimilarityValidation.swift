// desktop/native/gather-core/Sources/GatherCore/Runtime/Similarity/SimilarityValidation.swift
// W2c 步骤 1：Similarity 参数校验 / 解析（纯函数）。
//
// 来源：Services/SimilarityService.swift 91-100 行 validateSimilarityParameters 与
// analyze 开头的参数解析（196-202 行）逐字下沉：
//   threshold ?? getNumber("default_threshold", 10)
//   minGroupSize ?? getNumber("default_min_group_size", 2)
//   groupingMode ?? .global
//   先 validate（Double 语义：Number.isInteger 拒绝 NaN/∞/小数），后安全整数化。
//
// 边界：无 IO、无 SQL、无 Store 依赖；getNumber 以闭包注入（设置读取留在 Runtime）。
//
// 命名注记：旧顶层函数 validateSimilarityParameters 与旧私有 struct
// AnalysisRunParams 均保留在 Services/SimilarityService.swift（同模块顶层同名
// public 类型/同签名函数会 hard error），故新类型命名为 SimilarityAnalysisParams、
// 入口收敛到 SimilarityValidation 命名空间。

import Foundation

/// TS: analysis_runs.params —— 分析 run 的参数指纹（JSON key 与旧
/// AnalysisRunParams 逐字相同：threshold / minGroupSize / groupingMode）。
public struct SimilarityAnalysisParams: Codable, Equatable, Sendable {
    public let threshold: Int
    public let minGroupSize: Int
    public let groupingMode: SimilarityGroupingMode

    public init(threshold: Int, minGroupSize: Int, groupingMode: SimilarityGroupingMode) {
        self.threshold = threshold
        self.minGroupSize = minGroupSize
        self.groupingMode = groupingMode
    }
}

/// TS: similarity.service.ts 的参数校验与默认值解析（纯函数面）。
public enum SimilarityValidation {
    /// TS: SettingsService.getNumber 键名。
    public static let defaultThresholdKey = "default_threshold"
    public static let defaultMinGroupSizeKey = "default_min_group_size"

    /// TS 默认值（analyze / recluster 的 getNumber 兜底）。
    public static let fallbackThreshold: Double = 10
    public static let fallbackMinGroupSize: Double = 2

    /// TS: validateSimilarityParameters。参数类型为 Double 对齐 TS number：
    /// Number.isInteger 校验（拒绝 NaN/∞/小数），通过后调用方再安全转 Int。
    public static func validate(threshold: Double, minGroupSize: Double) throws {
        if threshold.isNaN || threshold.isInfinite || threshold.rounded() != threshold || threshold < 0 || threshold > 64 {
            throw SimilarityError.thresholdInvalid
        }
        if minGroupSize.isNaN || minGroupSize.isInfinite || minGroupSize.rounded() != minGroupSize || minGroupSize < 2 {
            throw SimilarityError.minGroupInvalid
        }
    }

    /// 参数解析 + 校验：nil 走显式默认值；校验先于整数化（NaN/小数抛
    /// SIM_THRESHOLD_INVALID / SIM_MIN_GROUP_INVALID，绝不 Int(NaN) 陷阱）。
    public static func resolved(
        threshold: Double?,
        minGroupSize: Double?,
        groupingMode: SimilarityGroupingMode?,
        defaultThreshold: Double = fallbackThreshold,
        defaultMinGroupSize: Double = fallbackMinGroupSize
    ) throws -> SimilarityAnalysisParams {
        let thresholdValue = threshold ?? defaultThreshold
        let minGroupSizeValue = minGroupSize ?? defaultMinGroupSize
        try validate(threshold: thresholdValue, minGroupSize: minGroupSizeValue)
        return SimilarityAnalysisParams(
            threshold: Int(thresholdValue),
            minGroupSize: Int(minGroupSizeValue),
            groupingMode: groupingMode ?? .global
        )
    }

    /// 参数解析 + 校验（设置源注入版本）：nil → getNumber(默认值)，顺序与旧
    /// analyze 开头逐字一致（解析全部默认值后才校验）。
    public static func resolved(
        threshold: Double?,
        minGroupSize: Double?,
        groupingMode: SimilarityGroupingMode?,
        getNumber: (String, Double) -> Double
    ) throws -> SimilarityAnalysisParams {
        try resolved(
            threshold: threshold ?? getNumber(defaultThresholdKey, fallbackThreshold),
            minGroupSize: minGroupSize ?? getNumber(defaultMinGroupSizeKey, fallbackMinGroupSize),
            groupingMode: groupingMode
        )
    }
}
