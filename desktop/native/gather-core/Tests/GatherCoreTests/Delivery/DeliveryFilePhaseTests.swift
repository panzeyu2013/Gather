// desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryFilePhaseTests.swift
// WP2b：文件阶段的竞态与幂等门禁（verify → restore/remove → 事后 verify，整体持锁）。
//
// 覆盖：
// 1. 指纹 await 窗口内出现新输入 → .changed，绝不碰文件；
// 2. 锁外已出现新输入 → .skipped(.changed)，不 restore/remove；
// 3. 外部修改（指纹不符）→ .skipped(.conflict)；
// 4. restore 的 await 窗口内出现新输入 → .invalidated（文件可能已被旧备份覆盖）；
// 5. 备份缺失 → .fileFailed（保留 prepared intent 的旧语义）；
// 6. finalize 文件阶段只 verify，绝不 restore **也绝不删备份**（P1-1）；
// 7. 备份删除只在交付行删除成功之后（removeFinalizeBackup），幂等且受新交付守卫；
// 8. 同一路径的两个文件阶段被 XMPFileLock 串行化（最大并发 = 1）。

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
        let fixture = try makeFixture(fingerprint: { path in
            path == DeliveryTestSupport.backupPath ? "fp-backup" : "fp-edited"
        })
        defer { fixture.db.close() }

        let outcome = await fixture.phase.run(
            xmpPath: fixture.row.xmpPath, payload: fixture.payload)

        #expect(outcome == .skipped(.conflict(reason: "fingerprint-mismatch")))
        #expect(fixture.port.restoreCallCount == 0)
        #expect(fixture.port.removedPathsSnapshot.isEmpty)
        #expect(fixture.port.contents(DeliveryTestSupport.xmpPath) == "gather-written")
    }

    /// P1（复审）：restore 已成功、advance(fileDone) 未落库 → 盘上内容等于备份；
    /// 重放必须继续（幂等覆盖写），不能判 conflict 把交付永久卡死。
    @Test func restoreAlreadyAppliedIsNotTreatedAsConflict() async throws {
        let fixture = try makeFixture(fingerprint: { _ in "fp-restored" })
        defer { fixture.db.close() }

        let outcome = await fixture.phase.run(
            xmpPath: fixture.row.xmpPath, payload: fixture.payload)

        #expect(outcome == .completed,
                "盘上已是恢复目标（=备份内容）时应 proceed，而不是 conflict")
        #expect(fixture.port.restoreCallCount == 1)
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

    /// P1-1：finalize 的文件阶段只 verify。旧实现在这里删备份，DB CAS 一旦拒绝
    /// 就会留下「交付行还在、backup_path 指向已删文件」的悬空引用。
    @Test func finalizeFilePhaseLeavesBackupUntouched() async throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        let payload = DeliveryTestSupport.cleanupPayload(
            for: fixture.row, action: .finalize)

        let outcome = await fixture.phase.run(
            xmpPath: fixture.row.xmpPath, payload: payload)

        #expect(outcome == .completed)
        #expect(fixture.port.restoreCallCount == 0, "finalize 绝不 restore")
        #expect(fixture.port.removedPathsSnapshot.isEmpty, "文件阶段绝不删备份")
        #expect(fixture.port.contents(DeliveryTestSupport.backupPath) == "original")
        #expect(fixture.port.contents(DeliveryTestSupport.xmpPath) == "gather-written")
        #expect(try fixture.repo.get(fixture.row.xmpPath)?.typedStatus == .synced)
    }

    /// P1-1：备份删除是 DB 成功后的后置步骤——行未删时保留，行删后删除且幂等。
    @Test func removeFinalizeBackupWaitsForRowDeletionAndIsIdempotent() async throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        let xmpPath = fixture.row.xmpPath
        let backupPath = DeliveryTestSupport.backupPath

        // 交付行仍在（DB 段尚未成功）：绝不删备份。
        let retained = await fixture.phase.removeFinalizeBackup(
            xmpPath: xmpPath, backupPath: backupPath)
        guard case .retained(let reason) = retained else {
            Issue.record("期望 .retained，实际 \(retained)")
            return
        }
        #expect(reason.hasPrefix("delivery-reappeared"))
        #expect(fixture.port.removedPathsSnapshot.isEmpty)
        #expect(fixture.port.contents(backupPath) == "original")

        // DB 删除成功之后：删备份，重复调用 .absent（重放/重试安全）。
        // 夹具的 linkSession 默认不写 confirmed_at；删除门禁要求全部关联会话已确认。
        _ = try fixture.db.exec(
            "UPDATE delivery_sessions SET confirmed_at = '2026-01-01T00:00:00.000Z'")
        let deleted = try fixture.repo.deleteSyncedDelivery(
            xmpPath: xmpPath, deliveryId: fixture.row.id, revision: fixture.row.revision)
        #expect(deleted == .deleted)
        let removed = await fixture.phase.removeFinalizeBackup(
            xmpPath: xmpPath, backupPath: backupPath)
        #expect(removed == .removed)
        #expect(fixture.port.contents(backupPath) == nil)
        #expect(fixture.port.contents(DeliveryTestSupport.xmpPath) == "gather-written")

        let repeated = await fixture.phase.removeFinalizeBackup(
            xmpPath: xmpPath, backupPath: backupPath)
        #expect(repeated == .absent)
    }

    /// P1-1：删除失败只上报（.failed），绝不抛出；行已删，不再回滚。
    @Test func removeFinalizeBackupReportsFailureWithoutThrowing() async throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        let xmpPath = fixture.row.xmpPath
        let backupPath = DeliveryTestSupport.backupPath
        _ = try fixture.db.exec(
            "UPDATE delivery_sessions SET confirmed_at = '2026-01-01T00:00:00.000Z'")
        let deleted = try fixture.repo.deleteSyncedDelivery(
            xmpPath: xmpPath, deliveryId: fixture.row.id, revision: fixture.row.revision)
        #expect(deleted == .deleted)
        fixture.port.setRemoveFailure(DeliveryTestFileError.missingBackup(backupPath))

        let outcome = await fixture.phase.removeFinalizeBackup(
            xmpPath: xmpPath, backupPath: backupPath)

        guard case .failed(let reason) = outcome else {
            Issue.record("期望 .failed，实际 \(outcome)")
            return
        }
        #expect(reason.contains("missingBackup"))
        #expect(fixture.port.contents(backupPath) == "original")
        #expect(try fixture.repo.get(xmpPath) == nil)
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
