// desktop/native/gather-core/Sources/GatherPersistence/Support/BatchCursor.swift
// 批量并发调度的共享取号游标（内部实现，唯一真相源）。
//
// 合并背景：合并前 MetadataSyncCoordinator / IndexerService / QualityService /
// DuplicateService / WritebackService / MetadataService 各自持有一份逐字节同构的
// 私有游标（BatchCursor / QualityBatchCursor / WritebackBatchCursor /
// MetadataBatchCursor），语义完全一致（滑动窗口 + 首个失败停止调度）。本文件是
// 唯一实现；调度侧（worker 池、错误传播、保序）见同目录 BatchRunner.swift。
import Foundation

/// 固定数量常驻 worker 共用的取号游标：每个 worker 从游标取下一个未分配索引，
/// 取完为止（滑动窗口，慢项不阻塞整批）。
///
/// 不变量：
/// - **不重不漏**：0..<count 中每个索引在一批内至多被取到一次；未失败时全部会被
///   取到。`nextIndex()` 返回 nil 只表示「当前没有可取的号」（取完或已停发），
///   不代表该 worker 失败。
/// - **失败停止发号**（默认，也是本仓库全部 6 个调用点的语义）：任一 worker 调用
///   `markFailed()` 后，其余 worker 的 `nextIndex()` 立刻返回 nil——在飞项照常跑完，
///   失败后不再产生新的副作用；错误由抛出方经 task group 传播给调用方。这一条
///   与「Task.isCancelled 检查」互补：取消传播存在时间窗，游标停发把它封死。
/// - **并发安全**：`nextIndex()` / `markFailed()` 由同一把 NSLock 保护，可从任意
///   task/线程并发调用；`@unchecked Sendable` 的依据正是「全部可变状态都在锁内」。
final class BatchCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var failed = false
    private let count: Int
    private let advanceOnFailure: Bool

    /// - Parameters:
    ///   - count: 一批的项数（通常是 `items.count`）。
    ///   - advanceOnFailure: 失败后是否继续发号。false（默认）＝首个失败即停止调度
    ///     （见类型文档）；true＝`markFailed()` 只记录事实，剩余索引仍照常发完——
    ///     仅当调用方自行汇总单条错误、不向 task group 抛出时才具备「单条失败不
    ///     阻断整批」的效果（否则 task group 的取消仍会让 worker 在
    ///     `Task.isCancelled` 处停下）。无论取值如何，已取走的号都不回退、不重发。
    init(count: Int, advanceOnFailure: Bool = false) {
        self.count = count
        self.advanceOnFailure = advanceOnFailure
    }

    /// 取下一个索引；没有可取的号时返回 nil。
    func nextIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if failed && !advanceOnFailure { return nil }
        guard next < count else { return nil }
        defer { next += 1 }
        return next
    }

    /// 标记本批已有 worker 失败（幂等）：默认语义下从此不再向任何 worker 发号。
    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }
}
