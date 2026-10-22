// desktop/native/gather-core/Tests/GatherCoreTests/Services/DeliveryFaceSimilarityMirrorTests.swift
// Cut 2 / S5c-2b-2：FaceKw / Similarity 的 writeback 镜像与 confirm/cleanup 接线门禁。
//
// 覆盖面：
// 1. DeliveryModule 映射：旧写回模块名（face_kw / similarity）→ SchemaV1 真实值，
//    非法值返回 nil（不新增模块 case）。
// 2. 两域 writeback → deliveries / delivery_items / delivery_sessions：
//    written 与 failed 两种结果，module 固定 face-keyword / similarity，
//    revision/base/backup 与 Culling（S5c-2b-1）同一规则。
// 3. confirm 跨会话：先确认的会话落 confirmed_at、抛 OTHER_SESSION_PENDING，
//    对方确认后交付才翻 synced。
// 4. cleanup：外部修改标 conflict 并按路径回填 XMP_EXTERNALLY_MODIFIED；
//    文件阶段失败保留 intent，下一次 cleanup 先 replay 重试成功。
//
// 建库口径：makeTestDB()（SchemaV1 + Transition）——S5c-2b-3b-2b-1 起镜像的
// 状态读 delivery_items、base/backup 回读 deliveries，不再依赖旧 outbox/writeback 表。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
@testable import GatherDelivery

// MARK: - fixtures

private func addMirrorSession(_ db: DBConnection, _ id: String, acked: Bool = true) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, reload_acked_at, created_at, updated_at)
        VALUES (?, '', 'draft', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(id), .text(acked ? "2026-01-01T00:00:00.000Z" : "")])
}

private final class MirrorFingerprint: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String = "fp-current") { self.value = value }

    var current: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// 内存 XMP 假件：restore 覆盖写（幂等），remove 只删内存键；可注入失败。
private final class MirrorFilePort: DeliveryFilePort, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]
    private var restoredTargets: [String] = []
    private var restoreFailure: Error?
    private var removeFailure: Error?

    init(storage: [String: String] = [:]) { self.storage = storage }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func setContents(_ path: String, _ value: String) { locked { storage[path] = value } }
    func contents(_ path: String) -> String? { locked { storage[path] } }
    func setRestoreFailure(_ error: Error?) { locked { restoreFailure = error } }
    func setRemoveFailure(_ error: Error?) { locked { removeFailure = error } }

    var restoreTargets: [String] { locked { restoredTargets } }

    func fileExists(_ path: String) -> Bool { locked { storage[path] != nil } }

    func restore(photoPath: String, backupPath: String) async throws {
        let target = TSPath.xmpSidecarPath(photoPath)
        try locked {
            restoredTargets.append(target)
            if let restoreFailure { throw restoreFailure }
            guard let backup = storage[backupPath] else {
                throw DeliveryCoordinatorError.backupMissing(xmpPath: backupPath)
            }
            storage[target] = backup
        }
    }

    func removeFile(_ path: String) async throws {
        try locked {
            if let removeFailure { throw removeFailure }
            storage.removeValue(forKey: path)
        }
    }
}

private final class MirrorFaceWriteback: FaceWritebackProvider, @unchecked Sendable {
    var executeResult = FaceKwWritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0,
        errors: [], failedItems: [], report: ""
    )
    var executeError: Error?
    private(set) var executedItems: [FaceKwWritebackItem] = []

    func removeOwnedFaceKeywords(sessionId: String, entries: [FaceKeywordEntry]) async throws -> [String] {
        []
    }

    func preview(
        sessionId: String,
        options: FaceKwWritebackOptions?,
        boundPhotoIds: Set<String>,
        additions: [String: [String]]
    ) async throws -> FaceKwWritebackPreview {
        FaceKwWritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    }

    func execute(sessionId: String, items: [FaceKwWritebackItem]) async throws -> FaceKwWritebackResult {
        executedItems = items
        if let executeError { throw executeError }
        return executeResult
    }

    func confirmSync(sessionId: String) async throws {}

    func cleanup(sessionId: String) async throws -> FaceKwCleanupResult {
        FaceKwCleanupResult(deletedCount: 0, errors: [])
    }
}

