// desktop/native/gather-app/Sources/GatherApp/Support/GatherErrorText.swift
// 错误展示单点映射：所有领域错误的 description 都已是稳定错误码
// （或参数化 "CODE::p1::p2"），这里统一交给本地化表翻译；非码值回退通用文案。
// 取代旧命令客户端的三段式 message(for:)（命令桥类型已删除）。
import Foundation
import GatherCore

/// 数据提供者协议里 app 侧未接线的可选操作（保持既有「明确失败、不伪装成功」语义）。
struct UnsupportedOperationError: Error, CustomStringConvertible, Equatable {
    let code: String

    var description: String { code }
}

enum GatherErrorText {
    /// 页面展示一律经此出口，避免裸错误码直显。
    ///
    /// 三级策略（与迁移前各页面 helper 的可观察行为一致）：
    /// 1. 显式携带 NSLocalizedDescriptionKey 的错误（LocalizedError / 宿主或
    ///    测试注入的 NSError）：消息是错误码则翻译，否则保留原文（不吞诊断）；
    /// 2. Swift 领域错误（description 即错误码）：翻译为文案，未知码回退通用文案；
    /// 3. 其余（无描述可选）：回退通用文案。
    static func message(for error: Error) -> String {
        let nsError = error as NSError
        // 1. 真实 NSError（宿主 / 文件系统 / 测试注入）：保留既有诊断消息。
        //    Swift 领域错误桥接后的 userInfo 为空，故以类型判定而非 userInfo。
        if type(of: error) == NSError.self {
            return nsError.localizedDescription
        }
        // 2. Swift 领域错误：description 即错误码 → 翻译；未知码回退通用文案。
        if let described = error as? CustomStringConvertible {
            return GatherLocalization.errorText(described.description)
        }
        return GatherLocalization.errorText(nsError.localizedDescription)
    }
}
