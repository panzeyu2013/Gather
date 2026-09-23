// desktop/native/gather-core/Tests/GatherCoreTests/Services/CullingServiceTests.swift
// CullingService 行为测试（3.4 Culling 模块，最大服务）。
// TS 源: tests/unit/services/culling/*（culling-service.test.ts / culling-page.test.ts /
// culling-asset-page.test.ts / culling-history-repository.test.ts，用例逐一对应）。
//
// 差异说明：
// - TS 用 vi.fn 替身注入（photos/decisions/similarity/cache/outbox/db）；Swift 侧
//   用真实临时 SQLite（:memory: + 迁移）+ fake 端口（sync/mutation/writeback 均
//   记录调用），XMP 从不触碰（queuePhotoValues 的 outbox 写由测试显式开关）。
// - 行为断言与 TS 逐条对应：decide 语义、批量合并、summary 计数、历史栈
//   undo/redo、apply_history、reset、写回协作（fake provider 记录调用）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - Fake 端口

/// TS: metadataSync 替身（schedule/getSummary/flushSession/retrySession/
/// finalizeSession/confirmSync/cleanup 全部记录调用）。
private final class FakeSyncPort: CullingSyncPort {
    var scheduled: [String] = []
    var confirmSyncCalls: [(sessionId: String, sourceModule: String)] = []
    var cleanupCalls: [(sessionId: String, sourceModule: String)] = []
    var cleanupResult = CleanupResult(deletedCount: 0, errors: [])

    func schedule(xmpPath: String) { scheduled.append(xmpPath) }
    func getSummary(sessionId: String) throws -> MetadataSyncSummary {
        MetadataSyncSummary(sessionId: sessionId, pending: 0, writing: 0, written: 0, failed: 0, conflict: 0, synced: 0, items: [])
    }
    func flushSession(sessionId: String) async throws -> MetadataSyncSummary {
        MetadataSyncSummary(sessionId: sessionId, pending: 0, writing: 0, written: 0, failed: 0, conflict: 0, synced: 0, items: [])
    }
    func retrySession(sessionId: String) async throws -> MetadataSyncSummary {
        MetadataSyncSummary(sessionId: sessionId, pending: 0, writing: 0, written: 0, failed: 0, conflict: 0, synced: 0, items: [])
    }
    func finalizeSession(sessionId: String) async throws -> MetadataSyncSummary {
        MetadataSyncSummary(sessionId: sessionId, pending: 0, writing: 0, written: 0, failed: 0, conflict: 0, synced: 0, items: [])
    }
    func confirmSync(sessionId: String, sourceModule: String) throws -> MetadataSyncSummary {
        confirmSyncCalls.append((sessionId, sourceModule))
        return MetadataSyncSummary(sessionId: sessionId, pending: 0, writing: 0, written: 0, failed: 0, conflict: 0, synced: 0, items: [])
    }
    func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult {
        cleanupCalls.append((sessionId, sourceModule))
        return cleanupResult
    }
}

/// TS: MetadataMutationService 替身（queuePhotoValues 记录调用；可选把 outbox
/// 行真实写入，让 syncStatus 断言反映写后行——测试显式开启）。
private final class FakeMutationPort: MetadataMutationPort, @unchecked Sendable {
    var queued: [(sessionId: String, photoId: String, values: [String: JSONValue], source: MetadataMutationSource, schedule: Bool)] = []
    let outboxRepo: MetadataOutboxRepo?
    let connection: DBConnection?

