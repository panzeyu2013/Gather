// desktop/native/gather-core/Tests/GatherCoreTests/Services/DeliveryCoordinatorTests.swift
// Cut 2 / S4：DeliveryCoordinator 的行为门禁（内存 SchemaV1 + 内存 XMP 假件）。
//
// 覆盖面：
// 1. confirm：pending/failed/writing/conflict 门禁；written 成功后单事务翻 synced；
//    会话状态由聚合派生；重复 confirm 幂等。
// 2. 跨会话门禁：先确认的会话只落 confirmed_at，delivery 留在 written，
//    summary.unconfirmedSessionIds 指名阻塞会话。
// 3. cleanup：恢复备份 → 删 delivery/items/links → 删 intent；重复 cleanup 幂等。
// 4. restore 失败保留 prepared intent；replay 重试成功（文件+DB）。
// 5. fileDone 后崩溃：replay 只补 DB，绝不重放文件。
// 6. prepared 后崩溃：replay 重做文件+DB。
// 7. 外部修改：标 conflict、不恢复、不删行、不建 intent。
// 8. 未确认（written）交付不进入 cleanup。
// 9. 跨模块 item（P1-8）：其它模块 pending/failed 阻断整条 cleanup 且不碰文件；
//    其它模块全 synced 时只清本模块 item、保留交付；清干净后正常删除。
//
// 建库口径与 DeliveryRepoTests 一致：DBConnection(path: ":memory:") + exec(SchemaV1.sql)。

import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
@testable import GatherDelivery

// MARK: - fixtures

private func makeCoordinatorV1DB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try db.exec(SchemaV1.sql)
    return db
}

private func coordinatorInsertSession(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, reload_acked_at, created_at, updated_at)
        VALUES (?, '', 'draft', '2026-01-01T00:00:00.000Z',
                '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(id)])
}

private func coordinatorInsertPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
        VALUES (?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([
            .text(id), .text(sessionId), .text("/photos/" + id + ".jpg"), .text(id + ".jpg"),
        ])
}

private enum FakeFileError: Error, Equatable {
    case missingBackup(String)
    case injected
}

/// 内存 XMP 假件：restore 是覆盖写（幂等），removeFile 只删内存键。
private final class FakeDeliveryFilePort: DeliveryFilePort, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]
    private var restoredTargets: [String] = []
    private var removedPaths: [String] = []
    private var restoreFailure: Error?
    private var removeFailure: Error?

    init(storage: [String: String] = [:]) {
        self.storage = storage
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func setContents(_ path: String, _ value: String) {
        locked { storage[path] = value }
    }

    func contents(_ path: String) -> String? {
        locked { storage[path] }
    }

    func setRestoreFailure(_ error: Error?) {
        locked { restoreFailure = error }
    }

    func setRemoveFailure(_ error: Error?) {
        locked { removeFailure = error }
    }

    var restoreCallCount: Int {
        locked { restoredTargets.count }
    }

    var removedPathsSnapshot: [String] {
        locked { removedPaths }
    }

    func fileExists(_ path: String) -> Bool {
        locked { storage[path] != nil }
    }

    func restore(photoPath: String, backupPath: String) async throws {
        // 与真实 XMPProvider 同一路径语义：photo.ext → photo.xmp（TSPath.xmpSidecarPath）。
        let target = TSPath.xmpSidecarPath(photoPath)
        try locked {
            restoredTargets.append(target)
            if let restoreFailure { throw restoreFailure }
            guard let backup = storage[backupPath] else {
                throw FakeFileError.missingBackup(backupPath)
            }
            storage[target] = backup
        }
    }

    func removeFile(_ path: String) async throws {
        try locked {
            removedPaths.append(path)
            if let removeFailure { throw removeFailure }
            storage.removeValue(forKey: path)
        }
    }
}

private struct CoordinatorHarness {
    let db: DBConnection
    let deliveryRepo: DeliveryRepo
    let intentRepo: DeliveryIntentRepo
    let summaryQuery: DeliverySummaryQuery
    let files: FakeDeliveryFilePort
    let coordinator: DeliveryCoordinator

    init(
        fingerprint: @escaping DeliveryFingerprintProvider = { _ in "fp-current" }
    ) throws {
        let db = try makeCoordinatorV1DB()
        try coordinatorInsertSession(db, "s1")
        try coordinatorInsertSession(db, "s2")
        let deliveryRepo = DeliveryRepo(connection: db)
        let intentRepo = DeliveryIntentRepo(connection: db)
        let files = FakeDeliveryFilePort()
        self.db = db
        self.deliveryRepo = deliveryRepo
        self.intentRepo = intentRepo
        self.summaryQuery = DeliverySummaryQuery(connection: db)
        self.files = files
        self.coordinator = DeliveryCoordinator(
            connection: db,
            deliveryRepo: deliveryRepo,
            intentRepo: intentRepo,
            files: files,
            fingerprint: fingerprint,
            resolvePhotoPath: { _, delivery in delivery.photoPath }
        )
    }

