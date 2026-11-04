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
// 8. 存量收编：仅有 metadata item 的 written 交付按新策略自动确认；
// 9. 会话作用域（P1-2）：只动本会话的行与备份；候选过滤与 LIMIT 一起下推到 SQL
//    （旧实现"先全库截断再在 Application 侧跳过"会让本会话被别的会话的候选饿死）；
// 10. 会话内孤儿回收：作用域只收窄扫描根，"是否被引用"仍用全库引用集合。

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
        retention: MetadataRetentionService(
            lifecycle: MetadataLifecycleRepo(connection: db), coordinator: coordinator))
}

private struct SeededRetentionDelivery {
    let row: DeliveryRow
    let xmpPath: String
    let backupPath: String
}

/// 种一条交付。
///
/// - Parameter sessionId: 交付链接/确认的会话（默认 s1 = fixture 的主会话）。作用域
///   测试要造"别的会话的交付"时传 s2（调用前先用 seedSecondSession 落 s2 + 它的 photos）。
private func seedRetentionDelivery(
    _ fixture: RetentionFixture,
    photoId: String,
    module: DeliveryModule = .metadata,
    confirm: Bool,
    withItems: Bool = true,
    sessionId: String = "s1"
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
    _ = try fixture.repo.linkSession(xmpPath: xmpPath, sessionId: sessionId)
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
            scope: .module, sessionId: sessionId, module: module, requireReloadAck: false)
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

