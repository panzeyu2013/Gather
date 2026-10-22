// desktop/native/gather-core/Sources/GatherProtocol/API/Core/Confirmed.swift
// Cut 1 / 阶段 1A：破坏性操作的调用点标记（决策 D-011）。
//
// 职责：API 只接收 Confirmed<T>，不再接收裸 confirmed: Bool。
// 语义边界：这是**调用点标记**，不是密码学门禁——它让“没有经过确认弹窗”的调用
// 在类型层面写不出来；source 记录确认来源（用户弹窗 / 自动化 / 测试），便于审计。
// 构造器 public：Host/UI 确认模块、自动化与测试都可构造；API 实现不得自己“补”确认。
//
// 校验归属：确认语义在 UI 确认弹窗；API 实现只读取 value/source，不再校验 Bool。

import Foundation

public enum ConfirmationSource: String, Codable, CaseIterable, Sendable, Equatable {
    /// 用户确认弹窗（默认）。
    case userDialog
    /// 受控自动化（脚本/菜单批量操作），调用方必须已有明确意图。
    case automation
    /// 测试构造。
    case test
}

public struct Confirmed<Value: Sendable>: Sendable {
    public let value: Value
    public let source: ConfirmationSource

    public init(_ value: Value, source: ConfirmationSource = .userDialog) {
        self.value = value
        self.source = source
    }
}

extension Confirmed: Equatable where Value: Equatable {}

public extension Confirmed {
    /// 在保留确认来源的前提下变换载荷。
    func map<T: Sendable>(_ transform: (Value) -> T) -> Confirmed<T> {
        Confirmed<T>(transform(value), source: source)
    }
}
