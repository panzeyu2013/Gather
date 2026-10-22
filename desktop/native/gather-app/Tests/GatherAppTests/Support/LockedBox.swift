// desktop/native/gather-app/Tests/GatherAppTests/Support/LockedBox.swift
// 测试共享：NSLock 保护的锁盒（CL-12 收口；原 Similarity/Library/Gallery 三份
// 私有 LockedBox 合并为这一份）。
//
// 用法与旧私有实现完全相同：
//
//     private struct BoxState { var result: String? }
//     private let box = LockedBox(BoxState())
//     box.lock.withLock { box.result = "x" }
//
// 线程语义：与旧实现一致 —— 锁盒**不会**自动加锁，所有字段访问必须由调用方
// 显式包在 `lock.withLock` 里；动态成员只是把字段读写转发给内部 state。
// 旧实现暴露裸字段、同样依赖调用方持锁，因此这里没有放宽/收紧任何约束。

import Foundation

@dynamicMemberLookup
final class LockedBox<State>: @unchecked Sendable {
    let lock = NSLock()
    private var state: State

    init(_ state: State) {
        self.state = state
    }

    /// 字段读写转发（必须在 `lock.withLock` 临界区内使用）。
    subscript<T>(dynamicMember keyPath: WritableKeyPath<State, T>) -> T {
        get { state[keyPath: keyPath] }
        set { state[keyPath: keyPath] = newValue }
    }
}
