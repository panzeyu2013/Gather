// desktop/native/gather-app/Tests/GatherAppTests/C1RoundTripTests.swift
// C7：Capture One 桥的脚本 `error:<msg>` 报告解析——报错必须当"脚本失败"，
//     既不能被当成"没匹配到"（→ notFound），也不能落到 open -a 兜底（可能整批导入）。
// C4：C1RoundTripCoordinator 的自动 reload 收敛判据——没装 C1 时连 preflight 都不做、
//     notSettled 重试后整批只 reload 一次、持续 notSettled 的重试有上限（不自旋）。
//
// 全程用**协议替身**：替身只实现 CaptureOneBridging 的五个要求，构造与驱动过程
// 不 spawn 任何进程（不碰 osascript / System Events），所以能与其它 app 用例并行跑。
// 记账状态一律放在 LockedBox 里、每个用例各一份——本 target 的用例并行执行，
// 任何静态可变状态都会让断言互相污染。

import Foundation
import Testing
import GatherProtocol
import GatherTestSupport
@testable import GatherHost

// MARK: - C7：脚本 error 报告

/// 只测纯函数 reportedScriptError(in:)（不建桥、不 spawn、不读库）。
@Suite("C1 桥：脚本 error 报告解析（C7）")
struct C1ScriptErrorReportingTests {
    @Test("\"error:not running\" → 非 nil，并带上消息体")
    func parsesErrorReport() {
        let message = CaptureOneBridge.reportedScriptError(in: "error:not running")
        #expect(message != nil)
        // 前缀本身要被剥掉：抛错文案里再带一次 "error:" 只是噪音。
        #expect(message == "not running")
        #expect(message?.hasPrefix("error:") == false)
    }

    @Test("空消息体（\"error:\"）→ 非 nil 且不是空串")
    func emptyMessageFallsBack() {
        // 为什么要有兜底：AppleScript 的 `(theErr as text)` 可能给空串，抛一条
        // 空消息的错误会让 UI 只剩码值、看不出发生了什么。
        let message = CaptureOneBridge.reportedScriptError(in: "error:")
        #expect(message != nil)
        #expect(message?.isEmpty == false)
        #expect(message?.hasPrefix("error:") == false)
    }

    @Test("\"1\\n0\\n\" 与 \"0\\n0\" 是逐路径报告，不是错误")
    func numericReportsAreNotErrors() {
        #expect(CaptureOneBridge.reportedScriptError(in: "1\n0\n") == nil)
        #expect(CaptureOneBridge.reportedScriptError(in: "0\n0") == nil)
        // 单行 "1"/"0" 同样是正常报告（单路径选中 / 未选中）。
        #expect(CaptureOneBridge.reportedScriptError(in: "1") == nil)
        #expect(CaptureOneBridge.reportedScriptError(in: "0") == nil)
    }

    @Test("前导空白 + error: → 仍命中（判开头前先 trim）")
    func leadingWhitespaceStillParsed() {
        let message = CaptureOneBridge.reportedScriptError(in: "  \n\terror:-1728")
        #expect(message != nil)
        #expect(message == "-1728")
        #expect(message?.contains("error") == false)
    }

    @Test("消息中间出现 error: → nil（只认整段开头，不用 contains）")
    func midReportErrorIsNotErrorReport() {
        // 为什么：路径/消息里恰好含 "error:" 的批次不能被整批判成脚本失败。
        #expect(CaptureOneBridge.reportedScriptError(in: "1\nerror:x") == nil)
        #expect(CaptureOneBridge.reportedScriptError(in: "0\nerror:x\n1") == nil)
        #expect(CaptureOneBridge.reportedScriptError(in: "1\n0\nerror:") == nil)
    }
}

// MARK: - C4：自动 reload 协调器

/// CaptureOneBridging 的测试替身：只记账 + 回固定的预检结果，绝不 spawn。
///
/// `@unchecked Sendable` + LockedBox：协议继承 Sendable，而计数要跨隔离域
/// （协调器在 MainActor 上调用，协议方法本身 nonisolated async）。
private final class C1BridgeStub: CaptureOneBridging, @unchecked Sendable {
    struct State {
        /// preflight 被调用次数（P1-10 的核心断言：没装 C1 时必须是 0）。
        var preflightCalls = 0
        /// reloadMetadata 收到的 sessionId 序列（同一批只能出现一次）。
        var reloadSessionIds: [String] = []
        var preflightStatus: C1PreflightStatus
    }

    /// 四层全过（自动 reload 只有全过才真的 reload）。
    static let ready = C1PreflightStatus(
        reachable: true,
        appRunning: true,
        automationAuthorized: true,
        documentOpen: true,
        timedOut: false)

    private let box: LockedBox<State>