    init(outboxRepo: MetadataOutboxRepo? = nil, connection: DBConnection? = nil) {
        self.outboxRepo = outboxRepo
        self.connection = connection
    }

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        queued.append((sessionId, photoId, values, source, schedule))
        var xmpPath = ""
        var photoPath = ""
        if let connection {
            let row = try connection.prepare(
                "SELECT filepath FROM photos WHERE id = ?"
            ).get([.text(photoId)])
            photoPath = row?[0].textValue ?? ""
            xmpPath = TSPath.xmpSidecarPath(photoPath)
        }
        if let outboxRepo, !xmpPath.isEmpty {
            var patch = values
            patch["source"] = .string(source.rawValue)
            let dirtyFields = values.keys
                .filter { ["rating", "label", "keywords"].contains($0) }
                .compactMap { MetadataField(rawValue: $0) }
            let row = try outboxRepo.mergePatch(
                xmpPath: xmpPath,
                sessionId: sessionId,
                photoPath: photoPath,
                patch: .object(patch),
                dirtyFields: dirtyFields.map(\.rawValue)
            )
            return MetadataMutationResult(
                photoId: photoId, xmpPath: row.xmpPath,
                dirtyFields: dirtyFields, revision: Int(row.revision), status: row.status
            )
        }
        return MetadataMutationResult(
            photoId: photoId, xmpPath: xmpPath, dirtyFields: [], revision: 1, status: "pending"
        )
    }

    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        MetadataMutationResult(photoId: photoId, xmpPath: "", dirtyFields: [], revision: 0, status: "pending")
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

    func persistAttributes(items: [WritebackItem]) async throws {
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

    func getItems(sessionId: String, module: String, status: String?) async throws -> [WritebackItem] {
        getItemsCalls.append((sessionId, module))
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

// MARK: - 夹具

/// 会话 + 服务（真实 SQLite + 迁移；fake 端口注入，零 XMP/文件系统依赖）。
private struct CullingHarness {
    let db: DBConnection
    let sessionId: String
    let service: CullingService
    let photoRepo: PhotoRepo
    let similarityStore: SQLiteSimilarityStore
    let metadataStore: SQLiteMetadataStore
    let outboxRepo: MetadataOutboxRepo
    let cullingStore: SQLiteCullingStore
    let sync: FakeSyncPort
    let mutations: FakeMutationPort
    let writeback: FakeWritebackPort

    func decision(_ photoId: String) async throws -> CullingDecisionRecord? {
        try await cullingStore.decision(sessionId: sessionId, photoId: photoId)
    }
}

/// #require 宏不分解带 throw 的调用表达式（宏展开里的 `try` 语义），
/// 先取值再断言（swift-testing 文档模式）。
private func requireDecision(_ harness: CullingHarness, _ photoId: String) async throws -> CullingDecisionRecord {
    let row = try await harness.decision(photoId)
    return try #require(row)
}

private func requireCache(_ harness: CullingHarness, _ photoId: String) async throws -> MetadataCacheRecord {
    let row = try await harness.metadataStore.metadata(photoId: photoId)
    return try #require(row)
}

/// 最新相似度结果行的真实 id（TS mock 常量 9 在真实库是自增 id）。
private func latestResultId(_ harness: CullingHarness) async throws -> Int64 {
    let row = try await harness.similarityStore.latestResult(sessionId: "session")
    return try #require(row).id
}

/// 建已迁移库 + 会话 + 服务。`writeOutbox` 为 true 时 fake mutation 端口把
/// outbox 行真实写入（syncStatus 断言用）。
private func makeHarness(
    writeOutbox: Bool = false,
    history: Bool = true
) throws -> CullingHarness {
    // 历史栈在 Store 连接上：临时文件库双连接（旧 DBConnection + SQLiteDatabase）。
    let dbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-culling-\(UUID().uuidString).sqlite").path
    let db = try DBConnection(path: dbPath)
    try MigrationRunner().migrate(db)
    try insertSession(db, "session")
    let sync = FakeSyncPort()
    let outboxRepo = MetadataOutboxRepo(connection: db)
    let mutations = FakeMutationPort(
        outboxRepo: writeOutbox ? outboxRepo : nil,
        connection: writeOutbox ? db : nil
    )
    let writeback = FakeWritebackPort()
    let cullingStore = SQLiteCullingStore(database: try SQLiteDatabase(path: dbPath))
    let storeMetadata = SQLiteMetadataStore(database: try SQLiteDatabase(path: dbPath))
    let service = CullingService(
        photoRepo: PhotoRepo(connection: db),
        metadataOutboxRepo: outboxRepo,
        similarityStore: SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath)),
        connection: db,
        metadataSync: sync,
        metadataMutations: mutations,
        writeback: writeback,
        cullingStore: history ? cullingStore : nil,
        metadataStore: storeMetadata,
        getNumber: { _, defaultValue in defaultValue }
    )
    return CullingHarness(
        db: db, sessionId: "session", service: service,
        photoRepo: PhotoRepo(connection: db),
        similarityStore: SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath)),
        metadataStore: storeMetadata,
        outboxRepo: outboxRepo,
        cullingStore: cullingStore,
        sync: sync, mutations: mutations, writeback: writeback
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
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
          result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'pending', '{}', '{}', ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([
        .text(id), .text(sessionId), .text(path),
        .text((path as NSString).lastPathComponent),
        assetId.map { .text($0) } ?? .null,
        assetFileId.map { .text($0) } ?? .null,
        .int(Int64(width)), .int(Int64(height)),
    ])
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
    memberships: [SimilarityMembership],
    totalGroups: Int = 1
) async throws {
    _ = try await harness.similarityStore.replaceResult(
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

// MARK: - decide 语义（TS culling-service.test.ts 单决策面 + culling.ipc.ts 形状）

@Suite("CullingService decide 语义")
struct CullingDecideTests {
    @Test("decide keep → decision=keep, pickState=picked, revision=1，历史记录 fields=[pickState]")
    func decideKeep() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        try await harness.service.decide(sessionId: "session", photoId: "p1", decision: .keep)

        let row = try await requireDecision(harness, "p1")
        #expect(row.decision == "keep")
        #expect(row.revision == 1)
        #expect(row.rating == 0)
        let history = try await harness.cullingStore.historyList(sessionId: "session")
        #expect(history.count == 1)
        #expect(history[0].entries.count == 1)
        #expect(history[0].entries[0].fields == [.pickState])
        #expect(history[0].entries[0].before.pickState == .unreviewed)
        #expect(history[0].entries[0].after.pickState == .picked)
        #expect(harness.sync.scheduled.isEmpty)
    }

    @Test("decide reject → pickState=rejected；decide pending → unreviewed")
    func decideRejectAndPending() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        try await harness.service.decide(sessionId: "session", photoId: "p1", decision: .reject)
        await #expect(try await harness.decision("p1")?.decision == "reject")

        let state = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 1,
            patch: CullingUpdatePatch(pickState: .unreviewed)
        )
        #expect(state.states[0].pickState == .unreviewed)
        await #expect(try await harness.decision("p1")?.decision == "pending")
    }

    @Test("updateState rating 直写 cache + queuePhotoValues(rating) + schedule + syncStatus pending")
    func updateRatingQueuesMetadata() async throws {
        let harness = try makeHarness(writeOutbox: true)
        try addPhoto(harness.db, id: "p1")

        let result = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(rating: 5)
        )

        #expect(result.states[0].rating == 5)
        #expect(result.syncStatus == .pending)
        let cache = try await requireCache(harness, "p1")
        #expect(cache.rating == 5)
        #expect(harness.mutations.queued.count == 1)
        let queued = harness.mutations.queued[0]
        #expect(queued.photoId == "p1")
        #expect(queued.source == .culling)
        #expect(queued.schedule == false)
        #expect(queued.values["rating"] == .number(5))
        #expect(harness.sync.scheduled == ["/shoot/p1.xmp"])
        // 历史字段含 rating。
        let history = try await harness.cullingStore.historyList(sessionId: "session")
        #expect(history[0].entries[0].fields == [.rating])
    }

    @Test("updateState colorLabel 入队 label；None → 空串（写盘标签语义）")
    func updateColorLabelMapsNoneToEmpty() async throws {
        let harness = try makeHarness(writeOutbox: true)
        try addPhoto(harness.db, id: "p1")

        _ = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(colorLabel: .red)
        )
        #expect(harness.mutations.queued[0].values["label"] == .string("Red"))
        await #expect(try await harness.metadataStore.metadata(photoId: "p1")?.label == "Red")

        _ = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 1,
            patch: CullingUpdatePatch(colorLabel: CaptureOneColorLabel.none)
        )
        #expect(harness.mutations.queued[1].values["label"] == .string(""))
        // cache 落 'None'（与 TS updateLabel(patch.colorLabel) 一致）。
        await #expect(try await harness.metadataStore.metadata(photoId: "p1")?.label == "None")
    }

    @Test("updateState 携带 cache 兜底：无决策行时 rating/label 来自 cache")
    func updateStateFallsBackToCache() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try await harness.metadataStore.updateRating(photoId: "p1", rating: 4)
        try await harness.metadataStore.updateLabel(photoId: "p1", label: "Green")

        let state = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        #expect(state.states[0].rating == 4)
        #expect(state.states[0].colorLabel == .green)
    }

    @Test("revision 冲突抛 CULLING_REVISION_CONFLICT（expected/current 插值）")
    func revisionConflictThrows() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try await harness.service.decide(sessionId: "session", photoId: "p1", decision: .keep)

        await #expect(throws: CullingServiceError.revisionConflict(expected: 0, current: 1)) {
            try await harness.service.update(
                sessionId: "session", photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(pickState: .rejected)
            )
        }
        // 事务回滚：决策行保持 keep。
        await #expect(try await harness.decision("p1")?.decision == "keep")
    }

    @Test("空补丁抛 CULLING_PATCH_INVALID；非法 rating/pickState/colorLabel 抛逐字消息")
    func validatePatchErrors() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        await #expect(throws: CullingServiceError.patchInvalid) {
            try await harness.service.update(
                sessionId: "session", photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch()
            )
        }
        await #expect(throws: CullingServiceError.ratingOutOfRange) {
            try await harness.service.update(
                sessionId: "session", photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(rating: 6)
            )
        }
        await #expect(throws: CullingServiceError.ratingOutOfRange) {
            try await harness.service.update(
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
    func unknownPhotoThrows() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "known")

        await #expect(throws: CullingServiceError.photoNotInSession) {
            try await harness.service.update(
                sessionId: "session", photoId: "ghost", expectedRevision: 0,
                patch: CullingUpdatePatch(pickState: .picked)
            )
        }
        await #expect(throws: CullingServiceError.photoNotInSession) {
            try await harness.service.decide(sessionId: "session", photoId: "ghost", decision: .keep)
        }
    }

    @Test("IPC 式更新：getUpdateContext 复用上下文，第二次点击以新 revision 通过")
    func ipcStyleUpdateWithContext() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let context = try await harness.service.getUpdateContext(sessionId: "session")

        let first = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        // 点击突发：复用同一上下文（getUpdateContext 不重读会话），新 revision 通过。
        _ = context
        let second = try await harness.service.update(
            sessionId: "session", photoId: "p1",
            expectedRevision: first.states[0].revision,
            patch: CullingUpdatePatch(rating: 4)
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
    func batchDecideWritesGroupIds() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try await addSimilarityResult(harness, memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0), SimilarityMembership(photoId: "p2", groupIndex: 0)])
        let resultId = try await latestResultId(harness)
        let groupId = "\(resultId):0"

        try await harness.service.batchDecide(sessionId: "session", photoIds: ["p1", "p2"], decision: .keep)

        let first = try await requireDecision(harness, "p1")
        #expect(first.decision == "keep")
        #expect(first.groupId == groupId)
        #expect(first.revision == 1)
        let second = try await requireDecision(harness, "p2")
        #expect(second.decision == "keep")
        #expect(second.groupId == groupId)
        #expect(second.revision == 1)
        // 单历史操作承载两条 entry。
        let history = try await harness.cullingStore.historyList(sessionId: "session")
        #expect(history.count == 1)
        #expect(history[0].entries.map(\.photoId) == ["p1", "p2"])
    }

    @Test("共享 RAW/JPEG 元数据合并为一次 XMP 操作（upsert 两次、queuePhotoValues 一次、结果一条）")
    func coalescesSharedMetadata() async throws {
        let harness = try makeHarness()
        try addVariantPair(harness.db, assetId: "asset-1")

        let results = try await harness.service.batchUpdate(
            sessionId: "session", photoIds: ["asset-1-raw", "asset-1-jpg"],
            patch: CullingUpdatePatch(rating: 5)
        )

        // RAW/JPEG 共享同一侧车：一条操作结果。
        #expect(results.count == 1)
        #expect(results[0].xmpPath == "/shoot/asset-1.xmp")
        // 但两张照片都被 upsert。
        await #expect(try await harness.decision("asset-1-raw")?.rating == 5)
        await #expect(try await harness.decision("asset-1-jpg")?.rating == 5)
        #expect(harness.mutations.queued.count == 1)
        // rating 与 label 在同一历史操作内。
        let history = try await harness.cullingStore.historyList(sessionId: "session")
        #expect(history[0].entries.count == 2)
    }

    @Test("同一资产的变体 pick 更新合并为一次操作（upsert 两次、结果一条）")
    func coalescesAssetPick() async throws {
        let harness = try makeHarness()
        try addVariantPair(harness.db, assetId: "asset-1")

        let results = try await harness.service.batchUpdate(
            sessionId: "session", photoIds: ["asset-1-raw", "asset-1-jpg"],
            patch: CullingUpdatePatch(pickState: .picked)
        )

        #expect(results.count == 1)
        #expect(results[0].states.map(\.photoId) == ["asset-1-raw", "asset-1-jpg"])
        #expect(results[0].states.allSatisfy { $0.pickState == .picked })
        await #expect(try await harness.decision("asset-1-raw")?.decision == "keep")
        await #expect(try await harness.decision("asset-1-jpg")?.decision == "keep")
        // pick 不触碰 XMP。
        #expect(harness.mutations.queued.isEmpty)
        #expect(harness.sync.scheduled.isEmpty)
    }

    @Test("decideSimilarityGroup：K 保留 + 其余拒绝，整批单事务")
    func decideGroupKeepsKRejectsRest() async throws {
        let harness = try makeHarness()
        for id in ["p1", "p2", "p3", "p4"] { try addPhoto(harness.db, id: id) }
        try await addSimilarityResult(
            harness,
            memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0), SimilarityMembership(photoId: "p2", groupIndex: 0), SimilarityMembership(photoId: "p3", groupIndex: 0), SimilarityMembership(photoId: "p4", groupIndex: 0)]
        )

        let resultId = try await latestResultId(harness)
        let groupId = "\(resultId):0"
        let results = try await harness.service.decideSimilarityGroup(
            sessionId: "session", groupId: groupId, keepPhotoIds: ["p1", "p3"]
        )

        #expect(results.count == 4)
        await #expect(try await harness.decision("p1")?.decision == "keep")
        await #expect(try await harness.decision("p3")?.decision == "keep")
        await #expect(try await harness.decision("p2")?.decision == "reject")
        await #expect(try await harness.decision("p4")?.decision == "reject")
        // 全部照片都带组 id。
        await #expect(try await harness.decision("p2")?.groupId == groupId)
    }

    @Test("成员表为空时回退 groups_json 重建组索引")
    func groupIndexFallsBackToGroupsJson() async throws {
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

        try await harness.service.batchDecide(sessionId: "session", photoIds: ["p1", "p2"], decision: .keep)

        // 组 id "resultId:index" 由 groups_json 路径重建。
        let row = try await requireDecision(harness, "p1")
        #expect(row.groupId.hasSuffix(":0"))
        #expect(row.groupId.split(separator: ":").first == "1")
    }

    @Test("batchUpdate 拒绝陈旧照片 id：CULLING_PHOTOS_NOT_IN_SESSION")
    func batchRejectsStalePhotoIds() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "known")

        await #expect(throws: CullingServiceError.photosNotInSession) {
            try await harness.service.batchUpdate(
                sessionId: "session", photoIds: ["known", "stale"],
                patch: CullingUpdatePatch(rating: 5)
            )
        }
    }

    @Test("batchUpdate 空选择抛 CULLING_EMPTY_SELECTION")
    func batchEmptySelectionThrows() async throws {
        let harness = try makeHarness()

        await #expect(throws: CullingServiceError.emptySelection) {
            try await harness.service.batchUpdate(
                sessionId: "session", photoIds: [], patch: CullingUpdatePatch(rating: 5)
            )
        }
    }

    @Test("batchUpdate 去重输入 id 并给所有结果附同一历史操作 id")
    func batchDedupesAndSharesOperationId() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")

        let results = try await harness.service.batchUpdate(
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
    func undoThenRedo() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let applied = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let operationId = try #require(applied.historyOperationId)

        let undone = try await harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .undo
        )
        #expect(undone.count == 1)
        #expect(undone[0].states[0].pickState == .unreviewed)
        #expect(undone[0].historyOperationId == operationId)
        await #expect(try await harness.decision("p1")?.decision == "pending")

        let redone = try await harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .redo
        )
        #expect(redone[0].states[0].pickState == .picked)
        await #expect(try await harness.decision("p1")?.decision == "keep")

        // 历史栈顺序与 undone 标记。
        let history = try await harness.cullingStore.historyList(sessionId: "session")
        #expect(history.count == 1)
        #expect(history[0].undone == false)
    }

    @Test("undo/redo 同步恢复 rating/label（cache 与 outbox 一并回滚）")
    func undoRestoresRatingAndLabel() async throws {
        let harness = try makeHarness(writeOutbox: true)
        try addPhoto(harness.db, id: "p1")
        let applied = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(rating: 5, colorLabel: .red)
        )
        let operationId = try #require(applied.historyOperationId)

        _ = try await harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .undo
        )
        await #expect(try await harness.metadataStore.metadata(photoId: "p1")?.rating == 0)
        await #expect(try await harness.metadataStore.metadata(photoId: "p1")?.label == "None")
        await #expect(try await harness.decision("p1")?.rating == 0)
        // undo 再次入队 reverse 补丁并排程。
        #expect(harness.mutations.queued.count == 2)
        #expect(harness.sync.scheduled.count == 2)

        _ = try await harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .redo
        )
        await #expect(try await harness.metadataStore.metadata(photoId: "p1")?.rating == 5)
        await #expect(try await harness.metadataStore.metadata(photoId: "p1")?.label == "Red")
    }

    @Test("未知操作抛 CULLING_HISTORY_NOT_FOUND；方向状态不符抛 ALREADY_UNDONE / NOT_UNDONE")
    func historyStateErrors() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let applied = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let operationId = try #require(applied.historyOperationId)

        await #expect(throws: CullingServiceError.historyNotFound) {
            try await harness.service.applyHistory(
                sessionId: "session", requestedEntries: [],
                historyOperationId: 999, direction: .undo
            )
        }
        // 未 undo 就 redo → CULLING_HISTORY_NOT_UNDONE。
        await #expect(throws: CullingServiceError.historyNotUndone) {
            try await harness.service.applyHistory(
                sessionId: "session", requestedEntries: [],
                historyOperationId: operationId, direction: .redo
            )
        }
        _ = try await harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .undo
        )
        // 已 undo 再 undo → CULLING_HISTORY_ALREADY_UNDONE。
        await #expect(throws: CullingServiceError.historyAlreadyUndone) {
            try await harness.service.applyHistory(
                sessionId: "session", requestedEntries: [],
                historyOperationId: operationId, direction: .undo
            )
        }
    }

    @Test("历史操作被外部编辑分叉时抛 CULLING_HISTORY_DIVERGED")
    func historyDiverged() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        let applied = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let operationId = try #require(applied.historyOperationId)
        _ = try await harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: operationId, direction: .undo
        )
        // undo 之后、redo 之前外部改状态 → 与操作快照分歧。
        // 外部编辑（renderer 外的来源）不经过 updateState（否则 append 会删除
        // undone 分支），直接写决策行模拟。
        _ = try await harness.cullingStore.upsertDecisionState(
            sessionId: "session", photoId: "p1", groupId: "ungrouped",
            state: CullingDecisionState(
                decision: "reject", rating: 0, colorLabel: "None", revision: 3
            )
        )

        await #expect(throws: CullingServiceError.historyDiverged) {
            try await harness.service.applyHistory(
                sessionId: "session", requestedEntries: [],
                historyOperationId: operationId, direction: .redo
            )
        }
    }

    @Test("applyHistory 显式条目（renderer 重建补丁）：expectedRevision 校验 + 落库")
    func applyExplicitEntries() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        let results = try await harness.service.applyHistory(
            sessionId: "session",
            requestedEntries: [
                CullingHistoryApplyEntry(
                    photoId: "p1", expectedRevision: 0,
                    patch: CullingUpdatePatch(rating: 3, pickState: .picked)
                ),
            ]
        )
        #expect(results.count == 1)
        await #expect(try await harness.decision("p1")?.decision == "keep")
        await #expect(try await harness.decision("p1")?.rating == 3)
        // 新历史操作（undo 后追加即丢弃 redo 分支）。
        let history = try await harness.cullingStore.historyList(sessionId: "session")
        #expect(history.count == 1)
        #expect(history[0].entries[0].fields == [.rating, .pickState])

        // expectedRevision 不符 → CULLING_REVISION_CONFLICT。
        await #expect(throws: CullingServiceError.revisionConflict(expected: 0, current: 1)) {
            try await harness.service.applyHistory(
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
    func applyRejectsDuplicatePhotos() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        await #expect(throws: CullingServiceError.historyDuplicatePhotos) {
            try await harness.service.applyHistory(
                sessionId: "session",
                requestedEntries: [
                    CullingHistoryApplyEntry(photoId: "p1", expectedRevision: 0, patch: CullingUpdatePatch(pickState: .picked)),
                    CullingHistoryApplyEntry(photoId: "p1", expectedRevision: 0, patch: CullingUpdatePatch(rating: 4)),
                ]
            )
        }
    }

    @Test("历史栈顺序守卫（仓库层，与 TS culling-history-repository 一致）：undo/redo 只能沿栈顶")
    func historyStackOrder() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        let first = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let second = try await harness.service.update(
            sessionId: "session", photoId: "p2", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let firstId = try #require(first.historyOperationId!)
        let secondId = try #require(second.historyOperationId!)

        // 非栈顶 undo → CULLING_UNDO_NOT_LATEST（TS 逐字）。
        await #expect(throws: CullingStoreError.undoNotLatest) {
            try await harness.cullingStore.setHistoryUndone(sessionId: "session", operationId: firstId, undone: true)
        }
        try await harness.cullingStore.setHistoryUndone(sessionId: "session", operationId: secondId, undone: true)
        try await harness.cullingStore.setHistoryUndone(sessionId: "session", operationId: firstId, undone: true)
        // 非栈顶 redo → CULLING_REDO_OUT_OF_ORDER（TS 逐字）。
        await #expect(throws: CullingStoreError.redoOutOfOrder) {
            try await harness.cullingStore.setHistoryUndone(sessionId: "session", operationId: secondId, undone: false)
        }
        try await harness.cullingStore.setHistoryUndone(sessionId: "session", operationId: firstId, undone: false)
        try await harness.cullingStore.setHistoryUndone(sessionId: "session", operationId: secondId, undone: false)

        #expect(try await harness.cullingStore.historyList(sessionId: "session").map(\.undone) == [false, false])
    }

    @Test("undo 后追加新操作丢弃 redo 分支（TS 语义：append 删除 undone=1 行）")
    func appendDropsRedoBranch() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addPhoto(harness.db, id: "p3")
        let first = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        let abandoned = try await harness.service.update(
            sessionId: "session", photoId: "p2", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )
        _ = try await harness.service.applyHistory(
            sessionId: "session", requestedEntries: [],
            historyOperationId: abandoned.historyOperationId!, direction: .undo
        )
        let replacement = try await harness.service.update(
            sessionId: "session", photoId: "p3", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )

        // 被放弃的操作被删除；列表只剩 replacement 与 first。
        #expect(try await harness.cullingStore.historyOperation(
            sessionId: "session", operationId: abandoned.historyOperationId!
        ) == nil)
        #expect(try await harness.cullingStore.historyList(sessionId: "session").map(\.id)
            == [replacement.historyOperationId!, first.historyOperationId!])
    }

    @Test("getHistory 返回历史栈（limit 透传仓库 clamp）")
    func getHistoryLists() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        _ = try await harness.service.update(
            sessionId: "session", photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)
        )

        let history = try await harness.service.getHistory(sessionId: "session")
        #expect(history.count == 1)
        #expect(history[0].entries[0].photoId == "p1")
    }
}

