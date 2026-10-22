// desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryDBPhaseTests.swift
// WP2b：DB 删除 + intent.finish 的单事务语义。
//
// 覆盖：
// 1. 成功路径：删除交付与删除 intent 一起提交；
// 2. finish 失败（SQLite trigger 注入）→ 整个事务回滚：交付行仍在、intent 仍在；
// 3. 提交后重复调用幂等（.alreadyGone，不抛 rowNotFound）；
// 4. item 门禁跳过时 intent 标 applied + error，交付原样保留；
// 5. finalize 与 cleanup 同一事务纪律；
// 6. finalize 删除语句本身失败 → 整事务回滚（行 + intent 保留，replay 可重试；
//    备份删除是调用方的 DB 后置步骤，失败路径根本不会执行）。

import Foundation
import Testing
@testable import GatherDelivery
@testable import GatherPersistence
@testable import GatherProtocol

struct DeliveryDBPhaseTests {
    private func makeComponents() throws -> (
        db: DBConnection,
        repo: DeliveryRepo,
        intentRepo: DeliveryIntentRepo,
        writer: DeliveryStateWriter,
        intents: DeliveryIntentStore,
        phase: DeliveryDBPhase
    ) {
        let db = try DeliveryTestSupport.makeDB()
        let repo = DeliveryRepo(connection: db)
        let intentRepo = DeliveryIntentRepo(connection: db)
        let writer = DeliveryStateWriter(repo: repo)
        let intents = DeliveryIntentStore(repo: intentRepo)
        let phase = DeliveryDBPhase(
            connection: db, deliveryRepo: repo, writer: writer, intents: intents)
        return (db, repo, intentRepo, writer, intents, phase)
    }

    /// 未链接会话的 synced 交付：deleteSyncedDelivery 的 confirmed_at 门禁自然放行。
    private func makeUnlinkedSynced(
        repo: DeliveryRepo,
        backupPath: String = ""
    ) throws -> DeliveryRow {
        try DeliveryTestSupport.makeSyncedDelivery(
            repo: repo,
            backupPath: backupPath,
            sessionId: nil
        )
    }

    @Test func cleanupDeletesDeliveryAndIntentTogether() throws {
        let fixture = try makeComponents()
        defer { fixture.db.close() }
        let row = try makeUnlinkedSynced(repo: fixture.repo)
        let payload = DeliveryTestSupport.cleanupPayload(for: row)
        let intentId = try fixture.intentRepo.prepare(
            kind: .cleanup, xmpPath: row.xmpPath, payload: payload.json)

        let outcome = try fixture.phase.applyCleanup(
            intentId: intentId, xmpPath: row.xmpPath, payload: payload)

        #expect(outcome == .deleted)
        #expect(try fixture.repo.get(row.xmpPath) == nil)
        #expect(try fixture.intentRepo.get(intentId) == nil)
    }

    @Test func finishFailureRollsBackDeliveryDeletion() throws {
        let fixture = try makeComponents()
        defer { fixture.db.close() }
        let row = try makeUnlinkedSynced(repo: fixture.repo)
        let payload = DeliveryTestSupport.cleanupPayload(for: row)
        let intentId = try fixture.intentRepo.prepare(
            kind: .cleanup, xmpPath: row.xmpPath, payload: payload.json)
        try fixture.db.exec("""
            CREATE TRIGGER fail_intent_delete
            BEFORE DELETE ON delivery_intents
            BEGIN
              SELECT RAISE(ABORT, 'injected finish failure');
            END;
            """)

        do {
            _ = try fixture.phase.applyCleanup(
                intentId: intentId, xmpPath: row.xmpPath, payload: payload)
            Issue.record("finish 失败必须抛出")
        } catch let error as DeliveryDBPhaseError {
            guard case .finish = error else {
                Issue.record("期望 .finish，实际 \(error)")
                return
            }
        }

        // 删除已执行但 finish 失败：同一事务回滚，交付行与 intent 都必须还在。
        #expect(try fixture.repo.get(row.xmpPath)?.typedStatus == .synced)
        #expect(try fixture.intentRepo.get(intentId)?.phase == "prepared")

        // 去掉故障后重试：一次事务内删除 + 收尾。
        _ = try fixture.db.exec("DROP TRIGGER fail_intent_delete")
        let retried = try fixture.phase.applyCleanup(
            intentId: intentId, xmpPath: row.xmpPath, payload: payload)
        #expect(retried == .deleted)
        #expect(try fixture.repo.get(row.xmpPath) == nil)
        #expect(try fixture.intentRepo.get(intentId) == nil)
    }