    init(preflightStatus: C1PreflightStatus = C1BridgeStub.ready) {
        self.box = LockedBox(State(preflightStatus: preflightStatus))
    }

    var preflightCalls: Int { box.lock.withLock { box.preflightCalls } }
    var reloadSessionIds: [String] { box.lock.withLock { box.reloadSessionIds } }

    func selectedPhotoPaths() async throws -> [String] { [] }

    func reloadMetadata(sessionId: String) async throws {
        box.lock.withLock { box.reloadSessionIds.append(sessionId) }
    }

    func checkHealth() async -> Result<String, CaptureOneBridgeError> { .success("stub") }

    func preflight() async -> C1PreflightStatus {
        box.lock.withLock {
            box.preflightCalls += 1
            return box.preflightStatus
        }
    }

    static func documentProbeScript(appName: String) -> String { "stub-probe:" + appName }
}

/// 一次用例内的可变记账（每用例一份，绝不共享）。
private struct C1Bookkeeping {
    /// syncStatus 被读了几次 = 协调器真的推进了几步状态机。
    var syncCalls = 0
    /// 依次返回的状态；用尽后回落到用例给的兜底状态。
    var statuses: [CullingSyncStatus] = []
    /// onStatus 观测到的结果（按发生顺序）。
    var outcomes: [C1RoundTripOutcome] = []
}

@Suite("C1 自动 reload 协调器（C4 收敛判据）")
@MainActor
struct C1RoundTripCoordinatorTests {
    /// 收敛：written>0、pending/writing/conflict 全 0。
    private static func settled(written: Int = 2) -> CullingSyncStatus {
        CullingSyncStatus(summary: summary(written: written))
    }

    /// 未收敛：written>0 但还有 pending（仍能证明"有成功写回"，只是没排空）。
    private static func notSettled(written: Int = 2) -> CullingSyncStatus {
        CullingSyncStatus(summary: summary(written: written, pending: 1))
    }

    private static func summary(written: Int, pending: Int = 0) -> MetadataSyncSummary {
        MetadataSyncSummary(
            sessionId: "s1",
            pending: pending,
            writing: 0,
            written: written,
            failed: 0,
            conflict: 0,
            synced: 0,
            items: [])
    }

    /// 重试用例的 debounce：拉长到 60s，让每条重试定时器都被下一次 flush 立即取消。
    ///
    /// 为什么不注入 0/10ms：0 延迟的重试定时器会和测试里的 flush 抢同一个
    /// pendingSessions 队列（两次 drain 谁先跑不确定），"推进了几步"就成了
    /// 有时 N 有时 N+1。拉长后每条定时器都被 flush 取消，用例仍在毫秒级，
    /// 但每次 flush 恰好推进一个状态机步骤，断言可以写精确次数。
    private static let stepDebounce = C1AutoReloadSettings(
        enabled: true, debounceMilliseconds: 60_000)

    /// 造一个把状态序列喂给协调器的 syncStatus 闭包（读一次换一个，用尽后回落到 fallback）。
    private static func statusSource(
        book: LockedBox<C1Bookkeeping>,
        fallback: CullingSyncStatus
    ) -> @MainActor (String) async throws -> CullingSyncStatus {
        { _ in
            book.lock.withLock {
                book.syncCalls += 1
                return book.statuses.isEmpty ? fallback : book.statuses.removeFirst()
            }
        }
    }

    @Test("未安装 Capture One → 不读库、不 preflight，状态报 c1Unavailable")
    func unavailableShortCircuits() async {
        let bridge = C1BridgeStub()
        let book = LockedBox(C1Bookkeeping(statuses: [Self.settled()]))
        let coordinator = C1RoundTripCoordinator(
            bridge: bridge,
            syncStatus: Self.statusSource(book: book, fallback: Self.settled()),
            isC1Installed: { false },
            settings: { C1AutoReloadSettings() })
        coordinator.onStatus = { _, outcome in
            book.lock.withLock { book.outcomes.append(outcome) }
        }

        coordinator.noteDeliveryStateChanged(sessionId: "s1")
        await coordinator.flushPendingReloads()

        // 不装 C1 时连 debounce 定时器都不排：preflight（唯一的 spawn 点）必须是 0。
        let syncCalls = book.lock.withLock { book.syncCalls }
        let outcomes = book.lock.withLock { book.outcomes }
        #expect(bridge.preflightCalls == 0)
        #expect(syncCalls == 0)
        #expect(coordinator.reloadCount == 0)
        #expect(bridge.reloadSessionIds.isEmpty)
        // 原因按实际 enum 断言（没装 C1 + 自动 reload 开着 → .c1Unavailable）。
        #expect(outcomes == [.skipped(.c1Unavailable)])
        #expect(coordinator.lastFailure == nil)
    }

