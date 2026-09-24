// Tests/GatherCoreTests/Runtime/Culling/CullingRuntimeCancellationTests.swift
// W2b：并发点击 / CAS / 取消安全测试。
// 关键不变式：
// - 同一 expectedRevision 的并发点击恰一个成功、其余 CULLING_REVISION_CONFLICT；
// - 批量决策写入是单事务：中途冲突整批回滚（不产生部分照片落库的中间态）；
// - 任务取消不会产生部分写入（同步临界区不可挂起，副作用集中在 CAS 之后）。

import Foundation
import Testing
@testable import GatherCore

@Suite("CullingRuntime 并发/取消 (W2b)")
struct CullingRuntimeCancellationTests {

    @Test("并发同 revision 单张更新：恰一个成功、一个 CULLING_REVISION_CONFLICT")
    func concurrentUpdateSameRevisionExactlyOneConflict() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        let runtime = harness.runtime

        let first = Task {
            try await runtime.update(
                sessionId: "session", photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(pickState: .picked))
        }
        let second = Task {
            try await runtime.update(
                sessionId: "session", photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(pickState: .rejected))
        }

        var successes = 0
        var conflicts = 0
        for task in [first, second] {
            do {
                _ = try await task.value
                successes += 1
            } catch let error as CullingServiceError {
                guard case .revisionConflict = error else { throw error }
                conflicts += 1
            }
        }
        #expect(successes == 1, "同 revision 恰一个成功")
        #expect(conflicts == 1, "并发点击恰一个冲突")

