// desktop/native/gather-app/Sources/GatherUI/Support/DomainChangeGate.swift
// R4：领域变更事件的“去重 + 乱序保护”闸门。
//
// 背景：domainChanged 是 NotificationCenter 广播，监听方各自 debounce；
// 同一变更可能被重复投递/乱序投递（多写路径、跨 Task）。revision 让监听方有一个
// 可比较的“已应用到哪一版”。
//
// 纪律：gate 是页面/VM 级状态（每个监听方一份），不放进 GatherEventCenter；
// 只做单调比较，不承担业务语义。OSAllocatedUnfairLock 使其天然 Sendable。
import Foundation
import os

public final class DomainChangeGate: Sendable {
    private let lastApplied = OSAllocatedUnfairLock<[GatherChangeDomain: UInt64]>(initialState: [:])

    public init() {}

    /// 是否应当应用该变更：revision 必须严格大于该域已应用值。
    /// 返回 true 时同时推进水位；origin 过滤仍由 DomainEventFilter 负责。
    @discardableResult
    public func applyIfNewer(_ change: GatherApplicationChange) -> Bool {
        lastApplied.withLock { state in
            let last = state[change.domain] ?? 0
            guard change.revision > last else { return false }
            state[change.domain] = change.revision
            return true
        }
    }
}
