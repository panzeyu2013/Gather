// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Metadata/MetadataSyncRuntimeTests.swift
// MetadataSyncRuntime 直测（R4：由 Tests/.../Services/MetadataSyncCoordinatorTests.swift
// 迁入 Runtime/Metadata/，被测公开类型改名，4 tests / 1 suite 逐字搬迁；补齐数据安全
// 核心路径的协调器级覆盖）：
// 真实临时文件 + 真实 XMP 侧车读写（FakeFSXMPProvider），覆盖——
// 1) 排程写回：写前备份 + 原子写入 + markWritten（baseValues/指纹落库）
// 2) 外部修改 → 冲突检测（XMP_EXTERNAL_EDIT_CONFLICT）
// 3) reload-ack 门控的 confirm + cleanup：恢复备份、行删除
// 4) 备份缺失 → XMP_BACKUP_MISSING（cleanup 不误删）

import Foundation
import Testing
@testable import GatherCore

private func makeTempPhotoStore() async throws -> any PhotoStore {
    let (database, _) = try await makeMigratedStoreDatabase(label: "photos")
    return SQLitePhotoStore(database: database)
}


// MARK: - 测试基建

/// 真实文件系统 XMP 假件：侧车内容即属性 JSON，备份为真实文件拷贝，
/// 与 MetadataFingerprint.contentFingerprint 的真实读文件语义一致。
/// 真实文件系统 XMP 假件（internal：Runtime/Metadata/WritebackRuntimeTests 共用）。
final class FakeFSXMPProvider: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var backupCounter = 0

    private func sidecarPath(for photoPath: String) -> String {
        photoPath + ".xmp"
    }

    private func readJSON(_ photoPath: String) -> MetadataWriteAttributes {
        let path = sidecarPath(for: photoPath)
        guard let data = FileManager.default.contents(atPath: path) else {
            return MetadataWriteAttributes()
        }
        let decoded = (try? JSONDecoder().decode(MetadataWriteAttributes.self, from: data))
            ?? MetadataWriteAttributes()
        return decoded
    }

    private func writeJSON(_ photoPath: String, attributes: MetadataWriteAttributes) throws {
        let path = sidecarPath(for: photoPath)
        let data = try JSONEncoder().encode(attributes)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        readJSON(photoPath).keywords ?? []
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        readJSON(photoPath)
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        try writeJSON(photoPath, attributes: attributes)
    }

    func backup(photoPath: String) async throws -> String {
        lock.lock()
        backupCounter += 1
        let backupPath = "\(sidecarPath(for: photoPath)).gather-backup-\(backupCounter)"
        lock.unlock()
        let source = sidecarPath(for: photoPath)
        if let data = FileManager.default.contents(atPath: source) {
            try data.write(to: URL(fileURLWithPath: backupPath))
        }
        return backupPath
    }

    func restore(photoPath: String, backupPath: String) async throws {
        let target = sidecarPath(for: photoPath)
        if let data = FileManager.default.contents(atPath: backupPath) {
            try data.write(to: URL(fileURLWithPath: target))
        } else {
            try? FileManager.default.removeItem(atPath: target)
        }
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func removeFile(_ path: String) async throws {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private struct CoordinatorFixture {
    let db: SQLiteDatabase
    let dir: String
    let sessionId: String
    let photoPath: String
    let xmpPath: String
    let outbox: SQLiteWritebackStore
    let provider: FakeFSXMPProvider
    let coordinator: MetadataSyncRuntime

    let sessionStore: any SessionStore
    init() async throws {
        // 写回行读写经 Store 连接（独立连接）：两条连接须指向同一临时库文件。
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-mdc-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-sync-tests-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sessionId = "s-\(UUID().uuidString)"
        let photoPath = "\(dir)/photo.cr3"
        let xmpPath = "\(photoPath).xmp"
        // 原始侧车：写回前已存在，cleanup 恢复语义才有可校验的原始内容。
        let original = try JSONEncoder().encode(MetadataWriteAttributes(keywords: ["original"]))
        try original.write(to: URL(fileURLWithPath: xmpPath))
        _ = try await db.run("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)", [.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        let outbox = try SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath))
        let provider = FakeFSXMPProvider()
        let sessionStore = try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath))
        let coordinator = MetadataSyncRuntime(
            writebackStore: SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath)),
            xmp: provider,
            sessionStore: sessionStore,
            getNumber: { _, defaultValue in defaultValue },
            skipReloadAck: false
        )
        self.db = db
        self.dir = dir
        self.sessionId = sessionId
        self.photoPath = photoPath
        self.xmpPath = xmpPath
        self.outbox = outbox
        self.provider = provider
        self.sessionStore = sessionStore
        self.coordinator = coordinator
    }

    func cleanupFiles() {
        try? FileManager.default.removeItem(atPath: dir)
    }
}

