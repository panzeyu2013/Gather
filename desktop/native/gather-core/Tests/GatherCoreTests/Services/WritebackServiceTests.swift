// desktop/native/gather-core/Tests/GatherCoreTests/Services/WritebackServiceTests.swift
// WritebackService 直测（Cut 2 / S5c-2b-3a）：持久化层是统一交付模型。
//
// 覆盖：
// 1) preview 写 deliveries / delivery_items / delivery_sessions（pending）；
// 2) execute：端到端文件写入（S5c-2b-3b-2a 起执行器直接 xmp.writeAttributes，
//    不再经 MetadataSyncPort/outbox）→ item/delivery written；
// 3) persistAttributes/persistKeywords 更新 delivery_items 并被 execute 写进 XMP；
// 4) 部分失败：逐项 written/failed，交付按「有成功即 written」收敛；
// 5) retryFailed 从 delivery_items 读 failed 重放（不重新 preview）；
// 6) 跨模块门禁 / 共享侧车去重 / 空 cleanup / confirmSync；
// 7) 旧同步栈（writeback_items / metadata_outbox / sessions.writeback_status）
//    已删除：服务只写交付模型。
// 8) P0-1 TOCTOU：慢 restore 的 cleanup 与 writeback 写盘共用 XMPFileLock，
//    最终保留新内容、cleanup 报 FILE_RACED（不删 DB/不静默覆盖）；
//    正常 cleanup → writeback 同路径不死锁。
// 9) XMPFileLock：同一归一化路径串行、不同路径可并行。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
@testable import GatherDelivery

// MARK: - 夹具

