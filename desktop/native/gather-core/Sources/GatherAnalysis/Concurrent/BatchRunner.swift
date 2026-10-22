// desktop/native/gather-core/Sources/GatherAnalysis/Concurrent/BatchRunner.swift
// 有界并发批处理的唯一实现（内部）。
//
// 合并背景（R2）：MetadataSyncCoordinator / IndexerService / QualityService /
// DuplicateService / WritebackService / MetadataService 曾各自持有一份逐字节同构的
// 私有包装体（4× `batchAsync` + 2× `mapConcurrent`），取号游标已先收敛到
// `BatchCursor`。本文件是唯一实现；6 个文件里 12 个调用点只传参数，语义逐点不变
// （合并前逐行 diff 只差函数名/访问级别与 `sort`+`map` 的等价写法）。
//
// 不变量（对全部 12 个调用点成立，靠独立探针实测 + 直接单测锁定）：
// - **并发上限**：worker 数 = `min(max(1, concurrency), items.count)`；每个 worker
//   串行取号执行，因此同时最多 `concurrency` 个 `body` 在飞。`concurrency <= 0`
//   视为 1；空数组直接返回 `[]`（不建 task group、body 零调用）。
//   （探针：concurrency=4、24 项 → 在飞峰值恰为 4。）
// - **保序**：返回数组与 `items` 一一对应（按输入索引升序），与完成顺序无关。
//   （探针：完成序与输入序相反时输出仍为输入序。）
// - **错误传播**：`body` 抛出的错误经 task group 重抛，抛出的是**完成序上第一个被
//   group 观察到的错误**，不保证输入索引序。抛错方先 `cursor.markFailed()`：其余
//   worker 立即不再取新号；同时标准库会取消剩余子任务，取消感知的在飞 `body` 立刻
//   收尾（`Task.sleep` 等抛 CancellationError），不感知取消的同步在飞工作则跑完后才
//   返回——两者都在 group 退出前收尾。成功返回全部结果，失败不返回部分结果。
//   （探针：并发 3、索引 0 睡 300ms 后抛 .slow、索引 1 立即抛 .fast → 抛 .fast，
//   启动索引 [0,1,2]，索引 0 的 sleep 观察到取消，整个调用 ~0ms 返回。）
// - **取消**：worker 每次取号前检查 `Task.isCancelled`；调用方取消后不再取新号，
//   已启动项按各自取消语义收尾，返回已完成项的部分结果（若在飞 body 因取消抛错，
//   则按上面的规则抛错）。`markFailed` 与取消检查互补：取消传播存在时间窗，游标
//   停发把它封死。
//
// 12 个调用点的真实参数（并发数 / body 错误策略）——差异都在调用点，不在包装体：
//   MetadataService.getMetadata         16 / body 全 catch（try? + 逐照片隔离）
//   MetadataService.getMetadata         10 / body 全 catch（逐照片隔离）
//   MetadataService.batchSet             4 / body 逐项 catch，汇总 BatchMetadataResult
//   MetadataSyncCoordinator.cleanup      2 / body 全 catch，返回 (deleted, error)
//   MetadataSyncCoordinator.finalize     2 / body 全 catch，返回 (deleted, error)
//   WritebackService.execute             4 / body 逐项 catch，汇总 errors
//   DuplicateService.computeVisualHashes 8 / body 不抛（try? 兜底不可达）
//   DuplicateService stat 阶段          32 / body 抛 JobCancelledError（可中断）
//   DuplicateService sha256 阶段         2 / body 抛 JobCancelledError（可中断）
//   QualityService.analyze               6 / body 可抛（context.throwIfCancelled）
//   IndexerService.scanBatch             4 / body 可抛（context.throwIfCancelled）
//   IndexerService.backfillChecksums     6 / body 全 catch，失败项返回 nil
// 所有调用点都用「首个失败停发新号」（`BatchCursor(advanceOnFailure: false)`）；
// 无生产调用点需要 `advanceOnFailure: true`，故不暴露该参数（避免无消费者的 API）。
//
// 错误序与兄弟任务取消的行为直接来自标准库 `withThrowingTaskGroup`：本函数不加任何
// 额外调度，合并前后是同一段代码，因此逐点等价。
// Swift 6：worker 子任务并发执行，闭包与结果都必须可跨并发域传递。
// 约束加在泛型上（T: Sendable / R: Sendable）而不是用 @unchecked 绕过：
// 每个调用点的 T/R 都是值类型或已 Sendable 的结构体（见上方 12 个调用点清单）。
public func batchAsync<T: Sendable, R: Sendable>(
    _ items: [T],
    concurrency: Int,
    body: @escaping @Sendable (T) async throws -> R
) async throws -> [R] {
    let limit = max(1, concurrency)
    guard !items.isEmpty else { return [] }
    let cursor = BatchCursor(count: items.count)
    var collected: [(index: Int, value: R)] = []
    try await withThrowingTaskGroup(of: [(Int, R)].self) { group in
        for _ in 0..<min(limit, items.count) {
            group.addTask {
                var local: [(Int, R)] = []
                while !Task.isCancelled, let index = cursor.nextIndex() {
                    do {
                        local.append((index, try await body(items[index])))
                    } catch {
                        cursor.markFailed()
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