/// 种一个"别的会话"（含它自己的 photos 行，photo_id 外键要用）。
///
/// sessionId 的作用域测试需要**真实存在**的第二会话：delivery_sessions.session_id
/// 有外键，而且验证"作用域外不扫"要有它自己的 source_path。
private func seedSecondSession(
    _ fixture: RetentionFixture,
    id: String,
    sourcePath: String,
    photoIds: [String]
) throws {
    _ = try fixture.db.prepare("""
        INSERT INTO sessions (id, name, status, source_path, created_at, updated_at)
        VALUES (?, '', 'draft', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(id), .text(sourcePath)])
    for photoId in photoIds {
        // filepath 写 seedRetentionDelivery 真正落盘的位置（fixture.dir），
        // source_path 才是"这个会话的照片目录"（两者在测试里可以不同）。
        _ = try fixture.db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
            VALUES (?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run([
                .text(photoId), .text(id), .text(fixture.dir + "/" + photoId + ".jpg"),
                .text(photoId + ".jpg"),
            ])
    }
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

    // 只属于 s1 的已确认交付（seedRetentionDelivery 默认 linkSession(s1) + confirm(s1)）。
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

// MARK: - 10. 会话作用域下推（候选查询）

/// 会话过滤必须在 SQL 里、在 LIMIT **之前**生效。
///
/// 下推前的形状是"全库先截断、再在 Application 侧跳过作用外行"：`limit: 1` 时第一行
/// 若属于别的会话，本会话一条都轮不到（用户点了"立即清理"却什么都没发生）。上一版
/// 用"多取 8 倍"把边界从 1 推到 8 —— 只是把 bug 推远（见下一个用例的 9 条更早候选），
/// 下推之后 LIMIT 的语义才是"本会话的前 N 条"。
@Test func retentionScopePushesSessionFilterIntoQuery() async throws {
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    try seedSecondSession(
        fixture, id: "s2", sourcePath: fixture.dir, photoIds: ["s2p0", "s2p1"])

    // 两条 s2 候选都比 s1 那条更早：全库时间序的前两条都属于 s2。
    var foreign: [SeededRetentionDelivery] = []
    for (offset, photoId) in ["s2p0", "s2p1"].enumerated() {
        let delivery = try seedRetentionDelivery(
            fixture, photoId: photoId, confirm: true, sessionId: "s2")
        try ageRetentionDelivery(fixture, id: delivery.row.id, days: 30 - Double(offset))
        foreign.append(delivery)
    }
    let own = try seedRetentionDelivery(fixture, photoId: "p1", confirm: true)
    try ageRetentionDelivery(fixture, id: own.row.id, days: 20)

    let result = await fixture.retention.run(
        policy: MetadataRetentionPolicy(
            retentionDays: 7, isEnabled: true, batchLimit: 1,
            includeOrphanBackups: false, adoptLegacyRows: false),
        sessionId: "s1")

    #expect(result.scanned == 1)
    #expect(result.deletedDeliveries == 1)
    #expect(try fixture.repo.get(own.xmpPath) == nil, "本会话的候选必须轮得到")
    for delivery in foreign {
        #expect(try fixture.repo.get(delivery.xmpPath) != nil, "作用域外的行必须原样保留")
        #expect(FileManager.default.fileExists(atPath: delivery.backupPath))
    }
}

/// 上一版靠"多取 8 倍再过滤"缓解饥饿，但放大不是修复：更早的候选超过倍数照样 0 删除。
/// 这里刻意造 9 条更早的 s2 候选（> 旧放大倍数 8），limit 仍是 1。
@Test func retentionScopeLimitIsNotStarvedByForeignCandidates() async throws {
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    let foreignPhotos = (0..<9).map { "s2p\($0)" }
    try seedSecondSession(
        fixture, id: "s2", sourcePath: fixture.dir, photoIds: foreignPhotos)
    for (offset, photoId) in foreignPhotos.enumerated() {
        let delivery = try seedRetentionDelivery(
            fixture, photoId: photoId, confirm: true, sessionId: "s2")
        try ageRetentionDelivery(fixture, id: delivery.row.id, days: 40 - Double(offset))
    }
    let own = try seedRetentionDelivery(fixture, photoId: "p1", confirm: true)
    try ageRetentionDelivery(fixture, id: own.row.id, days: 10)

    let result = await fixture.retention.run(
        policy: MetadataRetentionPolicy(
            retentionDays: 7, isEnabled: true, batchLimit: 1,
            includeOrphanBackups: false, adoptLegacyRows: false),
        sessionId: "s1")

    #expect(result.deletedDeliveries == 1, "作用域外的候选不占本批配额")
    #expect(try fixture.repo.get(own.xmpPath) == nil)
}

// MARK: - 11. 会话内孤儿回收

/// 作用域运行**也要**回收孤儿（上一版直接整段跳过），但两个集合不对称：
/// 扫描根收窄到本会话 source_path，引用集合仍是全库。
@Test func retentionScopedRunReclaimsOrphansUnderOwnRootOnly() async throws {
    let fixture = try makeRetentionFixture()
    defer { fixture.cleanup() }
    let fileManager = FileManager.default
    let aged = Date().addingTimeInterval(-2 * 86_400)

    // s2 有自己的根目录：作用域 s1 的清理不该去别人的照片目录动手。
    let s2Root = fixture.dir + "/s2-root"
    try fileManager.createDirectory(atPath: s2Root, withIntermediateDirectories: true)
    try seedSecondSession(fixture, id: "s2", sourcePath: s2Root, photoIds: ["s2p0"])

    // 1) s1 根目录里"无引用且超龄"的受控备份：应删。
    let orphan = fixture.dir + "/p9.xmp.gather-backup-" + UUID().uuidString.lowercased()
    try Data("orphan".utf8).write(to: URL(fileURLWithPath: orphan))
    try fileManager.setAttributes([.modificationDate: aged], ofItemAtPath: orphan)

    // 2) 同目录、同样超龄，但被 s2 的交付引用：必须保留。这是"引用集合不能按会话
    //    缩小"的证伪点——缩小了它就会在本会话的清理里被当孤儿删掉。
    let referenced = try seedRetentionDelivery(
        fixture, photoId: "s2p0", confirm: true, sessionId: "s2")
    try fileManager.setAttributes(
        [.modificationDate: aged], ofItemAtPath: referenced.backupPath)

    // 3) s2 根目录里的超龄孤儿：作用域 s1 不扫它（扫描根是作用域的一部分）。
    let foreignOrphan = s2Root + "/p7.xmp.gather-backup-" + UUID().uuidString.lowercased()
    try Data("foreign".utf8).write(to: URL(fileURLWithPath: foreignOrphan))
    try fileManager.setAttributes([.modificationDate: aged], ofItemAtPath: foreignOrphan)

    let result = await fixture.retention.run(
        policy: MetadataRetentionPolicy(
            retentionDays: 7, isEnabled: true,
            includeOrphanBackups: true, adoptLegacyRows: false),
        sessionId: "s1")

    #expect(result.orphanBackupsDeleted == 1)
    #expect(!fileManager.fileExists(atPath: orphan))
    #expect(
        fileManager.fileExists(atPath: referenced.backupPath),
        "被别的会话引用的备份不能当孤儿删")
    #expect(fileManager.fileExists(atPath: foreignOrphan), "作用域外的目录不扫")
}
