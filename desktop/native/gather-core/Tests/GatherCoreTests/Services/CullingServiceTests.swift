// desktop/native/gather-core/Tests/GatherCoreTests/Services/CullingServiceTests.swift
// CullingService 行为测试（3.4 Culling 模块，最大服务）。
// TS 源: tests/unit/services/culling/*（culling-service.test.ts / culling-page.test.ts /
// culling-asset-page.test.ts / culling-history-repository.test.ts，用例逐一对应）。
//
// 差异说明：
// - TS 用 vi.fn 替身注入（photos/decisions/similarity/cache/outbox/db）；Swift 侧
//   用真实临时 SQLite（:memory: + 迁移）+ fake 端口（mutation/writeback 记录调用），
//   XMP 从不触碰；同步态只读交付模型（旧 outbox 不再参与）。
// - 行为断言与 TS 逐条对应：decide 语义、批量合并、summary 计数、历史栈
//   undo/redo、apply_history、reset、写回协作（fake provider 记录调用）。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
@testable import GatherDelivery

// MARK: - Fake 端口

/// TS: MetadataMutationService 替身（queuePhotoValues 记录调用）。
/// S5c-2b-3b-2b-1 起 CullingService 不再读旧 outbox，替身也不再写库。
private final class FakeMutationPort: MetadataMutationPort, @unchecked Sendable {
    var queued: [(sessionId: String, photoId: String, values: [String: JSONValue], source: MetadataMutationSource, schedule: Bool)] = []

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        queued.append((sessionId, photoId, values, source, schedule))
        return MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending"
        )
    }

}

/// TS: WritebackService 替身（preview/persistAttributes/execute/retryFailed/
/// getItems/confirmSync/cleanup 全部记录调用，行为由测试注入）。
private final class FakeWritebackPort: CullingWritebackPort {
    var previewCalls: [(sessionId: String, module: String, photoIds: Set<String>?)] = []
    var persistCalls: [[WritebackItem]] = []
    var executeCalls: [(sessionId: String, module: String, items: [WritebackItem])] = []
    var retryFailedCalls: [(sessionId: String, module: String)] = []
    var getItemsCalls: [(sessionId: String, module: String)] = []
    var confirmSyncCalls: [(sessionId: String, module: String)] = []
    var cleanupCalls: [(sessionId: String, module: String)] = []
    var previewItems: [WritebackItem] = []
    var executeResult = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [],
        report: "Written: 0, Failed: 0, Skipped: 0"
    )
    var cleanupResult = CleanupResult(deletedCount: 0, errors: [])
    var getItemsResult: [WritebackItem] = []
    /// 按 status 参数返回不同行（retry 的「重试前 failed / 重试后 written」用例）。
    var getItemsHandler: ((_ status: String?) throws -> [WritebackItem])?

    func preview(
        sessionId: String,
        module: String,
        options: WritebackOptions,
        photoIds: Set<String>?,
        keywordAdditions: [String: [String]]?
    ) async throws -> WritebackPreview {
        previewCalls.append((sessionId, module, photoIds))
        return WritebackPreview(items: previewItems, totalCount: previewItems.count, affectedPhotos: previewItems.count)
    }

    func persistAttributes(items: [WritebackItem]) throws {
        persistCalls.append(items)
    }

    func execute(sessionId: String, module: String, items: [WritebackItem]) async throws -> WritebackResult {
        executeCalls.append((sessionId, module, items))
        return executeResult
    }

    func retryFailed(sessionId: String, module: String) async throws -> WritebackResult {
        retryFailedCalls.append((sessionId, module))
        return executeResult
    }

    func getItems(sessionId: String, module: String, status: String?) throws -> [WritebackItem] {
        getItemsCalls.append((sessionId, module))
        if let getItemsHandler { return try getItemsHandler(status) }
        return getItemsResult
    }

    func confirmSync(sessionId: String, module: String) async throws {
        confirmSyncCalls.append((sessionId, module))
    }

    func cleanup(sessionId: String, module: String) async throws -> CleanupResult {
        cleanupCalls.append((sessionId, module))
        return cleanupResult
    }
}

// MARK: - 交付端口替身（S5c-2a）

/// 内存侧车假件：restore 是覆盖写（幂等），removeFile 只删内存键；
/// 可注入 restore 失败验证「失败保留 intent、replay 可重试」。
private final class FakeDeliveryFiles: DeliveryFilePort, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]
    private var restoreFailure: Error?
    private var removeFailure: Error?
    private(set) var restoreTargets: [String] = []
    private(set) var removedPaths: [String] = []

    init(storage: [String: String] = [:]) {
        self.storage = storage
    }

    func setContents(_ path: String, _ value: String) { lock.withLock { storage[path] = value } }

    func contents(_ path: String) -> String? { lock.withLock { storage[path] } }

    func setRestoreFailure(_ error: Error?) { lock.withLock { restoreFailure = error } }

    func clearRestoreFailure() { lock.withLock { restoreFailure = nil } }

    func setRemoveFailure(_ error: Error?) { lock.withLock { removeFailure = error } }

    func clearRemoveFailure() { lock.withLock { removeFailure = nil } }

    func fileExists(_ path: String) -> Bool { lock.withLock { storage[path] != nil } }

    func restore(photoPath: String, backupPath: String) async throws {
        try lock.withLock {
            restoreTargets.append(TSPath.xmpSidecarPath(photoPath))
            if let restoreFailure { throw restoreFailure }
            guard let backup = storage[backupPath] else {
                throw DeliveryCoordinatorError.backupMissing(xmpPath: backupPath)
            }
            storage[TSPath.xmpSidecarPath(photoPath)] = backup
        }
    }

    func removeFile(_ path: String) async throws {
        try lock.withLock {
            if let removeFailure { throw removeFailure }
            removedPaths.append(path)
            storage.removeValue(forKey: path)
        }
    }
}

private enum FakeDeliveryFileError: Error, Equatable {
    case restoreFailed
    case removeFailed
}

/// 可变内容指纹（cleanup 的外部修改判定）。测试串行执行，只需锁内读写。
private final class FakeFingerprint: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String = "fp-current") { self.value = value }

    var current: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

// MARK: - 夹具

/// 会话 + 服务（真实 SQLite + 迁移；fake 端口注入，零 XMP/文件系统依赖）。
private struct CullingHarness {
    let db: DBConnection
    let sessionId: String
    let service: CullingService
    let photoRepo: PhotoRepo
    let decisionRepo: CullingDecisionRepo
    let similarityRepo: SimilarityResultRepo
    let cacheRepo: MetadataCacheRepo
    let historyRepo: CullingHistoryRepo
    let mutations: FakeMutationPort
    let writeback: FakeWritebackPort
    let deliveryFiles: FakeDeliveryFiles
    let deliveryFingerprint: FakeFingerprint
    let deliveryRepo: DeliveryRepo
    let deliveryIntents: DeliveryIntentRepo
    let deliveryCoordinator: DeliveryCoordinator

    func decision(_ photoId: String) throws -> CullingDecisionRow? {
        try decisionRepo.getDecision(sessionId: sessionId, photoId: photoId)
    }
}

/// #require 宏不分解带 throw 的调用表达式（宏展开里的 `try` 语义），
/// 先取值再断言（swift-testing 文档模式）。
private func requireDecision(_ harness: CullingHarness, _ photoId: String) throws -> CullingDecisionRow {
    let row = try harness.decision(photoId)
    return try #require(row)
}

private func requireCache(_ harness: CullingHarness, _ photoId: String) throws -> MetadataCacheRow {
    let row = try harness.cacheRepo.get(photoId)
    return try #require(row)
}

/// 最新相似度结果行的真实 id（TS mock 常量 9 在真实库是自增 id）。
private func latestResultId(_ harness: CullingHarness) throws -> Int64 {
    let row = try harness.similarityRepo.getLatest(sessionId: "session")
    return try #require(row).id
}

/// 建已迁移库 + 会话 + 服务。同步态只读交付模型（旧 outbox 不再参与）。
private func makeHarness(
    history: Bool = true,
    triageDisplayPolicy: ((String) throws -> TriageDisplayPolicy)? = nil,
    flushMetadata: ((String) async throws -> Void)? = nil
) throws -> CullingHarness {
    let db = try makeTestDB()
    try insertSession(db, "session")
    let mutations = FakeMutationPort()
    let writeback = FakeWritebackPort()
    let historyRepo = CullingHistoryRepo(connection: db)
    // S5c-2a：culling confirm/cleanup 走真实 coordinator（真实 SQLite），
    // 只把「文件/指纹」换成内存替身，验证模块过滤、门禁、冲突与重试。
    let deliveryFiles = FakeDeliveryFiles()
    let deliveryFingerprint = FakeFingerprint()
    let deliveryRepo = DeliveryRepo(connection: db)
    let deliveryIntents = DeliveryIntentRepo(connection: db)
    let deliveryCoordinator = DeliveryCoordinator(
        connection: db,
        deliveryRepo: deliveryRepo,
        intentRepo: deliveryIntents,
        files: deliveryFiles,
        fileLock: XMPFileLock(),
        fingerprint: { [deliveryFingerprint] _ in deliveryFingerprint.current },
        resolvePhotoPath: { _, delivery in delivery.photoPath }
    )
    let service = CullingService(
        photoRepo: PhotoRepo(connection: db),
        cullingDecisionRepo: CullingDecisionRepo(connection: db),
        similarityResultRepo: SimilarityResultRepo(connection: db),
        metadataCacheRepo: MetadataCacheRepo(connection: db),
        connection: db,
        metadataMutations: mutations,
        writeback: writeback,
        cullingHistoryRepo: history ? historyRepo : nil,
        getNumber: { _, defaultValue in defaultValue },
        triageDisplayPolicy: triageDisplayPolicy,
        flushMetadata: flushMetadata,
        delivery: deliveryCoordinator.adapter(for: .culling)
    )
    return CullingHarness(
        db: db, sessionId: "session", service: service,
        photoRepo: PhotoRepo(connection: db),
        decisionRepo: CullingDecisionRepo(connection: db),
        similarityRepo: SimilarityResultRepo(connection: db),
        cacheRepo: MetadataCacheRepo(connection: db),
        historyRepo: historyRepo,
        mutations: mutations, writeback: writeback,
        deliveryFiles: deliveryFiles, deliveryFingerprint: deliveryFingerprint,
        deliveryRepo: deliveryRepo, deliveryIntents: deliveryIntents,
        deliveryCoordinator: deliveryCoordinator
    )
}

/// 插入照片（可选 asset 配对，外键保持开启）。
private func addPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String = "session",
    filepath: String? = nil,
    assetId: String? = nil,
    assetFileId: String? = nil,
    width: Int = 100,
    height: Int = 100
) throws {
    let path = filepath ?? "/shoot/\(id).jpg"
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
          asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'pending', ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([
        .text(id), .text(sessionId), .text(path),
        .text((path as NSString).lastPathComponent),
        assetId.map { .text($0) } ?? .null,
        assetFileId.map { .text($0) } ?? .null,
        .int(Int64(width)), .int(Int64(height)),
    ])
}

/// 插入一条 T0 建议行（门控测试用；gid 由 photos.asset_id 决定）。
private func insertTriage(
    _ db: DBConnection,
    photoId: String,
    verdict: String,
    fingerprint: String,
    policyVersion: String = "triage-v1",
    confidence: Double = 0.9
) throws {
    _ = try db.prepare("""
        INSERT INTO triage_suggestions
          (photo_id, session_id, verdict, score, confidence, reasons_json, group_id,
           policy_version, input_fingerprint, computed_at)
        VALUES (?, 'session', ?, 0.8, ?, '[]', NULL, ?, ?, 't')
        """).run([
            .text(photoId), .text(verdict), .real(confidence),
            .text(policyVersion), .text(fingerprint),
        ])
}

/// 建一条「已写」交付（S5c-2a：confirm/cleanup 的输入形状）。
/// 默认 culling item + 本会话链接；otherSessionId 用于跨会话门禁用例。
@discardableResult
private func seedWrittenDelivery(
    _ harness: CullingHarness,
    photoId: String,
    sessionId: String = "session",
    module: DeliveryModule = .culling,
    backupPath: String = "",
    baseFingerprint: String = "fp-current",
    baseValues: JSONValue = .object([:]),
    otherSessionId: String? = nil
) throws -> DeliveryRow {
    let xmpPath = "/shoot/\(photoId).xmp"
    let photoPath = "/shoot/\(photoId).jpg"
    let repo = harness.deliveryRepo
    _ = try repo.createOrGet(xmpPath: xmpPath, photoPath: photoPath, revision: 1)
    _ = try repo.markWriting(xmpPath: xmpPath, revision: 1)
    _ = try repo.markWritten(
        xmpPath: xmpPath,
        revision: 1,
        baseFingerprint: baseFingerprint,
        baseValues: baseValues,
        backupPath: backupPath
    )
    _ = try repo.upsertItem(
        xmpPath: xmpPath,
        photoId: photoId,
        module: module,
        status: .written
    )
    _ = try repo.linkSession(xmpPath: xmpPath, sessionId: sessionId)
    if let otherSessionId {
        _ = try repo.linkSession(xmpPath: xmpPath, sessionId: otherSessionId)
    }
    guard let row = try repo.get(xmpPath) else {
        throw DeliveryRepoError.rowNotFound(xmpPath: xmpPath)
    }
    return row
}

/// §5.4-2 reload_acked_at 门禁：确认/收尾前必须已由 Capture One 重载确认。
private func ackReload(_ db: DBConnection, sessionId: String = "session") throws {
    _ = try db.prepare(
        "UPDATE sessions SET reload_acked_at = '2026-01-01T00:00:00.000Z' WHERE id = ?"
    ).run([.text(sessionId)])
}