private final class MirrorSimilarityWriteback: SimilarityWritebackProvider, @unchecked Sendable {
    var executeResult = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0,
        errors: [], failedItems: [], report: ""
    )
    var retryResult = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0,
        errors: [], failedItems: [], report: ""
    )
    var retryHook: (() throws -> Void)?
    private(set) var executedItems: [WritebackItem] = []
    private(set) var retryCalls = 0
    private(set) var previewCalls = 0
    private(set) var persistCalls = 0

    func preview(sessionId: String) async throws -> WritebackPreview {
        previewCalls += 1
        return WritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    }

    func persistKeywords(items: [WritebackItem]) throws {
        persistCalls += 1
    }

    func getItems(sessionId: String, status: String?) throws -> [WritebackItem] {
        []
    }

    func execute(sessionId: String, items: [WritebackItem]) async throws -> WritebackResult {
        executedItems = items
        return executeResult
    }

    func retryFailed(sessionId: String) async throws -> WritebackResult {
        retryCalls += 1
        try retryHook?()
        return retryResult
    }
}

private struct MirrorHarness {
    let db: DBConnection
    let sessionId: String
    let faceService: FaceKwService
    let similarityService: SimilarityService
    let coordinator: DeliveryCoordinator
    let deliveryRepo: DeliveryRepo
    let intentRepo: DeliveryIntentRepo
    let files: MirrorFilePort
    let fingerprint: MirrorFingerprint
    let faceWriteback: MirrorFaceWriteback
    let similarityWriteback: MirrorSimilarityWriteback

    init() throws {
        let db = try makeTestDB()
        try addMirrorSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/shoot/p1.jpg")
        let sessionRepo = SessionRepo(connection: db)
        let deliveryRepo = DeliveryRepo(connection: db)
        let intentRepo = DeliveryIntentRepo(connection: db)
        let files = MirrorFilePort()
        let fingerprint = MirrorFingerprint()
        let coordinator = DeliveryCoordinator(
            connection: db,
            deliveryRepo: deliveryRepo,
            intentRepo: intentRepo,
            files: files,
            fingerprint: { [fingerprint] _ in fingerprint.current },
            resolvePhotoPath: { _, delivery in delivery.photoPath }
        )
        let faceWriteback = MirrorFaceWriteback()
        let similarityWriteback = MirrorSimilarityWriteback()
        let faceService = FaceKwService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: sessionRepo,
            faceRepo: FaceRepo(connection: db),
            personRepo: PersonRepo(connection: db),
            connection: db,
            writebackProvider: faceWriteback,
            delivery: coordinator.adapter(for: .faceKeyword)
        )
        let similarityService = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: sessionRepo,
            similarityResultRepo: SimilarityResultRepo(connection: db),
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            connection: db,
            writebackProvider: similarityWriteback,
            delivery: coordinator.adapter(for: .similarity)
        )
        self.db = db
        self.sessionId = "s1"
        self.faceService = faceService
        self.similarityService = similarityService
        self.coordinator = coordinator
        self.deliveryRepo = deliveryRepo
        self.intentRepo = intentRepo
        self.files = files
        self.fingerprint = fingerprint
        self.faceWriteback = faceWriteback
        self.similarityWriteback = similarityWriteback
    }
}

/// 交付行上的写回基线（S5c-2b-3b-2a 起镜像只回读 deliveries，不再抄 outbox）：
/// 模拟执行器已把 base_fingerprint/base_values/backup_path 直接落库。
private func seedMirrorOutbox(
    _ db: DBConnection,
    xmpPath: String,
    sessionId: String = "s1",
    photoPath: String,
    backupPath: String = "",
    fingerprint: String = "fp-current",
    values: JSONValue = .object(["rating": .number(3)])
) throws {
    _ = sessionId
    let repo = DeliveryRepo(connection: db)
    _ = try repo.createOrGet(xmpPath: xmpPath, photoPath: photoPath)
    _ = try repo.markWriting(xmpPath: xmpPath, revision: 0)
    _ = try repo.markWritten(
        xmpPath: xmpPath,
        revision: 0,
        baseFingerprint: fingerprint,
        baseValues: values,
        backupPath: backupPath
    )
}

