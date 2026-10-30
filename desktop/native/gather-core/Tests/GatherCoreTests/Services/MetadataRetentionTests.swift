// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataRetentionTests.swift
// P1 下一波 §3.1.4 验收：保留期 GC 的三态与四条补充规则。
//
// 覆盖：
// 1. 已确认 + 超过保留期 → 行与备份都回收；
// 2. written（未确认）不回收——备份是用户唯一撤销点；
// 3. C1 门禁：会话未 reload-ack 时跳过，ack 之后才回收（手动"立即清理"可越过）；
// 4. 备份删除失败：行已删、备份保留、错误可见，replay 补删后闭环；
// 5. 零 item 行（CASCADE 清空）→ 删行 + 备份；
// 6. 文件已消失行（父目录仍在）→ 删行 + 备份；卷离线（父目录不在）不碰；
// 7. 孤儿备份：只删受控命名 + mtime>24h + DB 无引用的文件，普通文件/新备份/被引用备份不删；
// 8. 存量收编：仅有 metadata item 的 written 交付按新策略自动确认。

import Foundation
import os
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherDelivery
@testable import GatherApplication
import GatherTestSupport

// MARK: - fixtures

private final class RetentionFailingRemovePort: DeliveryFilePort, @unchecked Sendable {
    private let inner = FileSystemDeliveryFilePort()
    private let remainingFailures: OSAllocatedUnfairLock<Int>

    init(failures: Int) {
        self.remainingFailures = OSAllocatedUnfairLock(initialState: failures)
    }

    func fileExists(_ path: String) -> Bool {
        inner.fileExists(path)
    }

    func restore(photoPath: String, backupPath: String) async throws {
        try await inner.restore(photoPath: photoPath, backupPath: backupPath)
    }

    func removeFile(_ path: String) async throws {
        let fail = remainingFailures.withLock { remaining -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if fail { throw RetentionInjectedError.removeFailed }
        try await inner.removeFile(path)
    }
}

private enum RetentionInjectedError: Error, Equatable {
    case removeFailed
}

private struct RetentionFixture {
    let db: DBConnection
    let dir: String
    let repo: DeliveryRepo
    let coordinator: DeliveryCoordinator
    let retention: MetadataRetentionService

    func cleanup() {
        db.close()
        try? FileManager.default.removeItem(atPath: dir)
    }
}

/// gate: true = 模拟"装了 C1"（requireReloadAck + c1Required 都开）。
private func makeRetentionFixture(
    captureOneActive: Bool = false,
    files: (any DeliveryFilePort)? = nil
) throws -> RetentionFixture {
    let db = try DBConnection(path: ":memory:")
    try db.exec(SchemaCurrent.ddl)
    let dir = try makeTempDir()
    let repo = DeliveryRepo(connection: db)
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
        fingerprint: { _ in "retention-fp" },
        resolvePhotoPath: { _, delivery in delivery.photoPath },
        requireReloadAck: true,
        c1Required: { captureOneActive }
    )
    // 会话 source_path 指到临时目录（孤儿备份扫描的根）。
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, source_path, created_at, updated_at)
        VALUES (?, '', 'draft', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text("s1"), .text(dir)])
    // delivery_items.photo_id 有外键：seedRetentionDelivery 用 p0/p1/p2，必须先落 photos 行。
    for photoId in ["p0", "p1", "p2"] {
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
            VALUES (?, 's1', ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run([
                .text(photoId), .text(dir + "/" + photoId + ".jpg"),
                .text(photoId + ".jpg"),
            ])
    }
    return RetentionFixture(
        db: db, dir: dir, repo: repo, coordinator: coordinator,
        retention: MetadataRetentionService(connection: db, coordinator: coordinator))
}

private struct SeededRetentionDelivery {
    let row: DeliveryRow
    let xmpPath: String
    let backupPath: String
}

