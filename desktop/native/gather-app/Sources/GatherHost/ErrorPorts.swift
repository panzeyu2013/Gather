// desktop/native/gather-app/Sources/GatherHost/ErrorPorts.swift
// Cut 3 / 3b-3（E-18 / E-19）：Domain/Analysis 错误 → GatherUI 错误端口的适配。
//
// WP4b：SyncAPIPortBridge.swift（18 个同步转发）已删除；本文件只保留与同步
// 无关的错误语义 conformance，Live API 仍是唯一实现。
import Foundation
import GatherAnalysis
import GatherDomain
import GatherProtocol
import GatherUI

extension JobCancelledError: JobCancellationMarker {}

extension JobServiceError: DomainErrorMessaging {
    public var rawErrorMessage: String? {
        switch self {
        case .jobFailed(_, let message), .waitForResultTimeout(let message):
            return message
        case .jobNotFound(let id), .leaseLost(let id):
            return id
        }
    }
}

extension FaceKwServiceError: DomainErrorMessaging {
    public var rawErrorMessage: String? { description }
}

// E-19 相邻：分析层的中文可读错误同样经端口上屏（原 UI 直接 as? 该类型）。
extension FaceEmbeddingError: DomainErrorMessaging {
    public var rawErrorMessage: String? { description }
}