// MARK: - summary / reset / groups

@Suite("CullingService summary 与 reset")
struct CullingSummaryResetTests {
    @Test("getSummary 计数 kept/rejected/pending/rated/labeled + totalGroups（stats_json）")
    func summaryCounts() async throws {
        let harness = try makeHarness()
        for id in ["p1", "p2", "p3", "p4", "p5"] { try addPhoto(harness.db, id: id) }
        try addDecision(harness.db, photoId: "p1", decision: "keep", rating: 5)
        try addDecision(harness.db, photoId: "p2", decision: "keep")
        try addDecision(harness.db, photoId: "p3", decision: "reject")
        try await harness.metadataStore.updateRating(photoId: "p4", rating: 3)
        try await harness.metadataStore.updateLabel(photoId: "p4", label: "Red")
        try await addSimilarityResult(harness, memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0)], totalGroups: 3)

        let summary = try await harness.service.getSummary(sessionId: "session")

        #expect(summary.totalPhotos == 5)
        #expect(summary.kept == 2)
        #expect(summary.rejected == 1)
        #expect(summary.pending == 2)
        #expect(summary.rated == 2) // p1(5) + p4(cache 3)
        #expect(summary.labeled == 1) // p4 的 cache 'Red'
        #expect(summary.totalGroups == 3)
    }

    @Test("totalGroups 在 stats_json 缺 totalGroups 时回退 groups_json 长度")
    func summaryTotalGroupsFallback() async throws {
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

        let summary = try await harness.service.getSummary(sessionId: "session")
        #expect(summary.totalGroups == 3)
    }

    @Test("无相似度结果时 totalGroups 为 0")
    func summaryWithoutSimilarity() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        #expect(try await harness.service.getSummary(sessionId: "session").totalGroups == 0)
    }

    @Test("reset 清空整个会话；reset(组) 只清该组（含 confirmed 命令面）")
    func resetScopes() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        try addDecision(harness.db, photoId: "p2", decision: "keep")
        // 把 p2 的组 id 改成特定组。
        _ = try harness.db.prepare(
            "UPDATE culling_decisions SET group_id = '7:0' WHERE photo_id = 'p2'"
        ).run()

        await #expect(throws: CullingServiceError.resetConfirmRequired) {
            try await harness.service.resetCommand(sessionId: "session", confirmed: false)
        }
        try await harness.service.resetCommand(sessionId: "session", groupId: "7:0", confirmed: true)
        await #expect(try await harness.decision("p1")?.decision == "keep")
        await #expect(try await harness.decision("p2") == nil)

        try await harness.service.reset(sessionId: "session")
        await #expect(try await harness.decision("p1") == nil)
        await #expect(try await harness.decision("p2") == nil)
    }

    @Test("getGroups 计数 keep/reject/pending 并按 groupIndex 排序")
    func groupsCountsAndOrder() async throws {
        let harness = try makeHarness()
        for id in ["p1", "p2", "p3", "p4", "p5", "p6"] { try addPhoto(harness.db, id: id) }
        try await addSimilarityResult(
            harness,
            memberships: [SimilarityMembership(photoId: "p1", groupIndex: 1), SimilarityMembership(photoId: "p2", groupIndex: 1), SimilarityMembership(photoId: "p3", groupIndex: 1), SimilarityMembership(photoId: "p4", groupIndex: 0), SimilarityMembership(photoId: "p5", groupIndex: 0)]
        )
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        try addDecision(harness.db, photoId: "p2", decision: "reject")

        let resultId = try await latestResultId(harness)
        let groups = try await harness.service.getGroups(sessionId: "session")

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
    func groupsWithoutResult() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        #expect(try await harness.service.getGroups(sessionId: "session").isEmpty)
    }

    @Test("decideSimilarityGroup 前置校验：无结果/组太小/keep 非法")
    func decideGroupValidation() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")

        await #expect(throws: CullingServiceError.noSimilarity) {
            try await harness.service.decideSimilarityGroup(sessionId: "session", groupId: "1:0", keepPhotoIds: ["p1"])
        }
        try await addSimilarityResult(harness, memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0)])
        let firstId = try await latestResultId(harness)
        await #expect(throws: CullingServiceError.groupTooSmall) {
            try await harness.service.decideSimilarityGroup(sessionId: "session", groupId: "\(firstId):0", keepPhotoIds: ["p1"])
        }
        try addPhoto(harness.db, id: "p2")
        _ = try await harness.similarityStore.replaceResult(
            sessionId: "session", groupsJson: "{\"groups\":[]}", statsJson: "{}",
            threshold: 10, minGroupSize: 2,
            memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0), SimilarityMembership(photoId: "p2", groupIndex: 0)]
        )
        let secondId = try await latestResultId(harness)
        let groupId = "\(secondId):0"
        // keep 数量非法（空/全量/组外照片）。
        await #expect(throws: CullingServiceError.keepNotInGroup) {
            try await harness.service.decideSimilarityGroup(sessionId: "session", groupId: groupId, keepPhotoIds: [])
        }
        await #expect(throws: CullingServiceError.keepNotInGroup) {
            try await harness.service.decideSimilarityGroup(sessionId: "session", groupId: groupId, keepPhotoIds: ["p1", "p2"])
        }
        await #expect(throws: CullingServiceError.keepNotInGroup) {
            try await harness.service.decideSimilarityGroup(sessionId: "session", groupId: groupId, keepPhotoIds: ["outside"])
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

    @Test("writeback rating/color_label 计划：keep→5/Green，reject→1/Red")
    func writebackRatingAndLabelPlans() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        try addDecision(harness.db, photoId: "p2", decision: "reject")
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
        #expect(rated[0].attributes?.rating == 5)
        #expect(rated[1].attributes?.rating == 1)

        _ = try await harness.service.writeback(sessionId: "session", target: .colorLabel, confirmed: true)
        let labeled = harness.writeback.persistCalls[1]
        #expect(labeled[0].attributes?.label == "Green")
        #expect(labeled[1].attributes?.label == "Red")
    }

    @Test("confirmSync：协调器确认 + 写回项存在时写回确认")
    func confirmSyncDelegates() async throws {
        let harness = try makeHarness()
        harness.writeback.getItemsResult = [
            WritebackItem(id: 1, photoId: "p1", photoPath: "/shoot/p1.jpg", sessionId: "session",
                module: "culling", keywords: [], xmpPath: "/shoot/p1.xmp", backupPath: "",
                xmpStatus: "written", errorMessage: "", attemptCount: 0, lastAttemptAt: "")
        ]

        try await harness.service.confirmSync(sessionId: "session")

        #expect(harness.sync.confirmSyncCalls.map(\.sourceModule) == ["culling"])
        #expect(harness.writeback.confirmSyncCalls.map(\.module) == ["culling"])
    }

    @Test("confirmSync 无写回项时只确认协调器")
    func confirmSyncWithoutWritebackItems() async throws {
        let harness = try makeHarness()
        try await harness.service.confirmSync(sessionId: "session")
        #expect(harness.sync.confirmSyncCalls.map(\.sourceModule) == ["culling"])
        #expect(harness.writeback.confirmSyncCalls.isEmpty)
    }

    @Test("cleanup 未确认抛 WRITEBACK_CLEANUP_CONFIRM_REQUIRED；确认后合并两路结果")
    func cleanupMergesResults() async throws {
        let harness = try makeHarness()
        await #expect(throws: CullingServiceError.writebackCleanupConfirmRequired) {
            _ = try await harness.service.cleanup(sessionId: "session", confirmed: false)
        }
        harness.sync.cleanupResult = CleanupResult(deletedCount: 2, errors: ["bg-error"])
        harness.writeback.cleanupResult = CleanupResult(deletedCount: 3, errors: ["wb-error"])

        let result = try await harness.service.cleanup(sessionId: "session", confirmed: true)

        #expect(result.deletedCount == 5)
        #expect(result.errors == ["bg-error", "wb-error"])
        #expect(harness.sync.cleanupCalls.map(\.sourceModule) == ["culling"])
        #expect(harness.writeback.cleanupCalls.map(\.module) == ["culling"])
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
        _ = try await harness.service.finalizeSync(sessionId: "session", confirmed: true)
        _ = try await harness.service.retryFailedWriteback(sessionId: "session", confirmed: true)
        #expect(harness.writeback.retryFailedCalls.map(\.module) == ["culling"])
    }

    @Test("syncStatus 委托协调器 getSummary")
    func syncStatusDelegates() async throws {
        let harness = try makeHarness()
        let summary = try harness.service.syncStatus(sessionId: "session")
        #expect(summary.sessionId == "session")
    }
}

