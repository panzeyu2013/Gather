// desktop/native/gather-core/Tests/GatherCoreTests/Concurrent/BatchCursorTests.swift
// 共享取号游标的不变量测试：不重不漏、失败停发、advanceOnFailure 分支。
import Testing
@testable import GatherDomain
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis

struct BatchCursorTests {
    /// 并发取号：8 个 worker 抢 4096 个号，恰好每个号被取走一次。
    @Test func concurrentWorkersDrainEveryIndexExactlyOnce() async {
        let cursor = BatchCursor(count: 4096)
        let collected = await withTaskGroup(of: [Int].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var local: [Int] = []
                    while let index = cursor.nextIndex() { local.append(index) }
                    return local
                }
            }
            var all: [Int] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }
        #expect(collected.count == 4096)
        #expect(Set(collected) == Set(0..<4096))
    }

    /// 默认语义：markFailed 之后不再发号（幂等），已取走的号不回退。
    @Test func failureStopsHandingOutIndices() {
        let cursor = BatchCursor(count: 4)
        #expect(cursor.nextIndex() == 0)
        #expect(cursor.nextIndex() == 1)
        cursor.markFailed()
        #expect(cursor.nextIndex() == nil)
        cursor.markFailed()
        #expect(cursor.nextIndex() == nil)
    }

    /// advanceOnFailure：失败只记录、号照发，取完后仍返回 nil（不重复发号）。
    @Test func advanceOnFailureKeepsHandingOutRemainingIndices() {
        let cursor = BatchCursor(count: 3, advanceOnFailure: true)
        #expect(cursor.nextIndex() == 0)
        cursor.markFailed()
        #expect(cursor.nextIndex() == 1)
        #expect(cursor.nextIndex() == 2)
        #expect(cursor.nextIndex() == nil)
    }

    /// 空批：永远取不到号（调用点另有 items.isEmpty 早返回，双层兜底）。
    @Test func zeroCountNeverHandsOutIndices() {
        let cursor = BatchCursor(count: 0)
        #expect(cursor.nextIndex() == nil)
    }
}
