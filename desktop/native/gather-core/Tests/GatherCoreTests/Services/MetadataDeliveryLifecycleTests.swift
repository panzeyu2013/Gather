// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataDeliveryLifecycleTests.swift
// P1 下一波 §3.1 验收：metadata 写回的"确认 → 结束 → 备份回收"生命周期。
//
// 覆盖：
// 1. 100 张写→自动确认→finalize：0 行 / 0 备份，XMP 内容不变（只 drop 不 restore）；
// 2. 自动确认三态：无 C1 写完即 synced；C1 待重载保持 written、reload 后自动 synced；
//    metadata_sync_auto_confirm=0 保持 written（手动确认）；
// 3. 共享文件：只删本模块 item，行/备份留给最后一个模块；最后一个模块结束才删行+备份；
// 4. "先确认再结束"：未确认时 finalize 不动它，notice 带 XMP_CONFIRM_INCOMPLETE；
// 5. 崩溃点：DB 已删、备份删除失败 → 行不回来、备份保留、replay 补删后闭环；
// 6. reload-ack 门禁：C1 在用时拦 confirm，未装 C1（c1Required=false）不拦。
//
// 建库口径与 DeliveryCoordinatorTests 一致（内存 SchemaCurrent + 真实文件的文件端口）。

import Foundation
import os
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherDelivery
@testable import GatherApplication
import GatherTestSupport

// MARK: - fixtures

/// reload-ack 门禁的三种接线（对应 §3.1.2 的三个场景）。
private enum LifecycleGate {
    /// 生产默认：未装 C1 → 组合根注入 c1Required={ false }，门禁关闭。
    case noC1
    /// 装了 C1：requireReloadAck=true + c1Required=true。
    case c1
    /// 未接线（旧行为）：只开 requireReloadAck，门禁常开。
    case legacyOn
}

private final class LifecycleSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(_ values: [String: String]) {
        self.values = values
    }

    func get(_ key: String, _ fallback: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? fallback
    }

    /// #9：端口语义是「未设置 = nil」，不能折叠成空串（默认值由键决定）。
    func stored(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

/// 第一次删除抛错的文件端口（模拟"DB 提交后删备份失败"的崩溃点）。
///
/// 用 OSAllocatedUnfairLock 而不是 NSLock：removeFile 是 async 函数，
/// NSLock.lock() 在异步上下文里是编译期错误（Swift 6）。
private enum LifecycleInjectedError: Error, Equatable {
    case removeFailed
}

private struct LifecycleFixture {
    let db: DBConnection
    let dir: String
    let repo: DeliveryRepo
    let coordinator: DeliveryCoordinator
    let service: MetadataDeliveryService
    let settings: LifecycleSettingsBox

    func cleanup() {
        db.close()
        try? FileManager.default.removeItem(atPath: dir)
    }
}

private func makeLifecycleFixture(
    gate: LifecycleGate = .noC1,
    settings: [String: String] = [:],
    files: (any DeliveryFilePort)? = nil
) throws -> LifecycleFixture {
    let db = try DBConnection(path: ":memory:")
    try db.exec(SchemaCurrent.ddl)
    let dir = try makeTempDir()
    let box = LifecycleSettingsBox(settings)
    let repo = DeliveryRepo(connection: db)
    let requireReloadAck: Bool
    let c1Required: (@Sendable () -> Bool)?
    switch gate {
    case .noC1:
        requireReloadAck = true
        c1Required = { false }
    case .c1:
        requireReloadAck = true
        c1Required = { true }
    case .legacyOn:
        requireReloadAck = true
        c1Required = nil
    }
    let port: any DeliveryFilePort
    if let files {
        port = files
    } else {
        port = FileSystemDeliveryFilePort()
    }
    let coordinator = DeliveryCoordinator(
        connection: db,
        deliveryRepo: repo,
        intentRepo: DeliveryIntentRepo(connection: db),
        files: port,
        fileLock: XMPFileLock(),
        fingerprint: { _ in "lifecycle-fp" },
        resolvePhotoPath: { _, delivery in delivery.photoPath },
        requireReloadAck: requireReloadAck,
        c1Required: c1Required
    )
    let service = MetadataDeliveryService(
        lifecycle: MetadataLifecycleRepo(connection: db),
        coordinator: coordinator,
        settings: ClosureSettingsReader { key in box.stored(key.rawValue) }
    )
    // 会话：默认**没有** reload_acked_at（C1 待重载的初始态）。
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, source_path, created_at, updated_at)
        VALUES (?, '', 'draft', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text("s1"), .text(dir)])
    // delivery_items.photo_id 有外键：100 张端到端用例需要 p0…p99。
    for index in 0..<100 {
        let photoId = "p\(index)"
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
            VALUES (?, 's1', ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run([
                .text(photoId), .text(dir + "/" + photoId + ".jpg"),
                .text(photoId + ".jpg"),
            ])
    }
    return LifecycleFixture(
        db: db, dir: dir, repo: repo, coordinator: coordinator,
        service: service, settings: box)
}

