// desktop/native/gather-core/Sources/GatherProtocol/Protocol/SessionErrors.swift
// Cut 3 / 3b-0：SessionService 的域错误从
// GatherDomain/Services/SessionService.swift 上移到协议层（E-19-④）。
//
// 为什么放 GatherProtocol：它是无载荷纯枚举，只依赖 GatherErrorCode；UI / Host
// 需要按码值取本地化文案，但不该因此依赖 GatherDomain。SessionService 仍抛
// 同一个类型，LiveSessionAPI 继续用 gatherCode 映射成 GatherError。
//
// 注意：该枚举不满足 LocalizedError（历史语义），错误展示漏斗必须先取
// gatherCode，不能走 NSError 桥接（否则码值会丢成通用文案）。

/// SessionService 的稳定错误集（码值映射见 gatherCode）。
public enum SessionServiceError: Error, Equatable, Sendable {
    case sourceNotDir
    case sourceRootForbidden
    case deleteNotConfirmed
    case sessionNotFound
}

/// TS 错误码映射（rawValue 与 TS 错误消息字符串逐字一致，桥接层序列化用）。
extension SessionServiceError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .sourceNotDir: .SESSION_SOURCE_NOT_DIR
        case .sourceRootForbidden: .SESSION_SOURCE_ROOT_FORBIDDEN
        case .deleteNotConfirmed: .SESSION_DELETE_NOT_CONFIRMED
        case .sessionNotFound: .SESSION_NOT_FOUND
        }
    }
}