/// 轮询等待 outbox 行到达目标状态（waitForIdle 在行尚未进入 writing 时立即返回）。
@discardableResult
private func waitForStatus(
    _ repo: SQLiteWritebackStore,
    xmpPath: String,
    status: String,
    timeoutMs: Int = 5000
) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if (try? await repo.outboxEntry(xmpPath: xmpPath))?.status == status { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

// MARK: - 测试

@Suite(.serialized)
struct MetadataSyncRuntimeTests {
    /// 1) 排程写回：备份原始侧车 → 写入新属性 → markWritten（指纹与基线落库）。
    @Test func scheduledWritebackBacksUpWritesAndMarksWritten() async throws {
        let fx = try await CoordinatorFixture()
        defer { fx.cleanupFiles() }

        try await fx.outbox.mergeOutboxPatch(
            xmpPath: fx.xmpPath,
            sessionId: fx.sessionId,
            photoPath: fx.photoPath,
            patch: JSONValue.object(["keywords": .array([.string("a")]), "rating": .number(4)]),
            dirtyFields: ["keywords", "rating"]
        )
        fx.coordinator.schedule(xmpPath: fx.xmpPath, delayMs: 0)

        #expect(await waitForStatus(fx.outbox, xmpPath: fx.xmpPath, status: "written"))
        let row = try await fx.outbox.outboxEntry(xmpPath: fx.xmpPath)
        #expect(row != nil)
        #expect(row!.baseFingerprint.isEmpty == false)
        #expect(row!.backupPath.isEmpty == false)
        // 备份是真实文件，且保留了原始内容。
        #expect(fx.provider.fileExists(row!.backupPath))
        let backupData = FileManager.default.contents(atPath: row!.backupPath)
        let backupAttrs = try JSONDecoder().decode(
            MetadataWriteAttributes.self, from: backupData ?? Data())
        #expect(backupAttrs.keywords == ["original"])
        // 侧车已写入新属性。
        let written = try await fx.provider.readAttributes(photoPath: fx.photoPath)
        #expect(written.keywords == ["a"])
        #expect(written.rating == 4)

        await fx.coordinator.shutdown()
    }

    /// 2) 外部修改侧车后再次排程 → 冲突（XMP_EXTERNAL_EDIT_CONFLICT），不覆盖外部内容。
    @Test func externalEditRaisesConflict() async throws {
        let fx = try await CoordinatorFixture()
        defer { fx.cleanupFiles() }

        try await fx.outbox.mergeOutboxPatch(
            xmpPath: fx.xmpPath,
            sessionId: fx.sessionId,
            photoPath: fx.photoPath,
            patch: JSONValue.object(["rating": .number(4)]),
            dirtyFields: ["rating"]
        )
        fx.coordinator.schedule(xmpPath: fx.xmpPath, delayMs: 0)
        #expect(await waitForStatus(fx.outbox, xmpPath: fx.xmpPath, status: "written"))

        // 外部工具修改侧车（跳过 Gather 写回）。
        try await fx.provider.writeAttributes(
            photoPath: fx.photoPath,
            attributes: MetadataWriteAttributes(keywords: ["external"], rating: 5)
        )
        try await fx.outbox.mergeOutboxPatch(
            xmpPath: fx.xmpPath,
            sessionId: fx.sessionId,
            photoPath: fx.photoPath,
            patch: JSONValue.object(["rating": .number(1)]),
            dirtyFields: ["rating"]
        )
        fx.coordinator.schedule(xmpPath: fx.xmpPath, delayMs: 0)
        #expect(await waitForStatus(fx.outbox, xmpPath: fx.xmpPath, status: "conflict"))

        let row = try await fx.outbox.outboxEntry(xmpPath: fx.xmpPath)
        #expect(row?.status == "conflict")
        #expect(row?.errorMessage == "XMP_EXTERNAL_EDIT_CONFLICT")
        // 外部内容未被覆盖。
        let current = try await fx.provider.readAttributes(photoPath: fx.photoPath)
        #expect(current.rating == 5)

        await fx.coordinator.shutdown()
    }

    /// 3) reload-ack 门控：确认同步后清理恢复原始侧车并删除 outbox 行。
    @Test func confirmAndCleanupRestoresBackup() async throws {
        let fx = try await CoordinatorFixture()
        defer { fx.cleanupFiles() }

        try await fx.outbox.mergeOutboxPatch(
            xmpPath: fx.xmpPath,
            sessionId: fx.sessionId,
            photoPath: fx.photoPath,
            patch: JSONValue.object(["keywords": .array([.string("a")])]),
            dirtyFields: ["keywords"]
        )
        fx.coordinator.schedule(xmpPath: fx.xmpPath, delayMs: 0)
        #expect(await waitForStatus(fx.outbox, xmpPath: fx.xmpPath, status: "written"))

        // 未 ack 前 confirm 必须被拒绝（数据丢失门）。
        do {
            _ = try await fx.coordinator.confirmSync(sessionId: fx.sessionId, sourceModule: "manual")
            Issue.record("expected reloadNotAcked")
        } catch let error as MetadataSyncError {
            #expect(error == .reloadNotAcked)
        }

        _ = try await fx.sessionStore.setReloadAckedAt(
            sessionId: fx.sessionId, iso: nowISOString())
        let summary = try await fx.coordinator.confirmSync(sessionId: fx.sessionId, sourceModule: "manual")
        #expect(summary.synced == 1)

        let result = try await fx.coordinator.cleanup(sessionId: fx.sessionId, sourceModule: "manual")
        #expect(result.deletedCount == 1)
        #expect(result.errors.isEmpty)
        // outbox 行已删除；侧车恢复为原始内容。
        #expect(try await fx.outbox.outboxEntry(xmpPath: fx.xmpPath) == nil)
        let restored = try await fx.provider.readAttributes(photoPath: fx.photoPath)
        #expect(restored.keywords == ["original"])
        #expect(restored.rating == nil)

        await fx.coordinator.shutdown()
    }

    /// 4) 备份缺失：cleanup 报 XMP_BACKUP_MISSING，行保持 synced（可重试）。
    @Test func cleanupReportsBackupMissingWithoutDeleting() async throws {
        let fx = try await CoordinatorFixture()
        defer { fx.cleanupFiles() }

        try await fx.outbox.mergeOutboxPatch(
            xmpPath: fx.xmpPath,
            sessionId: fx.sessionId,
            photoPath: fx.photoPath,
            patch: JSONValue.object(["keywords": .array([.string("a")])]),
            dirtyFields: ["keywords"]
        )
        fx.coordinator.schedule(xmpPath: fx.xmpPath, delayMs: 0)
        #expect(await waitForStatus(fx.outbox, xmpPath: fx.xmpPath, status: "written"))
        _ = try await fx.sessionStore.setReloadAckedAt(
            sessionId: fx.sessionId, iso: nowISOString())
        _ = try await fx.coordinator.confirmSync(sessionId: fx.sessionId, sourceModule: "manual")

        // 备份文件被外部删除。
        let row = try await fx.outbox.outboxEntry(xmpPath: fx.xmpPath)
        try await fx.provider.removeFile(row!.backupPath)

        let result = try await fx.coordinator.cleanup(sessionId: fx.sessionId, sourceModule: "manual")
        #expect(result.deletedCount == 0)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].contains("XMP_BACKUP_MISSING"))
        // 行保持 synced、侧车未被删除（可修复备份后重试清理）。
        #expect(try await fx.outbox.outboxEntry(xmpPath: fx.xmpPath)?.status == "synced")
        #expect(fx.provider.fileExists(fx.xmpPath))

        await fx.coordinator.shutdown()
    }
}