private func seedRetentionDelivery(
    _ fixture: RetentionFixture,
    photoId: String,
    module: DeliveryModule = .metadata,
    confirm: Bool,
    withItems: Bool = true
) throws -> SeededRetentionDelivery {
    let photoPath = fixture.dir + "/" + photoId + ".jpg"
    let xmpPath = TSPath.xmpSidecarPath(photoPath)
    try Data("photo-".utf8).write(to: URL(fileURLWithPath: photoPath))
    try Data("gather-written-\(photoId)".utf8).write(to: URL(fileURLWithPath: xmpPath))
    let backupPath = xmpPath + ".gather-backup-" + UUID().uuidString.lowercased()
    try Data("original-\(photoId)".utf8).write(to: URL(fileURLWithPath: backupPath))

    _ = try fixture.repo.createOrGet(
        xmpPath: xmpPath, photoPath: photoPath, revision: 1,
        baseFingerprint: "retention-fp", baseValues: .object([:]))
    if withItems {
        _ = try fixture.repo.upsertItem(
            xmpPath: xmpPath, photoId: photoId, module: module,
            attributes: ["rating": .number(4)], status: .pending)
    }
    _ = try fixture.repo.linkSession(xmpPath: xmpPath, sessionId: "s1")
    let owner = "retention-" + UUID().uuidString
    _ = try fixture.repo.claimWriting(xmpPath: xmpPath, revision: 1, leaseOwner: owner)
    guard let written = try fixture.repo.markWritten(
        xmpPath: xmpPath, revision: 1, leaseOwner: owner,
        baseFingerprint: "retention-fp", baseValues: .object([:]),
        backupPath: backupPath
    ) else {
        throw RetentionInjectedError.removeFailed
    }
    if withItems {
        for item in try fixture.repo.items(deliveryId: written.id) {
            _ = try fixture.repo.markItem(itemId: item.id, status: .written)
        }
    }
    if confirm {
        _ = try fixture.repo.confirm(
            scope: .module, sessionId: "s1", module: module, requireReloadAck: false)
    }
    guard let row = try fixture.repo.get(xmpPath) else {
        throw RetentionInjectedError.removeFailed
    }
    return SeededRetentionDelivery(row: row, xmpPath: xmpPath, backupPath: backupPath)
}

private func ageRetentionDelivery(_ fixture: RetentionFixture, id: Int64, days: Double) throws {
    let stamp = isoString(Date().addingTimeInterval(-days * 86_400))
    _ = try fixture.db.prepare("UPDATE deliveries SET updated_at = ? WHERE id = ?")
        .run([.text(stamp), .int(id)])
}

private func ackRetentionSession(_ fixture: RetentionFixture) throws {
    _ = try fixture.db.prepare("UPDATE sessions SET reload_acked_at = ? WHERE id = 's1'")
        .run([.text("2026-02-01T00:00:00.000Z")])
}

private let retentionPolicy = MetadataRetentionPolicy(
    retentionDays: 7,
    isEnabled: true,
    batchLimit: 200,
    ignoreReloadAck: false,
    includeOrphanBackups: false,
    adoptLegacyRows: false
)

// MARK: - 1/2. 已确认回收 vs 未确认保留

@Test func retentionReclaimsConfirmedExpiredRowsAndBackups() async throws {
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    var seeded: [SeededRetentionDelivery] = []
    for index in 0..<3 {
        let delivery = try seedRetentionDelivery(
            fixture, photoId: "p\(index)", confirm: true)
        try ageRetentionDelivery(fixture, id: delivery.row.id, days: 30)
        seeded.append(delivery)
    }

    let result = await fixture.retention.run(policy: retentionPolicy)
    #expect(result.scanned == 3)
    #expect(result.deletedDeliveries == 3)
    #expect(result.errors.isEmpty)
    #expect(try rowCount(fixture.db, "SELECT COUNT(*) FROM deliveries") == 0)
    for delivery in seeded {
        #expect(!FileManager.default.fileExists(atPath: delivery.backupPath))
        #expect(FileManager.default.fileExists(atPath: delivery.xmpPath), "XMP 仍保留")
    }
}

@Test func retentionKeepsWrittenRows() async throws {
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    let delivery = try seedRetentionDelivery(fixture, photoId: "p1", confirm: false)
    try ageRetentionDelivery(fixture, id: delivery.row.id, days: 30)

    let result = await fixture.retention.run(policy: retentionPolicy)
    #expect(result.scanned == 0, "written 不是保留期候选")
    #expect(result.deletedDeliveries == 0)
    #expect(try fixture.repo.get(delivery.xmpPath)?.typedStatus == .written)
    #expect(FileManager.default.fileExists(atPath: delivery.backupPath))
}

// MARK: - 3. C1 门禁

@Test func retentionSkipsUnackedCaptureOneSessionUntilReload() async throws {
    let fixture = try makeRetentionFixture(captureOneActive: true)
    defer { fixture.cleanup() }
    let delivery = try seedRetentionDelivery(fixture, photoId: "p1", confirm: true)
    try ageRetentionDelivery(fixture, id: delivery.row.id, days: 30)

    let first = await fixture.retention.run(policy: retentionPolicy)
    #expect(first.deletedDeliveries == 0)
    #expect(first.skipped == 1)
    #expect(try fixture.repo.get(delivery.xmpPath) != nil)
    #expect(FileManager.default.fileExists(atPath: delivery.backupPath))

    // C1 reload 之后（或用户手动"立即清理"）才回收。
    try ackRetentionSession(fixture)
    let second = await fixture.retention.run(policy: retentionPolicy)
    #expect(second.deletedDeliveries == 1)
    #expect(try fixture.repo.get(delivery.xmpPath) == nil)
    #expect(!FileManager.default.fileExists(atPath: delivery.backupPath))
}