    func insertPhoto(_ id: String, sessionId: String = "s1") throws {
        try coordinatorInsertPhoto(db, id: id, sessionId: sessionId)
    }

    /// §5.4-2：清掉 reload-ack 验证门禁（session 默认已确认）。
    func clearReloadAck(_ sessionId: String = "s1") throws {
        _ = try db.prepare("UPDATE sessions SET reload_acked_at = NULL WHERE id = ?")
            .run([.text(sessionId)])
    }
}

/// P0-1 的确定性注入点：在指纹复核的 await 窗口里写入一次真实新输入
/// （mergeInput → revision + 1、status = pending），模拟 cleanup/replay 文件阶段
/// 期间用户继续编辑。fingerprint 调用计数：cleanup 的第 1 次是 prepare 前的外
/// 部修改检查，第 2 次是文件阶段守卫；replay 只有守卫这 1 次。
private final class NewInputInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var callCount = 0
    private var injectOnCall = 1
    private var repo: DeliveryRepo?
    private var xmpPath = ""
    private var photoPath = ""
    private var expectedRevision: Int64 = 0

    func arm(
        deliveryRepo: DeliveryRepo,
        xmpPath: String,
        photoPath: String,
        expectedRevision: Int64,
        injectOnCall: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.repo = deliveryRepo
        self.xmpPath = xmpPath
        self.photoPath = photoPath
        self.expectedRevision = expectedRevision
        self.injectOnCall = injectOnCall
        self.armed = true
    }

    func fingerprint(_ path: String) async throws -> String {
        let plan: (repo: DeliveryRepo, xmpPath: String, photoPath: String, expected: Int64)? =
            lock.withLock {
                callCount += 1
                guard armed, callCount == injectOnCall, let repo else { return nil }
                return (repo, xmpPath, photoPath, expectedRevision)
            }
        if let plan {
            _ = try plan.repo.mergeInput(
                xmpPath: plan.xmpPath,
                photoPath: plan.photoPath,
                expectedRevision: plan.expected,
                newRevision: plan.expected + 1,
                baseFingerprint: "fp-new",
                baseValues: .object([:])
            )
        }
        return "fp-current"
    }
}

// MARK: - tests

struct DeliveryCoordinatorTests {
    private let xmp = "/v/IMG_1.xmp"
    private let photo = "/v/IMG_1.jpg"
    private let backup = "/backup/IMG_1.xmp"

    private func createDelivery(
        _ harness: CoordinatorHarness,
        xmpPath: String,
        photoPath: String,
        revision: Int64 = 1
    ) throws -> DeliveryRow {
        try harness.deliveryRepo.createOrGet(
            xmpPath: xmpPath,
            photoPath: photoPath,
            revision: revision
        )
    }

    private func driveToWritten(
        _ harness: CoordinatorHarness,
        xmpPath: String,
        revision: Int64 = 1,
        backupPath: String = "",
        baseFingerprint: String = "fp-current"
    ) throws {
        _ = try harness.deliveryRepo.markWriting(xmpPath: xmpPath, revision: revision)
        _ = try harness.deliveryRepo.markWritten(
            xmpPath: xmpPath,
            revision: revision,
            baseFingerprint: baseFingerprint,
            baseValues: .object([:]),
            backupPath: backupPath
        )
    }

    /// 建一条 written 交付（不 confirm）：调用方自行 link session / upsert item。
    private func makeWrittenDelivery(
        _ harness: CoordinatorHarness,
        xmpPath: String,
        photoPath: String,
        revision: Int64 = 1,
        backupPath: String = "",
        baseFingerprint: String = "fp-current"
    ) throws -> DeliveryRow {
        let row = try createDelivery(
            harness, xmpPath: xmpPath, photoPath: photoPath, revision: revision)
        try driveToWritten(
            harness, xmpPath: xmpPath, revision: revision,
            backupPath: backupPath, baseFingerprint: baseFingerprint)
        return row
    }

