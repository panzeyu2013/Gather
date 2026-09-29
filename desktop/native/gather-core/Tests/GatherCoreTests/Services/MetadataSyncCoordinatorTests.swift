// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataSyncCoordinatorTests.swift
// MetadataSyncCoordinator 直测（补齐数据安全核心路径的协调器级覆盖）：
// 真实临时文件 + 真实 XMP 侧车读写（FakeFSXMPProvider），覆盖——
// 1) 排程写回：写前备份 + 原子写入 + markWritten（baseValues/指纹落库）
// 2) 外部修改 → 冲突检测（XMP_EXTERNAL_EDIT_CONFLICT）
// 3) reload-ack 门控的 confirm + cleanup：恢复备份、行删除
// 4) 备份缺失 → XMP_BACKUP_MISSING（cleanup 不误删）

import Foundation
import Testing
@testable import GatherCore

// MARK: - 测试基建

/// 真实文件系统 XMP 假件：侧车内容即属性 JSON，备份为真实文件拷贝，
/// 与 MetadataFingerprint.contentFingerprint 的真实读文件语义一致。
private final class FakeFSXMPProvider: XMPProvider, @unchecked Sendable {
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

    /// 同步锁临界区辅助（Swift 6：async 上下文不得直接 lock/unlock）。
    private func makeBackupPath(_ source: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        backupCounter += 1
        return "\(source).gather-backup-\(backupCounter)"
    }

    func backup(photoPath: String) async throws -> String {
        let source = sidecarPath(for: photoPath)
        // 与真实 SidecarXMPProvider.backup 对齐：无侧车可备份 → ""（否则"从未存在的备份"
        // 会被 cleanup 误判为 XMP_BACKUP_MISSING，替身比实现宽松会掩盖这条契约）。
        guard let data = FileManager.default.contents(atPath: source) else { return "" }
        let backupPath = makeBackupPath(source)
        try data.write(to: URL(fileURLWithPath: backupPath))
        return backupPath
    }