// MARK: - 资产分组分页（TS culling-asset-page.test.ts / culling-page.test.ts，
// 真实 SQLite 语义对齐）

@Suite("CullingService 资产分组分页")
struct CullingPaginationTests {
    @Test("RAW/JPEG 变体永不分页，total 计逻辑资产")
    func neverSplitsVariantsAcrossPages() async throws {
        let harness = try makeHarness()
        try addVariantPair(harness.db, assetId: "asset-1")
        try addPhoto(harness.db, id: "single1", filepath: "/shoot/B001.jpg")
        try addPhoto(harness.db, id: "single2", filepath: "/shoot/C001.jpg")

        let first = try await harness.service.listPage(sessionId: "session", scope: .all, limit: 1)
        #expect(first.assets.count == 1)
        #expect(first.assets[0].photo.id == "asset-1-raw")
        #expect(first.assets[0].photo.variantCount == 2)
        #expect(first.assets[0].linkedVariantCount == 2)
        #expect(first.assets[0].photo.variants?.map(\.photoId) == ["asset-1-raw", "asset-1-jpg"])
        #expect(first.nextRowId == 1)
        #expect(first.total == 3)

        let second = try await harness.service.listPage(
            sessionId: "session", scope: .all, afterRowId: Int64(first.nextRowId ?? 0), limit: 1
        )
        #expect(second.assets.map(\.photo.id) == ["single1"])
        let third = try await harness.service.listPage(
            sessionId: "session", scope: .all, afterRowId: Int64(second.nextRowId ?? 0), limit: 1
        )
        #expect(third.assets.map(\.photo.id) == ["single2"])
        let fourth = try await harness.service.listPage(
            sessionId: "session", scope: .all, afterRowId: Int64(third.nextRowId ?? 0), limit: 1
        )
        #expect(fourth.assets.isEmpty)
        #expect(fourth.nextRowId == nil)

        // 走完全部页：3 个逻辑资产、无重复。
        var walked: [String] = []
        var cursor: Int64?
        for _ in 0..<20 {
            let page = try await harness.service.listPage(
                sessionId: "session", scope: .all, afterRowId: cursor, limit: 1
            )
            walked.append(contentsOf: page.assets.map(\.photo.id))
            guard let next = page.nextRowId else { break }
            cursor = Int64(next)
        }
        #expect(walked.count == 3)
        #expect(Set(walked).count == 3)
    }

