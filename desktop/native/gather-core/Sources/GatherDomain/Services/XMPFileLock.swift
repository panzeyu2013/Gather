// desktop/native/gather-core/Sources/GatherDomain/Services/XMPFileLock.swift
// Cut 2 / P0-1 收口：cleanup/finalize 的文件阶段与 WritebackService 写盘共用的
// 按 xmpPath 串行化锁。
//
// 背景：DeliveryCoordinator 的 revision/指纹守卫只能**事后**发现新输入，无法阻止
// 文件阶段（restore / remove / 写盘）本身与另一写者交错。旧备份一旦在新 XMP 落盘
// 之后恢复，就会把新内容覆盖回旧值（数据丢失）。本 actor 把「同一归一化侧车路径」
// 的文件阶段排成一条队列：
// - cleanup/finalize/replay 的 verify → restore/remove → 事后 verify 整体在锁内；
// - WritebackService 每个交付组的 backup → read → writeAttributes 在锁内；
// - LiveMetadataAPI 的 orphan restore/remove 的复核 → 文件 → 事后复核在锁内；
// - 不同路径互不阻塞，批次/顺序语义不变（执行仍按 xmpPath 排序分组）。
//
// 锁只覆盖文件阶段，绝不覆盖 DB 事务/await 之外的编排：调用方在锁内不得再次
// 以同一路径调用 run(path:)（锁不可重入，会自锁）。当前唯一嵌套面
// （writeGroupItems 内部不再取锁）已按此约束实现。

import Foundation
import GatherPersistence

/// 按归一化 xmpPath 串行化 XMP 文件阶段（进程内、跨服务共享）。
///
/// 用法：
/// ```swift
/// let value = try await fileLock.run(path: xmpPath) {
///     // 只放文件读写；不要在这里再取同一路径的锁。
/// }
/// ```
///
/// 同一把锁实例必须由组合根注入 DeliveryCoordinator、WritebackService 与
/// LiveMetadataAPI（生产：AppComposition 统一用 `.shared`；测试：显式构造同一
/// 实例）。默认 `.shared` 只用于缺省组合；多实例场景仍应显式共享，否则退化为
/// 无锁。
public actor XMPFileLock {
    /// 缺省共享实例：未显式注入的 coordinator/WritebackService 仍能互斥。
    public static let shared = XMPFileLock()

    /// 当前持有锁（含排队中已转交所有权）的归一化路径。
    private var active: Set<String> = []
    /// 每个路径的 FIFO 等待队列；release 时把所有权直接转交给队首。
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// 在 `path` 的文件锁内执行 `operation`，完成后释放（抛错同样释放）。
    ///
    /// - Parameter path: 侧车路径；内部用 `TSPath.normalize` 归一化，
    ///   因此 `./a.xmp` 与 `a.xmp` 视为同一把锁。
    /// - Parameter operation: 只能是文件阶段；返回的 `T` 需 Sendable。
    public func run<T: Sendable>(
        path: String,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let key = TSPath.normalize(path)
        await acquire(key)
        // 排队期间被取消：不再执行文件阶段，直接把所有权交给下一位。
        if Task.isCancelled {
            release(key)
            throw CancellationError()
        }
        do {
            let value = try await operation()
            release(key)
            return value
        } catch {
            release(key)
            throw error
        }
    }

    /// 只读探针（测试/诊断用）：该路径当前是否被持有或排队。
    public func isActive(path: String) -> Bool {
        active.contains(TSPath.normalize(path))
    }

    /// 当前等待某路径的调用数（测试用；不含持有者）。
    public func waiterCount(path: String) -> Int {
        waiters[TSPath.normalize(path)]?.count ?? 0
    }

    private func acquire(_ key: String) async {
        if !active.contains(key) {
            active.insert(key)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[key, default: []].append(continuation)
        }
    }

    /// 释放或把所有权转交给 FIFO 队首（active 保持 true，避免中间窗口被插队）。
    private func release(_ key: String) {
        guard var queue = waiters[key], !queue.isEmpty else {
            active.remove(key)
            return
        }
        let next = queue.removeFirst()
        if queue.isEmpty {
            waiters[key] = nil
        } else {
            waiters[key] = queue
        }
        next.resume()
    }
}
