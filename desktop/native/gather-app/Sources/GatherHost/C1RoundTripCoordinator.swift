// desktop/native/gather-app/Sources/GatherHost/C1RoundTripCoordinator.swift
// P1 下一波 / §3.10.1：Capture One 自动 reload 协调器。
//
// 职责（唯一职责）：把"交付状态变了"收敛成"最多一次、按批次一次"的 C1 reload。
//   · 只在批次**收敛**（pending/writing 归零、无冲突）且有 ≥1 条成功写回时动作；
//   · debounce 1.5s（同一批多次状态事件合并成一个定时器）；
//   · 串行：任何时刻最多一个 reload 在飞，后来的请求排队而不是并发（手动/自动共用队列）；
//   · 失败不风暴：同一批失败后抑制后续自动尝试，直到出现新的批次或用户手动重试；
//   · 失败可见：写入 lastFailure + 发 c1AutoReloadFailed 通知（UI 非阻塞提示 + 重试按钮）。
//
// 边界：
//   · 绝不在 delivery/execute 事务内调用（本类只由事件回调/用户按钮驱动）；
//   · 不写库：durable ack 由 CaptureOneBridge.reloadMetadata 内部写（既有语义）；
//   · 同时作为 UI 的 `any CaptureOneBridging`（纯委托），这样手动 reload 按钮与自动
//     reload 共用同一条串行队列，不会互相打架。
import Foundation
import GatherProtocol
import GatherUI

// MARK: - 输入/输出

/// 一次交付状态快照（由组合根从 culling.syncStatus 映射，见 signal(from:)）。
public struct C1DeliverySignal: Equatable, Sendable {
    public let sessionId: String
    public let written: Int
    public let failed: Int
    public let pending: Int
    public let writing: Int
    public let conflict: Int

    public init(
        sessionId: String,
        written: Int,
        failed: Int,
        pending: Int,
        writing: Int,
        conflict: Int
    ) {
        self.sessionId = sessionId
        self.written = written
        self.failed = failed
        self.pending = pending
        self.writing = writing
        self.conflict = conflict
    }

    /// 本批至少 1 条成功写回（plan §3.10.1 的门禁之一）。
    public var hasWork: Bool { written > 0 }

    /// 批次收敛：没有待写/在写/冲突。失败行不阻塞 reload（已写成功的行仍要刷新）。
    public var isSettled: Bool { pending == 0 && writing == 0 && conflict == 0 }
}

public struct C1AutoReloadSettings: Equatable, Sendable {
    /// c1_auto_reload == "1"（默认 1）。
    public var enabled: Bool
    /// 同一批状态事件的合并窗口（默认 1.5s，plan §3.10.1）。
    public var debounceMilliseconds: Int

    public init(enabled: Bool = true, debounceMilliseconds: Int = 1_500) {
        self.enabled = enabled
        self.debounceMilliseconds = max(0, debounceMilliseconds)
    }

    public static let `default` = C1AutoReloadSettings()
}

public enum C1AutoReloadSkipReason: String, Equatable, Sendable {
    /// c1_auto_reload=0。
    case autoReloadDisabled
    /// 预检不可达/无文档/未授权。
    case preflightUnavailable
    /// 本批没有成功写回的行。
    case noWrittenRows
    /// 仍在写入或存在冲突：等下一次状态事件。
    case notSettled
    /// 同一批已经失败过：不重试（避免风暴），等新批次或用户手动重试。
    case suppressedAfterFailure
}

public enum C1RoundTripOutcome: Equatable, Sendable {
    case reloaded(written: Int)
    case skipped(C1AutoReloadSkipReason)
    case failed(code: String, message: String)
}

public enum C1RoundTripError: Error, Equatable, CustomStringConvertible, Sendable {
    /// 预检不通过（手动 reload 用）：按缺什么给最贴近的既有码值。
    case preflightUnavailable(appRunning: Bool, documentOpen: Bool)
    case bridgeFailed(code: String, message: String)

