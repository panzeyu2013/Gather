// desktop/native/gather-core/Tests/GatherTestSupport/AsyncWait.swift
// GatherTestSupport：异步条件等待（2026-11-17 第二轮测试卫生审计；Wave 5 / M15 合并 app 增强版）。
//
// 背景：三个 core 测试文件（FaceKeywordingServiceTests / DuplicateServiceTests /
// SimilarityServiceTests）各自复制了一份同步轮询 helper——用 Thread.sleep(0.02)
// 在 while 循环里等条件成立。在 async 测试里调用它会**阻塞协作线程池**（其它
// 并发用例的续体排不上队），且 Deadline 用墙钟 Date() 计算。这里统一为一份
// 异步 helper：Task.sleep 让出执行权，ContinuousClock 单调计时，超时返回最后
// 一次求值结果（调用方必须断言返回值，不得 `_ =` 丢弃）。
//
// M15 去重：原先 gather-app/Tests/GatherAppTests/Support/AsyncWait.swift 有一份
// 增强版（AsyncWaitDefaults 环境变量 + 指数退避 + @MainActor + awaitNegativeWindow），
// 与本文件的两个 core helper 并存。现合并到本文件（core 侧两个函数保留，避免破坏
// core 测试），app 副本已删除；app 测试统一 import GatherTestSupport。
//
// 归位说明：放 GatherTestSupport（core/app 测试共享的普通 library target），
// 不 import Testing，故用普通函数 + Bool 返回值，而不是 #expect/#require。
import Foundation

/// 轮询等待**同步**条件成立：满足即返回 true；超时返回最后一次求值结果。
///
/// - Parameters:
///   - timeout: 兜底超时（秒）。正常路径「满足即返回」，该值只是失败上限。
///   - interval: 轮询间隔（秒）；过小会让并行套件空转，过大增加正常路径延迟。
///   - condition: 条件求值；抛错时原样抛出（rethrows），由调用方决定失败方式。
public func waitUntilCondition(
    timeout: TimeInterval = 5,
    interval: TimeInterval = 0.02,
    _ condition: () throws -> Bool
) async rethrows -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    let limit = max(timeout, 0)
    let step = max(interval, 0.001)
    while true {
        if try condition() { return true }
        // 测试被取消（例如 #expect 失败后提前收尾）时立即结束，不再空转到上限。
        if Task.isCancelled { return false }
        if limit <= 0 || clock.now - start >= .seconds(limit) {
            return try condition()
        }
        try? await Task.sleep(for: .seconds(step))
    }
}

/// 轮询等待**异步**条件成立（actor/异步探针用；语义同 `waitUntilCondition`）。
public func waitUntilConditionAsync(
    timeout: TimeInterval = 5,
    interval: TimeInterval = 0.02,
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    let limit = max(timeout, 0)
    let step = max(interval, 0.001)
    while true {
        if await condition() { return true }
        if Task.isCancelled { return false }
        if limit <= 0 || clock.now - start >= .seconds(limit) {
            return await condition()
        }
        try? await Task.sleep(for: .seconds(step))
    }
}

// MARK: - app 侧增强版（M15 合并：原 GatherAppTests/Support/AsyncWait.swift）

/// 兜底等待参数（P0-2 修复）。
///
/// 旧实现用 `Date()` 的 2s 墙钟：Swift Testing 默认并行时 MainActor 上同时排队
/// 数百个测试续体与轮询任务，2s 会被调度饥饿吃穿（本机整包并行 4/5 次在
/// `DuplicatesControlCenterAPITests:384` 2.0s 超时）。默认值放宽到 10s 只是
/// **失败上限**，正常路径仍「满足即返回」，不会拖慢全绿；超时始终有界。
/// 可用环境变量 `GATHER_TEST_WAIT_TIMEOUT`（秒）覆盖，夹在 0.1...60。
public enum AsyncWaitDefaults {
    public static let timeout: TimeInterval = {
        guard let raw = ProcessInfo.processInfo.environment["GATHER_TEST_WAIT_TIMEOUT"],
              let value = TimeInterval(raw), value.isFinite, value > 0
        else { return 10 }
        return min(max(value, 0.1), 60)
    }()

    /// 首次轮询间隔（秒）；被测防抖注入值通常也是 5ms。
    public static let initialInterval: TimeInterval = 0.005

    /// 退避上限（秒）：并行满载时降低等待者的唤醒频率，避免轮询自己把
    /// 被测任务挤出 MainActor 调度。
    public static let maxInterval: TimeInterval = 0.1
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
public func waitUntilAsync(
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
public func awaitNegativeWindow(_ duration: Duration) async {
    try? await Task.sleep(for: duration)
}