/// 真实文件系统 XMP 假件：侧车内容即属性 JSON，备份为真实文件拷贝。
private final class WritebackFSXMPProvider: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var backupCounter = 0
    /// 注入写盘失败的 photoPath（execute 直写后，逐项失败由 provider 决定）。
    private var failingPhotos = Set<String>()
    /// 写盘瞬间探针（P1-2 接线测试）：断言 execute 在碰文件前已带着 owner/heartbeat
    /// 进入 writing；只读快照，不改变 provider 行为。
    var onWriteAttributes: (@Sendable (String) -> Void)?
    /// 慢 restore 注入（P0-1 并发回归）：restore 进入后先 await hook，再写盘。
    private var restoreHook: (@Sendable () async -> Void)?

    func setRestoreHook(_ hook: (@Sendable () async -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        restoreHook = hook
    }

    func setWriteFailure(_ photoPath: String, _ failing: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        if failing { failingPhotos.insert(photoPath) } else { failingPhotos.remove(photoPath) }
    }

    /// 与生产 TSPath.xmpSidecarPath 同口径（替换扩展名，不是追加 .xmp）。
    private func sidecarPath(for photoPath: String) -> String {
        TSPath.xmpSidecarPath(photoPath)
    }

    private func readJSON(_ photoPath: String) -> MetadataWriteAttributes {
        guard let data = FileManager.default.contents(atPath: sidecarPath(for: photoPath)) else {
            return MetadataWriteAttributes()
        }
        return (try? JSONDecoder().decode(MetadataWriteAttributes.self, from: data))
            ?? MetadataWriteAttributes()
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        readJSON(photoPath).keywords ?? []
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        readJSON(photoPath)
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        let failing = lock.withLock { failingPhotos.contains(photoPath) }
        if failing {
            throw NSError(
                domain: "WritebackFSXMPProvider", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "injected write failure"])
        }
        onWriteAttributes?(photoPath)
        let data = try JSONEncoder().encode(attributes)
        try data.write(to: URL(fileURLWithPath: sidecarPath(for: photoPath)), options: .atomic)
    }

    private func nextBackupPath(_ source: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        backupCounter += 1
        return "\(source).gather-backup-\(backupCounter)"
    }

    func backup(photoPath: String) async throws -> String {
        let source = sidecarPath(for: photoPath)
        guard let data = FileManager.default.contents(atPath: source) else { return "" }
        let backupPath = nextBackupPath(source)
        try data.write(to: URL(fileURLWithPath: backupPath))
        return backupPath
    }

    func restore(photoPath: String, backupPath: String) async throws {
        if let hook = lock.withLock({ restoreHook }) {
            await hook()
        }
        guard let data = FileManager.default.contents(atPath: backupPath) else {
            throw DeliveryCoordinatorError.backupMissing(xmpPath: backupPath)
        }
        try data.write(to: URL(fileURLWithPath: sidecarPath(for: photoPath)))
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func removeFile(_ path: String) async throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

/// 单会话 + N 张照片的临时目录夹具（纯 SchemaCurrent）。
private struct WritebackFixture {
    let db: DBConnection
    let dir: String
    let sessionId: String
    let photoIds: [String]
    let photoPaths: [String]

    init(photoCount: Int = 1) throws {
        try self.init(fileNames: (0..<photoCount).map { "photo\($0).cr3" })
    }

    init(fileNames: [String]) throws {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-writeback-delivery-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sessionId = "s-\(UUID().uuidString)"
        _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)")
            .run([.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        var photoIds: [String] = []
        var photoPaths: [String] = []
        for (index, fileName) in fileNames.enumerated() {
            let photoId = "p\(index)"
            let photoPath = "\(dir)/\(fileName)"
            photoIds.append(photoId)
            photoPaths.append(photoPath)
            _ = try db.prepare("""
                INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """).run([
                    .text(photoId), .text(sessionId), .text(photoPath),
                    .text(fileName), .text(nowISOString()), .text(nowISOString()),
                ])
        }
        self.db = db
        self.dir = dir
        self.sessionId = sessionId
        self.photoIds = photoIds
        self.photoPaths = photoPaths
    }

    var sidecarPaths: [String] { photoPaths.map { TSPath.xmpSidecarPath($0) } }

    var deliveryRepo: DeliveryRepo { DeliveryRepo(connection: db) }

    /// Capture One 的 reload-ack（confirm 的 §5.4-2 门禁）：默认 NULL，测试显式确认。
    func acknowledgeReload() throws {
        _ = try db.prepare("UPDATE sessions SET reload_acked_at = ? WHERE id = ?")
            .run([.text(nowISOString()), .text(sessionId)])
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func delivery(_ xmpPath: String) throws -> DeliveryRow? {
        try deliveryRepo.get(xmpPath)
    }

    func items(
        module: DeliveryModule = .similarity,
        status: DeliveryItemStatus? = nil
    ) throws -> [DeliveryItemRow] {
        try deliveryRepo.listItems(sessionId: sessionId, module: module, status: status)
    }

    func scalar(_ sql: String, _ values: [DBValue?] = []) throws -> DBValue? {
        try db.prepare(sql).get(values)?[0]
    }

    func count(_ table: String) throws -> Int {
        Int(try scalar("SELECT COUNT(*) FROM \(table)")?.intValue ?? -1)
    }

}

/// S5c-2b-3b-2a：服务不再接 MetadataSyncPort/MetadataMutationPort——execute 直接
/// 写盘，cleanup 的 DeliveryCoordinator 由同一 connection + 注入的 xmp 自建。
private func makeService(
    fixture: WritebackFixture,
    xmp: WritebackFSXMPProvider
) -> WritebackService {
    WritebackService(
        deliveryRepo: DeliveryRepo(connection: fixture.db),
        xmp: xmp,
        photoRepo: PhotoRepo(connection: fixture.db),
        metadataCacheRepo: MetadataCacheRepo(connection: fixture.db),
        connection: fixture.db,
        keywordOrigins: nil,
        assetResolver: nil,
        fileLock: XMPFileLock()
    )
}

/// 写盘瞬间的交付租约快照（P1-2 接线测试）。
private final class LeaseSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (status: String, owner: String, heartbeat: String)?

    func record(status: String, owner: String, heartbeat: String) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil { value = (status, owner, heartbeat) }
    }

    var snapshot: (status: String, owner: String, heartbeat: String)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - 测试

@Suite(.serialized)
struct WritebackServiceTests {
    @Test("preview：交付行/交付项/会话链接落库为 pending")
    func previewPersistsPendingDelivery() async throws {
        let fixture = try WritebackFixture(photoCount: 2)
        defer { fixture.cleanup() }
        let service = makeService(fixture: fixture, xmp: WritebackFSXMPProvider())

        let preview = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [
                fixture.photoIds[0]: ["a"],
                fixture.photoIds[1]: ["b"],
            ]
        )
        #expect(preview.totalCount == 2)
        #expect(preview.affectedPhotos == 2)
        #expect(Set(preview.items.map { $0.keywords.first ?? "" }) == ["a", "b"])
        #expect(Set(preview.items.map { $0.id ?? -1 }).count == 2)

        for (index, xmpPath) in fixture.sidecarPaths.enumerated() {
            let delivery = try #require(try fixture.delivery(xmpPath))
            #expect(delivery.status == DeliveryStatus.pending.rawValue)
            #expect(delivery.photoPath == fixture.photoPaths[index])
        }
        let items = try fixture.items()
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.status == DeliveryItemStatus.pending.rawValue })
        #expect(Set(items.map(\.photoId)) == Set(fixture.photoIds))
        let links = Int(try fixture.scalar(
            "SELECT COUNT(*) FROM delivery_sessions WHERE session_id = ?",
            [.text(fixture.sessionId)])?.intValue ?? -1)
        #expect(links == 2)
    }

    @Test("execute：真实写盘 → item/delivery written")
    func executeWritesSidecarAndMarksDeliveryWritten() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)

        // 预置一份真实侧车：写前备份与写后指纹都必须落在磁盘上。
        let initial = MetadataWriteAttributes(keywords: ["before"])
        try JSONEncoder().encode(initial).write(
            to: URL(fileURLWithPath: fixture.sidecarPaths[0]))
        let preview = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["groupA", "portrait"]]
        )
        let result = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        #expect(result.written == 1)
        #expect(result.failed == 0)
        #expect(result.errors.isEmpty)

        let written = try await xmp.readAttributes(photoPath: fixture.photoPaths[0])
        #expect(written.keywords == ["before", "groupA", "portrait"])

        let delivery = try #require(try fixture.delivery(fixture.sidecarPaths[0]))
        #expect(delivery.status == DeliveryStatus.written.rawValue)
        // S5c-2b-3b-1：execute 直接落真实备份/指纹/基线（不再留空等 outbox 镜像）。
        #expect(!delivery.backupPath.isEmpty)
        #expect(FileManager.default.fileExists(atPath: delivery.backupPath))
        #expect(!delivery.baseFingerprint.isEmpty)
        #expect(
            delivery.baseValues.objectValue?["keywords"]?.arrayElements?.compactMap(\.stringValue)
                == ["before", "groupA", "portrait"])
        let items = try fixture.items()
        #expect(items.count == 1)
        #expect(items.first?.status == DeliveryItemStatus.written.rawValue)
        #expect((items.first?.attemptCount ?? 0) >= 1)
    }

    @Test("persistAttributes：写 delivery_items.attributes_json 并被 execute 写进 XMP")
    func persistAttributesUpdatesDeliveryItems() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)

        let preview = try await service.preview(
            sessionId: fixture.sessionId,
            module: "culling",
            keywordAdditions: [fixture.photoIds[0]: ["keep"]]
        )
        var item = try #require(preview.items.first)
        item.attributes = WritebackAttributes(keywords: ["keep", "hero"], rating: 4, label: "red")
        item.keywords = ["keep"]
        try service.persistAttributes(items: [item])
        try service.persistKeywords(items: [item])

        let persisted = try #require(try fixture.items(module: .culling).first)
        #expect(persisted.attributes["rating"]?.numberValue == 4)
        #expect(persisted.attributes["label"]?.stringValue == "red")
        #expect(
            persisted.attributes["keywords"]?.arrayElements?.compactMap { $0.stringValue }
                == ["keep", "hero"])
        #expect(persisted.keywordList == ["keep"])

        let result = try await service.execute(
            sessionId: fixture.sessionId, module: "culling", items: [item])
        #expect(result.written == 1)
        let written = try await xmp.readAttributes(photoPath: fixture.photoPaths[0])
        #expect(written.rating == 4)
        #expect(written.label == "red")
        #expect(written.keywords == ["keep", "hero"])
    }

    @Test("execute：部分失败 → 逐项 written/failed，交付按有成功即 written 收敛")
    func partialFailureMarksItemsIndividually() async throws {
        let fixture = try WritebackFixture(photoCount: 2)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        xmp.setWriteFailure(fixture.photoPaths[1])
        let service = makeService(fixture: fixture, xmp: xmp)

        let preview = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [
                fixture.photoIds[0]: ["a"],
                fixture.photoIds[1]: ["b"],
            ]
        )

        let result = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        #expect(result.written == 1)
        #expect(result.failed == 1)
        #expect(result.skipped == 0)
        #expect(result.totalAffected == 2)
        #expect(result.failedItems.count == 1)
        #expect(result.errors.contains { $0.contains("XMP_WRITE_FAILED") })

        let first = try #require(try fixture.delivery(fixture.sidecarPaths[0]))
        let second = try #require(try fixture.delivery(fixture.sidecarPaths[1]))
        #expect(first.status == DeliveryStatus.written.rawValue)
        #expect(second.status == DeliveryStatus.failed.rawValue)
        #expect(second.errorMessage.contains("XMP_WRITE_FAILED"))

        let items = try fixture.items()
        #expect(items.filter { $0.status == DeliveryItemStatus.written.rawValue }.count == 1)
        #expect(items.filter { $0.status == DeliveryItemStatus.failed.rawValue }.count == 1)
    }

    @Test("retryFailed：从 delivery_items 读 failed 重放，不重新 preview")
    func retryFailedReexecutesFailedItems() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        xmp.setWriteFailure(fixture.photoPaths[0])
        let service = makeService(fixture: fixture, xmp: xmp)

        let preview = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["groupA"]]
        )
        let sidecar = try #require(preview.items.first?.xmpPath)
        let first = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        #expect(first.failed == 1)
        #expect(first.written == 0)
        #expect(try fixture.delivery(sidecar)?.status == DeliveryStatus.failed.rawValue)
        #expect(try fixture.items(status: .failed).count == 1)

        // 不重新 preview：解除注入失败后直接重试失败项。
        xmp.setWriteFailure(fixture.photoPaths[0], false)
        let retried = try await service.retryFailed(
            sessionId: fixture.sessionId, module: "similarity")
        #expect(retried.written == 1)
        #expect(retried.failed == 0)
        #expect(retried.skipped == 0)
        #expect(try fixture.delivery(sidecar)?.status == DeliveryStatus.written.rawValue)
        let items = try fixture.items()
        #expect(items.first?.status == DeliveryItemStatus.written.rawValue)
        #expect((items.first?.attemptCount ?? 0) >= 2)
    }

    @Test("preview：另一模块的 written 交付项触发互斥门")
    func previewBlockedByOtherModuleActive() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let repo = fixture.deliveryRepo
        let sidecar = fixture.sidecarPaths[0]
        _ = try repo.createOrGet(xmpPath: sidecar, photoPath: fixture.photoPaths[0])
        // face_kw 模块已落盘（pending → written 是迁移表允许路径）。
        _ = try repo.upsertItem(
            xmpPath: sidecar, photoId: fixture.photoIds[0], module: .faceKeyword,
            keywords: ["kw"], status: .pending)
        _ = try repo.upsertItem(
            xmpPath: sidecar, photoId: fixture.photoIds[0], module: .faceKeyword,
            keywords: ["kw"], status: .written)

        let service = makeService(fixture: fixture, xmp: WritebackFSXMPProvider())
        do {
            _ = try await service.preview(sessionId: fixture.sessionId, module: "similarity")
            Issue.record("expected otherModuleActive")
        } catch let error as WritebackServiceError {
            #expect(error == .otherModuleActive)
        }
    }

    @Test("preview：共享同一侧车的 RAW+JPEG 只生成一条交付项")
    func previewDeduplicatesSharedSidecar() async throws {
        let fixture = try WritebackFixture(fileNames: ["photo.cr3", "photo.jpg"])
        defer { fixture.cleanup() }
        let service = makeService(fixture: fixture, xmp: WritebackFSXMPProvider())

        let rawSidecar = TSPath.xmpSidecarPath(fixture.photoPaths[0])
        let jpegSidecar = TSPath.xmpSidecarPath(fixture.photoPaths[1])
        #expect(rawSidecar == jpegSidecar, "前置条件：两者共享侧车")

        let preview = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["a"], fixture.photoIds[1]: ["b"]]
        )
        #expect(preview.affectedPhotos == 2)
        #expect(preview.totalCount == 1, "共享同一侧车的两张照片只能生成一条交付项")
        #expect(Set(preview.items.first?.keywords ?? []) == ["a", "b"])
        #expect(preview.items.first?.preview?.sharedPhotoCount == 2)
        #expect(try fixture.items().count == 1)
        #expect(try fixture.delivery(rawSidecar)?.status == DeliveryStatus.pending.rawValue)
    }

    @Test("二次 preview：written 交付按新输入重开为 pending（revision+1），execute 再写")
    func secondPreviewReopensWrittenDelivery() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)
        let sidecar = fixture.sidecarPaths[0]

        let first = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["a"]]
        )
        _ = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: first.items)
        let writtenRow = try #require(try fixture.delivery(sidecar))
        #expect(writtenRow.status == DeliveryStatus.written.rawValue)
        #expect(writtenRow.revision == 0)

        // 新输入：written 交付必须重开为 pending 并推进 revision，
        // 否则 execute 的 markWriting 会被迁移表拒绝（written → writing 非法）。
        let second = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["b"]]
        )
        let reopened = try #require(try fixture.delivery(sidecar))
        #expect(reopened.status == DeliveryStatus.pending.rawValue)
        #expect(reopened.revision == 1)
        // execute 直写后磁盘上已有 ["a"]；preview 按当前文件状态合并新词（旧实现
        // 用空 summary 不落盘，这条断言只能看到 ["b"]，属于测试夹具的假绿）。
        #expect(second.items.first?.keywords == ["a", "b"])

        let executed = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: second.items)
        #expect(executed.written == 1)
        #expect(executed.failed == 0)
        let final = try #require(try fixture.delivery(sidecar))
        #expect(final.status == DeliveryStatus.written.rawValue)
        #expect(final.revision == 1)
        #expect(try fixture.items().count == 1)
    }

    @Test("过渡镜像：execute 之后 DeliveryCoordinator.mirrorWriteback 再写一遍仍收敛")
    func mirrorAfterExecuteConvergesToWritten() async throws {
        // 生产顺序（S5c-2b-1/2 过渡期）：WritebackService.execute 先落交付，
        // Culling/FaceKw/Similarity 随后把结果镜像进同一交付（revision+1）。
        // 两步都必须收敛为 written，否则 2b-3b 删除镜像前会双写打架。
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)
        let preview = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["groupA"]]
        )
        _ = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        let executed = try #require(try fixture.delivery(fixture.sidecarPaths[0]))
        #expect(executed.status == DeliveryStatus.written.rawValue)

        let mirrored = try service.getItems(sessionId: fixture.sessionId, module: "similarity")
        let mirrorItems = mirrored.map { item in
            DeliveryWritebackMirrorItem(
                photoId: item.photoId,
                photoPath: item.photoPath,
                xmpPath: item.xmpPath,
                keywords: item.keywords,
                status: DeliveryItemStatus(rawValue: item.xmpStatus) ?? .failed
            )
        }
        let delivery = DeliveryCoordinator(
            connection: fixture.db, xmp: xmp, fileLock: XMPFileLock(), requireReloadAck: false)
        let summary = try delivery.mirrorWriteback(
            sessionId: fixture.sessionId, module: .similarity, items: mirrorItems)
        #expect(summary.errors.isEmpty)
        #expect(summary.deliveryCount == 1)

        let afterMirror = try #require(try fixture.delivery(fixture.sidecarPaths[0]))
        #expect(afterMirror.status == DeliveryStatus.written.rawValue)
        #expect(afterMirror.revision == 1)
        #expect(try fixture.items().first?.status == DeliveryItemStatus.written.rawValue)
    }

    @Test("cleanup：没有交付项时是无操作，不是 XMP_CLEANUP_REQUIRES_LOADED")
    func cleanupWithNoItemsIsNoop() async throws {
        let fixture = try WritebackFixture(photoCount: 0)
        defer { fixture.cleanup() }
        let service = makeService(fixture: fixture, xmp: WritebackFSXMPProvider())
        let result = try await service.cleanup(sessionId: fixture.sessionId, module: "similarity")
        #expect(result.deletedCount == 0)
        #expect(result.errors.isEmpty)
        #expect(try service.getItems(sessionId: fixture.sessionId, module: "similarity").isEmpty)
    }

    @Test("confirmSync：written → synced（交付与项），会话态由聚合派生")
    func confirmSyncFlipsDeliveredItems() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)

        let preview = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["a"]]
        )
        let executed = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        #expect(executed.written == 1)

        try fixture.acknowledgeReload()
        try await service.confirmSync(sessionId: fixture.sessionId, module: "similarity")
        #expect(try fixture.delivery(fixture.sidecarPaths[0])?.status == DeliveryStatus.synced.rawValue)
        #expect(try fixture.items().first?.status == DeliveryItemStatus.synced.rawValue)
        // D-021：会话写回态由交付聚合派生（不再写已删除的 sessions 列）。
        #expect(try DeliverySummaryQuery(connection: fixture.db)
            .summary(sessionId: fixture.sessionId, module: .similarity).writebackStatus == .done)
    }

    @Test("confirmSync 委托 Coordinator 门禁：pending 阻断、未 ack 不落确认、ack 后推进")
    func confirmSyncUsesCoordinatorGate() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let service = makeService(fixture: fixture, xmp: WritebackFSXMPProvider())
        let sidecar = fixture.sidecarPaths[0]
        let preview = try await service.preview(
            sessionId: fixture.sessionId, module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["gate"]])

        // 1) pending 交付：完整性门禁拒绝，confirmed_at 不落地。
        do {
            try await service.confirmSync(sessionId: fixture.sessionId, module: "similarity")
            Issue.record("pending 交付必须被 confirmSync 拒绝")
        } catch let error as DeliveryCoordinatorError {
            guard case .confirmIncomplete(let blockers) = error else {
                Issue.record("错误类型不符: \(error)")
                return
            }
            #expect(blockers == ["delivery:pending=1", "item:pending=1"])
        }
        #expect(try fixture.delivery(sidecar)?.status == DeliveryStatus.pending.rawValue)
        #expect(try fixture.scalar(
            "SELECT confirmed_at FROM delivery_sessions WHERE session_id = ?",
            [.text(fixture.sessionId)])?.textValue == "")

        // 2) 写回成功但 Capture One 未 ack reload：同一门禁拒绝。
        let executed = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        #expect(executed.written == 1)
        do {
            try await service.confirmSync(sessionId: fixture.sessionId, module: "similarity")
            Issue.record("未 ack reload 时 confirmSync 必须失败")
        } catch let error as DeliveryCoordinatorError {
            #expect(error == .reloadNotAcknowledged(sessionId: fixture.sessionId))
        }
        #expect(try fixture.delivery(sidecar)?.status == DeliveryStatus.written.rawValue)
        #expect(try fixture.scalar(
            "SELECT confirmed_at FROM delivery_sessions WHERE session_id = ?",
            [.text(fixture.sessionId)])?.textValue == "")

        // 3) ack 后同一入口推进：证明 confirmSync 不是被删掉，而是走完整门禁。
        try fixture.acknowledgeReload()
        try await service.confirmSync(sessionId: fixture.sessionId, module: "similarity")
        #expect(try fixture.delivery(sidecar)?.status == DeliveryStatus.synced.rawValue)
    }

    @Test("flushSession：只回读交付摘要，不再调度/写盘（S5c-2b-3b-2a）")
    func flushSessionOnlyProjectsSummary() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)

        let preview = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["a"]]
        )
        _ = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        let sidecar = fixture.sidecarPaths[0]
        let before = try Data(contentsOf: URL(fileURLWithPath: sidecar))

        let summary = try service.flushSession(sessionId: fixture.sessionId, module: "similarity")
        #expect(summary.sessionId == fixture.sessionId)
        #expect(summary.written == 1)
        #expect(summary.pending == 0)
        #expect(summary.items.map(\.xmpPath) == [sidecar])
        // 无参数版本按会话聚合，同样只读。
        #expect(try service.flushSession(sessionId: fixture.sessionId).written == 1)

        let after = try Data(contentsOf: URL(fileURLWithPath: sidecar))
        #expect(before == after, "flushSession 不得再触发写盘")
    }

    @Test("cleanup：synced 交付经 DeliveryCoordinator 恢复备份并删除交付行")
    func cleanupRestoresBackupThroughCoordinator() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)
        let sidecar = fixture.sidecarPaths[0]
        let original = MetadataWriteAttributes(keywords: ["before"])
        try JSONEncoder().encode(original).write(to: URL(fileURLWithPath: sidecar))

        let preview = try await service.preview(
            sessionId: fixture.sessionId,
            module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["after"]]
        )
        _ = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        try fixture.acknowledgeReload()
        try await service.confirmSync(sessionId: fixture.sessionId, module: "similarity")

        let result = try await service.cleanup(
            sessionId: fixture.sessionId, module: "similarity")
        #expect(result.errors.isEmpty)
        #expect(result.deletedCount == 1)
        #expect(try fixture.delivery(sidecar) == nil)
        #expect(try service.getItems(sessionId: fixture.sessionId, module: "similarity").isEmpty)
        let restored = try await xmp.readAttributes(photoPath: fixture.photoPaths[0])
        #expect(restored.keywords == ["before"], "cleanup 必须从真实备份恢复侧车")
    }

    // MARK: - writing 租约（P1-2）

    @Test("租约接线：execute 写盘时已是 writing + 本服务 owner + heartbeat，收敛后清空")
    func executeClaimsOwnLeaseBeforeWritingFiles() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let snapshot = LeaseSnapshot()
        xmp.onWriteAttributes = { photoPath in
            let sidecar = TSPath.xmpSidecarPath(photoPath)
            guard let row = try? fixture.deliveryRepo.get(sidecar) else { return }
            snapshot.record(
                status: row.status, owner: row.leaseOwner, heartbeat: row.heartbeatAt)
        }
        let service = makeService(fixture: fixture, xmp: xmp)
        let sidecar = fixture.sidecarPaths[0]
        let preview = try await service.preview(
            sessionId: fixture.sessionId, module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["lease"]])
        #expect(try fixture.delivery(sidecar)?.status == DeliveryStatus.pending.rawValue)

        let result = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        #expect(result.written == 1)
        #expect(result.failed == 0)

        let observed = try #require(snapshot.snapshot)
        #expect(observed.status == DeliveryStatus.writing.rawValue)
        #expect(observed.owner.hasPrefix("writeback-"))
        #expect(!observed.heartbeat.isEmpty)

        // 正常 pending → writing → written 不变：交付收敛、租约清空、只记 1 次尝试。
        let delivery = try #require(try fixture.delivery(sidecar))
        #expect(delivery.status == DeliveryStatus.written.rawValue)
        #expect(delivery.leaseOwner == "")
        #expect(delivery.heartbeatAt == "")
        #expect(delivery.attemptCount == 1)
        #expect(try fixture.items().first?.status == DeliveryItemStatus.written.rawValue)
    }

    @Test("崩溃恢复：markItem 后未 markWritten（租约过期）→ 下一次 execute 归位 written")
    func crashBetweenMarkItemAndMarkWrittenIsRecoveredByNextExecute() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)
        let preview = try await service.preview(
            sessionId: fixture.sessionId, module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["crash"]])
        let item = try #require(preview.items.first)
        let sidecar = try #require(item.xmpPath)
        let itemId = try #require(item.id)

        // 模拟崩溃：另一进程抢租约、写盘成功并 markItem(written)，但没跑到 markWritten。
        let repo = fixture.deliveryRepo
        _ = try repo.markWriting(
            xmpPath: sidecar, revision: 0, leaseOwner: "crashed-writer")
        try repo.markItem(itemId: Int64(itemId), status: .written)
        _ = try fixture.db.prepare("UPDATE deliveries SET heartbeat_at = ? WHERE xmp_path = ?")
            .run([.text("2000-01-01T00:00:00.000Z"), .text(sidecar)])
        #expect(try fixture.delivery(sidecar)?.status == DeliveryStatus.writing.rawValue)

        // 重启后的新进程（新 owner）再 execute：过期租约被抢占，交付归位 written。
        let restarted = makeService(fixture: fixture, xmp: xmp)
        let result = try await restarted.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        #expect(result.written == 1, "归位的交付计入 written")
        #expect(result.failed == 0)
        #expect(result.errors.isEmpty)

        let recovered = try #require(try fixture.delivery(sidecar))
        #expect(recovered.status == DeliveryStatus.written.rawValue)
        #expect(recovered.leaseOwner == "")
        #expect(recovered.heartbeatAt == "")
        #expect(recovered.attemptCount == 2, "抢占是一次新的写尝试")
        #expect(try fixture.items().first?.status == DeliveryItemStatus.written.rawValue)
    }


    @Test("崩溃恢复：executePending 无 pending/failed 项也会归位 writing")
    func executePendingRecoversInterruptedWritingWithoutPendingItems() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)
        let preview = try await service.preview(
            sessionId: fixture.sessionId, module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["manual"]])
        let item = try #require(preview.items.first)
        let sidecar = try #require(item.xmpPath)

        // 手动队列的崩溃现场：item 已 written、交付仍 writing、租约已过期。
        let repo = fixture.deliveryRepo
        _ = try repo.markWriting(
            xmpPath: sidecar, revision: 0, leaseOwner: "crashed-writer")
        try repo.markItem(itemId: Int64(try #require(item.id)), status: .written)
        _ = try fixture.db.prepare("UPDATE deliveries SET heartbeat_at = ? WHERE xmp_path = ?")
            .run([.text("2000-01-01T00:00:00.000Z"), .text(sidecar)])

        let restarted = makeService(fixture: fixture, xmp: xmp)
        let result = try await restarted.executePending(
            sessionId: fixture.sessionId, module: "similarity")
        #expect(result.written == 1)
        #expect(result.failed == 0)
        let recovered = try #require(try fixture.delivery(sidecar))
        #expect(recovered.status == DeliveryStatus.written.rawValue)
        #expect(recovered.leaseOwner == "")
        #expect(try fixture.items().first?.status == DeliveryItemStatus.written.rawValue)
    }
    @Test("租约丢失：renew 失败不得 markWritten/markFailed，交付保持 writing/接管者 owner")
    func leaseLossBeforeConvergenceSkipsStateWrite() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)
        let sidecar = fixture.sidecarPaths[0]
        try writeInitialSidecar(fixture, keywords: ["before"])
        let preview = try await service.preview(
            sessionId: fixture.sessionId, module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["lease-loss"]])

        // 写盘瞬间把租约换给另一个 owner：模拟长批次期间本服务租约被接管。
        let stolen = LockedFlag()
        xmp.onWriteAttributes = { _ in
            guard !stolen.isSet else { return }
            stolen.set()
            _ = try? fixture.db.prepare(
                "UPDATE deliveries SET lease_owner = ? WHERE xmp_path = ?"
            ).run([.text("thief"), .text(sidecar)])
        }

        let result = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        #expect(result.written == 1)
        #expect(result.errors.contains("DELIVERY_LEASE_LOST: \(sidecar)"))
        #expect(!result.errors.contains { $0.contains("DELIVERY_WRITE_FAILED") },
                "renew 失败后不得再尝试 markWritten/markFailed")

        // 交付行必须原样保留：不翻 written/failed、不写基线/备份。
        let row = try #require(try fixture.delivery(sidecar))
        #expect(row.status == DeliveryStatus.writing.rawValue)
        #expect(row.leaseOwner == "thief")
        #expect(row.baseFingerprint == "")
        #expect(row.backupPath == "")
        // item 级写也受 lease owner CAS：租约被接管后不得把 item 翻 written。
        #expect(try fixture.items().first?.status == DeliveryItemStatus.pending.rawValue)
    }

    @Test("租约保护：他人未过期 writing 租约 → execute 逐项失败并报 DELIVERY_LEASE_HELD")
    func executeFailsItemsInsteadOfSkippingWhenLeaseIsHeldByAnotherOwner() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let service = makeService(fixture: fixture, xmp: xmp)
        let preview = try await service.preview(
            sessionId: fixture.sessionId, module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["busy"]])
        let sidecar = fixture.sidecarPaths[0]
        // 另一个活跃写者持有未过期租约：本服务不得无条件复用。
        _ = try fixture.deliveryRepo.markWriting(
            xmpPath: sidecar, revision: 0, leaseOwner: "live-writer")

        let result = try await service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        #expect(result.written == 0)
        #expect(result.failed == 1, "租约冲突必须逐项失败，不能静默跳过")
        #expect(result.skipped == 0)
        #expect(result.errors.contains { $0.contains("DELIVERY_LEASE_HELD") })

        // 文件从未被本服务触碰，交付行仍归原 owner（attempt 也不变）。
        let delivery = try #require(try fixture.delivery(sidecar))
        #expect(delivery.status == DeliveryStatus.writing.rawValue)
        #expect(delivery.leaseOwner == "live-writer")
        #expect(delivery.attemptCount == 1)
        let failedItem = try #require(try fixture.items().first)
        #expect(failedItem.status == DeliveryItemStatus.failed.rawValue)
        #expect(failedItem.errorMessage.contains("DELIVERY_LEASE_HELD"))
        #expect(!FileManager.default.fileExists(atPath: sidecar))
    }

    // MARK: - P0-1 TOCTOU：cleanup 文件阶段与 writeback 写盘共用 XMPFileLock

    @Test("XMPFileLock：同一归一化路径串行（不同字符串表示不并行）")
    func xmpFileLockSerializesSameNormalizedPath() async throws {
        let lock = XMPFileLock()
        let firstEntered = LockedFlag()
        let hold = AsyncGate()
        let secondEntered = LockedFlag()
        let secondRequested = LockedFlag()
        let order = OrderLog()

        let first = Task {
            try await lock.run(path: "/v/./IMG_1.xmp") {
                firstEntered.set()
                await order.append("first")
                await hold.wait()
            }
        }
        let enteredFirst = await waitUntil { firstEntered.isSet }
        #expect(enteredFirst)

        let second = Task {
            secondRequested.set()
            try await lock.run(path: "/v/IMG_1.xmp") {
                secondEntered.set()
                await order.append("second")
            }
        }
        let requested = await waitUntil { secondRequested.isSet }
        #expect(requested)
        // 等第二个调用真正进入等待队列后，才能断言它没有越过持有者。
        let queued = await waitUntilAsync {
            await lock.waiterCount(path: "/v/IMG_1.xmp") == 1
        }
        #expect(queued)
        #expect(!secondEntered.isSet, "同一归一化路径必须串行")
        let beforeRelease = await order.snapshot
        #expect(beforeRelease == ["first"])

        hold.release()
        _ = try await first.value
        _ = try await second.value
        let afterRelease = await order.snapshot
        #expect(afterRelease == ["first", "second"])
    }

    @Test("XMPFileLock：不同路径可并行（持有一条不阻塞另一条）")
    func xmpFileLockRunsDifferentPathsConcurrently() async throws {
        let lock = XMPFileLock()
        let firstEntered = LockedFlag()
        let hold = AsyncGate()
        let secondDone = LockedFlag()

        let first = Task {
            try await lock.run(path: "/v/IMG_1.xmp") {
                firstEntered.set()
                await hold.wait()
            }
        }
        let enteredFirst = await waitUntil { firstEntered.isSet }
        #expect(enteredFirst)

        let second = Task {
            try await lock.run(path: "/v/IMG_2.xmp") { secondDone.set() }
        }
        let completedWhileHeld = await waitUntil { secondDone.isSet }
        #expect(completedWhileHeld, "不同 xmpPath 必须能并行完成")

        hold.release()
        _ = try await first.value
        _ = try await second.value
    }

    @Test("并发 cleanup（慢 restore）与 writeback：最终为新内容且 cleanup 不覆盖")
    func cleanupRacingWritebackKeepsNewContent() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let env = LockedDeliveryEnvironment(fixture: fixture, xmp: xmp)
        let sidecar = fixture.sidecarPaths[0]
        try writeInitialSidecar(fixture, keywords: ["before"])
        try await executeFirstWrite(env, keyword: "first")
        let synced = try #require(try fixture.delivery(sidecar))
        #expect(synced.typedStatus == .synced)

        // cleanup 进入 restore 后停住（模拟慢文件阶段），并保持 XMPFileLock。
        let restoreEntered = LockedFlag()
        let restoreRelease = AsyncGate()
        xmp.setRestoreHook {
            restoreEntered.set()
            await restoreRelease.wait()
        }

        let cleanupTask = Task {
            try await env.coordinator.cleanup(
                sessionId: fixture.sessionId, module: .similarity)
        }
        let entered = await waitUntil { restoreEntered.isSet }
        #expect(entered, "cleanup 必须先进入慢 restore 并持锁")

        // 新输入：preview 重开交付（revision+1 / pending），execute 写新内容。
        // cleanup 正持锁，所以 writeback 的 backup/read/write 必须排队。
        let preview = try await env.service.preview(
            sessionId: fixture.sessionId, module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["second"]])
        let writeTask = Task {
            try await env.service.execute(
                sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        }
        // 第一轮 execute 用 revision 0 落库；preview 的新输入把它推进到 1。
        let bumped = await waitUntil {
            (try? fixture.deliveryRepo.get(sidecar)?.revision) == 1
        }
        #expect(bumped, "writeback 必须先推进 revision 再等文件锁")

        restoreRelease.release()
        let cleanupSummary = try await cleanupTask.value
        let writeResult = try await writeTask.value

        // cleanup 的文件阶段事后复核看见 revision 变化：不删 DB、显式报 FILE_RACED；
        // writeback 随后把新内容写回，最终文件必须是新内容。
        #expect(cleanupSummary.deletedCount == 0)
        #expect(cleanupSummary.skippedCount == 1)
        #expect(cleanupSummary.errors.contains { $0.contains("XMP_CLEANUP_FILE_RACED") })
        #expect(writeResult.written == 1)
        #expect(writeResult.failed == 0)

        let final = try await xmp.readAttributes(photoPath: fixture.photoPaths[0])
        #expect(final.keywords?.contains("second") == true, "最终文件必须是新内容")
        let delivery = try #require(try fixture.delivery(sidecar))
        #expect(delivery.typedStatus == .written)
        #expect(delivery.revision == 1)
    }

    @Test("正常 cleanup 后同路径 writeback：不死锁且新内容落盘")
    func cleanupThenWritebackOnSamePathCompletesWithoutDeadlock() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        let xmp = WritebackFSXMPProvider()
        let env = LockedDeliveryEnvironment(fixture: fixture, xmp: xmp)
        let sidecar = fixture.sidecarPaths[0]
        try writeInitialSidecar(fixture, keywords: ["before"])
        try await executeFirstWrite(env, keyword: "first")

        let cleanup = try await env.coordinator.cleanup(
            sessionId: fixture.sessionId, module: .similarity)
        #expect(cleanup.deletedCount == 1)
        #expect(try fixture.delivery(sidecar) == nil)
        let restored = try await xmp.readAttributes(photoPath: fixture.photoPaths[0])
        #expect(restored.keywords == ["before"])

        // 同一路径再次 preview + execute：锁必须已完全释放，不能自锁。
        let preview = try await env.service.preview(
            sessionId: fixture.sessionId, module: "similarity",
            keywordAdditions: [fixture.photoIds[0]: ["after"]])
        let result = try await env.service.execute(
            sessionId: fixture.sessionId, module: "similarity", items: preview.items)
        #expect(result.written == 1)
        #expect(result.failed == 0)
        let final = try await xmp.readAttributes(photoPath: fixture.photoPaths[0])
        #expect(final.keywords?.contains("after") == true)
    }
}

