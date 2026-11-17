// desktop/native/gather-core/Tests/GatherTestSupport/AsyncWait.swift
// GatherTestSupport：异步条件等待（2026-11-17 第二轮测试卫生审计）。
//
// 背景：三个 core 测试文件（FaceKeywordingServiceTests / DuplicateServiceTests /
// SimilarityServiceTests）各自复制了一份同步轮询 helper——用 Thread.sleep(0.02)
// 在 while 循环里等条件成立。在 async 测试里调用它会**阻塞协作线程池**（其它
// 并发用例的续体排不上队），且 Deadline 用墙钟 Date() 计算。这里统一为一份
// 异步 helper：Task.sleep 让出执行权，ContinuousClock 单调计时，超时返回最后
// 一次求值结果（调用方必须断言返回值，不得 `_ =` 丢弃）。
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