    @Test("filtered 页只匹配首选 RAW 时资产保持完整")
    func filteredKeepsAssetCompleteWhenRawMatches() async throws {
        let harness = try makeHarness()
        try addVariantPair(harness.db, assetId: "asset-1")
        try addDecision(harness.db, photoId: "asset-1-raw", decision: "keep")

        let page = try await harness.service.listPage(
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
    func excludesAssetWhenOnlyJpegMatches() async throws {
        let harness = try makeHarness()
        try addVariantPair(harness.db, assetId: "asset-1")
        try addPhoto(harness.db, id: "single", filepath: "/shoot/B001.jpg")
        try addDecision(harness.db, photoId: "asset-1-jpg", decision: "keep")
        try addDecision(harness.db, photoId: "single", decision: "keep")

        let page = try await harness.service.listPage(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(pickStates: [.picked])
        )
        #expect(page.assets.map(\.photo.id) == ["single"])
        #expect(page.total == 1)

        // list()（JS 侧首选行过滤）与页视图一致。
        let full = try await harness.service.list(
            sessionId: "session", scope: .filtered, filters: CullingFilters(pickStates: [.picked])
        )
        #expect(full.map(\.photo.id) == ["single"])
    }

    @Test("首选 RAW 匹配时 JPEG 变体仍在页内（游标为组首 rowid）")
    func keepsAssetCompleteWithRawMatch() async throws {
        let harness = try makeHarness()
        // JPEG 先插（rowid 1, pending），RAW 后插（rowid 2, keep）。
        try addVariantPair(harness.db, assetId: "asset-1")
        try addDecision(harness.db, photoId: "asset-1-raw", decision: "keep")

        let page = try await harness.service.listPage(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(pickStates: [.picked])
        )

        #expect(page.assets.count == 1)
        #expect(page.assets[0].photo.variantCount == 2)
        #expect(page.assets[0].photo.variants?.map(\.photoId) == ["asset-1-raw", "asset-1-jpg"])
        // RAW 先插（rowid 1），组首 rowid 即游标。
        #expect(page.nextRowId == 1)
    }

    @Test("similarity_group 页：可解析组 id 下推 SQL 并计数组成员")
    func similarityGroupPagePushdown() async throws {
        let harness = try makeHarness()
        for id in ["p1", "p2"] { try addPhoto(harness.db, id: id) }
        try await addSimilarityResult(harness, memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0), SimilarityMembership(photoId: "p2", groupIndex: 0)])
        let groupId = "\(try await latestResultId(harness)):0"
        let dbgResult = try harness.db.prepare("SELECT id FROM similarity_results").query()
        let dbgMembers = try harness.db.prepare("SELECT result_id, photo_id, group_index FROM similarity_result_members").query()
        let dbgPhotos = try harness.db.prepare("SELECT id, rowid FROM photos").query()
        print("DBG-RESULT: \(dbgResult) MEMBERS: \(dbgMembers) PHOTOS: \(dbgPhotos) GROUPID: \(groupId)")
        let page2 = try await harness.service.listPage(sessionId: "session", scope: CullingScope.similarityGroup, requestedGroupId: groupId)
        print("DBG-PAGE2: \(page2.assets.map { $0.photo.id }) next=\(String(describing: page2.nextRowId))")

        let page = try await harness.service.listPage(
            sessionId: "session", scope: .similarityGroup, requestedGroupId: groupId
        )

        let rows = try harness.db.prepare("SELECT id, rowid FROM photos ORDER BY rowid").query()
        print("DBG-ROWIDS: \(rows)")
        print("DBG-GROUPID: \(groupId)")
        #expect(page.assets.map(\.photo.id) == ["p1", "p2"])
        #expect(page.assets.allSatisfy { $0.similarityGroupId == groupId })
        #expect(page.total == 2)
    }

