// desktop/native/gather-core/Sources/GatherCore/Runtime/Quality/QualityError.swift
// W2c：QualityRuntime 的错误类型（纯值类型，无 Store/SQL 依赖）。
//
// 消息与 Services/QualityService.swift:22-42 的 QualityServiceError 逐字一致：
// failed 结果的 errorMessage 必须等于 TS error.message（"QUALITY_NO_ASSET_FILE"）；
// gatherCode 为桥接层序列化用（非可选，旧实现同款）。

import Foundation

public enum QualityError: Error, Equatable {
    case noAssetFile
}

/// TS 错误消息逐字对齐。
extension QualityError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noAssetFile: "QUALITY_NO_ASSET_FILE"
        }
    }
}

/// TS 错误码映射（桥接层序列化用）。
extension QualityError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .noAssetFile: .QUALITY_NO_ASSET_FILE
        }
    }
}