private func faceMirrorItem(
    id: Int64?,
    photoId: String = "p1",
    photoPath: String = "/shoot/p1.jpg",
    xmpPath: String = "/shoot/p1.xmp",
    keywords: [String] = ["Alice"],
    attributes: FaceKwWritebackAttributes? = nil,
    status: String = "written",
    errorMessage: String = ""
) -> FaceKwWritebackItem {
    FaceKwWritebackItem(
        id: id,
        photoId: photoId,
        photoPath: photoPath,
        sessionId: "s1",
        module: "face_kw",
        keywords: keywords,
        attributes: attributes,
        xmpPath: xmpPath,
        backupPath: "",
        xmpStatus: status,
        errorMessage: errorMessage,
        attemptCount: 0,
        lastAttemptAt: ""
    )
}

private func similarityMirrorItem(
    id: Int?,
    photoId: String = "p1",
    photoPath: String = "/shoot/p1.jpg",
    xmpPath: String = "/shoot/p1.xmp",
    keywords: [String] = ["Group A"],
    attributes: WritebackAttributes? = nil,
    status: String = "written",
    errorMessage: String = ""
) -> WritebackItem {
    WritebackItem(
        id: id,
        photoId: photoId,
        photoPath: photoPath,
        sessionId: "s1",
        module: "similarity",
        keywords: keywords,
        attributes: attributes,
        xmpPath: xmpPath,
        backupPath: "",
        xmpStatus: status,
        errorMessage: errorMessage,
        attemptCount: 0,
        lastAttemptAt: ""
    )
}

private func writtenFaceResult(_ items: [FaceKwWritebackItem]) -> FaceKwWritebackResult {
    FaceKwWritebackResult(
        totalAffected: items.count, written: items.count, failed: 0, skipped: 0,
        errors: [], failedItems: [], report: "ok"
    )
}

private func writtenSimilarityResult(_ items: [WritebackItem]) -> WritebackResult {
    WritebackResult(
        totalAffected: items.count, written: items.count, failed: 0, skipped: 0,
        errors: [], failedItems: [], report: "ok"
    )
}

/// 建一条已确认（synced）交付：镜像 written → coordinator.confirm。
private func seedSyncedDelivery(
    _ harness: MirrorHarness,
    module: DeliveryModule,
    xmpPath: String = "/shoot/p1.xmp",
    photoId: String = "p1",
    backupPath: String = ""
) throws {
    try seedMirrorOutbox(
        harness.db, xmpPath: xmpPath, photoPath: "/shoot/p1.jpg",
        backupPath: backupPath
    )
    _ = try harness.coordinator.mirrorWriteback(
        sessionId: "s1",
        module: module,
        items: [DeliveryWritebackMirrorItem(
            photoId: photoId,
            photoPath: "/shoot/p1.jpg",
            xmpPath: xmpPath,
            keywords: module == .similarity ? ["Group A"] : ["Alice"],
            status: .written,
            backupPath: backupPath,
            baseFingerprint: "fp-current",
            baseValues: .object(["rating": .number(3)])
        )]
    )
    _ = try harness.coordinator.confirm(sessionId: "s1", module: module)
}

// MARK: - 模块映射