    @Test("similarity_group 页：不可解析组 id 回退 JS 相似度映射（total 按成员计数）")
    func similarityGroupUnparseableFallback() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try await addSimilarityResult(harness, memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0), SimilarityMembership(photoId: "p2", groupIndex: 0)])

        let page = try await harness.service.listPage(
            sessionId: "session", scope: .similarityGroup, requestedGroupId: "stale-group-id"
        )
        #expect(page.assets.isEmpty)
        #expect(page.total == 0)
    }

    @Test("预计算阈值层被最新结果谓词排除（stats_json 标记）")
    func excludesPrecomputedTiers() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        _ = try await harness.similarityStore.replaceResult(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"totalGroups\":1}", threshold: 10, minGroupSize: 2,
            memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0), SimilarityMembership(photoId: "p2", groupIndex: 0)]
        )
        // 阈值层后插：裸 MAX(id) 会选中它；谓词必须回退到主分析行成员。
        _ = try await harness.similarityStore.replaceResultForThreshold(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"totalGroups\":1,\"precomputed\":true}", threshold: 6, minGroupSize: 2,
            memberships: [SimilarityMembership(photoId: "p2", groupIndex: 0)]
        )

        let page = try await harness.service.listPage(sessionId: "session", scope: .similarityGroup)

        #expect(page.assets.map(\.photo.id) == ["p1", "p2"])
        #expect(page.total == 2)
    }

    @Test("quality 过滤器：损坏 result_json 行被跳过而不是让整页查询失败")
    func qualityFilterJsonGuard() async throws {
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

        let analysed = try await harness.service.listPage(
            sessionId: "session", scope: .filtered, filters: CullingFilters(qualityStatus: .analysed)
        )
        let ids = analysed.assets.map(\.photo.id)
        #expect(ids.contains("mixed"))
        #expect(ids.contains("good"))
        #expect(!ids.contains("bad"))
        #expect(analysed.total == 2)

        // 只有损坏行的照片也不算 failed，且查询不抛错。
        let failed = try await harness.service.listPage(
            sessionId: "session", scope: .filtered, filters: CullingFilters(qualityStatus: .failed)
        )
        #expect(failed.assets.isEmpty)

        // unanalysed：只有损坏行的照片计入。
        let unanalysed = try await harness.service.listPage(
            sessionId: "session", scope: .filtered, filters: CullingFilters(qualityStatus: .unanalysed)
        )
        #expect(unanalysed.assets.map(\.photo.id) == ["bad"])
        #expect(unanalysed.total == 1)
    }

    @Test("list() 全量装配：metadata JSON 解析 + session 级富化")
    func listAssemblesFullRows() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1", filepath: "/shoot/a.jpg")
        _ = try harness.db.prepare(
            "UPDATE photos SET metadata = '{\"make\":\"Nikon\"}' WHERE id = 'p1'"
        ).run()

        let assets = try await harness.service.list(sessionId: "session", scope: .all)

        #expect(assets.count == 1)
        #expect(assets[0].photo.id == "p1")
        #expect(assets[0].photo.metadata["make"] == .string("Nikon"))
        #expect(assets[0].state.pickState == .unreviewed)
        #expect(assets[0].syncStatus == .clean)
        #expect(assets[0].linkedVariantCount == 1)
    }

    @Test("list() filtered 经 matchesFilters 过滤；metadataConflictOnly 只在 JS 层应用")
    func listFilteredScope() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1", filepath: "/shoot/a.jpg")
        try addDecision(harness.db, photoId: "p1", decision: "keep", rating: 5)
        try await harness.metadataStore.updateLabel(photoId: "p1", label: "Red")

        let kept = try await harness.service.list(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(ratings: [5], pickStates: [.picked])
        )
        #expect(kept.count == 1)
        #expect(kept[0].state.rating == 5)

        let excluded = try await harness.service.list(
            sessionId: "session", scope: .filtered, filters: CullingFilters(ratings: [3])
        )
        #expect(excluded.isEmpty)
    }

    @Test("listPage 参数校验：afterRowId 非正 / limit 越界抛逐字 IPC 消息")
    func listPageValidation() async throws {
        let harness = try makeHarness()
        await #expect(throws: CullingServiceError.afterRowIdInvalid) {
            _ = try await harness.service.listPage(sessionId: "session", scope: .all, afterRowId: 0)
        }
        await #expect(throws: CullingServiceError.pageLimitInvalid) {
            _ = try await harness.service.listPage(sessionId: "session", scope: .all, limit: 2001)
        }
        #expect(CullingServiceError.afterRowIdInvalid.description == "afterRowId must be a positive integer")
        #expect(CullingServiceError.pageLimitInvalid.description == "limit must be an integer between 1 and 2000")
    }
}