/// 建一条已确认（synced）交付：written → confirm（需要 reload ack）。
@discardableResult
private func seedSyncedDelivery(
    _ harness: CullingHarness,
    photoId: String,
    sessionId: String = "session",
    module: DeliveryModule = .culling,
    backupPath: String = "",
    baseFingerprint: String = "fp-current"
) throws -> DeliveryRow {
    try ackReload(harness.db, sessionId: sessionId)
    _ = try seedWrittenDelivery(
        harness, photoId: photoId, sessionId: sessionId, module: module,
        backupPath: backupPath, baseFingerprint: baseFingerprint
    )
    _ = try harness.deliveryCoordinator.confirm(sessionId: sessionId, module: module)
    guard let row = try harness.deliveryRepo.get("/shoot/\(photoId).xmp") else {
        throw DeliveryRepoError.rowNotFound(xmpPath: "/shoot/\(photoId).xmp")
    }
    return row
}

/// RAW/JPEG 变体对（共享资产与 asset_files 外键行）。
private func addVariantPair(_ db: DBConnection, assetId: String) throws {
    try insertAsset(db, id: assetId)
    try insertAssetFile(db, id: "\(assetId)-raw", normalizedPath: "/shoot/\(assetId).NEF")
    try insertAssetFile(db, id: "\(assetId)-jpg", normalizedPath: "/shoot/\(assetId).jpg")
    try addPhoto(db, id: "\(assetId)-raw", filepath: "/shoot/\(assetId).NEF", assetId: assetId, assetFileId: "\(assetId)-raw")
    try addPhoto(db, id: "\(assetId)-jpg", filepath: "/shoot/\(assetId).jpg", assetId: assetId, assetFileId: "\(assetId)-jpg")
}

/// 相似度结果（成员表 + stats_json.totalGroups）。
private func addSimilarityResult(
    _ harness: CullingHarness,
    memberships: [(photoId: String, groupIndex: Int)],
    totalGroups: Int = 1
) throws {
    _ = try harness.similarityRepo.replace(
        sessionId: harness.sessionId,
        groupsJson: "{\"groups\":[]}",
        statsJson: "{\"totalGroups\":\(totalGroups)}",
        threshold: 10,
        minGroupSize: 2,
        memberships: memberships
    )
}