    @Test func repeatedDBPhaseAfterCommitIsIdempotent() throws {
        let fixture = try makeComponents()
        defer { fixture.db.close() }
        let row = try makeUnlinkedSynced(repo: fixture.repo)
        let payload = DeliveryTestSupport.cleanupPayload(for: row)
        let intentId = try fixture.intentRepo.prepare(
            kind: .cleanup, xmpPath: row.xmpPath, payload: payload.json)

        let first = try fixture.phase.applyCleanup(
            intentId: intentId, xmpPath: row.xmpPath, payload: payload)
        #expect(first == .deleted)
        #expect(try fixture.intentRepo.get(intentId) == nil)

        // 行与 intent 都已不存在：重复调用必须幂等(alreadyGone)，不抛 rowNotFound。
        let second = try fixture.phase.applyCleanup(
            intentId: intentId, xmpPath: row.xmpPath, payload: payload)
        #expect(second == .alreadyGone)
        #expect(try fixture.repo.get(row.xmpPath) == nil)
    }

    @Test func itemGateSkipFinishesIntentWithErrorAndKeepsDelivery() throws {
        let fixture = try makeComponents()
        defer { fixture.db.close() }
        let row = try DeliveryTestSupport.makeSyncedDelivery(
            repo: fixture.repo,
            sessionId: nil,
            itemModule: .metadata,
            itemStatus: .pending
        )
        let payload = DeliveryTestSupport.cleanupPayload(for: row)
        let intentId = try fixture.intentRepo.prepare(
            kind: .cleanup, xmpPath: row.xmpPath, payload: payload.json)

        let outcome = try fixture.phase.applyCleanup(
            intentId: intentId, xmpPath: row.xmpPath, payload: payload)

        #expect(outcome == .foreignItemsPending(module: "metadata", status: "pending"))
        #expect(try fixture.repo.get(row.xmpPath)?.typedStatus == .synced)
        let intent = try #require(try fixture.intentRepo.get(intentId))
        #expect(intent.phase == "applied")
        #expect(intent.errorMessage.contains("XMP_CLEANUP_INCOMPLETE_ITEMS"))
    }

    /// P1-1：DB 删除语句失败时整事务回滚——交付行、intent（fileDone）都在，
    /// 备份由调用方在 DB 成功前不会删，因此不会出现悬空 backup_path。
    @Test func finalizeDeleteFailureRollsBackRowAndKeepsIntentRetryable() throws {
        let fixture = try makeComponents()
        defer { fixture.db.close() }
        let row = try makeUnlinkedSynced(repo: fixture.repo)
        let payload = DeliveryTestSupport.cleanupPayload(for: row, action: .finalize)
        let intentId = try fixture.intentRepo.prepare(
            kind: .cleanup, xmpPath: row.xmpPath, payload: payload.json)
        _ = try fixture.intentRepo.advance(id: intentId, to: .fileDone)
        try fixture.db.exec("""
            CREATE TRIGGER fail_delivery_delete_finalize
            BEFORE DELETE ON deliveries
            BEGIN
              SELECT RAISE(ABORT, 'injected finalize delivery delete failure');
            END;
            """)

        do {
            _ = try fixture.phase.applyFinalize(
                intentId: intentId, xmpPath: row.xmpPath, payload: payload)
            Issue.record("删除失败必须抛出")
        } catch let error as DeliveryDBPhaseError {
            guard case .database = error else {
                Issue.record("期望 .database，实际 \(error)")
                return
            }
        }
        #expect(try fixture.repo.get(row.xmpPath)?.typedStatus == .synced)
        #expect(try fixture.intentRepo.get(intentId)?.phase == "fileDone")

        // 去掉故障后 replay 的 DB 段：一次事务内删除 + 收尾。
        _ = try fixture.db.exec("DROP TRIGGER fail_delivery_delete_finalize")
        let retried = try fixture.phase.applyFinalize(
            intentId: intentId, xmpPath: row.xmpPath, payload: payload)
        #expect(retried == .deleted)
        #expect(try fixture.repo.get(row.xmpPath) == nil)
        #expect(try fixture.intentRepo.get(intentId) == nil)
    }

    @Test func finalizeSharesTheSameAtomicDeleteAndFinish() throws {
        let fixture = try makeComponents()
        defer { fixture.db.close() }
        let row = try makeUnlinkedSynced(repo: fixture.repo)
        let payload = DeliveryTestSupport.cleanupPayload(
            for: row, action: .finalize)
        let intentId = try fixture.intentRepo.prepare(
            kind: .cleanup, xmpPath: row.xmpPath, payload: payload.json)
        try fixture.db.exec("""
            CREATE TRIGGER fail_intent_delete_finalize
            BEFORE DELETE ON delivery_intents
            BEGIN
              SELECT RAISE(ABORT, 'injected finalize finish failure');
            END;
            """)

        do {
            _ = try fixture.phase.applyFinalize(
                intentId: intentId, xmpPath: row.xmpPath, payload: payload)
            Issue.record("finish 失败必须抛出")
        } catch let error as DeliveryDBPhaseError {
            guard case .finish = error else {
                Issue.record("期望 .finish，实际 \(error)")
                return
            }
        }
        #expect(try fixture.repo.get(row.xmpPath)?.typedStatus == .synced)
        #expect(try fixture.intentRepo.get(intentId)?.phase == "prepared")
    }
}
