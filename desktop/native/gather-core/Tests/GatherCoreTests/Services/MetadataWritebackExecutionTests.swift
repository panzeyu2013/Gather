// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataWritebackExecutionTests.swift
// P1-9 回归：手动元数据队列必须有产线执行器。
//
// 覆盖（真实 WritebackService + 可编程 XMP 假件，不手工调用 execute）：
// 1. setMetadata 入队后立即 executePending：rating/label/keywords 立刻在"盘上"
//    （stub 的写后状态）、delivery_items 不再是 pending、confirm 可推进 synced；
// 2. 写盘失败：setMetadata 抛错且交付项未被丢弃（failed 可经 executePending 重试），
//    错误串可见；
// 3. 执行器被其它模块 written 阻断：setMetadata 抛错且 metadata item 保持 pending，
//    解除阻断后可重试落盘（字面意义上的"保留 pending 供 retry"）；
// 4. batchSet 3 张：只触发一次 flush（调用计数），3 个交付项一次写盘。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
@testable import GatherDelivery

// MARK: - 假件

/// 可编程 XMP 假件：写属性会更新"盘上"状态（按 photoPath 隔离），可注入写失败。
private struct StubWriteError: Error, CustomStringConvertible {
    var description: String { "STUB_XMP_WRITE_FAILED" }
}

private final class WritebackTestXMP: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: MetadataWriteAttributes] = [:]
    private var failWrites = false
    private var successfulWrites = 0

    func setFailWrites(_ value: Bool) { lock.withLock { failWrites = value } }

    func attributes(for photoPath: String) -> MetadataWriteAttributes {
        lock.withLock { stored[photoPath] ?? MetadataWriteAttributes() }
    }

    var writeCount: Int { lock.withLock { successfulWrites } }

    func readKeywords(photoPath: String) async throws -> [String] {
        lock.withLock { stored[photoPath]?.keywords ?? [] }
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        lock.withLock { stored[photoPath] ?? MetadataWriteAttributes() }
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        let shouldFail = lock.withLock { failWrites }
        if shouldFail { throw StubWriteError() }
        lock.withLock {
            stored[photoPath] = attributes
            successfulWrites += 1
        }
    }

    func backup(photoPath: String) async throws -> String { "" }

    func restore(photoPath: String, backupPath: String) async throws {}

    func fileExists(_ path: String) -> Bool { true }

    func removeFile(_ path: String) async throws {}
}

/// flush 调用计数（batchSet 的"只 flush 一次"用独立 oracle）。
private final class FlushCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ sessionId: String) { lock.withLock { recorded.append(sessionId) } }

    var calls: Int { lock.withLock { recorded.count } }
    var sessions: [String] { lock.withLock { recorded } }
}

// MARK: - 夹具

private struct WritebackFixture {
    let db: DBConnection
    let root: URL
    let sessionId: String
    let photoIds: [String]
    let photoPaths: [String]
    let xmpPath: String
    let xmp: WritebackTestXMP
    let deliveryRepo: DeliveryRepo
    let mutations: MetadataMutationService
    let writeback: WritebackService
    let flushCounter: FlushCounter
    let service: MetadataService

    init(photoCount: Int) throws {
        let db = try makeTestDB()
        let sessionId = "s-p19-\(UUID().uuidString)"
        try insertSession(db, sessionId)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-p19-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var ids: [String] = []
        var paths: [String] = []
        for index in 0..<photoCount {
            let photoId = "p-p19-\(index)-\(UUID().uuidString)"
            let path = root.appendingPathComponent("IMG_\(index).jpg").path
            try Data("photo-bytes".utf8).write(to: URL(fileURLWithPath: path))
            try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: path)
            ids.append(photoId)
            paths.append(path)
        }

        let xmp = WritebackTestXMP()
        let deliveryRepo = DeliveryRepo(connection: db)
        let assetResolver = PhotoAssetResolver(connection: db)
        let mutations = MetadataMutationService(
            deliveryRepo: deliveryRepo, xmp: xmp, assetResolver: assetResolver)
        let writeback = WritebackService(
            deliveryRepo: deliveryRepo,
            xmp: xmp,
            photoRepo: PhotoRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            connection: db,
            assetResolver: assetResolver
        )
        let counter = FlushCounter()
        // 与组合根同一条接线：宿主注入 executePending(sessionId, module: "metadata")。
        let service = MetadataService(
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            xmp: xmp,
            connection: db,
            mutations: mutations,
            flushPending: { sessionId in
                counter.record(sessionId)
                return try await writeback.executePending(
                    sessionId: sessionId, module: "metadata")
            },
            assetResolver: assetResolver
        )

