// desktop/native/gather-app/Tests/GatherAppTests/Support/AsyncWait.swift
// 测试共享：条件等待（替代固定 Task.sleep 的"等异步落定"写法）。
//
// 动机：`try? await Task.sleep(for: .milliseconds(200))` 这类固定睡眠既慢又脆——
// 睡眠长度是全套件并行调度下的"最坏情况余量"，短了会 flake，长了白等。
// 条件等待「满足即返回」，上限只是兜底超时，兼顾速度与稳健。
//
// 注意：本文件与 GatherCore 测试无关，仅在 GatherAppTests 模块内可见。

import Foundation

/// 兜底等待参数（P0-2 修复）。
///
/// 旧实现用 `Date()` 的 2s 墙钟：Swift Testing 默认并行时 MainActor 上同时排队
/// 数百个测试续体与轮询任务，2s 会被调度饥饿吃穿（本机整包并行 4/5 次在
/// `DuplicatesControlCenterAPITests:384` 2.0s 超时）。默认值放宽到 10s 只是
/// **失败上限**，正常路径仍「满足即返回」，不会拖慢全绿；超时始终有界。
/// 可用环境变量 `GATHER_TEST_WAIT_TIMEOUT`（秒）覆盖，夹在 0.1...60。
enum AsyncWaitDefaults {
    static let timeout: TimeInterval = {
        guard let raw = ProcessInfo.processInfo.environment["GATHER_TEST_WAIT_TIMEOUT"],
              let value = TimeInterval(raw), value.isFinite, value > 0
        else { return 10 }
        return min(max(value, 0.1), 60)
    }()

    /// 首次轮询间隔（秒）；被测防抖注入值通常也是 5ms。
    static let initialInterval: TimeInterval = 0.005

    /// 退避上限（秒）：并行满载时降低等待者的唤醒频率，避免轮询自己把
    /// 被测任务挤出 MainActor 调度。
    static let maxInterval: TimeInterval = 0.1
}

/// 轮询等待条件成立（async 版：Task.sleep 让出 MainActor，被测 VM 的
/// debounce / 轮询 / 取数 Task 才能推进）。
///
/// Swift 6 迁移：本 helper 标注 @MainActor —— 条件闭包普遍捕获 @MainActor
/// 被测 VM/单例状态（MainActor 隔离闭包会被推断为非 Sendable），若 helper 是
/// nonisolated @concurrent，把闭包传进去即构成「发送非 Sendable 的 MainActor
/// 隔离值」。本文件所有调用方（Gallery/Library/Similarity/GlobalInfra 用例）
/// 都已在 MainActor 上运行，条件求值也必须在 MainActor 上读 VM 状态。
///
/// - Parameters:
///   - timeout: 兜底超时（秒）；正常路径远早于此返回。
///   - interval: 首次轮询间隔（秒），随后指数退避到 `AsyncWaitDefaults.maxInterval`。
/// - Returns: 条件最终是否成立。**调用方必须断言返回值**（`#expect(await ...)`
///   或 `try #require(await ...)`），不得 `_ =` 丢弃后继续断言派生状态。
@MainActor
@discardableResult
func waitUntilAsync(
    timeout: TimeInterval = AsyncWaitDefaults.timeout,
    interval: TimeInterval = AsyncWaitDefaults.initialInterval,
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    let limit = max(timeout, 0)
    var current = max(interval, 0.001)
    while true {
        if condition() { return true }
        // 测试被取消（例如 #expect 失败后提前收尾）时立即结束，不再空转到上限。
        if Task.isCancelled { return false }
        if limit <= 0 || clock.now - start >= .seconds(limit) { return false }
        try? await Task.sleep(for: .seconds(current))
        current = min(current * 2, AsyncWaitDefaults.maxInterval)
    }
}

/// 有界「负向」观察窗口：条件无法「满足即返回」（断言的是"窗口内不得发生 X"），
/// 故必须等满窗口——但窗口只需覆盖被测的防抖/轮询周期，而非拍脑袋的长睡眠。
func awaitNegativeWindow(_ duration: Duration) async {
    try? await Task.sleep(for: duration)
}
