// desktop/native/gather-app/Tests/GatherAppTests/Support/AsyncWait.swift
// 测试共享：条件等待（替代固定 Task.sleep 的"等异步落定"写法）。
//
// 动机：`try? await Task.sleep(for: .milliseconds(200))` 这类固定睡眠既慢又脆——
// 睡眠长度是全套件并行调度下的"最坏情况余量"，短了会 flake，长了白等。
// 条件等待「满足即返回」，上限只是兜底超时，兼顾速度与稳健。
//
// 注意：本文件与 GatherCore 测试无关，仅在 GatherAppTests 模块内可见。

import Foundation

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
///   - interval: 轮询间隔（秒）；默认 5ms（被测防抖注入值通常也是 5ms）。
/// - Returns: 条件最终是否成立（调用方仍应保留原有的显式断言，见各用例）。
@MainActor
@discardableResult
func waitUntilAsync(
    timeout: TimeInterval = 2,
    interval: TimeInterval = 0.005,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if condition() { return true }
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
    }
}

/// 有界「负向」观察窗口：条件无法「满足即返回」（断言的是"窗口内不得发生 X"），
/// 故必须等满窗口——但窗口只需覆盖被测的防抖/轮询周期，而非拍脑袋的长睡眠。
func awaitNegativeWindow(_ duration: Duration) async {
    try? await Task.sleep(for: duration)
}