        self.db = db
        self.root = root
        self.sessionId = sessionId
        self.photoIds = ids
        self.photoPaths = paths
        self.xmpPath = TSPath.normalize(TSPath.xmpSidecarPath(paths[0]))
        self.xmp = xmp
        self.deliveryRepo = deliveryRepo
        self.mutations = mutations
        self.writeback = writeback
        self.flushCounter = counter
        self.service = service
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        db.close()
    }

    func item(_ photoId: String, module: DeliveryModule = .metadata) throws -> DeliveryItemRow? {
        try deliveryRepo.listItems(sessionId: sessionId, module: module)
            .first { $0.photoId == photoId }
    }
}

// MARK: - 用例

@Suite("P1-9 手动元数据队列执行器")
struct MetadataWritebackExecutionTests {
    @Test("setMetadata 立即写盘：rating/label/keywords 落盘、item 不再 pending、confirm 推进")
    func setMetadataFlushesAndConfirmAdvances() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }

        let tags = MetadataTags(keywords: ["keep", "pick"], rating: 4, label: "Green")
        let merged = try await fixture.service.setMetadata(
            photoId: fixture.photoIds[0], tags: tags)

        #expect(merged.rating == 4)
        #expect(merged.label == "Green")
        #expect(merged.keywords == ["keep", "pick"])

        // 写盘执行器被调用一次，且"文件"（stub 的写后状态）立刻包含三项。
        #expect(fixture.flushCounter.calls == 1)
        let disk = fixture.xmp.attributes(for: fixture.photoPaths[0])
        #expect(disk.rating == 4)
        #expect(disk.label == "Green")
        #expect(disk.keywords == ["keep", "pick"])

        // 队列不再有 pending/failed；交付项已 written。
        let item = try #require(try fixture.item(fixture.photoIds[0]))
        #expect(item.typedStatus == .written)
        #expect(try fixture.deliveryRepo.listItems(
            sessionId: fixture.sessionId, module: .metadata, status: .pending).isEmpty)
        #expect(try fixture.deliveryRepo.listItems(
            sessionId: fixture.sessionId, module: .metadata, status: .failed).isEmpty)
        let delivery = try #require(try fixture.deliveryRepo.get(fixture.xmpPath))
        #expect(delivery.typedStatus == .written)

        // confirm 可推进：written → synced（无失败项阻断；先模拟 C1 已重载）。
        _ = try fixture.db.prepare(
            "UPDATE sessions SET reload_acked_at = '2026-01-01T00:00:00.000Z' WHERE id = ?"
        ).run([.text(fixture.sessionId)])
        try await fixture.writeback.confirmSync(sessionId: fixture.sessionId, module: "metadata")
        #expect(try fixture.deliveryRepo.get(fixture.xmpPath)?.typedStatus == .synced)
        #expect(try fixture.item(fixture.photoIds[0])?.typedStatus == .synced)
    }

    @Test("写盘失败：setMetadata 抛错、交付项保留可重试、错误可见")
    func writeFailureThrowsAndKeepsRetryableItem() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }
        fixture.xmp.setFailWrites(true)

        do {
            _ = try await fixture.service.setMetadata(
                photoId: fixture.photoIds[0], tags: MetadataTags(rating: 5))
            Issue.record("写盘失败时 setMetadata 必须抛错")
        } catch let error as MetadataServiceError {
            guard case .writebackFailed(let message) = error else {
                Issue.record("期望 writebackFailed，实际 \(error)")
                return
            }
            #expect(message.contains("STUB_XMP_WRITE_FAILED"))
        } catch {
            Issue.record("期望 MetadataServiceError，实际 \(error)")
        }

        // 入队没有被回滚：项落 failed（executePending 会再次加载 failed），错误可查。
        let item = try #require(try fixture.item(fixture.photoIds[0]))
        #expect(item.typedStatus == .failed)
        #expect(item.errorMessage.contains("STUB_XMP_WRITE_FAILED"))
        #expect(try fixture.deliveryRepo.get(fixture.xmpPath)?.typedStatus == .failed)
        #expect(fixture.xmp.attributes(for: fixture.photoPaths[0]).rating == nil)

        // 修复写盘后直接重试：同一 pending+failed 入口把值写进文件。
        fixture.xmp.setFailWrites(false)
        let retry = try await fixture.writeback.executePending(
            sessionId: fixture.sessionId, module: "metadata")
        #expect(retry.written == 1)
        #expect(retry.failed == 0)
        #expect(fixture.xmp.attributes(for: fixture.photoPaths[0]).rating == 5)
        #expect(try fixture.item(fixture.photoIds[0])?.typedStatus == .written)
    }

    @Test("执行器拒绝（其它模块 written）：抛错且 metadata item 保持 pending，解除后可重试")
    func executorRejectionKeepsPending() async throws {
        let fixture = try WritebackFixture(photoCount: 1)
        defer { fixture.cleanup() }

        // 同一侧车上的 similarity 项已 written → assertNoActiveOtherModule 拒绝 metadata。
        _ = try fixture.deliveryRepo.createOrGet(
            xmpPath: fixture.xmpPath, photoPath: fixture.photoPaths[0])
        let blocker = try fixture.deliveryRepo.upsertItem(
            xmpPath: fixture.xmpPath,
            photoId: fixture.photoIds[0],
            module: .similarity,
            keywords: ["face"],
            status: .pending
        )
        _ = try fixture.deliveryRepo.markItem(itemId: blocker.id, status: .written)

        do {
            _ = try await fixture.service.setMetadata(
                photoId: fixture.photoIds[0], tags: MetadataTags(rating: 3))
            Issue.record("执行器拒绝时 setMetadata 必须抛错")
        } catch let error as MetadataServiceError {
            guard case .writebackFailed(let message) = error else {
                Issue.record("期望 writebackFailed，实际 \(error)")
                return
            }
            #expect(message.contains("WRITEBACK_OTHER_MODULE_ACTIVE"))
        } catch {
            Issue.record("期望 MetadataServiceError，实际 \(error)")
        }

        // 字面意义上的"保留 pending 供 retry"：项仍在 pending，未被消费/丢弃。
        #expect(try fixture.item(fixture.photoIds[0])?.typedStatus == .pending)
        #expect(try fixture.deliveryRepo.get(fixture.xmpPath)?.typedStatus == .pending)
        #expect(fixture.xmp.attributes(for: fixture.photoPaths[0]).rating == nil)

        // 解除阻断后重试：同一条 pending 项落盘。
        _ = try fixture.deliveryRepo.deleteItems(
            xmpPath: fixture.xmpPath, module: .similarity, statuses: [.written])
        let retry = try await fixture.writeback.executePending(
            sessionId: fixture.sessionId, module: "metadata")
        #expect(retry.written == 1)
        #expect(fixture.xmp.attributes(for: fixture.photoPaths[0]).rating == 3)
        #expect(try fixture.item(fixture.photoIds[0])?.typedStatus == .written)
    }

    @Test("batchSet 3 张：只 flush 一次，3 个交付项一次写盘")
    func batchSetFlushesOnce() async throws {
        let fixture = try WritebackFixture(photoCount: 3)
        defer { fixture.cleanup() }

        let updates = fixture.photoIds.map {
            (photoId: $0, tags: MetadataTags(rating: 3, label: "Red"))
        }
        let result = try await fixture.service.batchSet(updates: updates)

        #expect(result.success == 3)
        #expect(result.failed == 0)
        #expect(result.errors.isEmpty)
        // 每张都 flush 会得到 3；整批只允许 1 次（同会话去重）。
        #expect(fixture.flushCounter.calls == 1)
        #expect(fixture.flushCounter.sessions == [fixture.sessionId])
        #expect(fixture.xmp.writeCount == 3)

        for (index, photoId) in fixture.photoIds.enumerated() {
            let disk = fixture.xmp.attributes(for: fixture.photoPaths[index])
            #expect(disk.rating == 3)
            #expect(disk.label == "Red")
            #expect(try fixture.item(photoId)?.typedStatus == .written)
        }
        #expect(try fixture.deliveryRepo.listItems(
            sessionId: fixture.sessionId, module: .metadata, status: .pending).isEmpty)
        #expect(try fixture.deliveryRepo.listItems(
            sessionId: fixture.sessionId, module: .metadata).count == 3)
    }
}