/// 决策行直插（跳过服务层，fixture 用）。
private func addDecision(
    _ db: DBConnection,
    photoId: String,
    decision: String,
    sessionId: String = "session",
    rating: Int64 = 0,
    revision: Int64 = 1
) throws {
    _ = try db.prepare("""
        INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, rating,
          color_label, decision_source, revision, created_at, updated_at)
        VALUES (?, ?, 'ungrouped', ?, ?, 'None', 'manual', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([
        .text(sessionId), .text(photoId), .text(decision), .int(rating), .int(revision),
    ])
}

/// 构造旧 WritebackService 的行/预览项（镜像测试的输入形状）。
private func makeWritebackItem(
    id: Int,
    photoId: String,
    xmpStatus: String = "pending",
    keywords: [String] = [],
    attributes: WritebackAttributes? = nil,
    errorMessage: String = ""
) -> WritebackItem {
    WritebackItem(
        id: id,
        photoId: photoId,
        photoPath: "/shoot/\(photoId).jpg",
        sessionId: "session",
        module: "culling",
        keywords: keywords,
        attributes: attributes,
        xmpPath: "/shoot/\(photoId).xmp",
        backupPath: "",
        xmpStatus: xmpStatus,
        errorMessage: errorMessage,
        attemptCount: 0,
        lastAttemptAt: ""
    )
}

// MARK: - decide 语义（TS culling-service.test.ts 单决策面 + culling.ipc.ts 形状）

@Suite("CullingService decide 语义")
struct CullingDecideTests {
    @Test("decide keep → decision=keep, pickState=picked, revision=1，历史记录 fields=[pickState]")
    func decideKeep() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        try harness.service.decide(sessionId: "session", photoId: "p1", decision: .keep)

        let row = try requireDecision(harness, "p1")
        #expect(row.decision == "keep")
        #expect(row.revision == 1)
        #expect(row.rating == 0)
        let history = try harness.historyRepo.list(sessionId: "session")
        #expect(history.count == 1)
        #expect(history[0].entries.count == 1)
        #expect(history[0].entries[0].fields == [.pickState])
        #expect(history[0].entries[0].before.pickState == .unreviewed)
        #expect(history[0].entries[0].after.pickState == .picked)
    }

    @Test("decide reject → pickState=rejected；decide pending → unreviewed")
    func decideRejectAndPending() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        try harness.service.decide(sessionId: "session", photoId: "p1", decision: .reject)
        #expect(try harness.decision("p1")?.decision == "reject")

        let state = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 1,
            patch: CullingUpdatePatch(pickState: .unreviewed)
        )
        #expect(state.states[0].pickState == .unreviewed)
        #expect(try harness.decision("p1")?.decision == "pending")
    }

    @Test("updateState rating 直写 cache + queuePhotoValues(rating, schedule) + syncStatus pending")
    func updateRatingQueuesMetadata() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        let result = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(rating: 5)
        )

        #expect(result.states[0].rating == 5)
        #expect(result.syncStatus == .pending)
        let cache = try requireCache(harness, "p1")
        #expect(cache.rating == 5)
        #expect(harness.mutations.queued.count == 1)
        let queued = harness.mutations.queued[0]
        #expect(queued.photoId == "p1")
        #expect(queued.source == .culling)
        // S5c-2b-3b-2a：CullingService 不再直连 sync 端口，排程随变更入队。
        #expect(queued.schedule == true)
        #expect(queued.values["rating"] == .number(5))
        // 历史字段含 rating。
        let history = try harness.historyRepo.list(sessionId: "session")
        #expect(history[0].entries[0].fields == [.rating])
    }

    @Test("updateState colorLabel 入队 label；None → 空串（写盘标签语义）")
    func updateColorLabelMapsNoneToEmpty() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        _ = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(colorLabel: .red)
        )
        #expect(harness.mutations.queued[0].values["label"] == .string("Red"))
        #expect(try harness.cacheRepo.get("p1")?.label == "Red")

        _ = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 1,
            patch: CullingUpdatePatch(colorLabel: CaptureOneColorLabel.none)
        )
        #expect(harness.mutations.queued[1].values["label"] == .string(""))
        // cache 落 'None'（与 TS updateLabel(patch.colorLabel) 一致）。
        #expect(try harness.cacheRepo.get("p1")?.label == "None")
    }

    @Test("updateState 携带 cache 兜底：无决策行时 rating/label 来自 cache")
    func updateStateFallsBackToCache() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try harness.cacheRepo.updateRating(photoId: "p1", rating: 4)
        try harness.cacheRepo.updateLabel(photoId: "p1", label: "Green")

        let state = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        #expect(state.states[0].rating == 4)
        #expect(state.states[0].colorLabel == .green)
    }

    @Test("revision 冲突抛 CULLING_REVISION_CONFLICT（expected/current 插值）")
    func revisionConflictThrows() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try harness.service.decide(sessionId: "session", photoId: "p1", decision: .keep)

        #expect(throws: CullingServiceError.revisionConflict(expected: 0, current: 1)) {
            try harness.service.updateState(
                sessionId: "session", photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(pickState: .rejected)
            )
        }
        // 事务回滚：决策行保持 keep。
        #expect(try harness.decision("p1")?.decision == "keep")
    }

    @Test("空补丁抛 CULLING_PATCH_INVALID；非法 rating/pickState/colorLabel 抛逐字消息")
    func validatePatchErrors() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        #expect(throws: CullingServiceError.patchInvalid) {
            try harness.service.updateState(
                sessionId: "session", photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch()
            )
        }
        #expect(throws: CullingServiceError.ratingOutOfRange) {
            try harness.service.updateState(
                sessionId: "session", photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(rating: 6)
            )
        }
        #expect(throws: CullingServiceError.ratingOutOfRange) {
            try harness.service.updateState(
                sessionId: "session", photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(rating: -1)
            )
        }
        // 错误消息与 TS 逐字一致。
        #expect(CullingServiceError.patchInvalid.description == "CULLING_PATCH_INVALID")
        #expect(CullingServiceError.ratingOutOfRange.description == "rating must be an integer from 0 to 5")
        #expect(CullingServiceError.invalidPickState.description == "Invalid pickState")
        #expect(CullingServiceError.invalidColorLabel.description == "Invalid colorLabel")
    }

    @Test("未知照片抛 CULLING_PHOTO_NOT_IN_SESSION（fresh-read 兜底后仍缺失）")
    func unknownPhotoThrows() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "known")

        #expect(throws: CullingServiceError.photoNotInSession) {
            try harness.service.updateState(
                sessionId: "session", photoId: "ghost", expectedRevision: 0,
                patch: CullingUpdatePatch(pickState: .picked)
            )
        }
        #expect(throws: CullingServiceError.photoNotInSession) {
            try harness.service.decide(sessionId: "session", photoId: "ghost", decision: .keep)
        }
    }

    @Test("IPC 式更新：getUpdateContext 复用上下文，第二次点击以新 revision 通过")
    func ipcStyleUpdateWithContext() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let context = try harness.service.getUpdateContext(sessionId: "session")

        let first = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked), context: context
        )
        // 点击突发：同一个上下文、新 revision（复用缓存上下文不重读会话）。
        let second = try harness.service.updateState(
            sessionId: "session", photoId: "p1",
            expectedRevision: first.states[0].revision,
            patch: CullingUpdatePatch(rating: 4), context: context
        )
        #expect(second.states[0].rating == 4)
        #expect(second.states[0].pickState == .picked)
        #expect(second.states[0].revision == 2)
    }
}

// MARK: - 批量（TS culling-service.test.ts 批量面）

@Suite("CullingService 批量决策")
struct CullingBatchTests {
    @Test("batchDecide 全部入组：upsert 顺序按输入序，组 id 来自相似度成员表")
    func batchDecideWritesGroupIds() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addSimilarityResult(harness, memberships: [(photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0)])
        let resultId = try latestResultId(harness)
        let groupId = "\(resultId):0"

        try harness.service.batchDecide(sessionId: "session", photoIds: ["p1", "p2"], decision: .keep)

        let first = try requireDecision(harness, "p1")
        #expect(first.decision == "keep")
        #expect(first.groupId == groupId)
        #expect(first.revision == 1)
        let second = try requireDecision(harness, "p2")
        #expect(second.decision == "keep")
        #expect(second.groupId == groupId)
        #expect(second.revision == 1)
        // 单历史操作承载两条 entry。
        let history = try harness.historyRepo.list(sessionId: "session")
        #expect(history.count == 1)
        #expect(history[0].entries.map(\.photoId) == ["p1", "p2"])
    }

    @Test("共享 RAW/JPEG 元数据合并为一次 XMP 操作（upsert 两次、queuePhotoValues 一次、结果一条）")
    func coalescesSharedMetadata() throws {
        let harness = try makeHarness()
        try addVariantPair(harness.db, assetId: "asset-1")

        let results = try harness.service.batchUpdate(
            sessionId: "session", photoIds: ["asset-1-raw", "asset-1-jpg"],
            patch: CullingUpdatePatch(rating: 5)
        )

        // RAW/JPEG 共享同一侧车：一条操作结果。
        #expect(results.count == 1)
        #expect(results[0].xmpPath == "/shoot/asset-1.xmp")
        // 但两张照片都被 upsert。
        #expect(try harness.decision("asset-1-raw")?.rating == 5)
        #expect(try harness.decision("asset-1-jpg")?.rating == 5)
        #expect(harness.mutations.queued.count == 1)
        // rating 与 label 在同一历史操作内。
        let history = try harness.historyRepo.list(sessionId: "session")
        #expect(history[0].entries.count == 2)
    }

    @Test("同一资产的变体 pick 更新合并为一次操作（upsert 两次、结果一条）")
    func coalescesAssetPick() throws {
        let harness = try makeHarness()
        try addVariantPair(harness.db, assetId: "asset-1")

        let results = try harness.service.batchUpdate(
            sessionId: "session", photoIds: ["asset-1-raw", "asset-1-jpg"],
            patch: CullingUpdatePatch(pickState: .picked)
        )

        #expect(results.count == 1)
        #expect(results[0].states.map(\.photoId) == ["asset-1-raw", "asset-1-jpg"])
        #expect(results[0].states.allSatisfy { $0.pickState == .picked })
        #expect(try harness.decision("asset-1-raw")?.decision == "keep")
        #expect(try harness.decision("asset-1-jpg")?.decision == "keep")
        // pick 不触碰 XMP。
        #expect(harness.mutations.queued.isEmpty)
    }

    @Test("decideSimilarityGroup：K 保留 + 其余拒绝，整批单事务")
    func decideGroupKeepsKRejectsRest() throws {
        let harness = try makeHarness()
        for id in ["p1", "p2", "p3", "p4"] { try addPhoto(harness.db, id: id) }
        try addSimilarityResult(
            harness,
            memberships: [("p1", 0), ("p2", 0), ("p3", 0), ("p4", 0)]
        )

        let resultId = try latestResultId(harness)
        let groupId = "\(resultId):0"
        let results = try harness.service.decideSimilarityGroup(
            sessionId: "session", groupId: groupId, keepPhotoIds: ["p1", "p3"]
        )

        #expect(results.count == 4)
        #expect(try harness.decision("p1")?.decision == "keep")
        #expect(try harness.decision("p3")?.decision == "keep")
        #expect(try harness.decision("p2")?.decision == "reject")
        #expect(try harness.decision("p4")?.decision == "reject")
        // 全部照片都带组 id。
        #expect(try harness.decision("p2")?.groupId == groupId)
    }

    @Test("成员表为空时回退 groups_json 重建组索引")
    func groupIndexFallsBackToGroupsJson() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1", filepath: "/a.jpg")
        try addPhoto(harness.db, id: "p2", filepath: "/b.jpg")
        // 直接插 similarity_results 行：groups_json 有组、成员表为空。
        _ = try harness.db.prepare("""
            INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES ('session', ?, '{}', 10, 2, '2026-01-01T00:00:00.000Z')
          """).run([
            .text("""
            {"groups":[{"images":[{"path":"/a.jpg"},{"path":"/b.jpg"}]}]}
            """),
        ])

        try harness.service.batchDecide(sessionId: "session", photoIds: ["p1", "p2"], decision: .keep)

        // 组 id "resultId:index" 由 groups_json 路径重建。
        let row = try requireDecision(harness, "p1")
        #expect(row.groupId.hasSuffix(":0"))
        #expect(row.groupId.split(separator: ":").first == "1")
    }

    @Test("batchUpdate 拒绝陈旧照片 id：CULLING_PHOTOS_NOT_IN_SESSION")
    func batchRejectsStalePhotoIds() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "known")

        #expect(throws: CullingServiceError.photosNotInSession) {
            try harness.service.batchUpdate(
                sessionId: "session", photoIds: ["known", "stale"],
                patch: CullingUpdatePatch(rating: 5)
            )
        }
    }

    @Test("batchUpdate 空选择抛 CULLING_EMPTY_SELECTION")
    func batchEmptySelectionThrows() throws {
        let harness = try makeHarness()

        #expect(throws: CullingServiceError.emptySelection) {
            try harness.service.batchUpdate(
                sessionId: "session", photoIds: [], patch: CullingUpdatePatch(rating: 5)
            )
        }
    }

    @Test("batchUpdate 去重输入 id 并给所有结果附同一历史操作 id")
    func batchDedupesAndSharesOperationId() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")

        let results = try harness.service.batchUpdate(
            sessionId: "session", photoIds: ["p1", "p1", "p2"],
            patch: CullingUpdatePatch(pickState: .picked)
        )

        #expect(results.count == 2)
        #expect(results[0].historyOperationId != nil)
        #expect(results[0].historyOperationId == results[1].historyOperationId)
    }
}

// MARK: - 历史栈 undo/redo（TS culling-history-repository.test.ts + apply_history 面）

@Suite("CullingService 历史栈 undo/redo")
struct CullingHistoryTests {
    @Test("undo 恢复 before 快照并标记 undone；redo 恢复 after 快照")
    func undoThenRedo() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let applied = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let operationId = try #require(applied.historyOperationId)

        let undone = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .undo
        )
        #expect(undone.count == 1)
        #expect(undone[0].states[0].pickState == .unreviewed)
        #expect(undone[0].historyOperationId == operationId)
        #expect(try harness.decision("p1")?.decision == "pending")

        let redone = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .redo
        )
        #expect(redone[0].states[0].pickState == .picked)
        #expect(try harness.decision("p1")?.decision == "keep")

        // 历史栈顺序与 undone 标记。
        let history = try harness.historyRepo.list(sessionId: "session")
        #expect(history.count == 1)
        #expect(history[0].undone == false)
    }

    @Test("undo/redo 同步恢复 rating/label（cache 与 outbox 一并回滚）")
    func undoRestoresRatingAndLabel() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let applied = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(rating: 5, colorLabel: .red)
        )
        let operationId = try #require(applied.historyOperationId)

        _ = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .undo
        )
        #expect(try harness.cacheRepo.get("p1")?.rating == 0)
        #expect(try harness.cacheRepo.get("p1")?.label == "None")
        #expect(try harness.decision("p1")?.rating == 0)
        // undo 再次入队 reverse 补丁；排程随入队（CullingService 不再直连 sync 端口）。
        #expect(harness.mutations.queued.count == 2)

        _ = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .redo
        )
        #expect(try harness.cacheRepo.get("p1")?.rating == 5)
        #expect(try harness.cacheRepo.get("p1")?.label == "Red")
    }

    @Test("未知操作抛 CULLING_HISTORY_NOT_FOUND；方向状态不符抛 ALREADY_UNDONE / NOT_UNDONE")
    func historyStateErrors() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let applied = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let operationId = try #require(applied.historyOperationId)

        #expect(throws: CullingServiceError.historyNotFound) {
            try harness.service.applyHistory(
                sessionId: "session", requestedEntries: [],
                historyOperationId: 999, direction: .undo
            )
        }
        // 未 undo 就 redo → CULLING_HISTORY_NOT_UNDONE。
        #expect(throws: CullingServiceError.historyNotUndone) {
            try harness.service.applyHistory(
                sessionId: "session", requestedEntries: [],
                historyOperationId: operationId, direction: .redo
            )
        }
        _ = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .undo
        )
        // 已 undo 再 undo → CULLING_HISTORY_ALREADY_UNDONE。
        #expect(throws: CullingServiceError.historyAlreadyUndone) {
            try harness.service.applyHistory(
                sessionId: "session", requestedEntries: [],
                historyOperationId: operationId, direction: .undo
            )
        }
    }

    @Test("历史操作被外部编辑分叉时抛 CULLING_HISTORY_DIVERGED")
    func historyDiverged() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let applied = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let operationId = try #require(applied.historyOperationId)
        _ = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .undo
        )
        // undo 之后、redo 之前外部改状态 → 与操作快照分歧。
        // 外部编辑（renderer 外的来源）不经过 updateState（否则 append 会删除
        // undone 分支），直接写决策行模拟。
        _ = try harness.decisionRepo.upsertState(
            sessionId: "session", photoId: "p1", groupId: "ungrouped",
            state: CullingDecisionStateInput(
                decision: "reject", rating: 0, colorLabel: "None", revision: 3
            )
        )

        #expect(throws: CullingServiceError.historyDiverged) {
            try harness.service.applyHistory(
                sessionId: "session", requestedEntries: [],
                historyOperationId: operationId, direction: .redo
            )
        }
    }

    @Test("applyHistory 显式条目（renderer 重建补丁）：expectedRevision 校验 + 落库")
    func applyExplicitEntries() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        let results = try harness.service.applyHistory(
            sessionId: "session",
            requestedEntries: [
                CullingHistoryApplyEntry(
                    photoId: "p1", expectedRevision: 0,
                    patch: CullingUpdatePatch(rating: 3, pickState: .picked)
                ),
            ]
        )
        #expect(results.count == 1)
        #expect(try harness.decision("p1")?.decision == "keep")
        #expect(try harness.decision("p1")?.rating == 3)
        // 新历史操作（undo 后追加即丢弃 redo 分支）。
        let history = try harness.historyRepo.list(sessionId: "session")
        #expect(history.count == 1)
        #expect(history[0].entries[0].fields == [.rating, .pickState])

        // expectedRevision 不符 → CULLING_REVISION_CONFLICT。
        #expect(throws: CullingServiceError.revisionConflict(expected: 0, current: 1)) {
            try harness.service.applyHistory(
                sessionId: "session",
                requestedEntries: [
                    CullingHistoryApplyEntry(
                        photoId: "p1", expectedRevision: 0,
                        patch: CullingUpdatePatch(pickState: .rejected)
                    ),
                ]
            )
        }
    }

    @Test("applyHistory 拒绝重复照片：'History command contains duplicate photos'")
    func applyRejectsDuplicatePhotos() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        #expect(throws: CullingServiceError.historyDuplicatePhotos) {
            try harness.service.applyHistory(
                sessionId: "session",
                requestedEntries: [
                    CullingHistoryApplyEntry(photoId: "p1", expectedRevision: 0, patch: CullingUpdatePatch(pickState: .picked)),
                    CullingHistoryApplyEntry(photoId: "p1", expectedRevision: 0, patch: CullingUpdatePatch(rating: 4)),
                ]
            )
        }
    }

    @Test("历史栈顺序守卫（仓库层，与 TS culling-history-repository 一致）：undo/redo 只能沿栈顶")
    func historyStackOrder() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        let first = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let second = try harness.service.updateState(
            sessionId: "session", photoId: "p2", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let firstId = try #require(first.historyOperationId!)
        let secondId = try #require(second.historyOperationId!)

        // 非栈顶 undo → CULLING_UNDO_NOT_LATEST（TS 逐字）。
        #expect(throws: PersistenceError(code: .CULLING_UNDO_NOT_LATEST)) {
            try harness.historyRepo.setUndone(sessionId: "session", operationId: firstId, undone: true)
        }
        try harness.historyRepo.setUndone(sessionId: "session", operationId: secondId, undone: true)
        try harness.historyRepo.setUndone(sessionId: "session", operationId: firstId, undone: true)
        // 非栈顶 redo → CULLING_REDO_OUT_OF_ORDER（TS 逐字）。
        #expect(throws: PersistenceError(code: .CULLING_REDO_OUT_OF_ORDER)) {
            try harness.historyRepo.setUndone(sessionId: "session", operationId: secondId, undone: false)
        }
        try harness.historyRepo.setUndone(sessionId: "session", operationId: firstId, undone: false)
        try harness.historyRepo.setUndone(sessionId: "session", operationId: secondId, undone: false)

        #expect(try harness.historyRepo.list(sessionId: "session").map(\.undone) == [false, false])
    }

    @Test("undo 后追加新操作丢弃 redo 分支（TS 语义：append 删除 undone=1 行）")
    func appendDropsRedoBranch() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addPhoto(harness.db, id: "p3")
        let first = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let abandoned = try harness.service.updateState(
            sessionId: "session", photoId: "p2", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        _ = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: abandoned.historyOperationId!, direction: .undo
        )
        let replacement = try harness.service.updateState(
            sessionId: "session", photoId: "p3", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )

        // 被放弃的操作被删除；列表只剩 replacement 与 first。
        #expect(try harness.historyRepo.get(
            sessionId: "session", operationId: abandoned.historyOperationId!
        ) == nil)
        #expect(try harness.historyRepo.list(sessionId: "session").map(\.id)
            == [replacement.historyOperationId!, first.historyOperationId!])
    }

    @Test("getHistory 返回历史栈（limit 透传仓库 clamp）")
    func getHistoryLists() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        _ = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )

        let history = try harness.service.getHistory(sessionId: "session")
        #expect(history.count == 1)
        #expect(history[0].entries[0].photoId == "p1")
    }
}

// MARK: - summary / reset / groups

@Suite("CullingService summary 与 reset")
struct CullingSummaryResetTests {
    @Test("getSummary 计数 kept/rejected/pending/rated/labeled + totalGroups（stats_json）")
    func summaryCounts() throws {
        let harness = try makeHarness()
        for id in ["p1", "p2", "p3", "p4", "p5"] { try addPhoto(harness.db, id: id) }
        // 唯一真相源 = photo_metadata_cache；决策行的 rating 只是镜像列，
        // 故意写成不同值（1 vs 5）证明计数读的是 cache。
        try addDecision(harness.db, photoId: "p1", decision: "keep", rating: 1)
        try harness.cacheRepo.updateRating(photoId: "p1", rating: 5)
        try addDecision(harness.db, photoId: "p2", decision: "keep")
        try addDecision(harness.db, photoId: "p3", decision: "reject")
        try harness.cacheRepo.updateRating(photoId: "p4", rating: 3)
        try harness.cacheRepo.updateLabel(photoId: "p4", label: "Red")
        try addSimilarityResult(harness, memberships: [(photoId: "p1", groupIndex: 0)], totalGroups: 3)

        let summary = try harness.service.getSummary(sessionId: "session")

        #expect(summary.totalPhotos == 5)
        #expect(summary.kept == 2)
        #expect(summary.rejected == 1)
        #expect(summary.pending == 2)
        #expect(summary.rated == 2) // p1(cache 5，镜像行 1 被忽略) + p4(cache 3)
        #expect(summary.labeled == 1) // p4 的 cache 'Red'
        #expect(summary.totalGroups == 3)
    }

    @Test("totalGroups 在 stats_json 缺 totalGroups 时回退 groups_json 长度")
    func summaryTotalGroupsFallback() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        _ = try harness.db.prepare("""
            INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES ('session', ?, '{}', 10, 2, '2026-01-01T00:00:00.000Z')
          """).run([
            .text("""
            {"groups":[{}, {}, {}]}
            """),
        ])

        let summary = try harness.service.getSummary(sessionId: "session")
        #expect(summary.totalGroups == 3)
    }

    @Test("无相似度结果时 totalGroups 为 0")
    func summaryWithoutSimilarity() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        #expect(try harness.service.getSummary(sessionId: "session").totalGroups == 0)
    }

    @Test("getGroups：归档成员隐藏，归档导致成员不足的组隐藏（P1）")
    func groupsFilterArchivedMembers() throws {
        let harness = try makeHarness()
        for id in ["p1", "p2", "p3", "p4"] { try addPhoto(harness.db, id: id) }
        try addSimilarityResult(harness, memberships: [
            (photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0),
            (photoId: "p3", groupIndex: 1), (photoId: "p4", groupIndex: 1),
        ], totalGroups: 2)

        #expect(try harness.service.getGroups(sessionId: "session").count == 2)

        // 归档组 1 的一个成员：可见只剩 1 张 → 该组隐藏。
        _ = try harness.db.prepare("UPDATE photos SET archived_at = ? WHERE id = 'p3'")
            .run([.text("2026-10-28T00:00:00.000Z")])
        let groups = try harness.service.getGroups(sessionId: "session")
        #expect(groups.map(\.groupIndex) == [0])
        #expect(groups[0].images.map(\.photoId).sorted() == ["p1", "p2"])

        // 归档组 0 的一个成员：组 0 也隐藏。
        _ = try harness.db.prepare("UPDATE photos SET archived_at = ? WHERE id = 'p2'")
            .run([.text("2026-10-28T00:00:00.000Z")])
        #expect(try harness.service.getGroups(sessionId: "session").isEmpty)
    }

    @Test("totalGroups 扣掉成员全部归档的组；部分归档不改快照口径")
    func totalGroupsExcludesFullyArchivedGroups() throws {
        let harness = try makeHarness()
        for id in ["p1", "p2", "p3", "p4"] { try addPhoto(harness.db, id: id) }
        try addSimilarityResult(harness, memberships: [
            (photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0),
            (photoId: "p3", groupIndex: 1), (photoId: "p4", groupIndex: 1),
        ], totalGroups: 2)
        #expect(try harness.service.getSummary(sessionId: "session").totalGroups == 2)

        _ = try harness.db.prepare("UPDATE photos SET archived_at = ? WHERE id IN ('p1','p2')")
            .run([.text("2026-10-28T00:00:00.000Z")])
        #expect(try harness.service.getSummary(sessionId: "session").totalGroups == 1,
                "整组移出后不得继续显示旧组数")

        _ = try harness.db.prepare("UPDATE photos SET archived_at = ? WHERE id = 'p3'")
            .run([.text("2026-10-28T00:00:00.000Z")])
        #expect(try harness.service.getSummary(sessionId: "session").totalGroups == 1,
                "部分归档不改 stats 口径")
    }

    @Test("reset 清空整个会话；reset(组) 只清该组（含 confirmed 命令面）")
    func resetScopes() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        try addDecision(harness.db, photoId: "p2", decision: "keep")
        // 把 p2 的组 id 改成特定组。
        _ = try harness.db.prepare(
            "UPDATE culling_decisions SET group_id = '7:0' WHERE photo_id = 'p2'"
        ).run()

        #expect(throws: CullingServiceError.resetConfirmRequired) {
            try harness.service.resetCommand(sessionId: "session", confirmed: false)
        }
        try harness.service.resetCommand(sessionId: "session", groupId: "7:0", confirmed: true)
        #expect(try harness.decision("p1")?.decision == "keep")
        #expect(try harness.decision("p2") == nil)

        try harness.service.reset(sessionId: "session")
        #expect(try harness.decision("p1") == nil)
        #expect(try harness.decision("p2") == nil)
    }

    @Test("getGroups 计数 keep/reject/pending 并按 groupIndex 排序")
    func groupsCountsAndOrder() throws {
        let harness = try makeHarness()
        for id in ["p1", "p2", "p3", "p4", "p5", "p6"] { try addPhoto(harness.db, id: id) }
        try addSimilarityResult(
            harness,
            memberships: [("p1", 1), ("p2", 1), ("p3", 1), ("p4", 0), ("p5", 0)]
        )
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        try addDecision(harness.db, photoId: "p2", decision: "reject")

        let resultId = try latestResultId(harness)
        let groups = try harness.service.getGroups(sessionId: "session")

        #expect(groups.count == 2)
        #expect(groups.map(\.groupIndex) == [0, 1])
        let group1 = groups[0]
        #expect(group1.groupId == "\(resultId):0")
        #expect(group1.images.map(\.photoId).sorted() == ["p4", "p5"])
        #expect(group1.keepCount == 0)
        #expect(group1.pendingCount == 2)
        let group2 = groups[1]
        #expect(group2.keepCount == 1)
        #expect(group2.rejectCount == 1)
        #expect(group2.pendingCount == 1)
    }

    @Test("无相似度结果时 getGroups 返回空")
    func groupsWithoutResult() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        #expect(try harness.service.getGroups(sessionId: "session").isEmpty)
    }

    @Test("decideSimilarityGroup 前置校验：无结果/组太小/keep 非法")
    func decideGroupValidation() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        #expect(throws: CullingServiceError.noSimilarity) {
            try harness.service.decideSimilarityGroup(sessionId: "session", groupId: "1:0", keepPhotoIds: ["p1"])
        }
        try addSimilarityResult(harness, memberships: [(photoId: "p1", groupIndex: 0)])
        let firstId = try latestResultId(harness)
        #expect(throws: CullingServiceError.groupTooSmall) {
            try harness.service.decideSimilarityGroup(sessionId: "session", groupId: "\(firstId):0", keepPhotoIds: ["p1"])
        }
        try addPhoto(harness.db, id: "p2")
        _ = try harness.similarityRepo.replace(
            sessionId: "session", groupsJson: "{\"groups\":[]}", statsJson: "{}",
            threshold: 10, minGroupSize: 2,
            memberships: [(photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0)]
        )
        let secondId = try latestResultId(harness)
        let groupId = "\(secondId):0"
        // keep 数量非法（空/全量/组外照片）。
        #expect(throws: CullingServiceError.keepNotInGroup) {
            try harness.service.decideSimilarityGroup(sessionId: "session", groupId: groupId, keepPhotoIds: [])
        }
        #expect(throws: CullingServiceError.keepNotInGroup) {
            try harness.service.decideSimilarityGroup(sessionId: "session", groupId: groupId, keepPhotoIds: ["p1", "p2"])
        }
        #expect(throws: CullingServiceError.keepNotInGroup) {
            try harness.service.decideSimilarityGroup(sessionId: "session", groupId: groupId, keepPhotoIds: ["outside"])
        }
    }
}

// MARK: - 写回协作（TS culling.ipc.ts 命令面，fake provider 记录调用）

@Suite("CullingService 写回协作")
struct CullingWritebackTests {
    @Test("writeback 未确认抛 WRITEBACK_CONFIRM_REQUIRED")
    func writebackRequiresConfirm() async throws {
        let harness = try makeHarness()
        await #expect(throws: CullingServiceError.writebackConfirmRequired) {
            _ = try await harness.service.writeback(
                sessionId: "session", target: .keyword, confirmed: false
            )
        }
        #expect(harness.writeback.previewCalls.isEmpty)
    }

    @Test("writeback 无决策抛 CULLING_NO_DECISIONS")
    func writebackNoDecisions() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        await #expect(throws: CullingServiceError.noDecisions) {
            _ = try await harness.service.writeback(
                sessionId: "session", target: .keyword, confirmed: true
            )
        }
    }

    @Test("writeback keyword：preview 按决策 id 过滤、关键词合并、persist 与 execute 接同一批项")
    func writebackKeywordFlow() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        try addDecision(harness.db, photoId: "p2", decision: "reject")
        // fake preview 返回两项（含一项不在决策集的，必须被过滤）。
        harness.writeback.previewItems = [
            WritebackItem(
                id: 1, photoId: "p1", photoPath: "/shoot/p1.jpg", sessionId: "session",
                module: "culling", keywords: ["existing"],
                attributes: WritebackAttributes(keywords: ["culling:keep"]),
                xmpPath: "/shoot/p1.xmp", backupPath: "", xmpStatus: "pending",
                errorMessage: "", attemptCount: 0, lastAttemptAt: ""
            ),
            WritebackItem(
                id: 2, photoId: "p2", photoPath: "/shoot/p2.jpg", sessionId: "session",
                module: "culling", keywords: [],
                xmpPath: "/shoot/p2.xmp", backupPath: "", xmpStatus: "pending",
                errorMessage: "", attemptCount: 0, lastAttemptAt: ""
            ),
            WritebackItem(
                id: 3, photoId: "p3", photoPath: "/shoot/p3.jpg", sessionId: "session",
                module: "culling", keywords: [],
                xmpPath: "/shoot/p3.xmp", backupPath: "", xmpStatus: "pending",
                errorMessage: "", attemptCount: 0, lastAttemptAt: ""
            ),
        ]

        _ = try await harness.service.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )

        // preview 只携带决策集内的照片 id。
        let previewCall = try #require(harness.writeback.previewCalls.first)
        #expect(previewCall.module == "culling")
        #expect(previewCall.photoIds == ["p1", "p2"])
        // p1 的关键词被合并（保留已有 + 计划关键词），p2 无既有关键词。
        let persisted = try #require(harness.writeback.persistCalls.first)
        #expect(persisted.map(\.photoId) == ["p1", "p2"])
        let p1 = persisted[0]
        #expect(p1.attributes?.keywords == ["existing", "culling:keep"])
        let p2 = persisted[1]
        #expect(p2.attributes?.keywords == ["culling:reject"])
        // execute 接同一批项。
        #expect(harness.writeback.executeCalls.first?.module == "culling")
        #expect(harness.writeback.executeCalls.first?.items.map(\.photoId) == ["p1", "p2"])
    }

    /// TS 合并用的是 [...new Set([...item.keywords, ...attributes.keywords])]：
    /// 既有词与计划词重复时只能保留一次，且保持既有顺序。
    /// 变异「去掉 merged.contains 去重」可杀。
    @Test("writeback keyword 合并去重：既有词与计划词重复只保留一次")
    func writebackKeywordMergeDeduplicates() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        harness.writeback.previewItems = [
            WritebackItem(
                id: 1, photoId: "p1", photoPath: "/shoot/p1.jpg", sessionId: "session",
                module: "culling", keywords: ["culling:keep", "other"],
                attributes: nil,
                xmpPath: "/shoot/p1.xmp", backupPath: "", xmpStatus: "pending",
                errorMessage: "", attemptCount: 0, lastAttemptAt: ""
            ),
        ]

        _ = try await harness.service.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )

        let persisted = try #require(harness.writeback.persistCalls.first)
        #expect(persisted.first?.attributes?.keywords == ["culling:keep", "other"],
                "既有词与计划词重复时必须去重且保持既有顺序")
    }

    @Test("writeback rating/color_label 计划：写唯一真相源（cache）的值，不是 keep→5 派生常量")
    func writebackRatingAndLabelPlans() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addDecision(harness.db, photoId: "p1", decision: "keep", rating: 1)
        try addDecision(harness.db, photoId: "p2", decision: "reject", rating: 5)
        try harness.cacheRepo.updateRating(photoId: "p1", rating: 3)
        try harness.cacheRepo.updateRating(photoId: "p2", rating: 0)
        try harness.cacheRepo.updateLabel(photoId: "p1", label: "Blue")
        try harness.cacheRepo.updateLabel(photoId: "p2", label: "None")
        // pending 决策不进计划。
        try addPhoto(harness.db, id: "p3")
        try addDecision(harness.db, photoId: "p3", decision: "pending")
        harness.writeback.previewItems = [
            WritebackItem(id: 1, photoId: "p1", photoPath: "/shoot/p1.jpg", sessionId: "session",
                module: "culling", keywords: [], xmpPath: "/shoot/p1.xmp", backupPath: "",
                xmpStatus: "pending", errorMessage: "", attemptCount: 0, lastAttemptAt: ""),
            WritebackItem(id: 2, photoId: "p2", photoPath: "/shoot/p2.jpg", sessionId: "session",
                module: "culling", keywords: [], xmpPath: "/shoot/p2.xmp", backupPath: "",
                xmpStatus: "pending", errorMessage: "", attemptCount: 0, lastAttemptAt: ""),
            WritebackItem(id: 3, photoId: "p3", photoPath: "/shoot/p3.jpg", sessionId: "session",
                module: "culling", keywords: [], xmpPath: "/shoot/p3.xmp", backupPath: "",
                xmpStatus: "pending", errorMessage: "", attemptCount: 0, lastAttemptAt: ""),
        ]

        _ = try await harness.service.writeback(sessionId: "session", target: .rating, confirmed: true)
        let rated = try #require(harness.writeback.persistCalls.first)
        #expect(rated.map(\.photoId) == ["p1", "p2"])
        // p1 用户设 3 星（决策行镜像写着 1）→ 写回必须写 3；keep→5 的派生常量会
        // 在 execute 落盘后反过来污染真相源。
        #expect(rated[0].attributes?.rating == 3)
        #expect(rated[1].attributes?.rating == 0)

        _ = try await harness.service.writeback(sessionId: "session", target: .colorLabel, confirmed: true)
        let labeled = harness.writeback.persistCalls[1]
        #expect(labeled[0].attributes?.label == "Blue")
        // 写盘标签语义：None → 空串（清空色标）。
        #expect(labeled[1].attributes?.label == "")
    }


    @Test("finalizeSync 未确认抛 CULLING_FINALIZE_CONFIRM_REQUIRED；retryFailedWriteback 未确认抛 WRITEBACK_RETRY_CONFIRM_REQUIRED")
    func finalizeAndRetryConfirmations() async throws {
        let harness = try makeHarness()
        await #expect(throws: CullingServiceError.finalizeConfirmRequired) {
            _ = try await harness.service.finalizeSync(sessionId: "session", confirmed: false)
        }
        await #expect(throws: CullingServiceError.writebackRetryConfirmRequired) {
            _ = try await harness.service.retryFailedWriteback(sessionId: "session", confirmed: false)
        }
        try ackReload(harness.db)
        _ = try await harness.service.finalizeSync(sessionId: "session", confirmed: true)
        _ = try await harness.service.retryFailedWriteback(sessionId: "session", confirmed: true)
        #expect(harness.writeback.retryFailedCalls.map(\.module) == ["culling"])
        // S5c-2b-1：finalize 已切 DeliveryCoordinator（dropWithoutRestore），
        // 旧 metadataSync.finalizeSession 不再被调用。
    }

    @Test("syncStatus 委托协调器 getSummary")
    func syncStatusDelegates() throws {
        let harness = try makeHarness()
        let summary = try harness.service.syncStatus(sessionId: "session")
        #expect(summary.sessionId == "session")
    }
}

// MARK: - 确认/清理接 DeliveryCoordinator（Cut 2 / S5c-2a）

/// S5c-2a 的验收面：culling confirm/cleanup 已切交付模型（module = .culling），
/// 而 finalize/writeback 仍在旧链路。用真实 coordinator + 真实 SQLite，只把
/// 文件/指纹换成内存替身，验证：单事务确认、跨会话门禁、外改冲突、失败可重试、
/// 模块过滤，以及「会话写回态由交付聚合派生」（不写已删的 sessions 列）。
@Suite("CullingService 确认/清理（S5c-2a 交付模型）")
struct CullingDeliverySyncTests {
    @Test("confirmSync：单事务把 culling 交付/items 翻 synced，会话态由聚合派生")
    func confirmSyncUsesCoordinator() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p1")
        try ackReload(harness.db)

        try await harness.service.confirmSync(sessionId: "session")

        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.synced.rawValue)
        let items = try harness.deliveryRepo.listItems(sessionId: "session", module: .culling)
        #expect(items.map(\.status) == [DeliveryItemStatus.synced.rawValue])
        // 旧两路（metadataSync.confirmSync / writeback.confirmSync）不再被调用。
        #expect(harness.writeback.confirmSyncCalls.isEmpty)
        // D-021：会话级写回状态不落库，由交付聚合派生（confirm 后 → done）。
        #expect(try DeliverySummaryQuery(connection: harness.db)
            .summary(sessionId: "session", module: .culling).writebackStatus == .done)
    }

    @Test("confirmSync：failed 交付阻断确认 → XMP_CONFIRM_INCOMPLETE，confirmed_at 不落地")
    func confirmSyncGateMapsToLegacyCode() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        // 失败态只能从 writing 进入（written -> failed 不在状态转移表内）。
        let repo = harness.deliveryRepo
        _ = try repo.createOrGet(xmpPath: "/shoot/p1.xmp", photoPath: "/shoot/p1.jpg", revision: 1)
        _ = try repo.markWriting(xmpPath: "/shoot/p1.xmp", revision: 1)
        _ = try repo.markFailedForTesting(xmpPath: "/shoot/p1.xmp", revision: 1, errorMessage: "boom")
        _ = try repo.upsertItem(xmpPath: "/shoot/p1.xmp", photoId: "p1", module: .culling, status: .failed)
        _ = try repo.linkSession(xmpPath: "/shoot/p1.xmp", sessionId: "session")

        await #expect(throws: DeliveryError.confirmIncomplete) {
            try await harness.service.confirmSync(sessionId: "session")
        }
        let links = try harness.db.prepare(
            "SELECT confirmed_at FROM delivery_sessions WHERE session_id = 'session'"
        ).query()
        #expect(links.allSatisfy { ($0[0].textValue ?? "").isEmpty })
    }

    @Test("confirmSync：跨会话未确认 → XMP_CONFIRM_OTHER_SESSION_PENDING（本会话先落地，交付留 written）")
    func confirmSyncReportsOtherSessionBlocker() async throws {
        let harness = try makeHarness()
        try insertSession(harness.db, "other")
        try addPhoto(harness.db, id: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p1", otherSessionId: "other")
        try ackReload(harness.db)

        await #expect(throws: DeliveryError.otherSessionNotConfirmed(sessionId: "other")) {
            try await harness.service.confirmSync(sessionId: "session")
        }

        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.written.rawValue)
        let own = try harness.db.prepare(
            "SELECT confirmed_at FROM delivery_sessions WHERE session_id = 'session'"
        ).query()
        #expect((own[0][0].textValue ?? "").isEmpty == false)
    }

    @Test("cleanup：恢复备份后删交付行；旧两路清理不再调用")
    func cleanupUsesCoordinator() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        _ = try seedWrittenDelivery(harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test")
        try ackReload(harness.db)
        try await harness.service.confirmSync(sessionId: "session")

        let result = try await harness.service.cleanup(sessionId: "session", confirmed: true)

        #expect(result.deletedCount == 1)
        #expect(result.errors.isEmpty)
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        // 文件阶段：备份内容恢复回侧车（restore 幂等覆盖）。
        #expect(harness.deliveryFiles.restoreTargets == ["/shoot/p1.xmp"])
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "original")
        #expect(harness.writeback.cleanupCalls.isEmpty)
        // 交付行删完后聚合回到 idle（不依赖已删的 sessions.writeback_status）。
        #expect(try DeliverySummaryQuery(connection: harness.db)
            .summary(sessionId: "session", module: .culling).writebackStatus == .idle)
    }

    @Test("cleanup：外部修改 → 标 conflict、不恢复、不删行，错误按旧码回填")
    func cleanupDetectsExternalEdit() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        _ = try seedWrittenDelivery(
            harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test",
            baseFingerprint: "fp-baseline"
        )
        try ackReload(harness.db)
        try await harness.service.confirmSync(sessionId: "session")
        harness.deliveryFingerprint.current = "fp-edited"

        let result = try await harness.service.cleanup(sessionId: "session", confirmed: true)

        #expect(result.deletedCount == 0)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.hasPrefix("XMP_EXTERNALLY_MODIFIED:") == true)
        #expect(result.errors.first?.contains("/shoot/p1.xmp") == true)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.conflict.rawValue)
        #expect(harness.deliveryFiles.restoreTargets.isEmpty)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == nil)
    }

    @Test("cleanup：文件阶段失败保留 intent 且交付仍在；修好后 replay 重试成功")
    func cleanupFailureIsRetryable() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        harness.deliveryFiles.setRestoreFailure(FakeDeliveryFileError.restoreFailed)
        _ = try seedWrittenDelivery(harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test")
        try ackReload(harness.db)
        try await harness.service.confirmSync(sessionId: "session")

        let failed = try await harness.service.cleanup(sessionId: "session", confirmed: true)
        #expect(failed.deletedCount == 0)
        #expect(failed.errors.contains { $0.hasPrefix("XMP_CLEANUP_FILE_FAILED") })
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.synced.rawValue)
        // prepared intent 仍在（下次 replay 重做文件，幂等）。
        #expect(try harness.deliveryIntents.pending().prepared.count == 1)
        // cleanup 不重试未完成 intent（由 replay 统一处理）。
        let repeated = try await harness.service.cleanup(sessionId: "session", confirmed: true)
        #expect(repeated.deletedCount == 0)
        #expect(repeated.errors.contains { $0.hasPrefix("XMP_CLEANUP_INTENT_PENDING") })

        harness.deliveryFiles.clearRestoreFailure()
        let replay = try await harness.deliveryCoordinator.replay()
        #expect(replay.appliedCount == 1)
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        #expect(try harness.deliveryIntents.pending().prepared.isEmpty)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "original")
    }

    @Test("cleanup：module=.culling 只清本模块交付（face-keyword 已确认交付不动）")
    func cleanupIsModuleScoped() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p1", module: .faceKeyword)
        try ackReload(harness.db)
        _ = try harness.deliveryCoordinator.confirm(sessionId: "session", module: .faceKeyword)

        let result = try await harness.service.cleanup(sessionId: "session", confirmed: true)

        #expect(result.deletedCount == 0)
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") != nil)
    }

    @Test("cleanup 未确认抛 WRITEBACK_CLEANUP_CONFIRM_REQUIRED（Confirmed 语义不变）")
    func cleanupRequiresConfirm() async throws {
        let harness = try makeHarness()
        await #expect(throws: CullingServiceError.writebackCleanupConfirmRequired) {
            _ = try await harness.service.cleanup(sessionId: "session", confirmed: false)
        }
    }

    @Test("默认文件端口：restore 覆盖写回侧车、removeFile 幂等、缺备份报错")
    func fileSystemPortRestoresSidecar() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-delivery-port-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("IMG_1.jpg").path
        let sidecar = TSPath.xmpSidecarPath(photo)
        let backup = directory.appendingPathComponent("IMG_1.xmp.gather-backup-test").path
        try "edited".write(toFile: sidecar, atomically: true, encoding: .utf8)
        try "original".write(toFile: backup, atomically: true, encoding: .utf8)

        let port = FileSystemDeliveryFilePort()
        try await port.restore(photoPath: photo, backupPath: backup)
        #expect(try String(contentsOfFile: sidecar, encoding: .utf8) == "original")
        // restore 不消费备份（幂等，删行失败可原样重试）。
        #expect(port.fileExists(backup))

        try await port.removeFile(sidecar)
        #expect(port.fileExists(sidecar) == false)
        try await port.removeFile(sidecar)
        #expect(port.fileExists(sidecar) == false)

        let missing = backup + "-missing"
        await #expect(throws: DeliveryCoordinatorError.backupMissing(xmpPath: missing)) {
            try await port.restore(photoPath: photo, backupPath: missing)
        }
    }
}

// MARK: - 资产分组分页（TS culling-asset-page.test.ts / culling-page.test.ts，
// 真实 SQLite 语义对齐）

@Suite("CullingService 资产分组分页")
struct CullingPaginationTests {
    @Test("RAW/JPEG 变体永不分页，total 计逻辑资产")
    func neverSplitsVariantsAcrossPages() throws {
        let harness = try makeHarness()
        try addVariantPair(harness.db, assetId: "asset-1")
        try addPhoto(harness.db, id: "single1", filepath: "/shoot/B001.jpg")
        try addPhoto(harness.db, id: "single2", filepath: "/shoot/C001.jpg")

        let first = try harness.service.listPage(sessionId: "session", scope: .all, limit: 1)
        #expect(first.assets.count == 1)
        #expect(first.assets[0].photo.id == "asset-1-raw")
        #expect(first.assets[0].photo.variantCount == 2)
        #expect(first.assets[0].linkedVariantCount == 2)
        #expect(first.assets[0].photo.variants?.map(\.photoId) == ["asset-1-raw", "asset-1-jpg"])
        #expect(first.nextCursor?.rowId == 1)
        #expect(first.total == 3)

        let second = try harness.service.listPage(
            sessionId: "session", scope: .all, afterRowId: Int64(first.nextCursor?.rowId ?? 0), limit: 1
        )
        #expect(second.assets.map(\.photo.id) == ["single1"])
        let third = try harness.service.listPage(
            sessionId: "session", scope: .all, afterRowId: Int64(second.nextCursor?.rowId ?? 0), limit: 1
        )
        #expect(third.assets.map(\.photo.id) == ["single2"])
        let fourth = try harness.service.listPage(
            sessionId: "session", scope: .all, afterRowId: Int64(third.nextCursor?.rowId ?? 0), limit: 1
        )
        #expect(fourth.assets.isEmpty)
        #expect(fourth.nextCursor?.rowId == nil)

        // 走完全部页：3 个逻辑资产、无重复。
        var walked: [String] = []
        var cursor: Int64?
        for _ in 0..<20 {
            let page = try harness.service.listPage(
                sessionId: "session", scope: .all, afterRowId: cursor, limit: 1
            )
            walked.append(contentsOf: page.assets.map(\.photo.id))
            guard let next = page.nextCursor?.rowId else { break }
            cursor = Int64(next)
        }
        #expect(walked.count == 3)
        #expect(Set(walked).count == 3)
    }

    @Test("filtered 页只匹配首选 RAW 时资产保持完整")
    func filteredKeepsAssetCompleteWhenRawMatches() throws {
        let harness = try makeHarness()
        try addVariantPair(harness.db, assetId: "asset-1")
        try addDecision(harness.db, photoId: "asset-1-raw", decision: "keep")

        let page = try harness.service.listPage(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(pickStates: [.picked])
        )

        #expect(page.assets.count == 1)
        #expect(page.assets[0].photo.id == "asset-1-raw")
        #expect(page.assets[0].photo.variantCount == 2)
        #expect(page.assets[0].photo.variants?.map(\.photoId) == ["asset-1-raw", "asset-1-jpg"])
        #expect(page.total == 1)
    }

    @Test("非首选 JPEG 单独匹配时资产被排除（SQL 下推与 JS 安全网一致）")
    func excludesAssetWhenOnlyJpegMatches() throws {
        let harness = try makeHarness()
        try addVariantPair(harness.db, assetId: "asset-1")
        try addPhoto(harness.db, id: "single", filepath: "/shoot/B001.jpg")
        try addDecision(harness.db, photoId: "asset-1-jpg", decision: "keep")
        try addDecision(harness.db, photoId: "single", decision: "keep")

        let page = try harness.service.listPage(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(pickStates: [.picked])
        )
        #expect(page.assets.map(\.photo.id) == ["single"])
        #expect(page.total == 1)

        // list()（JS 侧首选行过滤）与页视图一致。
        let full = try harness.service.list(
            sessionId: "session", scope: .filtered, filters: CullingFilters(pickStates: [.picked])
        )
        #expect(full.map(\.photo.id) == ["single"])
    }

    /// filtered scope 的 keyset 分页：游标边界必须是严格大于，翻页不得重复上一页
    /// 最后一个资产。变异「HAVING MIN(p.rowid) > ? 改成 >= ?」可杀。
    @Test("filtered scope 翻页不重复边界资产（游标严格大于）")
    func filteredPaginationDoesNotRepeatBoundaryAsset() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1", filepath: "/shoot/A001.jpg")
        try addPhoto(harness.db, id: "p2", filepath: "/shoot/B001.jpg")
        try addPhoto(harness.db, id: "p3", filepath: "/shoot/C001.jpg")
        for id in ["p1", "p2", "p3"] {
            try addDecision(harness.db, photoId: id, decision: "keep")
        }

        var walked: [String] = []
        var cursor: Int64?
        for _ in 0..<10 {
            let page = try harness.service.listPage(
                sessionId: "session", scope: .filtered,
                filters: CullingFilters(pickStates: [.picked]),
                afterRowId: cursor, limit: 1
            )
            walked.append(contentsOf: page.assets.map(\.photo.id))
            guard let next = page.nextCursor?.rowId else { break }
            cursor = Int64(next)
        }
        #expect(walked == ["p1", "p2", "p3"], "每页 1 个资产走完应恰好 3 个且不重复，实际 \(walked)")
    }

    @Test("首选 RAW 匹配时 JPEG 变体仍在页内（游标为组首 rowid）")
    func keepsAssetCompleteWithRawMatch() throws {
        let harness = try makeHarness()
        // JPEG 先插（rowid 1, pending），RAW 后插（rowid 2, keep）。
        try addVariantPair(harness.db, assetId: "asset-1")
        try addDecision(harness.db, photoId: "asset-1-raw", decision: "keep")

        let page = try harness.service.listPage(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(pickStates: [.picked]),
            limit: 1
        )

        #expect(page.assets.count == 1)
        #expect(page.assets[0].photo.variantCount == 2)
        #expect(page.assets[0].photo.variants?.map(\.photoId) == ["asset-1-raw", "asset-1-jpg"])
        // RAW 先插（rowid 1），首选行也是 RAW；组首 rowid 即游标。
        #expect(page.nextCursor?.rowId == 1)
    }

    @Test("similarity_group 页：可解析组 id 下推 SQL 并计数组成员")
    func similarityGroupPagePushdown() throws {
        let harness = try makeHarness()
        for id in ["p1", "p2"] { try addPhoto(harness.db, id: id) }
        try addSimilarityResult(harness, memberships: [(photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0)])
        let groupId = "\(try latestResultId(harness)):0"
        let page = try harness.service.listPage(
            sessionId: "session", scope: .similarityGroup, requestedGroupId: groupId
        )

        #expect(page.assets.map(\.photo.id) == ["p1", "p2"])
        #expect(page.assets.allSatisfy { $0.similarityGroupId == groupId })
        #expect(page.total == 2)
    }

    @Test("similarity_group 页：不可解析组 id 回退 JS 相似度映射（total 按成员计数）")
    func similarityGroupUnparseableFallback() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addSimilarityResult(harness, memberships: [(photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0)])

        let page = try harness.service.listPage(
            sessionId: "session", scope: .similarityGroup, requestedGroupId: "stale-group-id"
        )
        #expect(page.assets.isEmpty)
        #expect(page.total == 0)
    }

    @Test("预计算阈值层被最新结果谓词排除（stats_json 标记）")
    func excludesPrecomputedTiers() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        _ = try harness.similarityRepo.replace(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"totalGroups\":1}", threshold: 10, minGroupSize: 2,
            memberships: [(photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0)]
        )
        // 阈值层后插：裸 MAX(id) 会选中它；谓词必须回退到主分析行成员。
        _ = try harness.similarityRepo.replaceForThreshold(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"totalGroups\":1,\"precomputed\":true}", threshold: 6, minGroupSize: 2,
            memberships: [(photoId: "p2", groupIndex: 0)]
        )

        let page = try harness.service.listPage(sessionId: "session", scope: .similarityGroup)

        #expect(page.assets.map(\.photo.id) == ["p1", "p2"])
        #expect(page.total == 2)
    }

    @Test("quality 过滤器：损坏 result_json 行被跳过而不是让整页查询失败")
    func qualityFilterJsonGuard() throws {
        let harness = try makeHarness()
        try insertAssetFile(harness.db, id: "af-bad", normalizedPath: "/shoot/bad.jpg")
        try insertAssetFile(harness.db, id: "af-good", normalizedPath: "/shoot/good.jpg")
        try insertAssetFile(harness.db, id: "af-mixed", normalizedPath: "/shoot/mixed.jpg")
        for id in ["bad", "good", "mixed"] { try addPhoto(harness.db, id: id, assetFileId: "af-\(id)") }
        func analysis(_ photoId: String, _ fingerprint: String, _ resultJSON: String, _ updatedAt: String) throws {
            _ = try harness.db.prepare("""
                INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json,
                  input_fingerprint, created_at, updated_at)
                VALUES (?, ?, 'technical_quality', ?, ?, '2026-01-01T00:00:00.000Z', ?)
              """).run([
                .text(photoId), .text("af-\(photoId)"), .text(resultJSON),
                .text(fingerprint), .text(updatedAt),
            ])
        }
        try analysis("bad", "f-bad", "not json", "2026-01-03T00:00:00.000Z")
        try analysis("mixed", "f-mixed-new", "not json", "2026-01-03T00:00:00.000Z")
        try analysis("mixed", "f-mixed-old", #"{"status":"succeeded","qualityScore":0.8}"#, "2026-01-01T00:00:00.000Z")
        try analysis("good", "f-good", #"{"status":"succeeded","qualityScore":0.9}"#, "2026-01-01T00:00:00.000Z")

        let analysed = try harness.service.listPage(
            sessionId: "session", scope: .filtered, filters: CullingFilters(qualityStatus: .analysed)
        )
        let ids = analysed.assets.map(\.photo.id)
        #expect(ids.contains("mixed"))
        #expect(ids.contains("good"))
        #expect(!ids.contains("bad"))
        #expect(analysed.total == 2)

        // 只有损坏行的照片也不算 failed，且查询不抛错。
        let failed = try harness.service.listPage(
            sessionId: "session", scope: .filtered, filters: CullingFilters(qualityStatus: .failed)
        )
        #expect(failed.assets.isEmpty)

        // unanalysed：只有损坏行的照片计入。
        let unanalysed = try harness.service.listPage(
            sessionId: "session", scope: .filtered, filters: CullingFilters(qualityStatus: .unanalysed)
        )
        #expect(unanalysed.assets.map(\.photo.id) == ["bad"])
        #expect(unanalysed.total == 1)
    }

    @Test("list() 全量装配：photos.metadata/result 不再从行读 + session 级富化")
    func listAssemblesFullRows() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1", filepath: "/shoot/a.jpg")

        let assets = try harness.service.list(sessionId: "session", scope: .all)

        #expect(assets.count == 1)
        #expect(assets[0].photo.id == "p1")
        // V1 的 photos 无 metadata/result 列（Cut 2 S5a）：DTO 字段保留但恒为空。
        #expect(assets[0].photo.metadata.isEmpty)
        #expect(assets[0].photo.result.isEmpty)
        #expect(assets[0].state.pickState == .unreviewed)
        #expect(assets[0].syncStatus == .clean)
        #expect(assets[0].linkedVariantCount == 1)
    }

    @Test("list() filtered：SQL 下推 + JS 安全网同口径（星级读唯一真相源 cache）")
    func listFilteredScope() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1", filepath: "/shoot/a.jpg")
        try addDecision(harness.db, photoId: "p1", decision: "keep", rating: 1)
        try harness.cacheRepo.updateRating(photoId: "p1", rating: 5)
        try harness.cacheRepo.updateLabel(photoId: "p1", label: "Red")

        let kept = try harness.service.list(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(ratings: [5], pickStates: [.picked])
        )
        #expect(kept.count == 1)
        #expect(kept[0].state.rating == 5)

        let excluded = try harness.service.list(
            sessionId: "session", scope: .filtered, filters: CullingFilters(ratings: [3])
        )
        #expect(excluded.isEmpty)
    }

    @Test("listPage 参数校验：limit 越界 / 游标 rowId 非正 / keyKind 错配都在 Query 层拒绝")
    func listPageValidation() throws {
        let harness = try makeHarness()
        #expect(throws: GatherError.self) {
            _ = try harness.service.listPage(sessionId: "session", scope: .all, limit: 2001)
        }
        #expect(throws: GatherError.self) {
            _ = try harness.service.listPage(
                sessionId: "session", scope: .all,
                cursor: CullingPageCursor(sort: .importOrder, rowId: 0))
        }

        // keyKind 缺失/错配必须在 service 层拒绝，不能静默跳页。
        #expect(throws: GatherError.self) {
            _ = try harness.service.listPage(
                sessionId: "session", scope: .all, sort: .captureDesc,
                cursor: CullingPageCursor(sort: .captureDesc, rowId: 1), limit: 10)
        }
        #expect(throws: GatherError.self) {
            _ = try harness.service.listPage(
                sessionId: "session", scope: .all, sort: .ratingDesc,
                cursor: CullingPageCursor(sort: .ratingDesc, rowId: 1), limit: 10)
        }
        #expect(throws: GatherError.self) {
            _ = try harness.service.listPage(
                sessionId: "session", scope: .all, sort: .importOrder,
                cursor: CullingPageCursor(
                    sort: .importOrder, dateKey: "2026-01-01", rowId: 1), limit: 10)
        }
    }
}

// MARK: - 资产富化细节

@Suite("CullingService 资产富化")
struct CullingEnrichmentTests {
    @Test("面孔归一化：归一化 bbox 保留，预览像素坐标换算并 clamp，按面积降序")
    func faceNormalization() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1", width: 200, height: 100)
        _ = try harness.db.prepare("""
            INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h,
              embedding, confidence, analysis_signature, created_at)
            VALUES (?, 'session', ?, ?, ?, ?, X'00', 0.9, ?, '2026-01-01T00:00:00.000Z')
          """).run([
            .text("p1"), .real(0.1), .real(0.2), .real(0.3), .real(0.4),
            .text(#"{"previewMaxDimension":100}"#),
        ])
        _ = try harness.db.prepare("""
            INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h,
              embedding, confidence, analysis_signature, created_at)
            VALUES (?, 'session', ?, ?, ?, ?, X'00', 0.9, '', '2026-01-01T00:00:00.000Z')
          """).run([
            // 旧库预览像素坐标：analysisWidth=100 → x/100, y/50。
            .text("p1"), .real(50), .real(25), .real(100), .real(50),
        ])

        let assets = try harness.service.list(sessionId: "session", scope: .all)

        #expect(assets[0].photo.faceCount == 2)
        let faces = assets[0].faceBboxes
        #expect(faces.count == 2)
        // 面积降序：像素版面积 0.5*1.0=0.5 最大在前；clamp 到 1。
        #expect(faces[0] == [0.5, 0.5, 1.0, 1.0])
        #expect(faces[1] == [0.1, 0.2, 0.3, 0.4])
    }

    @Test("质量相对排名：同组成功质量按分数降序 1 起排名")
    func qualityRelativeRank() throws {
        let harness = try makeHarness()
        try insertAssetFile(harness.db, id: "af-1", normalizedPath: "/shoot/p1.jpg")
        try insertAssetFile(harness.db, id: "af-2", normalizedPath: "/shoot/p2.jpg")
        try addPhoto(harness.db, id: "p1", assetFileId: "af-1")
        try addPhoto(harness.db, id: "p2", assetFileId: "af-2")
        try addSimilarityResult(harness, memberships: [(photoId: "p1", groupIndex: 0), (photoId: "p2", groupIndex: 0)])
        func analysis(_ photoId: String, _ assetFileId: String, _ score: Double) throws {
            _ = try harness.db.prepare("""
                INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json,
                  input_fingerprint, created_at, updated_at)
                VALUES (?, ?, 'technical_quality', ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
              """).run([
                .text(photoId), .text(assetFileId),
                .text(#"{"status":"succeeded","qualityScore":\#(score)}"#),
                .text("f-\(photoId)"),
            ])
        }
        try analysis("p1", "af-1", 0.8)
        try analysis("p2", "af-2", 0.9)

        let assets = try harness.service.list(sessionId: "session", scope: .all)
        let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.photo.id, $0) })
        #expect(byId["p2"]?.quality?.relativeRank == 1)
        #expect(byId["p1"]?.quality?.relativeRank == 2)
        #expect(byId["p1"]?.similarityGroupId == "\(try latestResultId(harness)):0")
    }

    @Test("metadataSource 从交付项 module 投影；conflict 状态驱动 metadataConflictOnly 过滤")
    func metadataSourceAndConflictFilter() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        // 交付项 module 是 V1 的归属真相源；conflict 读 deliveries.status。
        _ = try seedWrittenDelivery(harness, photoId: "p1", module: .faceKeyword)
        _ = try harness.deliveryRepo.markConflictForTesting(
            xmpPath: "/shoot/p1.xmp", revision: 1, errorMessage: "external"
        )

        let assets = try harness.service.list(sessionId: "session", scope: .all)
        #expect(assets[0].metadataSource == .faceKeyword)
        #expect(assets[0].syncStatus == .conflict)

        // metadataConflictOnly 已下推到 SQL（同一 photo_path 规则），JS 安全网同口径。
        let conflicts = try harness.service.list(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(metadataConflictOnly: true)
        )
        #expect(conflicts.map(\.photo.id) == ["p1"])
        let all = try harness.service.list(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(metadataConflictOnly: false)
        )
        #expect(all.map(\.photo.id) == ["p1", "p2"])
    }

}// MARK: - §4.1 回归：单一真相源 / 冲突下推 / 栈序（重写后的不变量）

@Suite("CullingService 挑片状态单一真相源")
struct CullingSingleTruthSourceTests {
    @Test("决策行 rating/color_label 是镜像列：页面/筛选/summary 只认 cache")
    func mirrorColumnsAreNeverRead() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1", filepath: "/shoot/a.jpg")
        // 镜像列故意写成 keep/5/Green；唯一真相源写 2/Blue。
        try addDecision(harness.db, photoId: "p1", decision: "keep", rating: 5)
        _ = try harness.db.prepare(
            "UPDATE culling_decisions SET color_label = 'Green' WHERE photo_id = 'p1'"
        ).run()
        try harness.cacheRepo.updateRating(photoId: "p1", rating: 2)
        try harness.cacheRepo.updateLabel(photoId: "p1", label: "Blue")

        let assets = try harness.service.list(sessionId: "session", scope: .all)
        #expect(assets.count == 1)
        #expect(assets[0].state.rating == 2)
        #expect(assets[0].state.colorLabel == .blue)
        #expect(assets[0].state.pickState == .picked) // 取舍只来自决策行

        let summary = try harness.service.getSummary(sessionId: "session")
        #expect(summary.rated == 1)
        #expect(summary.labeled == 1)

        // SQL 下推同样只认 cache：镜像的 5 星不得命中。
        let byMirror = try harness.service.list(
            sessionId: "session", scope: .filtered, filters: CullingFilters(ratings: [5])
        )
        #expect(byMirror.isEmpty)
        let byCache = try harness.service.list(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(ratings: [2], colorLabels: [.blue])
        )
        #expect(byCache.map(\.photo.id) == ["p1"])
    }

    @Test("reset 清决策行 + cache 投影 + 触及照片的历史：页面/summary 收敛，其他照片不受影响")
    func resetConvergesAllReadPaths() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        let applied = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(rating: 4, pickState: .picked, colorLabel: .red)
        )
        #expect(applied.historyOperationId != nil)
        // p2 的星级没有决策行（非挑片写入）：reset 不得误清。
        try harness.cacheRepo.updateRating(photoId: "p2", rating: 5)

        try harness.service.reset(sessionId: "session")

        #expect(try harness.decision("p1") == nil)
        #expect(try harness.cacheRepo.get("p1")?.rating == 0)
        #expect(try harness.cacheRepo.get("p1")?.label == "None")
        #expect(try harness.cacheRepo.get("p2")?.rating == 5)

        let summary = try harness.service.getSummary(sessionId: "session")
        #expect(summary.rated == 1)
        #expect(summary.labeled == 0)
        #expect(summary.kept == 0)
        #expect(summary.pending == 2)

        let assets = try harness.service.list(sessionId: "session", scope: .all)
        let reset = try #require(assets.first { $0.photo.id == "p1" })
        #expect(reset.state.rating == 0)
        #expect(reset.state.colorLabel == .none)
        #expect(reset.state.pickState == .unreviewed)

        // 历史栈一并清空：不会留下「撤销 → 分歧」的死路。
        #expect(try harness.service.getHistory(sessionId: "session").isEmpty)
        #expect(try harness.historyRepo.stackTops(sessionId: "session")
            == CullingHistoryStackTops(undoId: nil, redoId: nil))
    }

    @Test("metadataConflictOnly 下推：total 与页内容同口径（不虚高、不空页）")
    func conflictFilterIsPushedDown() throws {
        let harness = try makeHarness()
        for id in ["p1", "p2", "p3"] { try addPhoto(harness.db, id: id) }
        _ = try seedWrittenDelivery(harness, photoId: "p1")
        _ = try harness.deliveryRepo.markConflictForTesting(
            xmpPath: "/shoot/p1.xmp", revision: 1, errorMessage: "external"
        )

        let filters = CullingFilters(metadataConflictOnly: true)
        let page = try harness.service.listPage(
            sessionId: "session", scope: .filtered, filters: filters, limit: 200
        )
        #expect(page.total == 1)
        #expect(page.assets.map(\.photo.id) == ["p1"])
        // JS 安全网（list）与 SQL 下推同一规则。
        #expect(try harness.service.list(sessionId: "session", scope: .filtered, filters: filters)
            .map(\.photo.id) == ["p1"])
    }

    @Test("交付侧车键走 DeliveryPath.sidecar：去重拼写的 photo 路径仍规范化")
    func sidecarKeyIsCanonical() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1", filepath: "/shoot/sub/../a.jpg")
        let result = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(rating: 4)
        )
        // 侧车键是规范化后的 /shoot/a.xmp（裸拼会得到 /shoot/sub/../a.xmp）。
        #expect(result.xmpPath == "/shoot/a.xmp")
        let page = try harness.service.listPage(sessionId: "session", scope: .all, limit: 200)
        #expect(page.assets.count == 1)
        // 手动队列尚未产生交付行 → 同步态按 .clean 呈现（交付是唯一读模型）。
        #expect(page.assets[0].syncStatus == .clean)
    }
}

@Suite("CullingService 历史栈序唯一规则")
struct CullingHistoryStackRuleTests {
    private func applyRatings(_ harness: CullingHarness, count: Int) throws -> [Int] {
        try addPhoto(harness.db, id: "p1")
        var ids: [Int] = []
        var revision = 0
        // 星级取值 0...5 循环，保证每次操作的 after 都合法且各不相同。
        for rating in (0..<count).map({ $0 % 6 }) {
            let applied = try harness.service.updateState(
                sessionId: "session", photoId: "p1", expectedRevision: revision,
                patch: CullingUpdatePatch(rating: Double(rating))
            )
            revision = applied.states[0].revision
            ids.append(try #require(applied.historyOperationId))
        }
        return ids
    }

    @Test("stackTops：undo=MAX(未撤销) / redo=MIN(已撤销)；非栈顶重做被顺序守卫拒绝")
    func stackTopsRule() throws {
        let harness = try makeHarness()
        let ids = try applyRatings(harness, count: 3)

        var tops = try harness.historyRepo.stackTops(sessionId: "session")
        #expect(tops.undoId == ids[2])
        #expect(tops.redoId == nil)

        _ = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [], historyOperationId: ids[2], direction: .undo)
        _ = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [], historyOperationId: ids[1], direction: .undo)
        tops = try harness.historyRepo.stackTops(sessionId: "session")
        #expect(tops.undoId == ids[0])
        #expect(tops.redoId == ids[1]) // MIN(已撤销)

        // 跳序重做（选 MAX(已撤销) = 旧 UI 的 first(where: undone)）必须被拒。
        #expect(throws: PersistenceError(code: .CULLING_REDO_OUT_OF_ORDER)) {
            try harness.historyRepo.setUndone(sessionId: "session", operationId: ids[2], undone: false)
        }
        _ = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [], historyOperationId: ids[1], direction: .redo)
        tops = try harness.historyRepo.stackTops(sessionId: "session")
        #expect(tops.undoId == ids[1])
        #expect(tops.redoId == ids[2])
    }

    @Test("getHistory 窗口外仍补栈顶：深度撤销后重做出口不消失（id DESC 保持）")
    func windowAlwaysContainsStackTops() throws {
        let harness = try makeHarness()
        let ids = try applyRatings(harness, count: 6)
        for id in ids.dropFirst().reversed() {
            _ = try harness.service.applyHistory(
                sessionId: "session", requestedEntries: [], historyOperationId: id, direction: .undo)
        }
        // 窗口只取最新 2 条（ids[5]/ids[4]，都已撤销）；栈顶 ids[0]/ids[1] 必须补进来，
        // 否则 UI 按「MAX(未撤销)/MIN(已撤销)」推导会误报「没有可撤销/可重做」。
        let window = try harness.service.getHistory(sessionId: "session", limit: 2)
        #expect(Set(window.map(\.id)).isSuperset(of: [ids[0], ids[1], ids[4], ids[5]]))
        #expect(window.map(\.id) == window.map(\.id).sorted(by: >))
    }

    @Test("历史条目引用已删除照片：跳过该条目、其余照常撤销，不崩溃")
    func missingHistoryPhotoIsSkipped() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        let results = try harness.service.batchUpdate(
            sessionId: "session", photoIds: ["p1", "p2"],
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let operationId = try #require(results.first?.historyOperationId)
        // p2 被删除（决策行级联删除，历史 operation_json 仍引用它）。
        _ = try harness.db.prepare("DELETE FROM photos WHERE id = 'p2'").run()

        let undone = try harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .undo
        )
        #expect(undone.flatMap(\.states).map(\.photoId) == ["p1"])
        #expect(try harness.decision("p1")?.decision == "pending")
    }

    @Test("历史整条都指向已删除照片：抛可读分歧错误而非崩溃/静默成功")
    func allMissingHistoryPhotosThrowsDiverged() throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let applied = try harness.service.updateState(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let operationId = try #require(applied.historyOperationId)
        _ = try harness.db.prepare("DELETE FROM photos WHERE id = 'p1'").run()

        #expect(throws: CullingServiceError.historyDiverged) {
            _ = try harness.service.applyHistory(
                sessionId: "session", requestedEntries: [],
                historyOperationId: operationId, direction: .undo
            )
        }
    }
}
@Suite("CullingService 代表行规则（与图库/导出同源）")
struct CullingRepresentativeRowRuleTests {
    @Test("JPEG 先入（rowid 更小）仍选 RAW：规则来自 PhotoRepo.preferredRowOrderSQL")
    func prefersRawOverSmallerRowid() throws {
        let harness = try makeHarness()
        try insertAsset(harness.db, id: "asset-2")
        try insertAssetFile(harness.db, id: "asset-2-jpg", normalizedPath: "/shoot/b.jpg")
        try insertAssetFile(harness.db, id: "asset-2-raw", normalizedPath: "/shoot/b.NEF")
        // 故意让 JPEG 先插（rowid 更小）：若本地重写「最小 rowid」就会错选 JPEG。
        try addPhoto(
            harness.db, id: "asset-2-jpg", filepath: "/shoot/b.jpg",
            assetId: "asset-2", assetFileId: "asset-2-jpg"
        )
        try addPhoto(
            harness.db, id: "asset-2-raw", filepath: "/shoot/b.NEF",
            assetId: "asset-2", assetFileId: "asset-2-raw"
        )
        // 规则自身也断言一次（RAW 优先于更小 rowid）。
        let rule = PhotoRepo.preferredRowOrderSQL(alias: "p2")
        #expect(rule.contains("DESC"))
        #expect(rule.hasSuffix("p2.rowid"))

        let assets = try harness.service.list(sessionId: "session", scope: .all)
        #expect(assets.map(\.photo.id) == ["asset-2-raw"])
        // 变体数组顺序 = rowid（导入序），primary 落在共享规则选出的代表行上。
        #expect(assets[0].photo.variants?.map(\.photoId) == ["asset-2-jpg", "asset-2-raw"])
        #expect(assets[0].photo.variants?.first(where: { $0.role == "primary" })?.photoId == "asset-2-raw")

        // 分页（.all 走 PhotoRepo.getAssetPage，不经过任何组谓词）同口径。
        let page = try harness.service.listPage(sessionId: "session", scope: .all, limit: 200)
        #expect(page.assets.map(\.photo.id) == ["asset-2-raw"])
        #expect(page.total == 1)

        // filtered 分页走 SQL 代表行谓词（PhotoRepo.preferredRowOrderSQL 经
        // preferredRowPredicate）：SQL 选出的代表行与内存态 primary 必须是同一张。
        let filtered = try harness.service.listPage(
            sessionId: "session", scope: .filtered, filters: CullingFilters(), limit: 200
        )
        #expect(filtered.assets.map(\.photo.id) == ["asset-2-raw"])
        #expect(filtered.total == 1)
    }
}
// MARK: - 写回镜像 / 摘要 / finalize / reload 门禁（Cut 2 / S5c-2b-1）

@Suite("CullingService 写回镜像与收尾（S5c-2b-1）")
struct CullingDeliveryCut2Tests {
    @Test("writeback 镜像：delivery written + item/link + revision/base/backup 来自交付行")
    func writebackMirrorsWrittenItems() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        harness.writeback.previewItems = [
            makeWritebackItem(id: 1, photoId: "p1", keywords: ["existing"]),
        ]
        harness.writeback.executeResult = WritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: "Written: 1, Failed: 0, Skipped: 0"
        )
        harness.writeback.getItemsResult = [
            makeWritebackItem(
                id: 1, photoId: "p1", xmpStatus: "written",
                keywords: ["existing", "culling:keep"],
                attributes: WritebackAttributes(keywords: ["existing", "culling:keep"])
            ),
        ]
        // S5c-2b-3b-2a：执行器已把备份/指纹/基线直接写进 deliveries；镜像只回读它。
        _ = try seedWrittenDelivery(
            harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test",
            baseFingerprint: "fp-written",
            baseValues: .object(["rating": .number(3)])
        )

        let result = try await harness.service.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )

        #expect(result.errors.isEmpty)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.written.rawValue)
        // 镜像对新输入重开交付（revision + 1）后再落 written。
        #expect(row.revision == 2)
        #expect(row.baseFingerprint == "fp-written")
        #expect(row.backupPath == "/shoot/p1.xmp.gather-backup-test")
        #expect(row.photoPath == "/shoot/p1.jpg")
        #expect(row.baseValues.objectValue?["rating"]?.numberValue == 3)
        let items = try harness.deliveryRepo.listItems(sessionId: "session", module: .culling)
        #expect(items.count == 1)
        #expect(items[0].photoId == "p1")
        #expect(items[0].status == DeliveryItemStatus.written.rawValue)
        #expect(items[0].keywordList == ["existing", "culling:keep"])
        let links = try harness.db.prepare(
            "SELECT session_id FROM delivery_sessions WHERE delivery_id = ?"
        ).query([.int(row.id)])
        #expect(links.compactMap { $0[0].textValue } == ["session"])
    }

    @Test("writeback 镜像：failed 结果 → delivery failed + item.errorMessage")
    func writebackMirrorsFailedItems() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        let failed = makeWritebackItem(
            id: 1, photoId: "p1", xmpStatus: "failed", errorMessage: "boom"
        )
        harness.writeback.previewItems = [makeWritebackItem(id: 1, photoId: "p1")]
        harness.writeback.executeResult = WritebackResult(
            totalAffected: 1, written: 0, failed: 1, skipped: 0,
            errors: ["/shoot/p1.jpg: boom"], failedItems: [failed],
            report: "Written: 0, Failed: 1, Skipped: 0"
        )
        harness.writeback.getItemsResult = [failed]

        let result = try await harness.service.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )

        #expect(result.failed == 1)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.failed.rawValue)
        let items = try harness.deliveryRepo.listItems(sessionId: "session", module: .culling)
        #expect(items.count == 1)
        #expect(items[0].status == DeliveryItemStatus.failed.rawValue)
        #expect(items[0].errorMessage == "boom")
    }

    @Test("writeback 镜像幂等：重复执行不复制行，只推进 revision")
    func writebackMirrorIsIdempotent() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        harness.writeback.previewItems = [makeWritebackItem(id: 1, photoId: "p1")]
        harness.writeback.executeResult = WritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: ""
        )
        // 不提供持久化行：验证 result.written + plan item 的兜底镜像路径。
        let first = try await harness.service.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )
        let second = try await harness.service.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )
        #expect(first.errors.isEmpty)
        #expect(second.errors.isEmpty)
        let deliveries = try harness.db.prepare("SELECT COUNT(*) FROM deliveries").query()
        #expect(deliveries[0][0].intValue == 1)
        let items = try harness.db.prepare("SELECT COUNT(*) FROM delivery_items").query()
        #expect(items[0][0].intValue == 1)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.written.rawValue)
        #expect(row.revision == 1)
    }

    @Test("retryFailedWriteback 镜像：重试后 failed → written")
    func retryFailedWritebackMirrorsWrittenItems() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let failed = makeWritebackItem(
            id: 1, photoId: "p1", xmpStatus: "failed", errorMessage: "boom"
        )
        let written = makeWritebackItem(
            id: 1, photoId: "p1", xmpStatus: "written",
            attributes: WritebackAttributes(rating: 4)
        )
        harness.writeback.getItemsHandler = { status in
            status == "failed" ? [failed] : [written]
        }
        harness.writeback.executeResult = WritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: ""
        )

        let result = try await harness.service.retryFailedWriteback(
            sessionId: "session", confirmed: true
        )

        #expect(result.errors.isEmpty)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.written.rawValue)
        let items = try harness.deliveryRepo.listItems(sessionId: "session", module: .culling)
        #expect(items.count == 1)
        #expect(items[0].status == DeliveryItemStatus.written.rawValue)
        #expect(items[0].attributes["rating"]?.numberValue == 4)
    }

    @Test("syncStatus：交付聚合映射 MetadataSyncSummary，按交付去重且 item failed 升级展示态")
    func syncStatusMapsDeliverySummary() throws {
        let harness = try makeHarness()
        let repo = harness.deliveryRepo
        for id in ["p1", "p2", "p3", "p4"] { try addPhoto(harness.db, id: id) }
        _ = try seedSyncedDelivery(harness, photoId: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p2")

        _ = try repo.createOrGet(xmpPath: "/shoot/p3.xmp", photoPath: "/shoot/p3.jpg", revision: 1)
        _ = try repo.markWriting(xmpPath: "/shoot/p3.xmp", revision: 1)
        _ = try repo.markFailedForTesting(xmpPath: "/shoot/p3.xmp", revision: 1, errorMessage: "boom")
        _ = try repo.upsertItem(xmpPath: "/shoot/p3.xmp", photoId: "p3", module: .culling, status: .failed)
        _ = try repo.linkSession(xmpPath: "/shoot/p3.xmp", sessionId: "session")

        _ = try repo.createOrGet(xmpPath: "/shoot/p4.xmp", photoPath: "/shoot/p4.jpg", revision: 1)
        _ = try repo.markWriting(xmpPath: "/shoot/p4.xmp", revision: 1)
        _ = try repo.markConflictForTesting(xmpPath: "/shoot/p4.xmp", revision: 1, errorMessage: "external")
        _ = try repo.upsertItem(xmpPath: "/shoot/p4.xmp", photoId: "p4", module: .culling, status: .written)
        _ = try repo.linkSession(xmpPath: "/shoot/p4.xmp", sessionId: "session")

        let summary = try harness.service.syncStatus(sessionId: "session")
        #expect(summary.sessionId == "session")
        #expect(summary.pending == 0)
        #expect(summary.writing == 0)
        #expect(summary.written == 1)
        #expect(summary.failed == 1)
        #expect(summary.conflict == 1)
        #expect(summary.synced == 1)
        #expect(summary.items.count == 4)

        // item 失败把 written 交付升级为 failed 计数（UI/confirm 门禁可见）。
        try addPhoto(harness.db, id: "p5")
        _ = try seedWrittenDelivery(harness, photoId: "p5")
        _ = try repo.upsertItem(xmpPath: "/shoot/p5.xmp", photoId: "p5", module: .culling, status: .pending)
        _ = try repo.upsertItem(xmpPath: "/shoot/p5.xmp", photoId: "p5", module: .culling, status: .failed)
        let escalated = try harness.service.syncStatus(sessionId: "session")
        #expect(escalated.written == 1)
        #expect(escalated.failed == 2)
        #expect(escalated.items.count == 5)
    }

    @Test("flush：回放 delivery intent，不再触发旧 outbox flushSession")
    func flushReplaysIntents() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        harness.deliveryFiles.setContents("/shoot/p1.xmp", "gather-written")
        let row = try seedSyncedDelivery(
            harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test"
        )
        _ = try harness.deliveryIntents.prepare(
            kind: .cleanup,
            xmpPath: "/shoot/p1.xmp",
            payload: DeliveryCleanupPayload(delivery: row, photoPath: "/shoot/p1.jpg").json
        )

        let summary = try await harness.service.flush(sessionId: "session")

        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "original")
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        #expect(summary.synced == 0)
        #expect(summary.items.isEmpty)
        #expect(try harness.deliveryIntents.pending().isEmpty)
    }

    @Test("retrySync：同样只回放 intent，不再触发旧 retrySession")
    func retrySyncReplaysIntents() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        harness.deliveryFiles.setContents("/shoot/p1.xmp", "gather-written")
        let row = try seedSyncedDelivery(
            harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test"
        )
        _ = try harness.deliveryIntents.prepare(
            kind: .cleanup,
            xmpPath: "/shoot/p1.xmp",
            payload: DeliveryCleanupPayload(delivery: row, photoPath: "/shoot/p1.jpg").json
        )

        _ = try await harness.service.retrySync(sessionId: "session")

        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "original")
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
    }

    @Test("finalizeSync：保留 XMP、删交付行/备份，不 restore；重复调用幂等")
    func finalizeDropsWithoutRestore() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        harness.deliveryFiles.setContents("/shoot/p1.xmp", "gather-written")
        _ = try seedSyncedDelivery(harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test")

        let summary = try await harness.service.finalizeSync(
            sessionId: "session", confirmed: true
        )

        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        #expect(try harness.deliveryRepo.listItems(sessionId: "session").isEmpty)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "gather-written")
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp.gather-backup-test") == nil)
        #expect(harness.deliveryFiles.restoreTargets.isEmpty, "finalize 不得 restore")
        #expect(summary.items.isEmpty)
        #expect(summary.synced == 0)
        let links = try harness.db.prepare("SELECT COUNT(*) FROM delivery_sessions").query()
        #expect(links[0][0].intValue == 0)

        let repeated = try await harness.service.finalizeSync(
            sessionId: "session", confirmed: true
        )
        #expect(repeated.items.isEmpty)
        #expect(harness.deliveryFiles.removedPaths == ["/shoot/p1.xmp.gather-backup-test"])
    }

    @Test("finalize：只删 synced，conflict / written 原样保留")
    func finalizeOnlyDeletesSynced() async throws {
        let harness = try makeHarness()
        let repo = harness.deliveryRepo
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addPhoto(harness.db, id: "p3")
        _ = try seedSyncedDelivery(harness, photoId: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p2")
        _ = try repo.markConflictForTesting(
            xmpPath: "/shoot/p2.xmp", revision: 1, errorMessage: "external"
        )
        _ = try seedWrittenDelivery(harness, photoId: "p3")

        let result = try await harness.deliveryCoordinator.finalize(
            sessionId: "session", module: .culling
        )

        #expect(result.deletedCount == 1)
        #expect(result.skippedCount == 0)
        #expect(result.errors.isEmpty)
        #expect(try repo.get("/shoot/p1.xmp") == nil)
        #expect(try repo.get("/shoot/p2.xmp")?.status == DeliveryStatus.conflict.rawValue)
        #expect(try repo.get("/shoot/p3.xmp")?.status == DeliveryStatus.written.rawValue)
    }

    @Test("finalize：DB 删除失败保留交付行/备份/fileDone intent，replay 重试成功；备份只在 DB 成功后删")
    func finalizeFailureIsRetryable() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        harness.deliveryFiles.setContents("/shoot/p1.xmp", "gather-written")
        _ = try seedSyncedDelivery(harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test")
        try harness.db.exec("""
            CREATE TRIGGER fail_finalize_delivery_delete
            BEFORE DELETE ON deliveries
            BEGIN
              SELECT RAISE(ABORT, 'injected finalize delivery delete failure');
            END;
            """)

        let failed = try await harness.deliveryCoordinator.finalize(
            sessionId: "session", module: .culling
        )
        #expect(failed.deletedCount == 0)
        #expect(failed.errors.contains { $0.hasPrefix("XMP_FINALIZE_DB_FAILED") })
        // P1-1：DB 失败时备份绝不能先被删掉（否则 backup_path 悬空）。
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.synced.rawValue)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp.gather-backup-test") == "original")
        #expect(harness.deliveryFiles.removedPaths.isEmpty)
        #expect(try harness.deliveryIntents.pending().fileDone.count == 1)

        _ = try harness.db.exec("DROP TRIGGER fail_finalize_delivery_delete")
        let replay = try await harness.deliveryCoordinator.replay()
        #expect(replay.appliedCount == 1)
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp.gather-backup-test") == nil)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "gather-written")
        #expect(harness.deliveryFiles.restoreTargets.isEmpty)
        #expect(try harness.deliveryIntents.pending().isEmpty)
    }

    @Test("reload ack 门禁：未确认时 confirm/finalize 拒绝且不落 confirmed_at/不删行")
    func reloadAckGateBlocksConfirmAndFinalize() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p1")

        await #expect(throws: DeliveryError.confirmRequiresSync) {
            try await harness.service.confirmSync(sessionId: "session")
        }
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.written.rawValue)
        let links = try harness.db.prepare(
            "SELECT confirmed_at FROM delivery_sessions WHERE session_id = 'session'"
        ).query()
        #expect(links.allSatisfy { ($0[0].textValue ?? "").isEmpty })

        try ackReload(harness.db)
        try await harness.service.confirmSync(sessionId: "session")
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.synced.rawValue)

        _ = try harness.db.prepare(
            "UPDATE sessions SET reload_acked_at = NULL WHERE id = 'session'"
        ).run()
        await #expect(throws: DeliveryError.confirmRequiresSync) {
            _ = try await harness.service.finalizeSync(sessionId: "session", confirmed: true)
        }
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.synced.rawValue)
    }
}
// P0 / G0：20k 会话的 service 分页性能门（默认跳过；GATHER_CULLING_PERF=1）。
private let cullingServicePerfEnabled =
    ProcessInfo.processInfo.environment["GATHER_CULLING_PERF"] == "1"

@Suite("CullingService 20k 分页性能")
struct CullingServicePerfTests {
    // skip-owner: p0-perf
    // 到期：2027-06-30
    // 原因：20k service 分页是发布前性能门，默认套件跳过，避免日常插入 2 万行。
    // 手动条件：GATHER_CULLING_PERF=1 swift test --filter CullingServicePerf
    @Test(.enabled(if: cullingServicePerfEnabled))
    func twentyThousandAssetsPageP95() throws {
        let harness = try makeHarness()
        defer { harness.db.close() }
        for index in 0..<20_000 {
            try addPhoto(harness.db, id: String(format: "p%05d", index))
        }

        var cursor: Int64?
        var durations: [Double] = []
        for _ in 0..<10 {
            let started = DispatchTime.now().uptimeNanoseconds
            let page = try harness.service.listPage(
                sessionId: "session", scope: .all,
                afterRowId: cursor, limit: 200)
            durations.append(
                Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            guard let next = page.nextCursor?.rowId, !page.assets.isEmpty else { break }
            cursor = Int64(next)
        }
        let sorted = durations.sorted()
        let p95 = sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        print("PERF culling-service-20k pages=\(durations.count) p95=\(String(format: "%.1f", p95))ms")
        #expect(!durations.isEmpty)
        #expect(p95 < 800, "20k service 分页 p95 超过 800ms：\(p95)ms")
    }

    @Test("applyHistory 带 source：T0 撤销按 ai 回写，不再变 manual")
    func applyHistoryCarriesSource() async throws {
        let harness = try makeHarness()
        defer { harness.db.close() }
        try addPhoto(harness.db, id: "p1")
        _ = try await harness.service.applyHistory(
            sessionId: "session",
            requestedEntries: [CullingHistoryApplyEntry(
                photoId: "p1",
                expectedRevision: 0,
                patch: CullingUpdatePatch(pickState: .picked)
            )],
            historyOperationId: nil,
            direction: nil,
            source: .ai
        )
        let row = try #require(try harness.decisionRepo.getDecision(
            sessionId: "session", photoId: "p1"))
        #expect(row.decisionSource == "ai")
        #expect(row.decision == "keep")
    }

    @Test("rating/label 入队后 flush 接线可调用（API 层在返回前执行）")
    func flushQueuedMetadataIsWired() async throws {
        final class Recorder: @unchecked Sendable {
            var sessions: [String] = []
        }
        let recorder = Recorder()
        let harness = try makeHarness(flushMetadata: { sessionId in
            recorder.sessions.append(sessionId)
        })
        defer { harness.db.close() }
        try addPhoto(harness.db, id: "p1")
        try await harness.service.flushQueuedMetadata(sessionId: "session")
        #expect(recorder.sessions == ["session"])
    }

    @Test("T0 门控：只展示指纹匹配行；人工决策资产不展示；关闭态全隐藏")
    func triageDisplayGate() throws {
        let gate = TriageSuggestionGate(fingerprint: "fp-current", policyVersion: "triage-v1")
        let harness = try makeHarness(triageDisplayPolicy: { _ in .matching(gate) })
        defer { harness.db.close() }
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try insertTriage(harness.db, photoId: "p1", verdict: "keep", fingerprint: "fp-current")
        try insertTriage(harness.db, photoId: "p2", verdict: "reject", fingerprint: "fp-stale")

        let page = try harness.service.listPage(sessionId: "session", scope: .all, limit: 10)
        let p1 = try #require(page.assets.first { $0.photo.id == "p1" })
        let p2 = try #require(page.assets.first { $0.photo.id == "p2" })
        #expect(p1.triage?.verdict == .keep)
        #expect(p2.triage == nil)

        // 人工决策过的资产即使有匹配建议也不再展示。
        _ = try harness.db.prepare("""
            INSERT INTO culling_decisions
              (session_id, photo_id, group_id, decision, rating, color_label,
               decision_source, revision, created_at, updated_at)
            VALUES ('session', 'p1', 'ungrouped', 'reject', 0, 'None', 'manual', 1, 't', 't')
            """).run([])
        let afterManual = try harness.service.listPage(sessionId: "session", scope: .all, limit: 10)
        #expect(afterManual.assets.first { $0.photo.id == "p1" }?.triage == nil)

        // T0 关闭：任何行都不展示。
        let hidden = try makeHarness(triageDisplayPolicy: { _ in .hidden })
        defer { hidden.db.close() }
        try addPhoto(hidden.db, id: "p1")
        try insertTriage(hidden.db, photoId: "p1", verdict: "keep", fingerprint: "fp-current")
        let hiddenPage = try hidden.service.listPage(sessionId: "session", scope: .all, limit: 10)
        #expect(hiddenPage.assets.first?.triage == nil)
    }

    // skip-owner: p0-perf
    // 到期：2027-06-30
    // 原因：20k summary 是首屏聚合回归门，默认套件跳过，避免日常插入 2 万行。
    // 手动条件：GATHER_CULLING_PERF=1 swift test --filter CullingServicePerf
    @Test(.enabled(if: cullingServicePerfEnabled))
    func twentyThousandSummaryP95() throws {
        let harness = try makeHarness()
        defer { harness.db.close() }
        for index in 0..<20_000 {
            try addPhoto(harness.db, id: String(format: "p%05d", index))
        }
        var durations: [Double] = []
        for _ in 0..<10 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try harness.service.getSummary(sessionId: "session")
            durations.append(
                Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        let sorted = durations.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        print("PERF culling-summary-20k p95=\(String(format: "%.1f", p95))ms")
        #expect(p95 < 200, "20k summary p95 超过 200ms：\(p95)ms")
    }
}

/// 测试适配：旧调用点用 rowid 变量翻页；统一折成 CullingPageQuery。
private extension CullingService {
    func listPage(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        requestedGroupId: String? = nil,
        sort: CullingSort = .importOrder,
        cursor: CullingPageCursor? = nil,
        afterRowId: Int64? = nil,
        limit: Int = 200
    ) throws -> CullingPage {
        let effectiveCursor = cursor ?? afterRowId.map {
            CullingPageCursor(sort: .importOrder, rowId: $0)
        }
        return try listPage(try CullingPageQuery(
            sessionId: sessionId, scope: scope, filters: filters,
            groupId: requestedGroupId, sort: sort,
            cursor: effectiveCursor, limit: limit))
    }
}
