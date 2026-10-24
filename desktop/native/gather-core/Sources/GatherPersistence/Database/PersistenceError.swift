// desktop/native/gather-core/Sources/GatherPersistence/Database/PersistenceError.swift
// P1-2 / R1：Persistence 层的类型化域错误。
//
// 背景：DBError.message(String) 同时承载「SQL 失败」与「域错误码」两种语义，
// 上层只能靠 GatherErrorCode(rawValue:) 反解，拼错即静默降级成通用文案。
// 本类型把域错误码变成值：code 参与 Equatable，detail 只进日志/透传。
//
// 边界纪律：
// - Persistence 的**域错误**一律抛 PersistenceError；
// - SQL 编译/执行失败仍抛 DBError（由 Database 门面收敛成 DatabaseError）；
// - 上层通过 CodedError 统一映射，不再匹配字符串。
import Foundation
import GatherProtocol

public struct PersistenceError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: GatherErrorCode
    /// 可选上下文（路径、行号、计数），只用于日志；不参与 UI 文案。
    public let detail: String?

    public init(code: GatherErrorCode, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    public var description: String {
        guard let detail, !detail.isEmpty else { return code.rawValue }
        return "\(code.rawValue): \(detail)"
    }

    /// 身份只有码：detail 是日志上下文，不参与相等性（测试可按码断言）。
    public static func == (lhs: PersistenceError, rhs: PersistenceError) -> Bool {
        lhs.code == rhs.code
    }
}

extension PersistenceError: CodedError {}
