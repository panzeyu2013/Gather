// desktop/native/gather-core/Sources/GatherPersistence/Database/DeliveryError.swift
// 交付链路的遗留错误码与写回失败记录（Cut 2 / S5c-2b-3b-2b-3）。
//
// 来源：MetadataSyncCoordinator.swift 删除后，仍被四个写回消费者使用的错误语义
// 需要一个归属（D-091：MetadataSyncError.externallyModified 迁移到新错误类型）。
// 这里只保留**仍在使用**的四个稳定码；旧协调器其余码（conflict/orphan/cleanup
// 状态机专用）随旧同步栈一起删除。
//
// 码值与本地化映射逐字沿用旧 MetadataSyncError（UI/报告卡按码值识别，不得漂移）：
//   XMP_CONFIRM_INCOMPLETE / XMP_CONFIRM_REQUIRES_SYNC /
//   XMP_CONFIRM_OTHER_SESSION_PENDING / XMP_EXTERNALLY_MODIFIED
import Foundation
import GatherProtocol

/// 宿主 XMP provider 的错误可被内核结构化的最小面（gather-app 的 SidecarXMPError 已实现）。
public protocol MetadataCodedError: Error, Sendable {
    var code: String { get }
    var xmpPath: String { get }
    /// 结构化字段名（rating/label/keywords）；nil = 整行或非字段级失败。
    var field: String? { get }
}

public extension MetadataCodedError {
    var field: String? { nil }
}

/// 落库的失败记录：稳定错误码 + 结构化字段。
public struct MetadataWritebackFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let xmpPath: String
    public let field: String?
    public let reason: String

    public init(code: String, xmpPath: String, field: String?, reason: String) {
        self.code = code
        self.xmpPath = xmpPath
        self.field = field
        self.reason = reason
    }

    /// 任意 Error → 类型化失败记录（优先宿主投递的错误码/字段，其次是内核错误码）。
    /// - Parameter fallbackField: 调用方已知的字段名兜底（如单字段行的 dirty field）。
    public static func from(
        _ error: Error,
        xmpPath: String,
        field fallbackField: String? = nil
    ) -> MetadataWritebackFailure {
        if let coded = error as? any MetadataCodedError {
            return MetadataWritebackFailure(
                code: coded.code,
                xmpPath: coded.xmpPath.isEmpty ? xmpPath : coded.xmpPath,
                field: coded.field ?? fallbackField,
                reason: String(describing: error))
        }
        if let delivery = error as? DeliveryError {
            // 落库 code 用精确错误码（不再拼 description）；reason 保留可读细节（如阻塞会话 id）。
            return MetadataWritebackFailure(
                code: delivery.gatherCode.rawValue,
                xmpPath: xmpPath,
                field: fallbackField,
                reason: delivery.description)
        }
        if error is MetadataFingerprintError {
            return MetadataWritebackFailure(
                code: "XMP_FINGERPRINT_FAILED", xmpPath: xmpPath, field: nil,
                reason: String(describing: error))
        }
        return MetadataWritebackFailure(
            code: "XMP_WRITE_FAILED", xmpPath: xmpPath, field: nil, reason: String(describing: error))
    }

    public var description: String {
        var text = code + ": " + xmpPath
        if let field { text += " field=" + field }
        text += " reason=" + reason
        return text
    }
}

/// 交付路径的唯一口径：photo 路径 → sidecar 路径。
///
/// 从已删除的 MetadataOutboxRepo 迁出（S5c-2b-3b-2b-3）：交付键必须与旧落库键
/// 完全一致（normalize + xmpSidecarPath），否则已有 deliveries 行会读不到。
public enum DeliveryPath {
    /// TSPath.xmpSidecarPath + ScanPath.canonical。对已经是 sidecar 路径的输入幂等。
    public static func sidecar(_ photoPath: String) -> String {
        TSPath.xmpSidecarPath(ScanPath.canonical(photoPath))
    }

    /// 归一化任意路径为 sidecar 键（入参可能是照片或 sidecar 路径）。
    public static func normalize(_ path: String) -> String {
        sidecar(path)
    }
}

/// 写回/交付确认的稳定失败码（旧 UI 按码值渲染，语义与旧 MetadataSyncError 相同）。
public enum DeliveryError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// confirm 门禁：仍有 pending/writing/failed/conflict 的交付或 item。
    case confirmIncomplete // XMP_CONFIRM_INCOMPLETE
    /// Capture One 尚未确认重载元数据（reload_acked_at 门禁）。
    case confirmRequiresSync // XMP_CONFIRM_REQUIRES_SYNC
    /// 同一 sidecar 被多个会话共享，且（除当前会话外的）关联会话尚未确认。
    case otherSessionNotConfirmed(sessionId: String) // XMP_CONFIRM_OTHER_SESSION_PENDING
    /// XMP sidecar 在写回/清理期间被外部修改。
    case externallyModified // XMP_EXTERNALLY_MODIFIED

    public var description: String {
        switch self {
        case .confirmIncomplete: "XMP_CONFIRM_INCOMPLETE"
        case .confirmRequiresSync: "XMP_CONFIRM_REQUIRES_SYNC"
        case .otherSessionNotConfirmed(let sessionId): "XMP_CONFIRM_OTHER_SESSION_PENDING: " + sessionId
        case .externallyModified: "XMP_EXTERNALLY_MODIFIED"
        }
    }

    public var errorDescription: String? { description }

    /// 本地化漏斗：每个错误码都映射到 GatherErrorCode（UI 不再解析 description 字符串）。
    public var gatherCode: GatherErrorCode {
        switch self {
        case .confirmIncomplete: .XMP_CONFIRM_INCOMPLETE
        case .confirmRequiresSync: .XMP_CONFIRM_REQUIRES_SYNC
        case .otherSessionNotConfirmed: .XMP_CONFIRM_OTHER_SESSION_PENDING
        case .externallyModified: .XMP_EXTERNALLY_MODIFIED
        }
    }
}