    public var code: String {
        switch self {
        case .preflightUnavailable(let appRunning, let documentOpen):
            if !appRunning { return GatherErrorCode.C1_NOT_RUNNING.rawValue }
            if !documentOpen { return GatherErrorCode.C1_NO_DOCUMENT.rawValue }
            return GatherErrorCode.C1_NOT_AUTHORIZED.rawValue
        case .bridgeFailed(let code, _):
            return code
        }
    }

    public var description: String {
        switch self {
        case .preflightUnavailable(let appRunning, let documentOpen):
            let detail = !appRunning ? "Capture One 未运行"
                : (!documentOpen ? "Capture One 未打开文档" : "自动化权限不可用")
            return code + ": " + detail
        case .bridgeFailed(let code, let message):
            return message.isEmpty ? code : code + ": " + message
        }
    }
}

// MARK: - 协调器

/// 选中 / 调整提示的实现入口（生产：CaptureOneBridge 的两个方法）。
///
/// 用 Sendable 闭包而不是协议一致性：桥是 nonisolated 的 Sendable class，
/// 协调器是 @MainActor 状态机；闭包让两个隔离域各自保持原样，也便于测试注入。
public struct C1RoundTripExtras: Sendable {
    public let select: @Sendable ([String]) async throws -> C1SelectionOutcome
    public let hints: @Sendable ([String]) -> [C1AdjustmentHint]

    public init(
        select: @escaping @Sendable ([String]) async throws -> C1SelectionOutcome = { _ in
            C1SelectionOutcome(method: .appleScript, paths: [], notFound: [], appName: nil)
        },
        hints: @escaping @Sendable ([String]) -> [C1AdjustmentHint] = { paths in
            paths.map { C1AdjustmentHint.none(photoPath: $0) }
        }
    ) {
        self.select = select
        self.hints = hints
    }
}

@MainActor
public final class C1RoundTripCoordinator: C1RoundTripReloading {
    /// 生产 debounce（plan §3.10.1：1.5s）。
    public static let defaultDebounceMilliseconds = 1_500

    private let bridge: any CaptureOneBridging
    private let syncStatus: @MainActor (String) async throws -> CullingSyncStatus
    private let settings: @MainActor () -> C1AutoReloadSettings
    private let clock: @MainActor () -> String
    private let extras: C1RoundTripExtras

    /// debounce 定时器（同一批只保留最后一个）。
    private var debounceTask: Task<Void, Never>?
    /// 串行队列尾（手动/自动共用：任何时刻最多一个 reload 在飞）。
    private var lastOperation: Task<Void, Never>?
    /// 待 reload 的会话（合并同一批的多次事件；同一会话只排一次）。
    private var pendingSessions: [String] = []
    /// 失败抑制：sessionId → 失败时的 written 计数（同批不重试）。
    private var suppressed: [String: Int] = [:]

    /// 最近一次自动 reload 失败（nil = 没有未处理的失败）。
    public private(set) var lastFailure: C1AutoReloadFailure?
    /// 观测回调（组合根接日志/事件；测试断言用）。
    public var onStatus: (@MainActor (String, C1RoundTripOutcome) -> Void)?
    /// 实际执行成功的 reload 次数（验收：批次结束只 reload 一次）。
    public private(set) var reloadCount = 0

    public init(
        bridge: any CaptureOneBridging,
        syncStatus: @escaping @MainActor (String) async throws -> CullingSyncStatus,
        settings: @escaping @MainActor () -> C1AutoReloadSettings = { .default },
        clock: @escaping @MainActor () -> String = C1RoundTripCoordinator.defaultNow,
        extras: C1RoundTripExtras = C1RoundTripExtras()
    ) {
        self.bridge = bridge
        self.syncStatus = syncStatus
        self.settings = settings
        self.clock = clock
        self.extras = extras
    }

    // MARK: 事件入口

