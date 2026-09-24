// desktop/native/gather-core/Sources/GatherCore/Runtime/Support/ConcurrentMap.swift
// W2a 前置：并发原语收敛（Runtime/Support/）。
//
// 取代 Services/DuplicateService.swift 的 `batchAsync`（约 714-744 行）与
// Services/QualityService.swift 的 `mapConcurrent`（约 593-622 行）两份逐字拷贝，
// 同时取代两处的锁游标 BatchCursor / QualityBatchCursor（含 unchecked 标注）。
//
// 语义（与两份旧实现逐条对齐，TS utils/async.ts batchAsync 的滑动窗口）：
// - 常驻 runner 数 = min(max(1, concurrency), items.count)：滑动窗口，慢项不阻塞整批；
// - 共享游标取号：每个 runner 完成一项后立刻取下一项，不为批次栅栏等待；
// - 结果按输入索引升序收集（完成序无关），返回 [R] 与输入等长；
// - 首个失败：命中错误的 runner 先 markFailed 再抛出，其余 runner 取号即止、
//   在飞项跑完；错误按完成序取第一个（task group 语义），原始错误类型不被包装；
// - 取消：父任务取消传播到子任务，runner 在 `Task.isCancelled` 处停取新项；
//   body 若因取消抛错则按普通错误传播（经 markFailed + task group 重抛），
//   否则在飞项跑完后返回已收集的部分结果（与旧实现一致，不额外抛 CancellationError）；
// - 空输入立即返回 []。
//
// 约束：本文件禁止 SQL 文本（Runtime 门禁）、禁止任何锁原语、禁止 unchecked Sendable 标注。

import Foundation

/// 保序滑动窗口并发执行（TS batchAsync 的 Swift 对应物）。
///
/// `run` 是唯一入口；调用方闭包在组内子任务中并发执行，异常经 task group 原样传播。
public enum ConcurrentMap {

    /// 以最多 `concurrency` 个常驻 runner 并发映射 `items`，结果保持输入顺序。
    ///
    /// - Parameters:
    ///   - items: 输入序列（索引即结果位置；元素仅在 runner 内按索引读取）。
    ///   - concurrency: runner 数上限；<= 0 时按 1 处理，超过输入数时按输入数处理。
    ///   - body: 单项处理闭包；抛出的错误触发「停止调度 + 传播」。
    /// - Returns: 与 `items` 等长、按输入索引升序的映射结果。
    /// - Throws: `body` 抛出的第一个错误；取消不会额外包装。
    public static func run<T, R>(
        _ items: [T],
        concurrency: Int,
        body: @escaping (T) async throws -> R
    ) async throws -> [R] {
        let limit = max(1, concurrency)
        guard !items.isEmpty else { return [] }
        let cursor = IndexCursor(count: items.count)
        var collected: [(index: Int, value: R)] = []
        try await withThrowingTaskGroup(of: [(Int, R)].self) { group in
            for _ in 0..<min(limit, items.count) {
                group.addTask {
                    var local: [(Int, R)] = []
                    while !Task.isCancelled {
                        guard let index = await cursor.nextIndex() else { break }
                        do {
                            local.append((index, try await body(items[index])))
                        } catch {
                            // 首个失败：停止调度（在飞项跑完后自然退出），原样抛错。
                            await cursor.markFailed()
                            throw error
                        }
                    }
                    return local
                }
            }
            for try await chunk in group {
                collected.append(contentsOf: chunk)
            }
        }
        collected.sort { $0.index < $1.index }
        return collected.map(\.value)
    }
}

/// 共享取号游标（actor 化）：runner 从中取下一个未分配项索引；失败后停止调度。
///
/// 取代旧实现的 `BatchCursor` / `QualityBatchCursor`（锁 + unchecked Sendable 标注）；
/// actor 隔离保证 `nextIndex` / `markFailed` 的线性一致性，无锁、无标注。
public actor IndexCursor {
    private let count: Int
    private var next = 0
    private var failed = false

    /// - Parameter count: 可分配索引总数（负值按 0 处理）。
    public init(count: Int) {
        self.count = max(0, count)
    }

    /// 取下一个未分配索引；已失败或已耗尽返回 nil。
    ///
    /// 每次成功调用独占一个索引（调用即分配，不回收），因此并发调用不会重复取号。
    public func nextIndex() -> Int? {
        guard !failed, next < count else { return nil }
        defer { next += 1 }
        return next
    }

    /// 标记失败：此后 `nextIndex` 一律返回 nil（在飞项不受影响）；幂等。
    public func markFailed() {
        failed = true
    }
}
