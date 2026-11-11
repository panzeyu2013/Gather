// desktop/native/gather-app/Tests/GatherAppTests/C1PendingJudgementReplayTests.swift
// Wave4c / task-48 回归：scan 非 succeeded 时 C1 判断登记 pending，成功后可重放；
// 失败/超时保持 pending 且可手动重试；UI store 计数与重试注入。
//
// 纯注入驱动：apply 结果由脚本队列给出，sleep 用无操作替身（不真等 15s）。
import Foundation
import Testing
import GatherProtocol
import GatherTestSupport
@testable import GatherUI
@testable import GatherApplication

private func wave48Judgement(path: String = "/shoot/a.cr2") -> C1VariantJudgement {
    C1VariantJudgement(photoPath: path, rating: 4, colorTag: 1, pick: true, keywords: ["wedding"])
}

private struct Wave48ApplyState {
    var results: [C1ImportJudgementReport]
    var calls = 0
    var pendingCounts: [Int] = []
}

@Suite("C1PendingJudgementReplay 失败→pending→成功重放")
struct C1PendingJudgementReplayTests {
    private func makeReplay(
        state: LockedBox<Wave48ApplyState>,
        maxAttempts: Int = 20,
        pollInterval: Duration = .seconds(60)
    ) -> C1PendingJudgementReplay {
        C1PendingJudgementReplay(
            apply: { _, _ in
                state.lock.withLock {
                    state.calls += 1
                    return state.results.isEmpty
                        ? C1ImportJudgementReport(applied: 1)
                        : state.results.removeFirst()
                }
            },
            onStateChange: { _, count in
                state.lock.withLock { state.pendingCounts.append(count) }
            },
            pollInterval: pollInterval,
            maxAttempts: maxAttempts,
            // 真实等待：否则 watcher 会紧循环把脚本结果一次耗尽，测不到 pending 保留。
            sleep: { duration in try? await Task.sleep(for: duration) })
    }

    @Test("扫描失败：登记 pending；下一次成功（手动重试）后落库并清空计数")
    func failedScanBecomesPendingThenApplies() async {
        let state = LockedBox(Wave48ApplyState(results: [
            C1ImportJudgementReport(applied: 1, ratings: 1, keeps: 1),
        ]))
        let replay = makeReplay(state: state)
        await replay.register(
            sessionId: "s1",
            judgements: [wave48Judgement()],
            skippedReason: "metadata.scan failed")
        #expect(await replay.pendingCount(sessionId: "s1") == 1)
        #expect(await replay.pendingReason(sessionId: "s1") == "metadata.scan failed")

        // 模拟"下一次扫描成功"：手动重试命中的 apply 返回 applied。
        await replay.retry(sessionId: "s1")
        #expect(await replay.pendingCount(sessionId: "s1") == 0)
        #expect(await replay.pendingReason(sessionId: "s1") == nil)
        #expect(state.lock.withLock { state.pendingCounts.last } == 0)
    }

    @Test("后台 watcher：扫描仍失败时保留 pending，成功那一轮自动落库")
    func watcherRetriesUntilSuccess() async {
        let state = LockedBox(Wave48ApplyState(results: [
            C1ImportJudgementReport(skippedReason: "timed out waiting metadata.scan"),
            C1ImportJudgementReport(skippedReason: "metadata.scan failed"),
            C1ImportJudgementReport(applied: 1, ratings: 1),
        ]))
        let replay = makeReplay(state: state, pollInterval: .milliseconds(1))
        await replay.register(
            sessionId: "s1",
            judgements: [wave48Judgement()],
            skippedReason: "timed out waiting metadata.scan")

        var spins = 0
        while true {
            let remaining = await replay.pendingCount(sessionId: "s1")
            if remaining == 0 || spins >= 1_000 { break }
            spins += 1
            do { try await Task.sleep(for: .milliseconds(2)) } catch { break }
        }
        #expect(await replay.pendingCount(sessionId: "s1") == 0)
        #expect(state.lock.withLock { state.calls } == 3)
    }

    @Test("超时：一直失败时保留 pending（不清零），可再次手动重试")
    func pendingStaysUntilSuccess() async {
        let state = LockedBox(Wave48ApplyState(results: [
            C1ImportJudgementReport(skippedReason: "timed out waiting metadata.scan"),
            C1ImportJudgementReport(applied: 1),
        ]))
        let replay = makeReplay(state: state)
        await replay.register(
            sessionId: "s1",
            judgements: [wave48Judgement()],
            skippedReason: "timed out waiting metadata.scan")
        await replay.retry(sessionId: "s1")
        #expect(await replay.pendingCount(sessionId: "s1") == 1)

        await replay.retry(sessionId: "s1")
        #expect(await replay.pendingCount(sessionId: "s1") == 0)
    }

    @Test("shutdown：清空 pending 并停止后台重试")
    func shutdownClearsPending() async {
        let state = LockedBox(Wave48ApplyState(results: [
            C1ImportJudgementReport(skippedReason: "metadata.scan failed"),
        ]))
        let replay = makeReplay(state: state)
        await replay.register(
            sessionId: "s1",
            judgements: [wave48Judgement()],
            skippedReason: "metadata.scan failed")
        await replay.shutdown()
        #expect(await replay.pendingCount(sessionId: "s1") == 0)
    }
}

// MARK: - UI store

@Suite("C1PendingJudgementStore")
@MainActor
struct C1PendingJudgementStoreTests {
    @Test("计数按会话读写；0 清理；reset 清空且移除重试动作")
    func storesCounts() {
        let store = C1PendingJudgementStore()
        store.setCount(sessionId: "s1", count: 3)
        store.setCount(sessionId: "s2", count: 1)
        #expect(store.count(sessionId: "s1") == 3)
        store.setCount(sessionId: "s1", count: 0)
        #expect(store.count(sessionId: "s1") == 0)
        #expect(store.counts["s2"] == 1)
        store.reset()
        #expect(store.counts.isEmpty)
        #expect(store.onRetry == nil)
    }

    @Test("重试动作注入后可被按钮调用（复用 Host 的同一 apply 口径）")
    func retryInvokesInjectedAction() async {
        let store = C1PendingJudgementStore()
        let calls = LockedBox(CallLog())
        store.onRetry = { sessionId in calls.lock.withLock { calls.items.append(sessionId) } }
        await store.retry(sessionId: "s1")
        #expect(calls.lock.withLock { calls.items } == ["s1"])
    }
}

/// LockedBox 动态成员只能映射具名属性。
private struct CallLog {
    var items: [String] = []
}