// MARK: - 资产富化细节

@Suite("CullingService 资产富化")
struct CullingEnrichmentTests {
    @Test("面孔归一化：归一化 bbox 保留，预览像素坐标换算并 clamp，按面积降序")
    func faceNormalization() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1", width: 200, height: 100)
        _ = try harness.db.prepare("""
            INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h,
              embedding, confidence, source_file_size, source_file_mtime_ms, analysis_signature, created_at)
            VALUES (?, 'session', ?, ?, ?, ?, X'00', 0.9, 0, 0, ?, '2026-01-01T00:00:00.000Z')
          """).run([
            .text("p1"), .real(0.1), .real(0.2), .real(0.3), .real(0.4),
            .text(#"{"previewMaxDimension":100}"#),
        ])
        _ = try harness.db.prepare("""
            INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h,
              embedding, confidence, source_file_size, source_file_mtime_ms, analysis_signature, created_at)
            VALUES (?, 'session', ?, ?, ?, ?, X'00', 0.9, 0, 0, '', '2026-01-01T00:00:00.000Z')
          """).run([
            // 旧库预览像素坐标：analysisWidth=100 → x/100, y/50。
            .text("p1"), .real(50), .real(25), .real(100), .real(50),
        ])

        let assets = try await harness.service.list(sessionId: "session", scope: .all)

        #expect(assets[0].photo.faceCount == 2)
        let faces = assets[0].faceBboxes
        #expect(faces.count == 2)
        // 面积降序：像素版面积 0.5*1.0=0.5 最大在前；clamp 到 1。
        #expect(faces[0] == [0.5, 0.5, 1.0, 1.0])
        #expect(faces[1] == [0.1, 0.2, 0.3, 0.4])
    }