@Test func retentionImmediatePolicyIgnoresReloadAckGate() async throws {
    let fixture = try makeRetentionFixture(captureOneActive: true)
    defer { fixture.cleanup() }
    let delivery = try seedRetentionDelivery(fixture, photoId: "p1", confirm: true)
    try ageRetentionDelivery(fixture, id: delivery.row.id, days: 30)

    let result = await fixture.retention.run(policy: .immediate)
    #expect(result.deletedDeliveries == 1)
    #expect(!FileManager.default.fileExists(atPath: delivery.backupPath))
}

// MARK: - 4. 备份删除失败的崩溃点

@Test func retentionBackupFailureKeepsIntentForReplay() async throws {
    let fixture = try makeRetentionFixture(files: RetentionFailingRemovePort(failures: 1))
    defer { fixture.cleanup() }
    let delivery = try seedRetentionDelivery(fixture, photoId: "p1", confirm: true)
    try ageRetentionDelivery(fixture, id: delivery.row.id, days: 30)

    let result = await fixture.retention.run(policy: retentionPolicy)
    #expect(result.deletedDeliveries == 1, "行删除已提交")
    #expect(FileManager.default.fileExists(atPath: delivery.backupPath), "备份删除失败要保留")
    #expect(result.errors.contains { $0.hasPrefix("XMP_FINALIZE_BACKUP_CLEANUP_FAILED") })
    #expect(try rowCount(fixture.db, "SELECT COUNT(*) FROM delivery_intents") == 1)

    _ = try await fixture.coordinator.replay()
    #expect(!FileManager.default.fileExists(atPath: delivery.backupPath))
    #expect(try rowCount(fixture.db, "SELECT COUNT(*) FROM delivery_intents") == 0)
}

// MARK: - 5. 零 item 行

@Test func retentionDeletesEmptyItemRows() async throws {
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    let delivery = try seedRetentionDelivery(
        fixture, photoId: "p1", confirm: false, withItems: false)
    try ageRetentionDelivery(fixture, id: delivery.row.id, days: 1)

    let result = await fixture.retention.run(policy: retentionPolicy)
    #expect(result.emptyRowsDeleted == 1)
    #expect(try fixture.repo.get(delivery.xmpPath) == nil)
    #expect(!FileManager.default.fileExists(atPath: delivery.backupPath))
}

@Test func retentionKeepsFreshEmptyRows() async throws {
    // mirror 写路径可能"先建行、后插 item"（两个事务）：一小时内的空行不动。
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    let delivery = try seedRetentionDelivery(
        fixture, photoId: "p1", confirm: false, withItems: false)

    let result = await fixture.retention.run(policy: retentionPolicy)
    #expect(result.emptyRowsDeleted == 0)
    #expect(try fixture.repo.get(delivery.xmpPath) != nil)
}

// MARK: - 6. 文件已消失行

@Test func retentionDeletesVanishedFileRows() async throws {
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    let delivery = try seedRetentionDelivery(fixture, photoId: "p1", confirm: false)
    try FileManager.default.removeItem(atPath: delivery.xmpPath)

    let result = await fixture.retention.run(policy: retentionPolicy)
    #expect(result.vanishedRowsDeleted == 1)
    #expect(try fixture.repo.get(delivery.xmpPath) == nil)
    #expect(!FileManager.default.fileExists(atPath: delivery.backupPath))
}

@Test func retentionKeepsRowsWhenVolumeLooksOffline() async throws {
    // 父目录不存在 = 卷离线，不能把"暂时读不到"当成"文件已删除"。
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    let delivery = try seedRetentionDelivery(fixture, photoId: "p1", confirm: false)
    let offlineDir = fixture.dir + "/offline-volume"
    let movedXmp = offlineDir + "/" + TSPath.basename(delivery.xmpPath)
    try FileManager.default.createDirectory(
        atPath: offlineDir, withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: delivery.xmpPath, toPath: movedXmp)
    _ = try fixture.db.prepare("UPDATE deliveries SET xmp_path = ? WHERE id = ?")
        .run([.text(movedXmp), .int(delivery.row.id)])
    try FileManager.default.removeItem(atPath: offlineDir)

    let result = await fixture.retention.run(policy: retentionPolicy)
    #expect(result.vanishedRowsDeleted == 0)
    #expect(try rowCount(fixture.db, "SELECT COUNT(*) FROM deliveries") == 1)
}

// MARK: - 7. 孤儿备份

