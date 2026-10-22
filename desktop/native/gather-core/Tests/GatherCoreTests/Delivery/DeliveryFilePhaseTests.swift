// desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryFilePhaseTests.swift
// WP2b：文件阶段的竞态与幂等门禁（verify → restore/remove → 事后 verify，整体持锁）。
//
// 覆盖：
// 1. 指纹 await 窗口内出现新输入 → .changed，绝不碰文件；
// 2. 锁外已出现新输入 → .skipped(.changed)，不 restore/remove；
// 3. 外部修改（指纹不符）→ .skipped(.conflict)；
// 4. restore 的 await 窗口内出现新输入 → .invalidated（文件可能已被旧备份覆盖）；
// 5. 备份缺失 → .fileFailed（保留 prepared intent 的旧语义）；
// 6. finalize 只删备份、绝不 restore；
// 7. 同一路径的两个文件阶段被 XMPFileLock 串行化（最大并发 = 1）。

import Foundation
import Testing
@testable import GatherDelivery
@testable import GatherPersistence
@testable import GatherProtocol

struct DeliveryFilePhaseTests {
    private func makeFixture(
        fingerprint: @escaping DeliveryFingerprintProvider = { _ in "fp-base" }
    ) throws -> (
        db: DBConnection,
        repo: DeliveryRepo,
        port: DeliveryTestFilePort,
        phase: DeliveryFilePhase,
        row: DeliveryRow,
        payload: DeliveryCleanupPayload
    ) {
        let db = try DeliveryTestSupport.makeDB()
        let repo = DeliveryRepo(connection: db)
        let row = try DeliveryTestSupport.makeSyncedDelivery(
            repo: repo,
            backupPath: DeliveryTestSupport.backupPath,
            itemModule: .culling
        )
        let port = DeliveryTestFilePort(storage: [
            DeliveryTestSupport.xmpPath: "gather-written",
            DeliveryTestSupport.backupPath: "original",
        ])
        let phase = DeliveryFilePhase(
            deliveryRepo: repo,
            files: port,
            fileLock: XMPFileLock(),
            fingerprint: fingerprint
        )
        return (
            db, repo, port, phase, row,
            DeliveryTestSupport.cleanupPayload(for: row)
        )
    }

    @Test func verifyReportsChangedWhenNewInputArrivesInsideFingerprintWindow() async throws {
        let db = try DeliveryTestSupport.makeDB()
        defer { db.close() }
        let repo = DeliveryRepo(connection: db)
        let row = try DeliveryTestSupport.makeSyncedDelivery(repo: repo)
        let port = DeliveryTestFilePort()
        let phase = DeliveryFilePhase(
            deliveryRepo: repo,
            files: port,
            fileLock: XMPFileLock(),
            fingerprint: { _ in
                _ = try repo.mergeInput(
                    xmpPath: row.xmpPath,
                    photoPath: row.photoPath,
                    expectedRevision: 1,
                    newRevision: 2,
                    baseFingerprint: "fp-new",
                    baseValues: .object([:])
                )
                return "fp-base"
            }
        )

        let verdict = try await phase.verify(
            xmpPath: row.xmpPath,
            payload: DeliveryTestSupport.cleanupPayload(for: row)
        )

        #expect(verdict == .changed(reason: "revision-changed"))
        #expect(port.restoreCallCount == 0, "快照已变时不得 restore")
        #expect(port.removedPathsSnapshot.isEmpty, "快照已变时不得 remove")
    }

    @Test func runSkipsMutationWhenSnapshotChangedBeforeLock() async throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        _ = try fixture.repo.mergeInput(
            xmpPath: fixture.row.xmpPath,
            photoPath: fixture.row.photoPath,
            expectedRevision: 1,
            newRevision: 2,
            baseFingerprint: "fp-new",
            baseValues: .object([:])
        )

        let outcome = await fixture.phase.run(
            xmpPath: fixture.row.xmpPath, payload: fixture.payload)