    @Test("质量相对排名：同组成功质量按分数降序 1 起排名")
    func qualityRelativeRank() async throws {
        let harness = try makeHarness()
        try insertAssetFile(harness.db, id: "af-1", normalizedPath: "/shoot/p1.jpg")
        try insertAssetFile(harness.db, id: "af-2", normalizedPath: "/shoot/p2.jpg")
        try addPhoto(harness.db, id: "p1", assetFileId: "af-1")
        try addPhoto(harness.db, id: "p2", assetFileId: "af-2")
        try await addSimilarityResult(harness, memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0), SimilarityMembership(photoId: "p2", groupIndex: 0)])
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

        let assets = try await harness.service.list(sessionId: "session", scope: .all)
        let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.photo.id, $0) })
        #expect(byId["p2"]?.quality?.relativeRank == 1)
        #expect(byId["p1"]?.quality?.relativeRank == 2)
        #expect(byId["p1"]?.similarityGroupId == "\(try await latestResultId(harness)):0")
    }

    @Test("metadataSource 从 outbox patch 解析；conflict 状态驱动 metadataConflictOnly 过滤")
    func metadataSourceAndConflictFilter() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        _ = try harness.db.prepare("""
            INSERT INTO metadata_outbox (xmp_path, owner_session_id, created_by_session_id, photo_path,
              patch_json, dirty_fields, source_module, revision, persisted_revision,
              base_fingerprint, base_values_json, backup_path, status, attempt_count,
              error_message, updated_at)
            VALUES ('/shoot/p1.xmp', 'session', 'session', '/shoot/p1.jpg',
              '{"rating":5,"source":"face-keyword"}', '["rating"]', 'face-keyword',
              1, 0, '', '{}', '', 'conflict', 0, '', '2026-01-01T00:00:00.000Z')
          """).run()
        _ = try harness.db.prepare("""
            INSERT INTO metadata_outbox_sessions (xmp_path, session_id, confirmed_at, linked_at)
            VALUES ('/shoot/p1.xmp', 'session', '', '2026-01-01T00:00:00.000Z')
          """).run()

        let assets = try await harness.service.list(sessionId: "session", scope: .all)
        #expect(assets[0].metadataSource == .faceKeyword)
        #expect(assets[0].syncStatus == .conflict)

        // metadataConflictOnly 只在 JS 层应用（SQL 无此下推）。
        let conflicts = try await harness.service.list(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(metadataConflictOnly: true)
        )
        #expect(conflicts.map(\.photo.id) == ["p1"])
        let all = try await harness.service.list(
            sessionId: "session", scope: .filtered,
            filters: CullingFilters(metadataConflictOnly: false)
        )
        #expect(all.map(\.photo.id) == ["p1", "p2"])
    }

    @Test("invalidateSessionLookup 使缓存失效：后台分析后再次 list 读到新数据")
    func invalidateSessionLookup() async throws {
        let harness = try makeHarness()
        try addPhoto(harness.db, id: "p1")
        _ = try await harness.service.list(sessionId: "session", scope: .all)
        // 模拟后台人脸分析写入后失效缓存。
        _ = try harness.db.prepare("""
            INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h,
              embedding, confidence, source_file_size, source_file_mtime_ms, analysis_signature, created_at)
            VALUES ('p1', 'session', 0, 0, 1, 1, X'00', 0.9, 0, 0, '', '2026-01-01T00:00:00.000Z')
          """).run()
        harness.service.invalidateSessionLookup(sessionId: "session")
        let assets = try await harness.service.list(sessionId: "session", scope: .all)
        #expect(assets[0].photo.faceCount == 1)
    }
}