@Test func retentionDeletesOnlyUnreferencedAgedControlledBackups() async throws {
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    let fileManager = FileManager.default
    let aged = Date().addingTimeInterval(-2 * 86_400)

    // 1) 孤儿（受控命名 + 48h）：应删。
    let orphan = fixture.dir + "/p9.xmp.gather-backup-" + UUID().uuidString.lowercased()
    try Data("orphan".utf8).write(to: URL(fileURLWithPath: orphan))
    try fileManager.setAttributes([.modificationDate: aged], ofItemAtPath: orphan)

    // 2) 普通文件：不删（白名单之外）。
    let plain = fixture.dir + "/notes.txt"
    try Data("note".utf8).write(to: URL(fileURLWithPath: plain))
    try fileManager.setAttributes([.modificationDate: aged], ofItemAtPath: plain)

    // 3) 新备份（受控命名但只有 1 分钟）：不删。
    let fresh = fixture.dir + "/p8.xmp.gather-header-" + UUID().uuidString.lowercased()
    try Data("fresh".utf8).write(to: URL(fileURLWithPath: fresh))

    // 4) 被引用的备份：不删。
    let referenced = try seedRetentionDelivery(fixture, photoId: "p1", confirm: true)
    try fileManager.setAttributes(
        [.modificationDate: aged], ofItemAtPath: referenced.backupPath)

    // P1-3 之后：孤儿清理受 isEnabled 约束（保留期=0 不得偷偷删），所以这里必须是 true。
    let result = await fixture.retention.run(policy: MetadataRetentionPolicy(
        retentionDays: 7,
        isEnabled: true,
        includeOrphanBackups: true,
        adoptLegacyRows: false))
    #expect(result.orphanBackupsDeleted == 1)
    #expect(!fileManager.fileExists(atPath: orphan))
    #expect(fileManager.fileExists(atPath: plain))
    #expect(fileManager.fileExists(atPath: fresh))
    #expect(fileManager.fileExists(atPath: referenced.backupPath))
}

// MARK: - 8. 存量收编

@Test func retentionAdoptsLegacyWrittenRows() async throws {
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    let delivery = try seedRetentionDelivery(fixture, photoId: "p1", confirm: false)
    #expect(delivery.row.typedStatus == .written)

    let result = await fixture.retention.run(policy: MetadataRetentionPolicy(
        retentionDays: 7,
        isEnabled: false,
        includeOrphanBackups: false,
        adoptLegacyRows: true))
    #expect(result.adopted == 1)
    #expect(try fixture.repo.get(delivery.xmpPath)?.typedStatus == .synced)
}

// MARK: - 9. 会话作用域（P1-2）

/// "立即清理"传了 sessionId，就必须只动本会话。旧实现忽略该参数 → 在一个会话点
/// 清理会确认并删除**所有会话**的行与备份（备份是唯一撤销点）。
@Test func retentionScopeOnlyTouchesOwnSession() async throws {
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    // 第二个会话（作用域外）。只影响 source_path 扫描，不需要照片。
    _ = try fixture.db.prepare("""
        INSERT INTO sessions (id, name, status, source_path, created_at, updated_at)
        VALUES (?, '', 'draft', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text("s2"), .text(fixture.dir)])

    // 只属于 s1 的已确认交付（seedRetentionDelivery 固定 linkSession(s1) + confirm(s1)）。
    let seeded = try seedRetentionDelivery(fixture, photoId: "p1", confirm: true)
    // 保留期 0 的 cutoff 就是"现在"；confirmed_at 带毫秒（.000Z）与 cutoff 的秒级
    // 文本比较会排到后面，所以显式回填一个旧确认时间（真实场景也是几天前）。
    _ = try fixture.db.prepare(
        "UPDATE delivery_sessions SET confirmed_at = ? WHERE session_id = ?")
        .run([.text("2026-01-01T00:00:00.000Z"), .text("s1")])
    // updated_at 是 expiredCandidates 的比较列（cutoff 取"现在"）：一起回填，
    // 避免"刚确认完的同毫秒"让候选集变成空集（否则用例会偶发假绿/假红）。
    _ = try fixture.db.prepare("UPDATE deliveries SET updated_at = ?")
        .run([.text("2026-01-01T00:00:00.000Z")])
    let scoped = MetadataRetentionPolicy(
        retentionDays: 0, isEnabled: true, includeOrphanBackups: false, adoptLegacyRows: false)

    // 作用域 = s2：一条都不能删（行与备份都在）。
    let otherScope = await fixture.retention.run(policy: scoped, sessionId: "s2")
    #expect(otherScope.deletedDeliveries == 0)
    #expect(try fixture.repo.get(seeded.xmpPath) != nil)
    #expect(FileManager.default.fileExists(atPath: seeded.backupPath))

    // 作用域 = s1：本会话的这条被回收，备份随行删除。
    let ownScope = await fixture.retention.run(policy: scoped, sessionId: "s1")
    #expect(ownScope.deletedDeliveries == 1)
    #expect(try fixture.repo.get(seeded.xmpPath) == nil)
    #expect(!FileManager.default.fileExists(atPath: seeded.backupPath))
}