    func restore(photoPath: String, backupPath: String) async throws {
        let target = sidecarPath(for: photoPath)
        // 与真实 SidecarXMPProvider.restore 对齐：备份缺失必须报错，绝不静默删掉侧车。
        guard let data = FileManager.default.contents(atPath: backupPath) else {
            throw MetadataSyncError.backupMissing
        }
        try data.write(to: URL(fileURLWithPath: target))
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func removeFile(_ path: String) async throws {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private struct CoordinatorFixture {
    let db: DBConnection
    let dir: String
    let sessionId: String
    let photoPath: String
    let xmpPath: String
    let outbox: MetadataOutboxRepo
    let provider: FakeFSXMPProvider
    let coordinator: MetadataSyncCoordinator

    init() throws {
        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
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
        _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)")
            .run([.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        let outbox = MetadataOutboxRepo(connection: db)
        let provider = FakeFSXMPProvider()
        let coordinator = MetadataSyncCoordinator(
            outboxRepo: outbox,
            writebackRepo: WritebackRepo(connection: db),
            xmp: provider,
            connection: db,
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
        self.coordinator = coordinator
    }

    func cleanupFiles() {
        try? FileManager.default.removeItem(atPath: dir)
    }
}

/// 轮询等待 outbox 行到达目标状态（waitForIdle 在行尚未进入 writing 时立即返回）。
@discardableResult
private func waitForStatus(
    _ repo: MetadataOutboxRepo,
    xmpPath: String,
    status: String,
    timeoutMs: Int = 5000
) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if (try? repo.get(xmpPath))?.status == status { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

// MARK: - 测试

@Suite(.serialized)
struct MetadataSyncCoordinatorTests {
    /// 1) 排程写回：备份原始侧车 → 写入新属性 → markWritten（指纹与基线落库）。
    @Test func scheduledWritebackBacksUpWritesAndMarksWritten() async throws {
        let fx = try CoordinatorFixture()
        defer { fx.cleanupFiles() }

        try fx.outbox.mergePatch(
            xmpPath: fx.xmpPath,
            sessionId: fx.sessionId,
            photoPath: fx.photoPath,
            patch: JSONValue.object(["keywords": .array([.string("a")]), "rating": .number(4)]),
            dirtyFields: ["keywords", "rating"]
        )
        fx.coordinator.schedule(xmpPath: fx.xmpPath, delayMs: 0)

        #expect(await waitForStatus(fx.outbox, xmpPath: fx.xmpPath, status: "written"))
        let row = try fx.outbox.get(fx.xmpPath)
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
        let fx = try CoordinatorFixture()
        defer { fx.cleanupFiles() }

        try fx.outbox.mergePatch(
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
        try fx.outbox.mergePatch(
            xmpPath: fx.xmpPath,
            sessionId: fx.sessionId,
            photoPath: fx.photoPath,
            patch: JSONValue.object(["rating": .number(1)]),
            dirtyFields: ["rating"]
        )
        fx.coordinator.schedule(xmpPath: fx.xmpPath, delayMs: 0)
        #expect(await waitForStatus(fx.outbox, xmpPath: fx.xmpPath, status: "conflict"))

        let row = try fx.outbox.get(fx.xmpPath)
        #expect(row?.status == "conflict")
        #expect(row?.errorMessage == "XMP_EXTERNAL_EDIT_CONFLICT")
        // 外部内容未被覆盖。
        let current = try await fx.provider.readAttributes(photoPath: fx.photoPath)
        #expect(current.rating == 5)

        await fx.coordinator.shutdown()
    }

    /// 2b) 崩溃窗口补写：只有磁盘属性**恰好等于** patch 才算"已写完"。
    /// 关键词数组比较若被跳过，本地新增的关键词会被静默丢弃（事务被误判为已完成）。
    @Test func crashWindowCompletionRequiresExactKeywordMatch() async throws {
        let fx = try CoordinatorFixture()
        defer { fx.cleanupFiles() }

        // 磁盘现状 = 崩溃前写入的部分状态 {rating 4, keywords ["a"]}；待写 patch 多一个 "b"。
        try await fx.provider.writeAttributes(
            photoPath: fx.photoPath, attributes: MetadataWriteAttributes(keywords: ["a"], rating: 4))
        _ = try fx.outbox.mergePatch(
            xmpPath: fx.xmpPath, sessionId: fx.sessionId, photoPath: fx.photoPath,
            patch: JSONValue.object([
                "keywords": .array([.string("a"), .string("b")]),
                "rating": .number(4),
                "source": .string("face-keyword"),
            ]),
            dirtyFields: ["keywords", "rating"])
        // 已有基线（指纹为陈旧值）+ 已有备份路径 = 崩溃窗口的形状。
        try fx.outbox.initializeBaseline(
            xmpPath: fx.xmpPath, baselineFingerprint: "stale-fingerprint",
            baselineValues: .object(["keywords": .array([.string("a")]), "rating": .number(4)]))
        try fx.outbox.setBackupPath(xmpPath: fx.xmpPath, backupPath: fx.dir + "/photo.cr3.xmp.pre-crash")

        let summary = try await fx.coordinator.flushSession(sessionId: fx.sessionId)
        #expect(summary.written == 1)
        let current = try await fx.provider.readAttributes(photoPath: fx.photoPath)
        #expect(current.keywords == ["a", "b"], "补写判定漏比关键词 → patch 未真正落盘却被判 written")
        #expect(current.rating == 4)
        await fx.coordinator.shutdown()
    }

    /// 3) reload-ack 门控：确认同步后清理恢复原始侧车并删除 outbox 行。
    @Test func confirmAndCleanupRestoresBackup() async throws {
        let fx = try CoordinatorFixture()
        defer { fx.cleanupFiles() }

        try fx.outbox.mergePatch(
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
            _ = try fx.coordinator.confirmSync(sessionId: fx.sessionId, sourceModule: "manual")
            Issue.record("expected reloadNotAcked")
        } catch let error as MetadataSyncError {
            #expect(error == .reloadNotAcked)
        }

        _ = try SessionRepo(connection: fx.db).setReloadAckedAt(
            sessionId: fx.sessionId, iso: nowISOString())
        let summary = try fx.coordinator.confirmSync(sessionId: fx.sessionId, sourceModule: "manual")
        #expect(summary.synced == 1)

        let result = try await fx.coordinator.cleanup(sessionId: fx.sessionId, sourceModule: "manual")
        #expect(result.deletedCount == 1)
        #expect(result.errors.isEmpty)
        // outbox 行已删除；侧车恢复为原始内容。
        #expect(try fx.outbox.get(fx.xmpPath) == nil)
        let restored = try await fx.provider.readAttributes(photoPath: fx.photoPath)
        #expect(restored.keywords == ["original"])
        #expect(restored.rating == nil)

        await fx.coordinator.shutdown()
    }

    /// 4) 备份缺失：cleanup 报 XMP_BACKUP_MISSING，行保持 synced（可重试）。
    @Test func cleanupReportsBackupMissingWithoutDeleting() async throws {
        let fx = try CoordinatorFixture()
        defer { fx.cleanupFiles() }

        try fx.outbox.mergePatch(
            xmpPath: fx.xmpPath,
            sessionId: fx.sessionId,
            photoPath: fx.photoPath,
            patch: JSONValue.object(["keywords": .array([.string("a")])]),
            dirtyFields: ["keywords"]
        )
        fx.coordinator.schedule(xmpPath: fx.xmpPath, delayMs: 0)
        #expect(await waitForStatus(fx.outbox, xmpPath: fx.xmpPath, status: "written"))
        _ = try SessionRepo(connection: fx.db).setReloadAckedAt(
            sessionId: fx.sessionId, iso: nowISOString())
        _ = try fx.coordinator.confirmSync(sessionId: fx.sessionId, sourceModule: "manual")

        // 备份文件被外部删除。
        let row = try fx.outbox.get(fx.xmpPath)
        try await fx.provider.removeFile(row!.backupPath)

        let result = try await fx.coordinator.cleanup(sessionId: fx.sessionId, sourceModule: "manual")
        #expect(result.deletedCount == 0)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].contains("XMP_BACKUP_MISSING"))
        // 行保持 synced、侧车未被删除（可修复备份后重试清理）。
        #expect(try fx.outbox.get(fx.xmpPath)?.status == "synced")
        #expect(fx.provider.fileExists(fx.xmpPath))

        await fx.coordinator.shutdown()
    }
}

// MARK: - WritebackService 直测

/// MetadataMutationPort 替身：无资产解析器环境下按 photoId 查 filepath，
/// 复刻 queuePhotoValues 的 mergePatch 语义（source 注入 + dirty 过滤）。
private struct StubMutationPort: MetadataMutationPort {
    let db: DBConnection
    let outbox: MetadataOutboxRepo

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        let row = try db.prepare(
            "SELECT filepath FROM photos WHERE id = ? AND session_id = ?"
        ).get([.text(photoId), .text(sessionId)])
        let photoPath = row?[0].textValue ?? photoId
        let xmpPath = TSPath.xmpSidecarPath(photoPath)
        let dirtyFields = values.keys
            .filter { ["rating", "label", "keywords"].contains($0) }
            .compactMap { MetadataField(rawValue: $0) }
        var patch = values
        patch["source"] = .string(source.rawValue)
        let merged = try outbox.mergePatch(
            xmpPath: xmpPath,
            sessionId: sessionId,
            photoPath: photoPath,
            patch: .object(patch),
            dirtyFields: dirtyFields.map(\.rawValue)
        )
        return MetadataMutationResult(
            photoId: photoId,
            xmpPath: merged.xmpPath,
            dirtyFields: dirtyFields,
            revision: Int(merged.revision),
            status: merged.status
        )
    }

    /// 真实实现会读当前文件 + 按 op 合并 keywords，本替身无法忠实模拟；
    /// 旧实现静默返回"成功但什么都没写"——任何走 queueMutation 的用例都会假绿
    /// （例如 removeOwnedFaceKeywords 的撤销根本没入队）。改为显式抛错，禁止假绿。
    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        _ = (patch, source)
        throw MetadataMutationError.unsupportedField("StubMutationPort.queueMutation")
    }
}

/// MetadataSyncPort 替身：flushSession/confirmSync 返回脚本化的 summary（不触盘）。
/// 只实现被测服务真正消费的字段（items/status/xmpPath），不额外"帮忙"成功。
private final class ScriptedSyncPort: MetadataSyncPort, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: MetadataSyncSummary?

    func script(_ summary: MetadataSyncSummary) {
        lock.lock()
        scripted = summary
        lock.unlock()
    }

    private func take() -> MetadataSyncSummary {
        lock.lock()
        defer { lock.unlock() }
        return scripted ?? MetadataSyncSummary(
            sessionId: "", pending: 0, writing: 0, written: 0, failed: 0, conflict: 0, synced: 0, items: [])
    }

    func waitForIdle(xmpPath: String, timeoutMs: Int) async throws {}
    func flushSession(sessionId: String) async throws -> MetadataSyncSummary { take() }
    func confirmSync(sessionId: String, sourceModule: String) throws -> MetadataSyncSummary { take() }
    func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult {
        CleanupResult(deletedCount: 0, errors: [])
    }
}

@Suite(.serialized)
struct WritebackServiceTests {
    @Test func previewThenExecuteWritesSidecarAndReportsResult() async throws {
        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-writeback-tests-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let sessionId = "s-\(UUID().uuidString)"
        let photoId = "p1"
        let photoPath = "\(dir)/photo.cr3"
        _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)")
            .run([.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        _ = try db.prepare(
            "INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at) VALUES (?, ?, ?, 'photo.cr3', ?, ?)"
        ).run([.text(photoId), .text(sessionId), .text(photoPath), .text(nowISOString()), .text(nowISOString())])

        let provider = FakeFSXMPProvider()
        let outbox = MetadataOutboxRepo(connection: db)
        let coordinator = MetadataSyncCoordinator(
            outboxRepo: outbox,
            writebackRepo: WritebackRepo(connection: db),
            xmp: provider,
            connection: db,
            getNumber: { _, defaultValue in defaultValue },
            skipReloadAck: false
        )
        let service = WritebackService(
            writebackRepo: WritebackRepo(connection: db),
            xmp: provider,
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            metadataSync: coordinator,
            metadataMutations: StubMutationPort(db: db, outbox: outbox),
            outboxRepo: outbox,
            keywordOrigins: nil,
            assetResolver: nil
        )

        let preview = try await service.preview(
            sessionId: sessionId,
            module: "similarity",
            keywordAdditions: [photoId: ["groupA", "portrait"]]
        )
        #expect(preview.totalCount == 1)
        #expect(preview.affectedPhotos == 1)
        #expect(preview.items.first?.keywords == ["groupA", "portrait"])

        let result = try await service.execute(sessionId: sessionId, module: "similarity", items: preview.items)
        #expect(result.written == 1)
        #expect(result.failed == 0)
        #expect(result.errors.isEmpty)

        // 侧车真实写入关键词；outbox 行 written；writeback_items 状态落盘。
        let written = try await provider.readAttributes(photoPath: photoPath)
        #expect(written.keywords == ["groupA", "portrait"])
        #expect(try outbox.get(TSPath.xmpSidecarPath(photoPath))?.status == "written")
        let items = try service.getItems(sessionId: sessionId, module: "similarity")
        #expect(items.count == 1)
        #expect(items.first?.xmpStatus == "written")

        await coordinator.shutdown()
    }

    /// 另一模块存在未确认写回时，preview 必须被互斥门拦截。
    @Test func previewBlockedByOtherModuleActive() async throws {
        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-writeback-tests-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let sessionId = "s-\(UUID().uuidString)"
        let photoId = "p1"
        let photoPath = "\(dir)/photo.cr3"
        _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)")
            .run([.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        _ = try db.prepare(
            "INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at) VALUES (?, ?, ?, 'photo.cr3', ?, ?)"
        ).run([.text(photoId), .text(sessionId), .text(photoPath), .text(nowISOString()), .text(nowISOString())])

        let outbox = MetadataOutboxRepo(connection: db)
        // face_kw 模块的 written 行（另一模块未确认的工作）。
        _ = try outbox.mergePatch(
            xmpPath: TSPath.xmpSidecarPath(photoPath),
            sessionId: sessionId,
            photoPath: photoPath,
            patch: JSONValue.object([
                "keywords": .array([.string("kw")]),
                "source": .string("face-keyword"),
            ]),
            dirtyFields: ["keywords"]
        )
        // 唯一合法路径：先 claim（pending → writing），再 markWritten；否则不构成"已落盘"。
        #expect(try outbox.claim(xmpPath: TSPath.xmpSidecarPath(photoPath), expectedRevision: 1))
        #expect(try outbox.markWritten(
            xmpPath: TSPath.xmpSidecarPath(photoPath),
            revision: 1,
            fingerprint: "fp",
            baseValues: JSONValue.object([:]),
            backupPath: ""
        ))

        let provider = FakeFSXMPProvider()
        let coordinator = MetadataSyncCoordinator(
            outboxRepo: outbox,
            writebackRepo: WritebackRepo(connection: db),
            xmp: provider,
            connection: db,
            getNumber: { _, defaultValue in defaultValue },
            skipReloadAck: false
        )
        let service = WritebackService(
            writebackRepo: WritebackRepo(connection: db),
            xmp: provider,
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            metadataSync: coordinator,
            metadataMutations: StubMutationPort(db: db, outbox: outbox),
            outboxRepo: outbox,
            keywordOrigins: nil,
            assetResolver: nil
        )

        do {
            _ = try await service.preview(sessionId: sessionId, module: "similarity")
            Issue.record("expected otherModuleActive")
        } catch let error as WritebackServiceError {
            #expect(error == .otherModuleActive)
        }

        await coordinator.shutdown()
    }

    /// 共享侧车去重：同一 session 的 RAW+JPEG（photo.cr3 / photo.jpg）解析到同一
    /// 侧车路径 —— preview 必须只生成一行，否则同一侧车两行写回互相覆盖。
    @Test func previewDeduplicatesPhotosSharingOneSidecar() async throws {
        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-raw-jpeg-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let sessionId = "s-\(UUID().uuidString)"
        _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)")
            .run([.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        // 同一 stem、不同扩展名 → 同一侧车路径。
        let rawPath = "\(dir)/photo.cr3"
        let jpegPath = "\(dir)/photo.jpg"
        #expect(TSPath.xmpSidecarPath(rawPath) == TSPath.xmpSidecarPath(jpegPath), "前置条件：两者共享侧车")
        for (id, path) in [("p-raw", rawPath), ("p-jpeg", jpegPath)] {
            _ = try db.prepare(
                "INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)"
            ).run([.text(id), .text(sessionId), .text(path), .text((path as NSString).lastPathComponent), .text(nowISOString()), .text(nowISOString())])
        }

        let outbox = MetadataOutboxRepo(connection: db)
        let provider = FakeFSXMPProvider()
        let service = WritebackService(
            writebackRepo: WritebackRepo(connection: db),
            xmp: provider,
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            metadataSync: ScriptedSyncPort(),
            metadataMutations: StubMutationPort(db: db, outbox: outbox),
            outboxRepo: outbox,
            keywordOrigins: nil,
            assetResolver: nil
        )

        let preview = try await service.preview(
            sessionId: sessionId,
            module: "similarity",
            keywordAdditions: ["p-raw": ["a"], "p-jpeg": ["b"]]
        )
        #expect(preview.affectedPhotos == 2)
        #expect(preview.totalCount == 1, "共享同一侧车的两张照片只能生成一行写回项")
        #expect(Set(preview.items.first?.keywords ?? []) == ["a", "b"], "共享侧车的关键词取保序并集")
        #expect(preview.items.first?.preview?.sharedPhotoCount == 2)
        #expect(try service.getItems(sessionId: sessionId, module: "similarity").count == 1)
    }

    /// 空会话 cleanup：没有任何 writeback 行时是**无操作**，不是 XMP_CLEANUP_REQUIRES_LOADED。
    /// 守卫若退化为"只看 syncedItems.isEmpty"，错误会话/已清理会话上重复 cleanup 会抛错。
    @Test func cleanupWithNoItemsIsNoopNotError() async throws {
        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        let sessionId = "s-\(UUID().uuidString)"
        _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)")
            .run([.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        let outbox = MetadataOutboxRepo(connection: db)
        let service = WritebackService(
            writebackRepo: WritebackRepo(connection: db),
            xmp: FakeFSXMPProvider(),
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            metadataSync: ScriptedSyncPort(),
            metadataMutations: StubMutationPort(db: db, outbox: outbox),
            outboxRepo: outbox,
            keywordOrigins: nil,
            assetResolver: nil
        )
        let result = try await service.cleanup(sessionId: sessionId, module: "similarity")
        #expect(result.deletedCount == 0)
        #expect(result.errors.isEmpty)
        #expect(try service.getItems(sessionId: sessionId, module: "similarity").isEmpty)
    }

    /// failed 写回项必须能被 retryFailed 直接重放（execute 的入口守卫要接受 'failed'）。
    @Test func retryFailedReExecutesFailedWritebackItems() async throws {
        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-retry-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let sessionId = "s-\(UUID().uuidString)"
        let photoId = "p1"
        let photoPath = "\(dir)/photo.cr3"
        _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)")
            .run([.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        _ = try db.prepare(
            "INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at) VALUES (?, ?, ?, 'photo.cr3', ?, ?)"
        ).run([.text(photoId), .text(sessionId), .text(photoPath), .text(nowISOString()), .text(nowISOString())])

        let outbox = MetadataOutboxRepo(connection: db)
        let sync = ScriptedSyncPort()
        let service = WritebackService(
            writebackRepo: WritebackRepo(connection: db),
            xmp: FakeFSXMPProvider(),
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            metadataSync: sync,
            metadataMutations: StubMutationPort(db: db, outbox: outbox),
            outboxRepo: outbox,
            keywordOrigins: nil,
            assetResolver: nil
        )

        let preview = try await service.preview(
            sessionId: sessionId, module: "similarity", keywordAdditions: [photoId: ["groupA"]])
        let xmpPath = try #require(preview.items.first?.xmpPath)

        sync.script(scriptedSummary(sessionId: sessionId, xmpPath: xmpPath, status: .failed,
                                    error: "XMP_WRITE_FAILED: \(xmpPath)"))
        let first = try await service.execute(sessionId: sessionId, module: "similarity", items: preview.items)
        #expect(first.failed == 1)
        #expect(first.written == 0)
        #expect(try service.getItems(sessionId: sessionId, module: "similarity").first?.xmpStatus == "failed")

        // 不重新 preview：直接重试失败行。
        sync.script(scriptedSummary(sessionId: sessionId, xmpPath: xmpPath, status: .written, error: ""))
        let retried = try await service.retryFailed(sessionId: sessionId, module: "similarity")
        #expect(retried.written == 1, "failed 行必须能被重试写回（否则 retryFailed 是空操作）")
        #expect(retried.skipped == 0)
        #expect(retried.failed == 0)
        #expect(try service.getItems(sessionId: sessionId, module: "similarity").first?.xmpStatus == "written")
    }
}

/// 脚本化 summary：只放被测服务消费的 items。
private func scriptedSummary(
    sessionId: String, xmpPath: String, status: MetadataSyncStatus, error: String
) -> MetadataSyncSummary {
    MetadataSyncSummary(
        sessionId: sessionId,
        pending: 0, writing: 0,
        written: status == .written ? 1 : 0,
        failed: status == .failed ? 1 : 0,
        conflict: 0, synced: status == .synced ? 1 : 0,
        items: [MetadataSyncItem(
            xmpPath: xmpPath, revision: 1, persistedRevision: 0,
            status: status, attemptCount: 1, errorMessage: error, updatedAt: nowISOString())]
    )
}
