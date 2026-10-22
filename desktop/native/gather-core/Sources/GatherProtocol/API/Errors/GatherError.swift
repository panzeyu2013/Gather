// desktop/native/gather-core/Sources/GatherProtocol/API/Errors/GatherError.swift
// Cut 1 / 阶段 1A：API 边界唯一错误类型（设计 §3.3）。
//
// 职责：把 Router 时代的 BridgeError / 各服务错误枚举统一成 (code, params)；
// params 只存可上屏、可插值的字段（field/reason），underlying 只进日志。
// 校验归属：输入类型的 init/init(from:) 与 1B 的 API 实现都只抛 GatherError。
//
// 已知限制（D-010，待后续批次）：
// - 参数错误使用 GatherErrorCode.INVALID_PARAM（第 179 项），field/reason 完整保留。
// - PHOTO_NOT_FOUND / INVALID_PARAM / MISSING_PARAM 目前都不在 177 码内；
//   路径授权失败由 1B 在 API 实现边界收敛（见 PhotoPathPolicy）。

import Foundation

public struct GatherError: Error, Sendable, Equatable {
    public let code: GatherErrorCode
    public let params: [String: String]
    /// 仅日志；不得直接上屏（设计 §3.3）。
    public let underlying: String?

    public init(code: GatherErrorCode, params: [String: String] = [:], underlying: String? = nil) {
        self.code = code
        self.params = params
        self.underlying = underlying
    }

    /// 重试策略（保守）：只有明确的超时/忙状态可重试；参数、权限、确认类错误不可重试。
    public var retryable: Bool {
        switch code {
        case .C1_SCRIPT_TIMEOUT, .XMP_WRITER_TIMEOUT, .DUPLICATE_SCAN_BUSY,
             .WRITEBACK_OTHER_MODULE_ACTIVE, .WRITEBACK_FAILURES_PENDING:
            return true
        default:
            return false
        }
    }
}

public extension GatherError {
    /// 输入形状错误（缺字段、类型错、范围错、空数组等）。
    /// params 固定携带 field / reason，UI 与日志都可直接使用。
    static func invalidParameter(field: String, reason: String) -> GatherError {
        GatherError(
            code: .INVALID_PARAM,
            params: ["field": field, "reason": reason],
            underlying: nil
        )
    }

    /// 域内已有专用码时优先使用专用码（如 FACE_EPS_INVALID、SIM_THRESHOLD_INVALID）。
    static func invalidParameter(code: GatherErrorCode, field: String, reason: String) -> GatherError {
        GatherError(code: code, params: ["field": field, "reason": reason])
    }
}