private func markSessionReloadAcked(_ fixture: LifecycleFixture, sessionId: String = "s1") throws {
    _ = try fixture.db.prepare("UPDATE sessions SET reload_acked_at = ? WHERE id = ?")
        .run([.text("2026-02-01T00:00:00.000Z"), .text(sessionId)])
}

private struct SeededLifecycleDelivery {
    let row: DeliveryRow
    let xmpPath: String
    let photoPath: String
    let backupPath: String
}

/// 造一条"已写盘"的交付：真实 xmp/照片/备份文件 + delivery_items(written)。
private func seedLifecycleDelivery(
    _ fixture: LifecycleFixture,
    photoId: String,
    sessionId: String = "s1",
    modules: [DeliveryModule],
    confirmModules: [DeliveryModule] = []
) throws -> SeededLifecycleDelivery {
    let photoPath = fixture.dir + "/" + photoId + ".jpg"
    let xmpPath = TSPath.xmpSidecarPath(photoPath)
    try Data("photo-".utf8).write(to: URL(fileURLWithPath: photoPath))
    try Data("gather-written-\(photoId)".utf8).write(to: URL(fileURLWithPath: xmpPath))
    let backupPath = xmpPath + ".gather-backup-" + UUID().uuidString.lowercased()
    try Data("original-\(photoId)".utf8).write(to: URL(fileURLWithPath: backupPath))

    _ = try fixture.repo.createOrGet(
        xmpPath: xmpPath,
        photoPath: photoPath,
        revision: 1,
        baseFingerprint: "lifecycle-fp",
        baseValues: .object([:])
    )
    for module in modules {
        _ = try fixture.repo.upsertItem(
            xmpPath: xmpPath,
            photoId: photoId,
            module: module,
            attributes: ["rating": .number(3)],
            status: .pending
        )
    }
    _ = try fixture.repo.linkSession(xmpPath: xmpPath, sessionId: sessionId)
    let owner = "lifecycle-" + UUID().uuidString
    _ = try fixture.repo.claimWriting(xmpPath: xmpPath, revision: 1, leaseOwner: owner)
    guard let written = try fixture.repo.markWritten(
        xmpPath: xmpPath,
        revision: 1,
        leaseOwner: owner,
        baseFingerprint: "lifecycle-fp",
        baseValues: .object([:]),
        backupPath: backupPath
    ) else {
        throw LifecycleInjectedError.removeFailed
    }
    for item in try fixture.repo.items(deliveryId: written.id) {
        _ = try fixture.repo.markItem(itemId: item.id, status: .written)
    }
    // 需要 synced 时走真实 confirm（不直接改状态字面量）。
    for module in confirmModules {
        _ = try fixture.repo.confirm(
            scope: .module, sessionId: sessionId, module: module, requireReloadAck: false)
    }
    guard let row = try fixture.repo.get(xmpPath) else {
        throw LifecycleInjectedError.removeFailed
    }
    return SeededLifecycleDelivery(
        row: row, xmpPath: xmpPath, photoPath: photoPath, backupPath: backupPath)
}