    /// 交付状态变化（组合根在 DeliveryCoordinator.eventSink 里调用）。
    /// 只排一个 debounce 定时器；同一会话的多次事件合并。
    public func noteDeliveryStateChanged(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        if !pendingSessions.contains(sessionId) { pendingSessions.append(sessionId) }
        debounceTask?.cancel()
        let delay = settings().debounceMilliseconds
        debounceTask = Task { @MainActor [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            }
            guard let self else { return }
            await self.drainAutoReloads()
        }
    }

    /// 立刻处理已排队的事件（测试/退出/设置变更后调用；不等 debounce）。
    public func flushPendingReloads() async {
        debounceTask?.cancel()
        debounceTask = nil
        await drainAutoReloads()
        await lastOperation?.value
    }

    /// 手动 reload（按钮）：与自动 reload 共用串行队列，失败抛错。
    public func reloadMetadata(sessionId: String) async throws {
        let outcome = await enqueue { await self.performManualReload(sessionId: sessionId) }
        publish(sessionId: sessionId, outcome: outcome)
        switch outcome {
        case .reloaded:
            return
        case .skipped(.preflightUnavailable):
            let status = await bridge.preflight()
            throw C1RoundTripError.preflightUnavailable(
                appRunning: status.appRunning, documentOpen: status.documentOpen)
        case .skipped:
            throw C1RoundTripError.bridgeFailed(
                code: GatherErrorCode.C1_SCRIPT_FAILED.rawValue, message: "reload 被跳过")
        case .failed(let code, let message):
            throw C1RoundTripError.bridgeFailed(code: code, message: message)
        }
    }

    /// 最近一次自动 reload 失败（UI 读它显示非阻塞提示）。
    public func currentAutoReloadFailure() -> C1AutoReloadFailure? { lastFailure }

    /// 清掉失败提示（用户已手动处理 / 回到同步条）。
    public func clearAutoReloadFailure() { lastFailure = nil }