        guard case .skipped(.changed(let reason)) = outcome else {
            Issue.record("期望 .skipped(.changed)，实际 \(outcome)")
            return
        }
        #expect(reason == "revision-changed")
        #expect(fixture.port.restoreCallCount == 0)
        #expect(fixture.port.removedPathsSnapshot.isEmpty)
        #expect(fixture.port.contents(DeliveryTestSupport.xmpPath) == "gather-written")
    }

    @Test func fingerprintMismatchSkipsWithoutTouchingFiles() async throws {
        let fixture = try makeFixture(fingerprint: { _ in "fp-edited" })
        defer { fixture.db.close() }

        let outcome = await fixture.phase.run(
            xmpPath: fixture.row.xmpPath, payload: fixture.payload)

        #expect(outcome == .skipped(.conflict(reason: "fingerprint-mismatch")))
        #expect(fixture.port.restoreCallCount == 0)
        #expect(fixture.port.removedPathsSnapshot.isEmpty)
        #expect(fixture.port.contents(DeliveryTestSupport.xmpPath) == "gather-written")
    }

    @Test func cleanupRestoresBackupAndVerifiesAfterMutation() async throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }

        let outcome = await fixture.phase.run(
            xmpPath: fixture.row.xmpPath, payload: fixture.payload)

        #expect(outcome == .completed)
        #expect(fixture.port.restoreCallCount == 1)
        #expect(fixture.port.contents(DeliveryTestSupport.xmpPath) == "original")
    }

    @Test func newInputDuringRestoreIsReportedAsInvalidated() async throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        let repo = fixture.repo
        let row = fixture.row
        fixture.port.onRestore = {
            _ = try repo.mergeInput(
                xmpPath: row.xmpPath,
                photoPath: row.photoPath,
                expectedRevision: 1,
                newRevision: 2,
                baseFingerprint: "fp-new",
                baseValues: .object([:])
            )
        }

        let outcome = await fixture.phase.run(
            xmpPath: fixture.row.xmpPath, payload: fixture.payload)

        guard case .invalidated(let reason) = outcome else {
            Issue.record("期望 .invalidated，实际 \(outcome)")
            return
        }
        #expect(reason == "revision-changed")
        #expect(fixture.port.restoreCallCount == 1, "文件已执行，必须显式上报")
        #expect(try fixture.repo.get(row.xmpPath)?.typedStatus == .pending)
    }

    @Test func missingBackupIsFileFailedAndKeepsSnapshot() async throws {
        let db = try DeliveryTestSupport.makeDB()
        defer { db.close() }
        let repo = DeliveryRepo(connection: db)
        let row = try DeliveryTestSupport.makeSyncedDelivery(
            repo: repo, backupPath: DeliveryTestSupport.backupPath)
        let port = DeliveryTestFilePort(storage: [DeliveryTestSupport.xmpPath: "current"])
        let phase = DeliveryFilePhase(
            deliveryRepo: repo,
            files: port,
            fileLock: XMPFileLock(),
            fingerprint: { _ in "fp-base" }
        )

        let outcome = await phase.run(
            xmpPath: row.xmpPath,
            payload: DeliveryTestSupport.cleanupPayload(for: row)
        )

        guard case .fileFailed(let reason) = outcome else {
            Issue.record("期望 .fileFailed，实际 \(outcome)")
            return
        }
        #expect(reason.contains("XMP_BACKUP_MISSING"))
        #expect(try repo.get(row.xmpPath)?.typedStatus == .synced, "文件失败不改交付状态")
    }

    @Test func finalizeRemovesBackupWithoutRestoringSidecar() async throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        let payload = DeliveryTestSupport.cleanupPayload(
            for: fixture.row, action: .finalize)

        let outcome = await fixture.phase.run(
            xmpPath: fixture.row.xmpPath, payload: payload)

        #expect(outcome == .completed)
        #expect(fixture.port.restoreCallCount == 0, "finalize 绝不 restore")
        #expect(fixture.port.contents(DeliveryTestSupport.backupPath) == nil)
        #expect(fixture.port.contents(DeliveryTestSupport.xmpPath) == "gather-written")
    }

    @Test func concurrentPhasesOnSamePathAreSerializedByFileLock() async throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        let probe = DeliveryTestConcurrencyProbe()
        fixture.port.onRestore = {
            probe.begin()
            Thread.sleep(forTimeInterval: 0.02)
            probe.end()
        }

        async let first = fixture.phase.run(
            xmpPath: fixture.row.xmpPath, payload: fixture.payload)
        async let second = fixture.phase.run(
            xmpPath: fixture.row.xmpPath, payload: fixture.payload)
        let outcomes = await [first, second]

        #expect(outcomes == [.completed, .completed])
        #expect(probe.maximum == 1, "同一 xmpPath 的文件阶段必须串行")
        #expect(fixture.port.restoreCallCount == 2)
    }
}
