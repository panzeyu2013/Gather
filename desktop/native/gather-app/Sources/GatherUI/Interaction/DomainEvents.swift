import SwiftUI
import Foundation

/// 声明式领域事件订阅：页面不再手写 `onReceive + guard + debounce`。
///
/// 只覆盖写路径广播 `domainChanged`；jobProgress 的帧级节流仍由需要它的页面
/// 单独处理（进度帧语义特殊，不应强行统一）。
extension View {
    func refreshOnDomainEvents(
        _ domains: Set<GatherChangeDomain>,
        sessionId: String? = nil,
        excludingOrigin: String? = nil,
        debounce: Duration = .milliseconds(500),
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(DomainRefreshModifier(
            domains: domains,
            sessionId: sessionId,
            excludingOrigin: excludingOrigin,
            debounce: debounce,
            action: action
        ))
    }
}

extension View {
    /// 需要拿到 change 本身（如 Culling 的按域补刷）时使用；不 debounce，
    /// 由 VM 自己的 handleDomainChange 决定合并/丢弃。
    func handleDomainEvents(
        _ domains: Set<GatherChangeDomain>,
        sessionId: String? = nil,
        excludingOrigin: String? = nil,
        action: @escaping @MainActor (GatherApplicationChange) -> Void
    ) -> some View {
        modifier(DomainChangeModifier(
            domains: domains,
            sessionId: sessionId,
            excludingOrigin: excludingOrigin,
            action: action
        ))
    }
}

/// 领域事件的纯过滤契约（可单测，不依赖 SwiftUI 挂载）。
struct DomainEventFilter {
    let domains: Set<GatherChangeDomain>
    let sessionId: String?
    let excludingOrigin: String?

    func accepts(_ change: GatherApplicationChange) -> Bool {
        guard domains.contains(change.domain) else { return false }
        if let sessionId, !change.matches(sessionId: sessionId) { return false }
        if let excludingOrigin, change.origin == excludingOrigin { return false }
        return true
    }
}

private struct DomainChangeModifier: ViewModifier {
    let domains: Set<GatherChangeDomain>
    let sessionId: String?
    let excludingOrigin: String?
    let action: @MainActor (GatherApplicationChange) -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
            guard let change = notification.object as? GatherApplicationChange else { return }
            guard DomainEventFilter(
                domains: domains,
                sessionId: sessionId,
                excludingOrigin: excludingOrigin
            ).accepts(change) else { return }
            action(change)
        }
    }
}

extension View {
    /// 任务终态刷新：只关心“结束”信号，不处理进度帧。
    func refreshOnJobTerminal(
        sessionId: String? = nil,
        sessionOnly: Bool = false,
        debounce: Duration = .milliseconds(200),
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(JobTerminalRefreshModifier(
            sessionId: sessionId,
            sessionOnly: sessionOnly,
            debounce: debounce,
            action: action
        ))
    }
}

private struct JobTerminalRefreshModifier: ViewModifier {
    let sessionId: String?
    let sessionOnly: Bool
    let debounce: Duration
    let action: @MainActor () async -> Void

    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobTerminal)) { notification in
                guard let event = notification.object as? GatherJobEvent else { return }
                if sessionOnly, event.job.scopeType != "session" { return }
                if let sessionId, event.job.scopeId != sessionId { return }

                pending?.cancel()
                pending = Task { @MainActor in
                    do {
                        try await Task.sleep(for: debounce)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await action()
                }
            }
            .onDisappear {
                pending?.cancel()
                pending = nil
            }
    }
}

private struct DomainRefreshModifier: ViewModifier {
    let domains: Set<GatherChangeDomain>
    let sessionId: String?
    let excludingOrigin: String?
    let debounce: Duration
    let action: @MainActor () async -> Void

    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
                guard let change = notification.object as? GatherApplicationChange else { return }
                guard DomainEventFilter(
                    domains: domains,
                    sessionId: sessionId,
                    excludingOrigin: excludingOrigin
                ).accepts(change) else { return }

                pending?.cancel()
                pending = Task { @MainActor in
                    do {
                        try await Task.sleep(for: debounce)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await action()
                }
            }
            .onDisappear {
                pending?.cancel()
                pending = nil
            }
    }
}
