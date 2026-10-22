// desktop/native/gather-core/Tests/GatherTestSupport/Support/LockedBox.swift
// GatherTestSupport：NSLock 保护的锁盒（WP7 从 gather-app 的
// Tests/GatherAppTests/Support/LockedBox.swift 迁入，app 侧删除副本）。
//
// 目录说明：放在 Support/ 子目录是为了满足 scripts/check-duplicate-symbols.sh 的
// "LockedBox 声明必须位于 Tests/**/Support/" 路径约定（脚本只看路径，不看 target 名）；
// GatherTestSupport 本身就是测试夹具 target。
//
// 用法与旧 app 私有实现完全相同：
//
//     private struct BoxState { var result: String? }
//     private let box = LockedBox(BoxState())
//     box.lock.withLock { box.result = "x" }
//
// 线程语义：锁盒**不会**自动加锁，所有字段访问必须由调用方显式包在
// `lock.withLock` 里；动态成员只是把字段读写转发给内部 state。

import Foundation

@dynamicMemberLookup
public final class LockedBox<State>: @unchecked Sendable {
    public let lock = NSLock()
    private var state: State

    public init(_ state: State) {
        self.state = state
    }

    /// 字段读写转发（必须在 `lock.withLock` 临界区内使用）。
    public subscript<T>(dynamicMember keyPath: WritableKeyPath<State, T>) -> T {
        get { state[keyPath: keyPath] }
        set { state[keyPath: keyPath] = newValue }
    }
}