@Suite("DeliveryModule 旧写回名映射（S5c-2b-2）")
struct DeliveryModuleMappingTests {
    @Test("face_kw / face-keyword / similarity 映射到 SchemaV1 的真实值")
    func mapsLegacyNamesToSchemaValues() {
        #expect(DeliveryModule(writebackModule: "face_kw") == .faceKeyword)
        #expect(DeliveryModule(writebackModule: "face-keyword") == .faceKeyword)
        #expect(DeliveryModule(writebackModule: "similarity") == .similarity)
        #expect(DeliveryModule(writebackModule: "culling") == .culling)
        #expect(DeliveryModule(writebackModule: "template") == .template)
        #expect(DeliveryModule(writebackModule: "metadata") == .metadata)

        // 落库值只允许 CHECK 列出的 5 个值。
        #expect(DeliveryModule.faceKeyword.rawValue == "face-keyword")
        #expect(DeliveryModule.similarity.rawValue == "similarity")
        #expect(Set(DeliveryModule.allCases.map(\.rawValue))
            == ["culling", "face-keyword", "similarity", "template", "metadata"])

        // 反向映射与未知值。
        #expect(DeliveryModule.faceKeyword.writebackModuleName == "face_kw")
        #expect(DeliveryModule(writebackModule: DeliveryModule.faceKeyword.writebackModuleName) == .faceKeyword)
        #expect(DeliveryModule(writebackModule: "manual") == nil)
        #expect(DeliveryModule(writebackModule: "") == nil)
    }
}

// MARK: - 两域 writeback 镜像

@Suite("FaceKw/Similarity writeback → deliveries（S5c-2b-2）")
struct DeliveryWritebackMirrorDomainTests {
    @Test("face writeback 镜像：delivery written + item/模块 + revision/base/backup")
    func faceWritebackMirrorsWrittenItems() async throws {
        let harness = try MirrorHarness()
        defer { harness.db.close() }
        try seedMirrorOutbox(
            harness.db, xmpPath: "/shoot/p1.xmp", photoPath: "/shoot/p1.jpg",
            backupPath: "/backup/p1.xmp", fingerprint: "fp-face"
        )
        let item = faceMirrorItem(
            id: 11,
            attributes: FaceKwWritebackAttributes(keywords: ["Alice"])
        )
        harness.faceWriteback.executeResult = writtenFaceResult([item])

        let result = try await harness.faceService.writeback(
            sessionId: "s1", confirmed: true, items: [item]
        )

        #expect(result.errors.isEmpty)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.written.rawValue)
        // 镜像对新输入重开交付（revision + 1）后再落 written。
        #expect(row.revision == 1)
        #expect(row.baseFingerprint == "fp-face")
        #expect(row.backupPath == "/backup/p1.xmp")
        #expect(row.photoPath == "/shoot/p1.jpg")
        #expect(row.baseValues.objectValue?["rating"]?.numberValue == 3)

        let items = try harness.deliveryRepo.listItems(sessionId: "s1", module: .faceKeyword)
        #expect(items.count == 1)
        #expect(items[0].photoId == "p1")
        #expect(items[0].module == "face-keyword")
        #expect(items[0].status == DeliveryItemStatus.written.rawValue)
        #expect(items[0].keywordList == ["Alice"])

        let links = try harness.db.prepare(
            "SELECT session_id FROM delivery_sessions WHERE delivery_id = ?"
        ).query([.int(row.id)])
        #expect(links.compactMap { $0[0].textValue } == ["s1"])
    }

    @Test("face writeback failed：delivery failed + item.errorMessage 镜像")
    func faceWritebackMirrorsFailedItems() async throws {
        let harness = try MirrorHarness()
        defer { harness.db.close() }
        let failed = faceMirrorItem(id: 12, status: "failed", errorMessage: "boom")
        harness.faceWriteback.executeResult = FaceKwWritebackResult(
            totalAffected: 1, written: 0, failed: 1, skipped: 0,
            errors: ["/shoot/p1.jpg: boom"], failedItems: [failed], report: ""
        )

        let result = try await harness.faceService.writeback(
            sessionId: "s1", confirmed: true, items: [failed]
        )

        #expect(result.failed == 1)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.failed.rawValue)
        let items = try harness.deliveryRepo.listItems(sessionId: "s1", module: .faceKeyword)
        #expect(items.count == 1)
        #expect(items[0].status == DeliveryItemStatus.failed.rawValue)
        #expect(items[0].errorMessage == "boom")
    }

