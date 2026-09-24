// desktop/native/gather-core/Sources/GatherCore/Runtime/Similarity/SimilarityError.swift
// W2c 步骤 1：Similarity 纯函数层的错误类型。
//
// 来源：Services/SimilarityService.swift 27-66 行的 SimilarityServiceError 逐字
// 下沉——case 集、description 文案、gatherCode 映射三处与旧类型完全一致。
//
// 命名注记（设计 §5 待裁决项 3：ServiceError → Error）：旧类型
// SimilarityServiceError 仍由 Services/SimilarityService.swift 声明，同模块顶层
// 不允许并存同名 public 类型，故本文件落地为 SimilarityError；W2c 步骤 6 删除旧
// 服务后本类型即唯一错误类型。
//
// 边界：无 IO、无 SQL、无 Store 依赖（Runtime 纯函数层）。

import Foundation

public enum SimilarityError: Error, Equatable {
    case thresholdInvalid
    case minGroupInvalid
    case analysisRunning
    case noPhotos
    case noHashData
    case noResults
    case noHashRecluster
}

/// TS 错误消息逐字对齐（executor 失败路径经 JobService 以 String(describing:)
/// 记录为 errorMessage，必须等于 TS error.message）。
extension SimilarityError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .thresholdInvalid: "SIM_THRESHOLD_INVALID"
        case .minGroupInvalid: "SIM_MIN_GROUP_INVALID"
        case .analysisRunning: "SIM_ANALYSIS_RUNNING"
        case .noPhotos: "SIM_NO_PHOTOS"
        case .noHashData: "SIM_NO_HASH_DATA"
        case .noResults: "SIM_NO_RESULTS"
        case .noHashRecluster: "SIM_NO_HASH_RECLUSTER"
        }
    }
}

/// TS 错误码映射（rawValue 与 TS 错误消息字符串逐字一致，桥接层序列化用）。
extension SimilarityError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .thresholdInvalid: .SIM_THRESHOLD_INVALID
        case .minGroupInvalid: .SIM_MIN_GROUP_INVALID
        case .analysisRunning: .SIM_ANALYSIS_RUNNING
        case .noPhotos: .SIM_NO_PHOTOS
        case .noHashData: .SIM_NO_HASH_DATA
        case .noResults: .SIM_NO_RESULTS
        case .noHashRecluster: .SIM_NO_HASH_RECLUSTER
        }
    }
}
