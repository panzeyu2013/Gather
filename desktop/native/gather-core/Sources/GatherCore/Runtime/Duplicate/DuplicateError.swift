// desktop/native/gather-core/Sources/GatherCore/Runtime/Duplicate/DuplicateError.swift
// W2c：DuplicateRuntime 的错误类型（纯值类型，无 Store/SQL 依赖）。
//
// 错误消息与 Services/DuplicateService.swift:29-48 的 DuplicateServiceError 逐字
// 一致（TS 错误消息对账）：executor 失败路径经 JobService 以 String(describing:)
// 记录为 errorMessage，必须等于 TS error.message；gatherCode 仅 scanBusy 在
// GatherErrorCode 有对应码，其余为普通 Error（旧实现同款映射）。

import Foundation

public enum DuplicateError: Error, Equatable {
    /// TS: throw new Error('DUPLICATE_SCAN_BUSY')
    case scanBusy
    /// TS: throw new Error(\`Duplicate group \${groupId} was not found or has no members\`)
    case groupNotFound(Int)
    /// TS: throw new Error(\`Duplicate member \${memberId} was not found\`)
    case memberNotFound(Int)
}

/// TS 错误消息逐字对齐（与旧 DuplicateServiceError.description 逐字相同）。
extension DuplicateError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .scanBusy: "DUPLICATE_SCAN_BUSY"
        case .groupNotFound(let groupId): "Duplicate group \(groupId) was not found or has no members"
        case .memberNotFound(let memberId): "Duplicate member \(memberId) was not found"
        }
    }
}

/// TS 错误码映射（仅 scanBusy 有对应码）。
extension DuplicateError {
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .scanBusy: .DUPLICATE_SCAN_BUSY
        case .groupNotFound, .memberNotFound: nil
        }
    }
}
