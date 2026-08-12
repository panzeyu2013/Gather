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

public final class NativeCommandClient {
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

    /// 对齐 TS translateError：错误消息是 GatherErrorCode 则翻译为中文文案，
    /// 否则原样返回。页面展示一律经此出口，避免裸错误码直显。
    public static func message(for error: Error) -> String {
        if let native = error as? NativeCommandError { return GatherLocalization.errorText(native.description) }
        if let router = error as? RouterCommandError { return GatherLocalization.errorText(router.message) }
        if let bridge = error as? BridgeError { return GatherLocalization.errorText(bridge.description) }
        return GatherLocalization.errorText((error as NSError).localizedDescription)
    }
}
