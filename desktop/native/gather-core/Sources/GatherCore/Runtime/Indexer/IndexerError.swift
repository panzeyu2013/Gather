// desktop/native/gather-core/Sources/GatherCore/Runtime/Indexer/IndexerError.swift
// idx2c：删除 Services/IndexerService.swift 时，仍被 IndexerRuntime 引用的错误
// 枚举原样迁入 Runtime（原 Services/IndexerService.swift:25-49）。
// 纪律：不留兼容别名、不双定义；对外仍以 description/gatherCode 维持 TS 逐字语义。
import Foundation

public enum IndexerError: Error, Equatable {
    case sessionNotFound
    case noSourcePath
}

/// TS 错误消息逐字对齐（executor 失败路径以 String(describing:) 记录，
/// 必须等于 TS error.message）。
extension IndexerError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sessionNotFound: "SESSION_NOT_FOUND"
        case .noSourcePath: "INDEX_SESSION_NO_SOURCE"
        }
    }
}

/// TS 错误码映射（桥接层序列化用）。
extension IndexerError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .sessionNotFound: .SESSION_NOT_FOUND
        case .noSourcePath: .INDEX_SESSION_NO_SOURCE
        }
    }
}