    @Test("similarity writeback 镜像：module=similarity + attributes/keywords")
    func similarityWritebackMirrorsWrittenItems() async throws {
        let harness = try MirrorHarness()
        defer { harness.db.close() }
        try seedMirrorOutbox(
            harness.db, xmpPath: "/shoot/p1.xmp", photoPath: "/shoot/p1.jpg",
            backupPath: "/backup/p1.xmp", fingerprint: "fp-sim"
        )
        let item = similarityMirrorItem(
            id: 21,
            attributes: WritebackAttributes(keywords: ["Group A"], rating: 4)
        )
        harness.similarityWriteback.executeResult = writtenSimilarityResult([item])

        let result = try await harness.similarityService.writeback(
            sessionId: "s1", items: [item]
        )

        #expect(result.errors.isEmpty)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.written.rawValue)
        // 镜像对新输入重开交付（revision + 1）后再落 written。
        #expect(row.revision == 1)
        #expect(row.baseFingerprint == "fp-sim")
        #expect(row.backupPath == "/backup/p1.xmp")
        let items = try harness.deliveryRepo.listItems(sessionId: "s1", module: .similarity)
        #expect(items.count == 1)
        #expect(items[0].module == "similarity")
        #expect(items[0].status == DeliveryItemStatus.written.rawValue)
        #expect(items[0].keywordList == ["Group A"])
    }

    @Test("similarity writeback failed：delivery/item 均 failed")
    func similarityWritebackMirrorsFailedItems() async throws {
        let harness = try MirrorHarness()
        defer { harness.db.close() }
        let failed = similarityMirrorItem(id: 22, status: "failed", errorMessage: "sim-boom")
        harness.similarityWriteback.executeResult = WritebackResult(
            totalAffected: 1, written: 0, failed: 1, skipped: 0,
            errors: [], failedItems: [failed], report: ""
        )

        let result = try await harness.similarityService.writeback(
            sessionId: "s1", items: [failed]
        )

        #expect(result.failed == 1)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.failed.rawValue)
        let items = try harness.deliveryRepo.listItems(sessionId: "s1", module: .similarity)
        #expect(items.count == 1)
        #expect(items[0].status == DeliveryItemStatus.failed.rawValue)
        #expect(items[0].errorMessage == "sim-boom")
    }

    @Test("similarity retry 镜像：只推进本次重试的 failed 项")
    func similarityRetryMirrorsOnlyRetriedItems() async throws {
        let harness = try MirrorHarness()
        defer { harness.db.close() }
        // 失败项直接种进统一交付模型（S5c-2b-3b-2b-1：旧 writeback_items 不再参与）。
        let repo = harness.deliveryRepo
        _ = try repo.createOrGet(xmpPath: "/shoot/p1.xmp", photoPath: "/shoot/p1.jpg")
        _ = try repo.markWriting(xmpPath: "/shoot/p1.xmp", revision: 0)
        _ = try repo.markFailed(
            xmpPath: "/shoot/p1.xmp", revision: 0, errorMessage: "boom"
        )
        let saved = try repo.upsertItem(
            xmpPath: "/shoot/p1.xmp", photoId: "p1", module: .similarity,
            keywords: ["Group A"], status: .failed, errorMessage: "boom"
        )
        _ = try repo.linkSession(xmpPath: "/shoot/p1.xmp", sessionId: "s1")

        harness.similarityWriteback.retryResult = writtenSimilarityResult([])
        harness.similarityWriteback.retryHook = {
            _ = try repo.markItem(itemId: saved.id, status: .written)
        }

        let result = try await harness.similarityService.retryFailedWriteback(sessionId: "s1")

        #expect(harness.similarityWriteback.retryCalls == 1)
        #expect(result.errors.isEmpty)
        let delivery = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(delivery.status == DeliveryStatus.written.rawValue)
        let items = try harness.deliveryRepo.listItems(sessionId: "s1", module: .similarity)
        #expect(items.count == 1)
        #expect(items[0].status == DeliveryItemStatus.written.rawValue)
    }
}