// MARK: - 并发测试支撑（仅本文件）

/// 线程安全布尔探针。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 并发测试的调用顺序记录。
private actor OrderLog {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }

    var snapshot: [String] { values }
}

/// 轮询等待（可控超时，避免固定 sleep 的抖动）。
private func waitUntil(
    timeoutMs: Int = 3_000,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// 异步条件的轮询等待（actor 探针用）。
private func waitUntilAsync(
    timeoutMs: Int = 3_000,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// 共享锁 + 真实 XMPProvider 的 cleanup/writeback 环境。
private struct LockedDeliveryEnvironment {
    let fixture: WritebackFixture
    let xmp: WritebackFSXMPProvider
    let fileLock: XMPFileLock
    let coordinator: DeliveryCoordinator
    let service: WritebackService

    init(fixture: WritebackFixture, xmp: WritebackFSXMPProvider) {
        let fileLock = XMPFileLock()
        let deliveryRepo = DeliveryRepo(connection: fixture.db)
        let coordinator = DeliveryCoordinator(
            connection: fixture.db,
            deliveryRepo: deliveryRepo,
            intentRepo: DeliveryIntentRepo(connection: fixture.db),
            files: XMPDeliveryFilePort(xmp),
            fileLock: fileLock
        )
        let service = WritebackService(
            deliveryRepo: deliveryRepo,
            xmp: xmp,
            photoRepo: PhotoRepo(connection: fixture.db),
            metadataCacheRepo: MetadataCacheRepo(connection: fixture.db),
            connection: fixture.db,
            keywordOrigins: nil,
            assetResolver: nil,
            delivery: coordinator,
            fileLock: fileLock
        )
        self.fixture = fixture
        self.xmp = xmp
        self.fileLock = fileLock
        self.coordinator = coordinator
        self.service = service
    }
}

private func writeInitialSidecar(
    _ fixture: WritebackFixture,
    keywords: [String]
) throws {
    try JSONEncoder().encode(MetadataWriteAttributes(keywords: keywords))
        .write(to: URL(fileURLWithPath: fixture.sidecarPaths[0]))
}

/// 第一轮真实写盘 + confirm（交付进入 synced，可被 cleanup 选中）。
private func executeFirstWrite(
    _ env: LockedDeliveryEnvironment,
    keyword: String
) async throws {
    let preview = try await env.service.preview(
        sessionId: env.fixture.sessionId, module: "similarity",
        keywordAdditions: [env.fixture.photoIds[0]: [keyword]])
    let result = try await env.service.execute(
        sessionId: env.fixture.sessionId, module: "similarity", items: preview.items)
    #expect(result.written == 1)
    _ = try env.fixture.db.prepare(
        "UPDATE sessions SET reload_acked_at = ? WHERE id = ?"
    ).run([.text(nowISOString()), .text(env.fixture.sessionId)])
    _ = try env.coordinator.confirm(
        sessionId: env.fixture.sessionId, module: .similarity)
}