    /// 单会话既确认的 synced 交付（culling item 已 synced）。
    private func makeSyncedDelivery(
        _ harness: CoordinatorHarness,
        xmpPath: String = "/v/IMG_1.xmp",
        photoPath: String = "/v/IMG_1.jpg",
        photoId: String = "p1",
        revision: Int64 = 1,
        backupPath: String = "",
        baseFingerprint: String = "fp-current"
    ) throws {
        try harness.insertPhoto(photoId)
        _ = try createDelivery(
            harness, xmpPath: xmpPath, photoPath: photoPath, revision: revision)
        _ = try harness.deliveryRepo.linkSession(xmpPath: xmpPath, sessionId: "s1")
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: xmpPath, photoId: photoId, module: .culling, status: .written)
        try driveToWritten(
            harness, xmpPath: xmpPath, revision: revision,
            backupPath: backupPath, baseFingerprint: baseFingerprint)
        _ = try harness.coordinator.confirm(sessionId: "s1", module: .culling)
    }

    // MARK: confirm

    @Test func confirmGatesPendingThenSyncsInOneTransaction() throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        try harness.insertPhoto("p1")

        _ = try createDelivery(harness, xmpPath: xmp, photoPath: photo)
        _ = try harness.deliveryRepo.linkSession(xmpPath: xmp, sessionId: "s1")
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: xmp, photoId: "p1", module: .culling, status: .pending)

        do {
            _ = try harness.coordinator.confirm(sessionId: "s1", module: .culling)
            Issue.record("pending 交付必须被 confirm 门禁拒绝")
        } catch let error as DeliveryCoordinatorError {
            #expect(error == .confirmIncomplete(
                blockers: ["delivery:pending=1", "item:pending=1"]))
        } catch {
            Issue.record("错误类型不符: \(error)")
        }

        // pending → writing → written 后，门禁放行。
        _ = try harness.deliveryRepo.markWriting(xmpPath: xmp, revision: 1)
        _ = try harness.deliveryRepo.markWritten(
            xmpPath: xmp, revision: 1,
            baseFingerprint: "fp-current", baseValues: .object([:]), backupPath: "")
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: xmp, photoId: "p1", module: .culling, status: .written)

        let summary = try harness.coordinator.confirm(sessionId: "s1", module: .culling)
        #expect(summary.confirmedLinks == 1)
        #expect(summary.deliveriesSynced == 1)
        #expect(summary.itemsSynced == 1)
        #expect(summary.unconfirmedSessionIds.isEmpty)
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .synced)

        // 会话状态派生（不写 sessions 列）。
        let derived = try harness.coordinator.sessionSummary(
            sessionId: "s1", module: .culling)
        #expect(derived.state == .synced)
        #expect(derived.writebackStatus == .done)
        #expect(derived.blockers.isEmpty)

        // 重复 confirm 幂等：不再产生迁移。
        let repeated = try harness.coordinator.confirm(sessionId: "s1", module: .culling)
        #expect(repeated.confirmedLinks == 0)
        #expect(repeated.deliveriesSynced == 0)
        #expect(repeated.itemsSynced == 0)
    }

    @Test func confirmRejectsEveryBlockingDeliveryState() throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        try harness.insertPhoto("p1")

        let fixtures: [(path: String, target: DeliveryStatus)] = [
            ("/v/a-pending.xmp", .pending),
            ("/v/b-writing.xmp", .writing),
            ("/v/c-failed.xmp", .failed),
            ("/v/d-conflict.xmp", .conflict),
        ]
        for fixture in fixtures {
            _ = try createDelivery(
                harness, xmpPath: fixture.path, photoPath: "/v/shared.jpg")
            _ = try harness.deliveryRepo.linkSession(
                xmpPath: fixture.path, sessionId: "s1")
            _ = try harness.deliveryRepo.upsertItem(
                xmpPath: fixture.path, photoId: "p1",
                module: .culling, status: .pending)
            switch fixture.target {
            case .writing:
                _ = try harness.deliveryRepo.markWriting(
                    xmpPath: fixture.path, revision: 1)
            case .failed:
                _ = try harness.deliveryRepo.markFailed(
                    xmpPath: fixture.path, revision: 1, errorMessage: "injected")
            case .conflict:
                _ = try harness.deliveryRepo.markConflict(
                    xmpPath: fixture.path, revision: 1, errorMessage: "external")
            case .pending:
                break
            default:
                break
            }
        }

        do {
            _ = try harness.coordinator.confirm(sessionId: "s1", module: .culling)
            Issue.record("四种阻断态都必须被 confirm 门禁拒绝")
        } catch let error as DeliveryCoordinatorError {
            guard case .confirmIncomplete(let blockers) = error else {
                Issue.record("错误类型不符: \(error)")
                return
            }
            #expect(blockers == [
                "delivery:pending=1",
                "delivery:writing=1",
                "delivery:failed=1",
                "delivery:conflict=1",
                "item:pending=4",
            ])
        } catch {
            Issue.record("错误类型不符: \(error)")
        }
    }

    @Test func confirmWaitsForAllLinkedSessionsBeforeSyncing() throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        try harness.insertPhoto("p1", sessionId: "s1")
        // 共享侧车的每个会话都必须有「本会话照片 × 模块」的 item，
        // 否则 module scope 的 confirm 不会把该交付算进另一会话的确认范围。
        try harness.insertPhoto("p2", sessionId: "s2")

        _ = try createDelivery(harness, xmpPath: xmp, photoPath: photo)
        _ = try harness.deliveryRepo.linkSession(xmpPath: xmp, sessionId: "s1")
        _ = try harness.deliveryRepo.linkSession(xmpPath: xmp, sessionId: "s2")
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: xmp, photoId: "p1", module: .culling, status: .written)
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: xmp, photoId: "p2", module: .culling, status: .written)
        try driveToWritten(harness, xmpPath: xmp)

        let first = try harness.coordinator.confirm(sessionId: "s1", module: .culling)
        #expect(first.confirmedLinks == 1)
        #expect(first.deliveriesSynced == 0, "s2 未确认：不得翻 synced")
        #expect(first.itemsSynced == 0)
        #expect(first.unconfirmedSessionIds == ["s2"])
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .written)
        #expect(try harness.coordinator.sessionSummary(
            sessionId: "s1", module: .culling).state == .written)

        let second = try harness.coordinator.confirm(sessionId: "s2", module: .culling)
        #expect(second.confirmedLinks == 1)
        #expect(second.deliveriesSynced == 1)
        // 一个侧车文件没有模块/会话边界：confirm 把该交付下所有 written item 一起推进。
        #expect(second.itemsSynced == 2)
        #expect(second.unconfirmedSessionIds.isEmpty)
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .synced)
    }

    // MARK: cleanup

    @Test func cleanupRestoresBackupDeletesRowsAndIsIdempotent() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)

        let result = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)
        #expect(result.deletedCount == 1)
        #expect(result.conflictedCount == 0)
        #expect(result.skippedCount == 0)
        #expect(result.errors.isEmpty)
        #expect(harness.files.contents(xmp) == "original")
        #expect(harness.files.restoreCallCount == 1)
        #expect(try harness.deliveryRepo.get(xmp) == nil)
        #expect(try harness.deliveryRepo.listItems(sessionId: "s1").isEmpty)
        #expect(try harness.intentRepo.pending().isEmpty)
        #expect(try harness.coordinator.sessionSummary(
            sessionId: "s1", module: .culling).state == .idle)

        // 重复 cleanup 幂等：没有候选、没有新 intent。
        let repeated = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)
        #expect(repeated.deletedCount == 0)
        #expect(repeated.conflictedCount == 0)
        #expect(repeated.errors.isEmpty)
        #expect(try harness.intentRepo.pending().isEmpty)
    }

    @Test func cleanupWithoutBackupRemovesWrittenSidecar() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(xmp, "gather-written")
        // backupPath 为空 = 写入前没有原始侧车：cleanup 删除本次写入的文件。
        try makeSyncedDelivery(harness)

        let result = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)
        #expect(result.deletedCount == 1)
        #expect(result.errors.isEmpty)
        #expect(harness.files.removedPathsSnapshot == [xmp])
        #expect(harness.files.contents(xmp) == nil)
        #expect(try harness.deliveryRepo.get(xmp) == nil)
    }

    @Test func cleanupSkipsWhenForeignModuleItemsPending() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)
        // 同一个侧车文件上另一个模块还有未写盘的输入（P1-8 的真实形态）。
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: xmp, photoId: "p1", module: .metadata,
            attributes: ["rating": .number(5)], status: .pending)

        let result = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)

        #expect(result.deletedCount == 0)
        #expect(result.skippedCount == 1)
        #expect(result.errors.contains {
            $0.hasPrefix("XMP_CLEANUP_INCOMPLETE_ITEMS")
                && $0.contains("module=metadata")
                && $0.contains("status=pending")
        })
        // 不碰文件、不建 intent、不删任何行。
        #expect(harness.files.restoreCallCount == 0)
        #expect(harness.files.contents(xmp) == "gather-written")
        #expect(try harness.intentRepo.pending().isEmpty)
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .synced)
        #expect(try harness.deliveryRepo.item(
            xmpPath: xmp, photoId: "p1", module: .culling)?.typedStatus == .synced)
        #expect(try harness.deliveryRepo.item(
            xmpPath: xmp, photoId: "p1", module: .metadata)?.typedStatus == .pending)

        // 其它模块的待写入输入处理掉之后，cleanup 恢复为正常删除。
        _ = try harness.deliveryRepo.deleteItems(
            xmpPath: xmp, module: .metadata, statuses: [.pending])
        let clean = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)
        #expect(clean.deletedCount == 1)
        #expect(harness.files.contents(xmp) == "original")
        #expect(try harness.deliveryRepo.get(xmp) == nil)
    }

    @Test func cleanupSkipsWhenForeignModuleItemsFailed() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        try makeSyncedDelivery(harness)
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: xmp, photoId: "p1", module: .metadata,
            status: .failed, errorMessage: "injected")

        let result = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)

        #expect(result.deletedCount == 0)
        #expect(result.skippedCount == 1)
        #expect(result.errors.contains {
            $0.hasPrefix("XMP_CLEANUP_INCOMPLETE_ITEMS")
                && $0.contains("module=metadata")
                && $0.contains("status=failed")
        })
        #expect(try harness.deliveryRepo.get(xmp) != nil)
        #expect(try harness.deliveryRepo.item(
            xmpPath: xmp, photoId: "p1", module: .metadata)?.typedStatus == .failed)
        #expect(harness.files.restoreCallCount == 0)
    }

    @Test func cleanupRetainsDeliveryWhenForeignModuleItemsAreSynced() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: xmp, photoId: "p1", module: .metadata,
            attributes: ["label": .string("Green")], status: .synced)

        let result = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)

        #expect(result.deletedCount == 0)
        #expect(result.skippedCount == 1)
        #expect(result.errors.contains {
            $0.hasPrefix("XMP_CLEANUP_RETAINED_FOREIGN_ITEMS")
                && $0.contains("modules=metadata")
        })
        // 只清本模块 item；交付与其它模块 item 保留，文件绝不动。
        #expect(try harness.deliveryRepo.item(
            xmpPath: xmp, photoId: "p1", module: .culling) == nil)
        #expect(try harness.deliveryRepo.item(
            xmpPath: xmp, photoId: "p1", module: .metadata)?.typedStatus == .synced)
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .synced)
        #expect(harness.files.restoreCallCount == 0)
        #expect(harness.files.contents(xmp) == "gather-written")
    }

    @Test func cleanupRestoreFailureKeepsPreparedIntentThenReplayRetries() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)

        harness.files.setRestoreFailure(FakeFileError.injected)
        let failed = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)
        #expect(failed.deletedCount == 0)
        #expect(failed.errors.count == 1)
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .synced)

        let backlog = try harness.intentRepo.pending()
        #expect(backlog.prepared.count == 1)
        #expect(backlog.fileDone.isEmpty)

        // P0-1：intent payload 必须带 revision/status/base_fingerprint 快照。
        let prepared = try #require(backlog.prepared.first)
        let routed = try #require(DeliveryCleanupPayload(intent: prepared))
        #expect(routed.revision == 1)
        #expect(routed.status == DeliveryStatus.synced.rawValue)
        #expect(routed.baseFingerprint == "fp-current")

        // 恢复条件后 replay：prepared 相位重做文件 + DB。
        harness.files.setRestoreFailure(nil)
        let replayed = try await harness.coordinator.replay()
        #expect(replayed.appliedCount == 1)
        #expect(replayed.failedCount == 0)
        #expect(harness.files.contents(xmp) == "original")
        #expect(try harness.deliveryRepo.get(xmp) == nil)
        #expect(try harness.intentRepo.pending().isEmpty)
    }

    @Test func replayPreparedRedoesFileAndDB() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)

        let row = try #require(try harness.deliveryRepo.get(xmp))
        let payload = DeliveryCleanupPayload(delivery: row, photoPath: photo)
        _ = try harness.intentRepo.prepare(
            kind: .cleanup, xmpPath: xmp, payload: payload.json)

        let replayed = try await harness.coordinator.replay()
        #expect(replayed.appliedCount == 1)
        #expect(replayed.failedCount == 0)
        #expect(harness.files.restoreCallCount == 1)
        #expect(harness.files.contents(xmp) == "original")
        #expect(try harness.deliveryRepo.get(xmp) == nil)

        // 重复 replay 幂等：intent 已闭环，不再触碰文件。
        let repeated = try await harness.coordinator.replay()
        #expect(repeated.appliedCount == 0)
        #expect(repeated.skippedCount == 0)
        #expect(repeated.failedCount == 0)
        #expect(harness.files.restoreCallCount == 1)
        #expect(harness.files.contents(xmp) == "original")
    }

    @Test func replayFileDoneOnlyAppliesDBWithoutReplayingFile() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "already-restored")
        try makeSyncedDelivery(harness, backupPath: backup)

        let row = try #require(try harness.deliveryRepo.get(xmp))
        let payload = DeliveryCleanupPayload(delivery: row, photoPath: photo)
        let intentId = try harness.intentRepo.prepare(
            kind: .cleanup, xmpPath: xmp, payload: payload.json)
        _ = try harness.intentRepo.advance(id: intentId, to: .fileDone)

        let replayed = try await harness.coordinator.replay()
        #expect(replayed.appliedCount == 1)
        #expect(replayed.failedCount == 0)
        #expect(harness.files.restoreCallCount == 0, "fileDone 绝不重放文件")
        #expect(harness.files.contents(xmp) == "already-restored")
        #expect(try harness.deliveryRepo.get(xmp) == nil)
        #expect(try harness.intentRepo.pending().isEmpty)
    }

    @Test func cleanupMarksConflictWhenXMPChangedExternally() async throws {
        let harness = try CoordinatorHarness(fingerprint: { _ in "fp-edited" })
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "external-edit")
        try makeSyncedDelivery(
            harness, backupPath: backup, baseFingerprint: "fp-base")

        let result = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)
        #expect(result.deletedCount == 0)
        #expect(result.conflictedCount == 1)
        #expect(result.errors.isEmpty)
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .conflict)
        #expect(harness.files.restoreCallCount == 0, "冲突时不得恢复/覆盖外部修改")
        #expect(harness.files.contents(xmp) == "external-edit")
        #expect(try harness.intentRepo.pending().isEmpty)
    }

    @Test func cleanupIgnoresWrittenButUnconfirmedDelivery() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        try harness.insertPhoto("p1")
        _ = try createDelivery(harness, xmpPath: xmp, photoPath: photo)
        _ = try harness.deliveryRepo.linkSession(xmpPath: xmp, sessionId: "s1")
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(harness, xmpPath: xmp, backupPath: backup)

        let result = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)
        #expect(result.deletedCount == 0)
        #expect(result.skippedCount == 0)
        #expect(result.errors.isEmpty)
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .written)
        #expect(try harness.intentRepo.pending().isEmpty)
    }

    // MARK: confirm/finalize 的 reload-ack 门禁 + finalize（S5c-2b-1）

    @Test func confirmRequiresReloadAck() throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        try harness.insertPhoto("p1")
        _ = try createDelivery(harness, xmpPath: xmp, photoPath: photo)
        _ = try harness.deliveryRepo.linkSession(xmpPath: xmp, sessionId: "s1")
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(harness, xmpPath: xmp)
        try harness.clearReloadAck()

        do {
            _ = try harness.coordinator.confirm(sessionId: "s1", module: .culling)
            Issue.record("未 ack reload 时必须拒绝 confirm")
        } catch let error as DeliveryCoordinatorError {
            #expect(error == .reloadNotAcknowledged(sessionId: "s1"))
            #expect(error.code == "XMP_CONFIRM_REQUIRES_SYNC")
        }
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .written)
        let links = try harness.db.prepare(
            "SELECT confirmed_at FROM delivery_sessions WHERE session_id = 's1'"
        ).query()
        #expect(links.allSatisfy { ($0[0].textValue ?? "").isEmpty })
    }

    @Test func finalizeDropsWithoutRestoreAndDeletesBackup() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)

        let result = try await harness.coordinator.finalize(
            sessionId: "s1", module: .culling)

        #expect(result.deletedCount == 1)
        #expect(result.skippedCount == 0)
        #expect(result.errors.isEmpty)
        #expect(harness.files.contents(xmp) == "gather-written", "finalize 保留 XMP")
        #expect(harness.files.contents(backup) == nil, "备份文件被丢弃")
        #expect(harness.files.restoreCallCount == 0, "finalize 绝不 restore")
        #expect(try harness.deliveryRepo.get(xmp) == nil)
        #expect(try harness.intentRepo.pending().isEmpty)
        #expect(try harness.coordinator.sessionSummary(
            sessionId: "s1", module: .culling).state == .idle)

        // 幂等：没有候选，返回 0 且不建 intent。
        let repeated = try await harness.coordinator.finalize(
            sessionId: "s1", module: .culling)
        #expect(repeated.deletedCount == 0)
        #expect(repeated.errors.isEmpty)
        #expect(try harness.intentRepo.pending().isEmpty)
    }

    @Test func finalizeRequiresReloadAck() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)
        try harness.clearReloadAck()

        do {
            _ = try await harness.coordinator.finalize(
                sessionId: "s1", module: .culling)
            Issue.record("未 ack reload 时必须拒绝 finalize")
        } catch let error as DeliveryCoordinatorError {
            #expect(error == .reloadNotAcknowledged(sessionId: "s1"))
        }
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .synced)
        #expect(harness.files.contents(backup) == "original")
        #expect(try harness.intentRepo.pending().isEmpty)
    }

    @Test func finalizeSkipsConflictAndUnconfirmedDeliveries() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        // p3：先确认（synced，唯一候选）——confirm 是会话+模块门禁，必须
        // 在 conflict/written 夹具出现之前完成，否则会被 XMP_CONFIRM_INCOMPLETE 拒绝。
        try makeSyncedDelivery(
            harness, xmpPath: "/v/p3.xmp", photoPath: "/v/p3.jpg", photoId: "p3")
        try harness.insertPhoto("p1", sessionId: "s1")
        try harness.insertPhoto("p2", sessionId: "s1")

        // p1：conflict（不是候选）。
        _ = try createDelivery(harness, xmpPath: "/v/p1.xmp", photoPath: "/v/p1.jpg")
        try driveToWritten(harness, xmpPath: "/v/p1.xmp")
        _ = try harness.deliveryRepo.markConflict(
            xmpPath: "/v/p1.xmp", revision: 1, errorMessage: "external")
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: "/v/p1.xmp", photoId: "p1", module: .culling, status: .written)
        _ = try harness.deliveryRepo.linkSession(xmpPath: "/v/p1.xmp", sessionId: "s1")

        // p2：written 未确认（不是候选）。
        _ = try createDelivery(harness, xmpPath: "/v/p2.xmp", photoPath: "/v/p2.jpg")
        try driveToWritten(harness, xmpPath: "/v/p2.xmp")
        _ = try harness.deliveryRepo.upsertItem(
            xmpPath: "/v/p2.xmp", photoId: "p2", module: .culling, status: .written)
        _ = try harness.deliveryRepo.linkSession(xmpPath: "/v/p2.xmp", sessionId: "s1")

        let result = try await harness.coordinator.finalize(
            sessionId: "s1", module: .culling)
        #expect(result.deletedCount == 1)
        #expect(result.errors.isEmpty)
        #expect(try harness.deliveryRepo.get("/v/p1.xmp")?.typedStatus == .conflict)
        #expect(try harness.deliveryRepo.get("/v/p2.xmp")?.typedStatus == .written)
        #expect(try harness.deliveryRepo.get("/v/p3.xmp") == nil)
    }

    @Test func replayPreparedFinalizeRemovesBackupThenDeletesRows() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)

        let row = try #require(try harness.deliveryRepo.get(xmp))
        let payload = DeliveryCleanupPayload(
            delivery: row, photoPath: photo, action: .finalize)
        _ = try harness.intentRepo.prepare(
            kind: .cleanup, xmpPath: xmp, payload: payload.json)

        let replayed = try await harness.coordinator.replay()
        #expect(replayed.appliedCount == 1)
        #expect(replayed.failedCount == 0)
        #expect(harness.files.contents(backup) == nil)
        #expect(harness.files.contents(xmp) == "gather-written")
        #expect(harness.files.restoreCallCount == 0)
        #expect(try harness.deliveryRepo.get(xmp) == nil)
        #expect(try harness.intentRepo.pending().isEmpty)
    }

    @Test func replayFileDoneFinalizeOnlyDeletesDB() async throws {
        let harness = try CoordinatorHarness()
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)

        let row = try #require(try harness.deliveryRepo.get(xmp))
        let payload = DeliveryCleanupPayload(
            delivery: row, photoPath: photo, action: .finalize)
        let intentId = try harness.intentRepo.prepare(
            kind: .cleanup, xmpPath: xmp, payload: payload.json)
        _ = try harness.intentRepo.advance(id: intentId, to: .fileDone)

        let replayed = try await harness.coordinator.replay()
        #expect(replayed.appliedCount == 1)
        #expect(harness.files.contents(backup) == "original", "fileDone 不重放文件")
        #expect(harness.files.removedPathsSnapshot.isEmpty)
        #expect(harness.files.restoreCallCount == 0)
        #expect(harness.files.contents(xmp) == "gather-written")
        #expect(try harness.deliveryRepo.get(xmp) == nil)
    }

    // MARK: - P0-1：文件阶段 revision/指纹守卫

    /// cleanup 的文件阶段守卫：prepare 之后、restore 之前出现新输入
    /// （revision+1 / status=pending）→ 绝不能用旧备份覆盖新内容。
    @Test func cleanupAbortsRestoreWhenNewInputArrivesDuringFilePhase() async throws {
        let injector = NewInputInjector()
        let harness = try CoordinatorHarness(fingerprint: injector.fingerprint)
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)
        injector.arm(
            deliveryRepo: harness.deliveryRepo,
            xmpPath: xmp,
            photoPath: photo,
            expectedRevision: 1,
            injectOnCall: 2
        )

        let result = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)

        #expect(result.deletedCount == 0)
        #expect(result.conflictedCount == 0)
        #expect(result.skippedCount == 1)
        #expect(result.errors.contains {
            $0.contains("XMP_CLEANUP_ABANDONED") && $0.contains("revision-changed")
        })
        #expect(harness.files.restoreCallCount == 0, "revision 已变：绝不 restore 旧备份")
        #expect(harness.files.contents(xmp) == "gather-written", "新写入的侧车必须保留")
        let row = try #require(try harness.deliveryRepo.get(xmp))
        #expect(row.revision == 2)
        #expect(row.typedStatus == .pending)
        #expect(try harness.intentRepo.pending().isEmpty, "守卫拒绝后 intent 必须标终态")
    }

    /// 无备份场景（cleanup 删侧车）同样要守卫：新输入到达时绝不 unlink 新文件。
    @Test func cleanupAbortsSidecarDeleteWhenNewInputArrivesDuringFilePhase() async throws {
        let injector = NewInputInjector()
        let harness = try CoordinatorHarness(fingerprint: injector.fingerprint)
        defer { harness.db.close() }
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness)
        injector.arm(
            deliveryRepo: harness.deliveryRepo,
            xmpPath: xmp,
            photoPath: photo,
            expectedRevision: 1,
            injectOnCall: 2
        )

        let result = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)

        #expect(result.deletedCount == 0)
        #expect(result.skippedCount == 1)
        #expect(result.errors.contains { $0.contains("XMP_CLEANUP_ABANDONED") })
        #expect(harness.files.removedPathsSnapshot.isEmpty, "新输入到达后绝不删侧车")
        #expect(harness.files.contents(xmp) == "gather-written")
        #expect(try harness.deliveryRepo.get(xmp)?.revision == 2)
        #expect(try harness.intentRepo.pending().isEmpty)
    }

    /// 行快照一致但盘上指纹在守卫的 await 窗口里变了：标 conflict，不 restore。
    @Test func cleanupMarksConflictWhenFingerprintChangesDuringFilePhase() async throws {
        let calls = CallCounter()
        let harness = try CoordinatorHarness(fingerprint: { _ in
            calls.next() == 1 ? "fp-current" : "fp-edited"
        })
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "external-edit")
        try makeSyncedDelivery(harness, backupPath: backup, baseFingerprint: "fp-current")

        let result = try await harness.coordinator.cleanup(
            sessionId: "s1", module: .culling)

        #expect(result.deletedCount == 0)
        #expect(result.conflictedCount == 1)
        #expect(result.errors.isEmpty)
        #expect(result.conflictedXmpPaths == [xmp])
        #expect(harness.files.restoreCallCount == 0)
        #expect(harness.files.contents(xmp) == "external-edit")
        #expect(try harness.deliveryRepo.get(xmp)?.typedStatus == .conflict)
        #expect(try harness.intentRepo.pending().isEmpty)
    }

    /// replay 的 prepared 相位：payload 里记录的 revision/fingerprint 已过期时
    /// 绝不重做文件；intent 标终态 + 错误可见，重复 replay 幂等。
    @Test func replayPreparedAbortsWhenNewInputArrived() async throws {
        let injector = NewInputInjector()
        let harness = try CoordinatorHarness(fingerprint: injector.fingerprint)
        defer { harness.db.close() }
        harness.files.setContents(backup, "original")
        harness.files.setContents(xmp, "gather-written")
        try makeSyncedDelivery(harness, backupPath: backup)

        let row = try #require(try harness.deliveryRepo.get(xmp))
        let payload = DeliveryCleanupPayload(delivery: row, photoPath: photo)
        _ = try harness.intentRepo.prepare(
            kind: .cleanup, xmpPath: xmp, payload: payload.json)
        injector.arm(
            deliveryRepo: harness.deliveryRepo,
            xmpPath: xmp,
            photoPath: photo,
            expectedRevision: 1,
            injectOnCall: 1
        )

        let replayed = try await harness.coordinator.replay()
        #expect(replayed.appliedCount == 0)
        #expect(replayed.failedCount == 0)
        #expect(replayed.skippedCount == 1)
        #expect(replayed.errors.contains {
            $0.contains("XMP_CLEANUP_ABANDONED") && $0.contains("revision-changed")
        })
        #expect(harness.files.restoreCallCount == 0, "旧 revision 的 prepared 不得重放文件")
        #expect(harness.files.contents(xmp) == "gather-written")
        let latest = try #require(try harness.deliveryRepo.get(xmp))
        #expect(latest.revision == 2)
        #expect(latest.typedStatus == .pending)
        #expect(try harness.intentRepo.pending().isEmpty)

        // 重复 replay 幂等：applied intent 已清掉，不再碰文件。
        let repeated = try await harness.coordinator.replay()
        #expect(repeated.appliedCount == 0)
        #expect(repeated.skippedCount == 0)
        #expect(repeated.failedCount == 0)
        #expect(harness.files.restoreCallCount == 0)
        #expect(harness.files.contents(xmp) == "gather-written")
    }
}

/// 线程安全的调用计数器（fingerprint 注入用）。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