// MARK: - confirm 跨会话 / 门禁

@Suite("FaceKw/Similarity confirm 跨会话（S5c-2b-2）")
struct DeliveryConfirmDomainTests {
    private func makeCrossSessionHarness() throws -> MirrorHarness {
        let harness = try MirrorHarness()
        try addMirrorSession(harness.db, "s2")
        try insertPhoto(harness.db, id: "p2", sessionId: "s2", filepath: "/shoot/shared.jpg")
        return harness
    }

    private func seedSharedDelivery(_ harness: MirrorHarness, module: DeliveryModule) throws {
        _ = try harness.coordinator.mirrorWriteback(
            sessionId: "s1",
            module: module,
            items: [
                DeliveryWritebackMirrorItem(
                    photoId: "p1", photoPath: "/shoot/shared.jpg",
                    xmpPath: "/shoot/shared.xmp",
                    keywords: module == .similarity ? ["Group A"] : ["Alice"],
                    status: .written
                ),
                DeliveryWritebackMirrorItem(
                    photoId: "p2", photoPath: "/shoot/shared.jpg",
                    xmpPath: "/shoot/shared.xmp",
                    keywords: [],
                    status: .written
                ),
            ]
        )
        _ = try harness.deliveryRepo.linkSession(xmpPath: "/shoot/shared.xmp", sessionId: "s2")
    }

    @Test("face confirm：先确认一方抛 OTHER_SESSION_PENDING，对方确认后 synced")
    func faceConfirmCrossSession() async throws {
        let harness = try makeCrossSessionHarness()
        defer { harness.db.close() }
        try seedSharedDelivery(harness, module: .faceKeyword)

        await #expect(throws: DeliveryError.otherSessionNotConfirmed(sessionId: "s2")) {
            _ = try await harness.faceService.confirmSync(sessionId: "s1")
        }
        let written = try #require(try harness.deliveryRepo.get("/shoot/shared.xmp"))
        #expect(written.status == DeliveryStatus.written.rawValue)
        let confirmedAt = try harness.db.prepare(
            "SELECT confirmed_at FROM delivery_sessions WHERE session_id = 's1'"
        ).get([])
        #expect((confirmedAt?[0].textValue ?? "").isEmpty == false)

        _ = try await harness.faceService.confirmSync(sessionId: "s2")
        let synced = try #require(try harness.deliveryRepo.get("/shoot/shared.xmp"))
        #expect(synced.status == DeliveryStatus.synced.rawValue)
    }

    @Test("similarity confirm：同样的跨会话门禁与旧码")
    func similarityConfirmCrossSession() async throws {
        let harness = try makeCrossSessionHarness()
        defer { harness.db.close() }
        try seedSharedDelivery(harness, module: .similarity)

        await #expect(throws: DeliveryError.otherSessionNotConfirmed(sessionId: "s2")) {
            _ = try await harness.similarityService.confirmSync(sessionId: "s1")
        }
        _ = try await harness.similarityService.confirmSync(sessionId: "s2")
        let synced = try #require(try harness.deliveryRepo.get("/shoot/shared.xmp"))
        #expect(synced.status == DeliveryStatus.synced.rawValue)
    }

    @Test("未 ack reload：confirm 抛 XMP_CONFIRM_REQUIRES_SYNC（两域同码）")
    func confirmRequiresReloadAck() async throws {
        let harness = try MirrorHarness()
        defer { harness.db.close() }
        _ = try harness.db.prepare("UPDATE sessions SET reload_acked_at = NULL WHERE id = 's1'").run([])

        await #expect(throws: DeliveryError.confirmRequiresSync) {
            _ = try await harness.faceService.confirmSync(sessionId: "s1")
        }
        await #expect(throws: DeliveryError.confirmRequiresSync) {
            _ = try await harness.similarityService.confirmSync(sessionId: "s1")
        }
    }
}

// MARK: - cleanup 冲突 / 失败重试

