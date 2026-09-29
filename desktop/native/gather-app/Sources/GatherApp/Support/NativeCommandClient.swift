// Phase 3 收尾：SwiftUI 页面共用的同进程命令客户端。
//
// SwiftUI 直接复用 CommandRouter，保留参数校验、错误码和 JobService 语义，
// 不在页面层复制领域服务调用逻辑。
import Foundation
import GatherCore

public enum NativeCommandError: Error, Equatable, CustomStringConvertible {
    case failed(String)
    case emptyResponse(String)

    public var description: String {
        switch self {
        case .failed(let message): return message
        case .emptyResponse(let command): return "EMPTY_RESPONSE:\(command)"
        }
    }
}

/// Swift 6 迁移：客户端本身无状态 —— 唯一存储属性 `router` 是不可变 let，
/// 类型 CommandRouter 已声明 `: Sendable`（见 CommandRouter.swift），
/// final 类 + 全 let 的 Sendable 存储属性可被编译器静态验证，故直接声明
/// `Sendable`（非 @unchecked）：页面把它送进 Task / Task.detached 时不需要
/// 再复制或加锁。
public final class NativeCommandClient: Sendable {
    public let router: CommandRouter

    public init(router: CommandRouter) {
        self.router = router
    }

    @discardableResult
    public func execute(
        _ command: String,
        params: [String: GatherCore.JSONValue] = [:]
    ) throws -> GatherCore.JSONValue {
        try router.execute(command, params: params)
    }

    public func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue] = [:]
    ) async throws -> GatherCore.JSONValue {
        let response: WebResponse = await withCheckedContinuation { continuation in
            router.executeAsync(command, params: params) { response in
                continuation.resume(returning: response)
            }
        }
        guard response.ok else {
            throw NativeCommandError.failed(response.error ?? "COMMAND_FAILED:\(command)")
        }
        guard let data = response.data else {
            throw NativeCommandError.emptyResponse(command)
        }
        return data
    }

    /// 对齐 TS translateError：错误消息是 GatherErrorCode 则翻译为中文文案；
    /// 未知码与原始诊断一律回退通用文案（errorText 语义），裸诊断不上屏。
    public static func message(for error: Error) -> String {
        if let native = error as? NativeCommandError { return GatherLocalization.errorText(native.description) }
        if let router = error as? RouterCommandError { return GatherLocalization.errorText(router.message) }
        if let bridge = error as? BridgeError { return GatherLocalization.errorText(bridge.description) }
        return GatherLocalization.errorText((error as NSError).localizedDescription)
    }

    /// 页面错误文案的唯一漏斗：在 message(for:) 之上补 SessionServiceError 的
    /// 码值翻译。SessionServiceError 不满足 LocalizedError，NSError 桥接会把
    /// 码值丢成「The operation couldn't be completed…」，故必须先取 gatherCode。
    /// 语义等同「所有带码错误 → 本地化模板；其余 → 通用文案」。
    public static func userFacingMessage(for error: Error) -> String {
        if let sessionError = error as? SessionServiceError {
            return GatherLocalization.errorText(sessionError.gatherCode.rawValue)
        }
        return message(for: error)
    }
}