    /// 关闭：取消定时器与排队（会话关闭时调用，避免晚到 reload）。
    public func shutdown() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingSessions.removeAll()
        lastOperation?.cancel()
        lastOperation = nil
    }

    // MARK: 自动路径

    private func drainAutoReloads() async {
        guard !pendingSessions.isEmpty else { return }
        let sessions = pendingSessions
        pendingSessions.removeAll()
        for sessionId in sessions {
            let outcome = await enqueue { await self.performAutoReload(sessionId: sessionId) }
            publish(sessionId: sessionId, outcome: outcome)
        }
    }

    private func performAutoReload(sessionId: String) async -> C1RoundTripOutcome {
        let config = settings()
        guard config.enabled else { return .skipped(.autoReloadDisabled) }
        let status: CullingSyncStatus
        do {
            status = try await syncStatus(sessionId)
        } catch {
            // 读状态失败不是 reload 失败：不写 lastFailure、不抑制（下次事件再来）。
            return .failed(
                code: GatherErrorCode.C1_SCRIPT_FAILED.rawValue,
                message: "读取同步状态失败: " + String(describing: error))
        }
        let signal = Self.signal(from: status, sessionId: sessionId)
        guard signal.hasWork else { return .skipped(.noWrittenRows) }
        guard signal.isSettled else { return .skipped(.notSettled) }
        if suppressed[sessionId] == signal.written { return .skipped(.suppressedAfterFailure) }
        let statusPreflight = await bridge.preflight()
        guard statusPreflight.reachable, statusPreflight.appRunning,
              statusPreflight.automationAuthorized, statusPreflight.documentOpen else {
            return .skipped(.preflightUnavailable)
        }
        do {
            try await bridge.reloadMetadata(sessionId: sessionId)
            reloadCount += 1
            suppressed.removeValue(forKey: sessionId)
            lastFailure = nil
            return .reloaded(written: signal.written)
        } catch {
            let failure = Self.failure(
                sessionId: sessionId, error: error, attemptedAt: clock())
            suppressed[sessionId] = signal.written
            lastFailure = failure
            NotificationCenter.default.post(
                name: Notification.Name.c1AutoReloadFailed, object: sessionId)
            return .failed(code: failure.code, message: failure.message)
        }
    }

    // MARK: 手动路径

    private func performManualReload(sessionId: String) async -> C1RoundTripOutcome {
        let status = await bridge.preflight()
        guard status.reachable, status.appRunning, status.documentOpen else {
            return .skipped(.preflightUnavailable)
        }
        do {
            try await bridge.reloadMetadata(sessionId: sessionId)
            reloadCount += 1
            suppressed.removeValue(forKey: sessionId)
            lastFailure = nil
            return .reloaded(written: 0)
        } catch {
            let failure = Self.failure(sessionId: sessionId, error: error, attemptedAt: clock())
            // 手动失败不进入抑制表：用户随时可以再点一次。
            lastFailure = failure
            return .failed(code: failure.code, message: failure.message)
        }
    }

    // MARK: 串行队列

    /// 排队执行：尾插到 `lastOperation` 之后，保证任何时刻最多一个 reload。
    private func enqueue(_ operation: @escaping @MainActor () async -> C1RoundTripOutcome) async -> C1RoundTripOutcome {
        let previous = lastOperation
        let task = Task { @MainActor () -> C1RoundTripOutcome in
            if let previous { _ = await previous.value }
            if Task.isCancelled { return .skipped(.suppressedAfterFailure) }
            return await operation()
        }
        lastOperation = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    private func publish(sessionId: String, outcome: C1RoundTripOutcome) {
        onStatus?(sessionId, outcome)
        switch outcome {
        case .reloaded(let written):
            GatherLogger.log(
                "c1.auto_reload session=\(sessionId) written=\(written) result=reloaded",
                level: .info)
        case .skipped(let reason):
            GatherLogger.log(
                "c1.auto_reload session=\(sessionId) result=skipped reason=\(reason.rawValue)",
                level: .info)
        case .failed(let code, let message):
            GatherLogger.log(
                "c1.auto_reload session=\(sessionId) result=failed code=\(code) detail=\(message)",
                level: .warn)
        }
    }

    // MARK: 映射/工具

    /// CullingSyncStatus → 交付信号（组合根/测试共用同一映射）。
    public static func signal(from status: CullingSyncStatus, sessionId: String) -> C1DeliverySignal {
        let summary = status.summary
        return C1DeliverySignal(
            sessionId: sessionId,
            written: summary.written,
            failed: summary.failed,
            pending: summary.pending,
            writing: summary.writing,
            conflict: summary.conflict)
    }

    static func failure(sessionId: String, error: Error, attemptedAt: String) -> C1AutoReloadFailure {
        let code = (error as? any CodedError)?.code.rawValue
            ?? GatherErrorCode.C1_SCRIPT_FAILED.rawValue
        return C1AutoReloadFailure(
            sessionId: sessionId,
            code: code,
            message: String(describing: error),
            attemptedAt: attemptedAt)
    }

    public static func defaultNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - 扩展能力（§3.10.2 / §3.10.3）

extension C1RoundTripCoordinator: C1RoundTripExtending {
    public func selectVariants(paths: [String]) async throws -> C1SelectionOutcome {
        try await extras.select(paths)
    }

    public func adjustmentHints(paths: [String]) -> [C1AdjustmentHint] {
        extras.hints(paths)
    }
}

// MARK: - 纯委托（让手动/自动 reload 共用同一串行队列）

extension C1RoundTripCoordinator: CaptureOneBridging {
    public func selectedPhotoPaths() async throws -> [String] {
        try await bridge.selectedPhotoPaths()
    }

    public func checkHealth() async -> Result<String, CaptureOneBridgeError> {
        await bridge.checkHealth()
    }

    public func preflight() async -> C1PreflightStatus {
        await bridge.preflight()
    }

    public nonisolated static func documentProbeScript(appName: String) -> String {
        CaptureOneBridge.documentProbeScript(appName: appName)
    }
}