@Suite("FaceKw/Similarity cleanup 冲突与重试（S5c-2b-2）")
struct DeliveryCleanupDomainTests {
    @Test("face cleanup：外部修改标 conflict + 回填 XMP_EXTERNALLY_MODIFIED，不删行")
    func faceCleanupReportsExternalConflict() async throws {
        let harness = try MirrorHarness()
        defer { harness.db.close() }
        try seedSyncedDelivery(harness, module: .faceKeyword, backupPath: "/backup/p1.xmp")
        harness.fingerprint.current = "fp-edited"

        let result = try await harness.faceService.cleanup(sessionId: "s1", confirmed: true)

        #expect(result.deletedCount == 0)
        #expect(result.errors.contains { $0.contains("XMP_EXTERNALLY_MODIFIED") })
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.conflict.rawValue)
        #expect(try harness.deliveryRepo.listItems(sessionId: "s1", module: .faceKeyword).count == 1)
        #expect(harness.files.restoreTargets.isEmpty)
    }

    @Test("similarity cleanup：外部修改同样标 conflict")
    func similarityCleanupReportsExternalConflict() async throws {
        let harness = try MirrorHarness()
        defer { harness.db.close() }
        try seedSyncedDelivery(harness, module: .similarity, backupPath: "/backup/p1.xmp")
        harness.fingerprint.current = "fp-edited"

        let result = try await harness.similarityService.cleanup(sessionId: "s1")

        #expect(result.deletedCount == 0)
        #expect(result.errors.contains { $0.contains("XMP_EXTERNALLY_MODIFIED") })
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.conflict.rawValue)
    }

    @Test("face cleanup 失败保留 intent；下一次 cleanup 先 replay 重试成功")
    func faceCleanupRetriesAfterFileFailure() async throws {
        let harness = try MirrorHarness()
        defer { harness.db.close() }
        try seedSyncedDelivery(harness, module: .faceKeyword, backupPath: "/backup/p1.xmp")
        harness.files.setContents("/backup/p1.xmp", "original")
        harness.files.setRestoreFailure(MirrorFileError.injected)

        let failed = try await harness.faceService.cleanup(sessionId: "s1", confirmed: true)
        #expect(failed.errors.contains { $0.contains("XMP_CLEANUP_FILE_FAILED") })
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.synced.rawValue)
        #expect(try harness.intentRepo.pending().prepared.count == 1)

        harness.files.setRestoreFailure(nil)
        let retried = try await harness.faceService.cleanup(sessionId: "s1", confirmed: true)

        #expect(retried.errors.isEmpty)
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        #expect(try harness.intentRepo.pending().all.isEmpty)
        // 第一次 restore 失败后 intent 保留；replay 对同一目标重试一次（restore 幂等）。
        #expect(harness.files.restoreTargets == ["/shoot/p1.xmp", "/shoot/p1.xmp"])
        #expect(harness.files.contents("/shoot/p1.xmp") == "original")
    }

    @Test("similarity cleanup 失败保留 intent；下一次 cleanup 先 replay 重试成功")
    func similarityCleanupRetriesAfterFileFailure() async throws {
        let harness = try MirrorHarness()
        defer { harness.db.close() }
        try seedSyncedDelivery(harness, module: .similarity, backupPath: "/backup/p1.xmp")
        harness.files.setContents("/backup/p1.xmp", "original")
        harness.files.setRestoreFailure(MirrorFileError.injected)

        let failed = try await harness.similarityService.cleanup(sessionId: "s1")
        #expect(failed.errors.contains { $0.contains("XMP_CLEANUP_FILE_FAILED") })
        #expect(try harness.intentRepo.pending().prepared.count == 1)

        harness.files.setRestoreFailure(nil)
        let retried = try await harness.similarityService.cleanup(sessionId: "s1")

        #expect(retried.errors.isEmpty)
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        #expect(harness.files.contents("/shoot/p1.xmp") == "original")
    }
}

private enum MirrorFileError: Error, Equatable {
    case injected
}