private func lifecycleContents(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - 1. 100 张写→自动确认→finalize

@Test func metadataLifecycleHundredFilesEndToEnd() async throws {
    let fixture = try makeLifecycleFixture()
    defer { fixture.cleanup() }

    var seeded: [SeededLifecycleDelivery] = []
    for index in 0..<100 {
        seeded.append(try seedLifecycleDelivery(
            fixture, photoId: "p\(index)", modules: [.metadata]))
    }

    var state = try fixture.service.state(sessionId: "s1")
    #expect(state.written == 100, "写盘后应停在待确认")
    #expect(state.synced == 0)
    #expect(state.backupCount == 100)
    #expect(state.backupBytes > 0)
    #expect(state.rows.count == 100)

    // 自动确认（无 C1：写完即确认）。
    let confirmOutcome = fixture.service.autoConfirmAfterWrite(sessionId: "s1")
    guard case .confirmed(let links, let deliveries, let items) = confirmOutcome else {
        Issue.record("自动确认应成功，实际 \(confirmOutcome)")
        return
    }
    #expect(links == 100)
    #expect(deliveries == 100)
    #expect(items == 100)

    state = try fixture.service.state(sessionId: "s1")
    #expect(state.synced == 100)
    #expect(state.written == 0)

    // 结束：100 行 + 100 备份都消失，XMP 内容一字不改。
    let finalized = try await fixture.service.finalizeSync(sessionId: "s1")
    #expect(finalized.deleted == 100)
    #expect(finalized.retained == 0)
    #expect(finalized.errors.isEmpty)
    #expect(try rowCount(fixture.db, "SELECT COUNT(*) FROM deliveries") == 0)
    #expect(try rowCount(fixture.db, "SELECT COUNT(*) FROM delivery_items") == 0)
    for delivery in seeded {
        #expect(!FileManager.default.fileExists(atPath: delivery.backupPath), "备份应被删除")
        // finalize 绝不 restore：XMP 仍是写盘后的内容（不是备份里的 original-*）。
        #expect(lifecycleContents(delivery.xmpPath)?.hasPrefix("gather-written-") == true)
    }
    let remaining = try fixture.service.state(sessionId: "s1")
    #expect(remaining.rows.isEmpty)
    #expect(remaining.backupCount == 0)
}

// MARK: - 2. 自动确认三态

@Test func autoConfirmWithoutCaptureOneConfirmsImmediately() throws {
    let fixture = try makeLifecycleFixture(gate: .noC1)
    defer { fixture.cleanup() }
    _ = try seedLifecycleDelivery(fixture, photoId: "p1", modules: [.metadata])

    #expect(fixture.coordinator.reloadAckGateEnabled == false, "未装 C1 时门禁应关闭")
    let outcome = fixture.service.autoConfirmAfterWrite(sessionId: "s1")
    guard case .confirmed = outcome else {
        Issue.record("无 C1 时应直接确认，实际 \(outcome)")
        return
    }
    #expect(try fixture.service.state(sessionId: "s1").synced == 1)
}

@Test func autoConfirmDefersUntilReloadWhenCaptureOneIsActive() throws {
    let fixture = try makeLifecycleFixture(gate: .c1)
    defer { fixture.cleanup() }
    _ = try seedLifecycleDelivery(fixture, photoId: "p1", modules: [.metadata])

    #expect(fixture.coordinator.reloadAckGateEnabled == true)
    #expect(fixture.service.autoConfirmAfterWrite(sessionId: "s1") == .deferredToReloadAck)
    #expect(try fixture.service.state(sessionId: "s1").written == 1)

    // C1 reload 成功（宿主写 reload_acked_at）后再确认。
    try markSessionReloadAcked(fixture)
    let outcome = fixture.service.autoConfirmAfterWrite(sessionId: "s1")
    guard case .confirmed = outcome else {
        Issue.record("reload 后应自动确认，实际 \(outcome)")
        return
    }
    #expect(try fixture.service.state(sessionId: "s1").synced == 1)
}

@Test func autoConfirmCanBeDisabledBySetting() throws {
    let fixture = try makeLifecycleFixture(
        gate: .noC1, settings: [MetadataDeliveryService.autoConfirmKey: "0"])
    defer { fixture.cleanup() }
    _ = try seedLifecycleDelivery(fixture, photoId: "p1", modules: [.metadata])

    #expect(fixture.service.autoConfirmAfterWrite(sessionId: "s1") == .disabled)
    #expect(try fixture.service.state(sessionId: "s1").written == 1)
    // 手动确认仍然可用。
    let state = try fixture.service.confirmSync(sessionId: "s1")
    #expect(state.synced == 1)
}

@Test func legacyWiringStillRequiresReloadAck() throws {
    // 旧行为（组合根未接线）：门禁常开，无 ack 时 confirm 被挡。
    let fixture = try makeLifecycleFixture(gate: .legacyOn)
    defer { fixture.cleanup() }
    _ = try seedLifecycleDelivery(fixture, photoId: "p1", modules: [.metadata])

    #expect(fixture.coordinator.reloadAckGateEnabled == true)
    do {
        _ = try fixture.service.confirmSync(sessionId: "s1")
        Issue.record("未 ack 且门禁开启时必须拒绝 confirm")
    } catch let error as MetadataDeliveryError {
        #expect(error == .reloadNotAcknowledged)
        #expect(error.code == "XMP_CONFIRM_REQUIRES_SYNC")
    }
    #expect(try fixture.service.state(sessionId: "s1").written == 1)
}

// MARK: - 3. 共享文件的模块作用域收尾

@Test func sharedFileFinalizeOnlyDropsOwnModuleItems() async throws {
    let fixture = try makeLifecycleFixture()
    defer { fixture.cleanup() }
    let seeded = try seedLifecycleDelivery(
        fixture,
        photoId: "p1",
        modules: [.culling, .metadata],
        confirmModules: [.culling, .metadata]
    )
    #expect(seeded.row.typedStatus == .synced)

    // metadata 先结束：只删自己的 item，行与备份保留。
    let first = try await fixture.coordinator.finalize(sessionId: "s1", module: .metadata)
    #expect(first.deletedCount == 0)
    #expect(first.retainedCount == 1)
    #expect(first.errors.isEmpty)
    #expect(try fixture.repo.get(seeded.xmpPath)?.typedStatus == .synced)
    #expect(FileManager.default.fileExists(atPath: seeded.backupPath), "共享文件的备份必须留到最后")
    let itemsAfterMetadata = try fixture.repo.items(deliveryId: seeded.row.id)
    #expect(itemsAfterMetadata.map(\.module) == ["culling"])

    // culling 最后结束：删行 + 删备份。
    let second = try await fixture.coordinator.finalize(sessionId: "s1", module: .culling)
    #expect(second.deletedCount == 1)
    #expect(second.retainedCount == 0)
    #expect(try fixture.repo.get(seeded.xmpPath) == nil)
    #expect(!FileManager.default.fileExists(atPath: seeded.backupPath))
    #expect(lifecycleContents(seeded.xmpPath) == "gather-written-p1", "只 drop，绝不 restore")
}

// MARK: - 4. 先确认再结束

@Test func finalizeBeforeConfirmKeepsRowAndReportsConfirmIncomplete() async throws {
    let fixture = try makeLifecycleFixture()
    defer { fixture.cleanup() }
    let seeded = try seedLifecycleDelivery(fixture, photoId: "p1", modules: [.metadata])

    let outcome = try await fixture.service.finalizeSync(sessionId: "s1")
    #expect(outcome.deleted == 0)
    #expect(outcome.state.written == 1)
    #expect(FileManager.default.fileExists(atPath: seeded.backupPath), "未确认的备份是唯一撤销点")
    #expect(try fixture.repo.get(seeded.xmpPath)?.typedStatus == .written)
    #expect(outcome.errors.contains { $0.hasPrefix("XMP_CONFIRM_INCOMPLETE") })
    #expect(outcome.state.notices.contains { $0.hasPrefix("XMP_CONFIRM_INCOMPLETE") })
}

// MARK: - 5. 崩溃点：DB 成功 / 备份删除失败 → replay 补删

@Test func finalizeBackupFailureKeepsAppliedIntentAndReplayFinishes() async throws {
    let port = FailingRemoveFilePort(inner: FileSystemDeliveryFilePort(), failures: 1)
    let fixture = try makeLifecycleFixture(files: port)
    defer { fixture.cleanup() }
    let seeded = try seedLifecycleDelivery(
        fixture, photoId: "p1", modules: [.metadata], confirmModules: [.metadata])

    let first = try await fixture.service.finalizeSync(sessionId: "s1")
    #expect(first.deleted == 1, "行删除已提交")
    #expect(FileManager.default.fileExists(atPath: seeded.backupPath), "备份删除失败必须保留")
    #expect(first.errors.contains { $0.hasPrefix("XMP_FINALIZE_BACKUP_CLEANUP_FAILED") })
    #expect(try fixture.repo.get(seeded.xmpPath) == nil)
    // 行已删、备份未删 → applied intent 保留，等 replay 补删。
    #expect(try rowCount(fixture.db, "SELECT COUNT(*) FROM delivery_intents WHERE phase = 'applied'") == 1)

    let replay = try await fixture.coordinator.replay()
    #expect(replay.failedCount == 0)
    #expect(!FileManager.default.fileExists(atPath: seeded.backupPath), "startup replay 补删孤儿备份")
    #expect(try rowCount(fixture.db, "SELECT COUNT(*) FROM delivery_intents") == 0)
    #expect(lifecycleContents(seeded.xmpPath) == "gather-written-p1")
}