    @Test("没装 C1 且用户关掉自动 reload → 报 autoReloadDisabled（用户设置优先）")
    func disabledSettingWinsWhenUnavailable() async {
        let bridge = C1BridgeStub()
        let book = LockedBox(C1Bookkeeping())
        let coordinator = C1RoundTripCoordinator(
            bridge: bridge,
            syncStatus: Self.statusSource(book: book, fallback: Self.settled()),
            isC1Installed: { false },
            settings: { C1AutoReloadSettings(enabled: false) })
        coordinator.onStatus = { _, outcome in
            book.lock.withLock { book.outcomes.append(outcome) }
        }

        coordinator.noteDeliveryStateChanged(sessionId: "s1")
        await coordinator.flushPendingReloads()

        let outcomes = book.lock.withLock { book.outcomes }
        let syncCalls = book.lock.withLock { book.syncCalls }
        #expect(outcomes == [.skipped(.autoReloadDisabled)])
        #expect(bridge.preflightCalls == 0)
        #expect(syncCalls == 0)
        #expect(coordinator.reloadCount == 0)
    }

    @Test("notSettled 重试后收敛 → 整批只 reload 一次")
    func retryThenReloadsExactlyOnce() async {
        let bridge = C1BridgeStub()
        // 第一次读到"还有 pending"，重试时读到收敛（written 不变 = 同一批，不重置上限）。
        let book = LockedBox(C1Bookkeeping(statuses: [Self.notSettled()]))
        let coordinator = C1RoundTripCoordinator(
            bridge: bridge,
            syncStatus: Self.statusSource(book: book, fallback: Self.settled()),
            settings: { Self.stepDebounce })
        coordinator.onStatus = { _, outcome in
            book.lock.withLock { book.outcomes.append(outcome) }
        }

        coordinator.noteDeliveryStateChanged(sessionId: "s1")
        await coordinator.flushPendingReloads()   // 第 1 步：notSettled → 只排重试
        #expect(coordinator.reloadCount == 0)
        #expect(bridge.preflightCalls == 0)

        await coordinator.flushPendingReloads()   // 第 2 步：settled → preflight + reload
        await coordinator.flushPendingReloads()   // 第 3 步：无事可做，不能二次 reload

        // 验收口径：批次收敛后整批只 reload 一次（C1 里不会反复 Load Metadata）。
        let syncCalls = book.lock.withLock { book.syncCalls }
        let outcomes = book.lock.withLock { book.outcomes }
        #expect(coordinator.reloadCount == 1)
        #expect(bridge.reloadSessionIds == ["s1"])
        #expect(syncCalls == 2)
        #expect(bridge.preflightCalls == 1)
        #expect(outcomes == [.skipped(.notSettled), .reloaded(written: 2)])
        #expect(coordinator.lastFailure == nil)
    }

    @Test("持续 notSettled → 重试到上限就停（不自旋，也不算失败）")
    func persistentNotSettledStopsRetrying() async {
        let bridge = C1BridgeStub()
        // statuses 恒空 → 每次都回落到 notSettled（永远读不到收敛）。
        let book = LockedBox(C1Bookkeeping())
        let coordinator = C1RoundTripCoordinator(
            bridge: bridge,
            syncStatus: Self.statusSource(book: book, fallback: Self.notSettled()),
            settings: { Self.stepDebounce })
        coordinator.onStatus = { _, outcome in
            book.lock.withLock { book.outcomes.append(outcome) }
        }

        coordinator.noteDeliveryStateChanged(sessionId: "s1")
        // 初始 1 次 + maxSettleRetries 次重试 = 上界；多 flush 几次证明"已经停了"。
        for _ in 0..<(C1RoundTripCoordinator.maxSettleRetries + 3) {
            await coordinator.flushPendingReloads()
        }

        let syncCalls = book.lock.withLock { book.syncCalls }
        let outcomes = book.lock.withLock { book.outcomes }
        #expect(syncCalls == C1RoundTripCoordinator.maxSettleRetries + 1)
        #expect(outcomes.count == syncCalls)
        #expect(outcomes.allSatisfy { $0 == .skipped(.notSettled) })
        // 从未收敛 → 从不 preflight、从不 reload。
        #expect(bridge.preflightCalls == 0)
        #expect(coordinator.reloadCount == 0)
        // 放弃之后不再自旋：再 flush 一次也不会多读状态。
        await coordinator.flushPendingReloads()
        #expect(book.lock.withLock { book.syncCalls } == syncCalls)
        // 放弃等待 ≠ 写回失败：不写 lastFailure（否则会误报"未重载"）。
        #expect(coordinator.lastFailure == nil)
    }
}