        let row = try #require(try await harness.decision("p1"))
        #expect(row.revision == 1, "只落库一次")
        let history = try await harness.cullingStore.historyList(sessionId: harness.sessionId)
        #expect(history.count == 1, "只产生一个历史操作")
    }

    @Test("并发更新不同照片：都成功（CAS 不误报）")
    func concurrentUpdatesDifferentPhotosBothSucceed() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        let runtime = harness.runtime

        let first = Task {
            try await runtime.update(
                sessionId: "session", photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(rating: 4))
        }
        let second = Task {
            try await runtime.update(
                sessionId: "session", photoId: "p2", expectedRevision: 0,
                patch: CullingUpdatePatch(rating: 5))
        }
        _ = try await first.value
        _ = try await second.value

        #expect(try await harness.decision("p1")?.revision == 1)
        #expect(try await harness.decision("p2")?.revision == 1)
        let queued = await harness.mutations.queued
        #expect(queued.count == 2)
    }

    @Test("预读后并发写入者抢先：CAS 失败映射 CULLING_REVISION_CONFLICT 且无副作用")
    func updateCASFailureAfterPreReadMapsToRevisionConflict() async throws {
        let harness = try await makeCullingRuntimeHarness(wrapCullingStore: { RacingCullingStore(base: $0) })
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingDecision(harness.db, photoId: "p1", decision: "pending", revision: 0)
        let racing = try #require(harness.cullingStore as? RacingCullingStore)
        let db = harness.db
        // 模拟并发点击：预读拿到 revision 0，CAS 前另一个写入者推到 1。
        await racing.setBeforeApplyDecisionStates {
            try? await db.run(
                "UPDATE culling_decisions SET revision = 1 WHERE session_id = 'session' AND photo_id = 'p1'")
        }

        await #expect(throws: CullingServiceError.revisionConflict(expected: 0, current: 1)) {
            _ = try await harness.runtime.update(
                sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(rating: 5))
        }

        #expect(try await harness.decision("p1")?.revision == 1, "失败方不落库")
        #expect(try await harness.cullingStore.historyList(sessionId: harness.sessionId).isEmpty)
        #expect(await harness.mutations.queued.isEmpty, "CAS 冲突不产生 outbox 副作用")
    }

    @Test("batch 单事务回滚：中途冲突时先命中的照片也不落库、无历史/outbox")
    func batchDecisionWritesRollbackAsOneTransaction() async throws {
        let harness = try await makeCullingRuntimeHarness(wrapCullingStore: { RacingCullingStore(base: $0) })
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        try await insertCullingDecision(harness.db, photoId: "p1", decision: "pending", revision: 0)
        try await insertCullingDecision(harness.db, photoId: "p2", decision: "pending", revision: 0)
        let racing = try #require(harness.cullingStore as? RacingCullingStore)
        let db = harness.db
        // 预读之后、CAS 之前并发写入者改掉 p2：事务内 p1 先命中、p2 冲突 → 整批回滚。
        await racing.setBeforeApplyDecisionStates {
            try? await db.run(
                "UPDATE culling_decisions SET revision = 1 WHERE session_id = 'session' AND photo_id = 'p2'")
        }

        await #expect(throws: CullingServiceError.revisionConflict(expected: 0, current: 1)) {
            _ = try await harness.runtime.batchUpdate(
                sessionId: harness.sessionId, photoIds: ["p1", "p2"],
                patch: CullingUpdatePatch(rating: 5))
        }

        #expect(try await harness.decision("p1")?.revision == 0, "整批回滚：p1 不被部分写入")
        #expect(try await harness.decision("p1")?.rating == 0)
        #expect(try await harness.decision("p2")?.revision == 1, "并发写入者的行保留")
        #expect(try await harness.cullingStore.historyList(sessionId: harness.sessionId).isEmpty)
        #expect(await harness.mutations.queued.isEmpty)
    }

    @Test("并发 batchUpdate 同一批照片：不出现部分照片落库的中间态")
    func concurrentBatchUpdatesNeverLeavePartialState() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        let runtime = harness.runtime

        let first = Task {
            try await runtime.batchUpdate(
                sessionId: "session", photoIds: ["p1", "p2"],
                patch: CullingUpdatePatch(pickState: .picked))
        }
        let second = Task {
            try await runtime.batchUpdate(
                sessionId: "session", photoIds: ["p1", "p2"],
                patch: CullingUpdatePatch(pickState: .picked))
        }
        var successes = 0
        for task in [first, second] {
            do {
                _ = try await task.value
                successes += 1
            } catch let error as CullingServiceError {
                guard case .revisionConflict = error else { throw error }
            }
        }
        #expect(successes >= 1)

        let p1 = try #require(try await harness.decision("p1"))
        let p2 = try #require(try await harness.decision("p2"))
        #expect(p1.revision == p2.revision, "两张照片要么都更新、要么都不更新（整批原子）")
        #expect(Int(p1.revision) == successes, "每个成功批次恰好一次 revision 递增")
        #expect(p1.decision == "keep" && p2.decision == "keep")
        let history = try await harness.cullingStore.historyList(sessionId: harness.sessionId)
        #expect(history.count == successes, "每个成功批次一个历史操作")
        #expect(await harness.mutations.queued.isEmpty, "pick 无 XMP 副作用")
    }

    @Test("取消在飞 update：全量落库或全不落库，无部分写入")
    func cancelledUpdateLeavesAllOrNothingState() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingVariantPair(harness.db, assetId: "asset-1")
        let runtime = harness.runtime

        let task = Task {
            try await runtime.update(
                sessionId: "session", photoId: "asset-1-raw", expectedRevision: 0,
                patch: CullingUpdatePatch(pickState: .picked))
        }
        task.cancel()
        var applied = false
        do {
            _ = try await task.value
            applied = true
        } catch {
            applied = false
        }

        let raw = try await harness.decision("asset-1-raw")
        let jpg = try await harness.decision("asset-1-jpg")
        let history = try await harness.cullingStore.historyList(sessionId: harness.sessionId)
        if applied {
            #expect(raw?.revision == 1)
            #expect(jpg?.revision == 1)
            #expect(raw?.decision == "keep" && jpg?.decision == "keep")
            #expect(history.count == 1)
        } else {
            #expect(raw == nil && jpg == nil, "取消后不允许部分变体落库")
            #expect(history.isEmpty)
        }
    }
}
