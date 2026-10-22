// desktop/native/gather-core/Tests/GatherTestSupport/AsyncGate.swift
// GatherTestSupport：可控放行闸（Cut 3 / 3a-4 迁入；原 Tests/GatherCoreTests/Support/AsyncGate.swift）。
// 原 CL-12 收口：DuplicateServiceTests / FaceKeywordingServiceTests / SimilarityServiceTests
// 三份逐字相同的私有实现合并。
//
// 幂等等待门：swift-testing 并行下 Task 调度延迟明显，用它替代固定 sleep。
//
// 线程安全说明（Swift 6 Sendable）：`continuations`/`released` 只在 `lock`（NSLock）
// 临界区内读写；门会被 @Sendable 的 thumbnailProvider / inference 闭包捕获
// （Duplicate/Similarity 两处必须），故统一标注 @unchecked（锁纪律无法被编译器
// 静态验证）。FaceKeywordingServiceTests 原本不要求该 conformance；附带它不改变
// 运行语义。

import Foundation

public final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    public init() {}

    public func wait() async {
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

    public func release() {
        lock.lock()
        released = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}
