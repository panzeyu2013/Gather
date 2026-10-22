// desktop/native/gather-app/Tests/GatherAppTests/Support/AsyncGate.swift
// 测试共享：可控放行闸（app target 单份；core 侧同名 helper 在
// GatherCoreTests/Support/AsyncGate.swift —— 两个测试 target 不能互相 import）。
//
// 幂等等待门：swift-testing 并行下 Task 调度延迟明显，用它替代固定 sleep。
// 本 target 的调用点没有 @Sendable 捕获，故不附加 @unchecked Sendable，
// 与合并前 app 侧声明保持一致。

import Foundation

final class AsyncGate {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        let mustWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if released { return false }
            return true
        }()
        guard mustWait else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}
