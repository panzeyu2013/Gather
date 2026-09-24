// Tests/GatherCoreTests/Runtime/Culling/CullingRuntimeTestSupport.swift
// W2b：CullingLookupLoader / CullingRuntime 测试共享夹具。
// 真实临时 SQLite（StoreMigrator 建表）+ fake 端口（sync/mutation/writeback 记录调用，
// 可选把 outbox 行真实写入以便断言提交后状态回读）；零 XMP / 文件系统依赖。
//
// 命名都带 Culling 前缀，避免与既有测试文件的 file-private 夹具冲突。

import Foundation
import Testing
@testable import GatherCore

// MARK: - Fake 端口

/// TS: metadataSync 替身（schedule / 四命令 / confirm / cleanup 记录调用）。
final class FakeCullingSyncPort: CullingSyncPort {
    var scheduled: [String] = []
    var getSummaryCalls: [String] = []
    var flushCalls: [String] = []
    var retryCalls: [String] = []
    var finalizeCalls: [String] = []
    var confirmSyncCalls: [(sessionId: String, sourceModule: String)] = []
    var cleanupCalls: [(sessionId: String, sourceModule: String)] = []
    var cleanupResult = CleanupResult(deletedCount: 0, errors: [])

    static func summary(_ sessionId: String) -> MetadataSyncSummary {
        MetadataSyncSummary(
            sessionId: sessionId, pending: 0, writing: 0, written: 0,
            failed: 0, conflict: 0, synced: 0, items: []
        )
    }

    func schedule(xmpPath: String) { scheduled.append(xmpPath) }
    func getSummary(sessionId: String) async throws -> MetadataSyncSummary {
        getSummaryCalls.append(sessionId)
        return Self.summary(sessionId)
    }
    func flushSession(sessionId: String) async throws -> MetadataSyncSummary {
        flushCalls.append(sessionId)
        return Self.summary(sessionId)
    }
    func retrySession(sessionId: String) async throws -> MetadataSyncSummary {
        retryCalls.append(sessionId)
        return Self.summary(sessionId)
    }
    func finalizeSession(sessionId: String) async throws -> MetadataSyncSummary {
        finalizeCalls.append(sessionId)
        return Self.summary(sessionId)
    }
    func confirmSync(sessionId: String, sourceModule: String) async throws -> MetadataSyncSummary {
        confirmSyncCalls.append((sessionId, sourceModule))
        return Self.summary(sessionId)
    }
    func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult {
        cleanupCalls.append((sessionId, sourceModule))
        return cleanupResult
    }
}

/// TS: MetadataMutationService 替身（queuePhotoValues 记录；可选真实写 outbox 行）。
/// actor：MetadataMutationPort 是 Sendable，actor 隔离替代锁与检查豁免。
actor FakeCullingMutationPort: MetadataMutationPort {
    struct Queued: Sendable, Equatable {
        let sessionId: String
        let photoId: String
        let values: [String: JSONValue]
        let source: MetadataMutationSource
        let schedule: Bool
    }

    private(set) var queued: [Queued] = []
    private let writebackStore: (any WritebackStore)?
    private let connection: SQLiteDatabase?

    init(writebackStore: (any WritebackStore)? = nil, connection: SQLiteDatabase? = nil) {
        self.writebackStore = writebackStore
        self.connection = connection
    }

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) async throws -> MetadataMutationResult {
        queued.append(Queued(
            sessionId: sessionId, photoId: photoId, values: values, source: source, schedule: schedule
        ))
        var xmpPath = ""
        var photoPath = ""
        if let connection {
            let row = try await connection.queryOne(
                "SELECT filepath FROM photos WHERE id = ?", [.text(photoId)]
            )
            photoPath = row?.text(at: 0) ?? ""
            xmpPath = TSPath.xmpSidecarPath(photoPath)
        }
        if let writebackStore, !xmpPath.isEmpty {
            var patch = values
            patch["source"] = .string(source.rawValue)
            let dirtyFields = values.keys
                .filter { ["rating", "label", "keywords"].contains($0) }
                .compactMap { MetadataField(rawValue: $0) }
            let row = try await writebackStore.mergeOutboxPatch(
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

    /// 便捷断言：最后一次 rating/label 值。
    func lastQueuedValues(photoId: String) -> [String: JSONValue]? {
        queued.last(where: { $0.photoId == photoId })?.values
    }
}

/// TS: WritebackService 替身（culling.ipc.ts 用到的最小面，全部记录调用）。
final class FakeCullingWritebackPort: CullingWritebackPort {
    var previewCalls: [(sessionId: String, module: String, photoIds: Set<String>?)] = []
    var persistCalls: [[WritebackItem]] = []
    var executeCalls: [(sessionId: String, module: String, items: [WritebackItem])] = []
    var retryFailedCalls: [(sessionId: String, module: String)] = []
    var getItemsCalls: [(sessionId: String, module: String)] = []
    var confirmSyncCalls: [(sessionId: String, module: String)] = []
    var cleanupCalls: [(sessionId: String, module: String)] = []
    var previewItems: [WritebackItem] = []
    var getItemsResult: [WritebackItem] = []
    var executeResult = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [],
        failedItems: [], report: "Written: 0, Failed: 0, Skipped: 0"
    )
    var cleanupResult = CleanupResult(deletedCount: 0, errors: [])

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

// MARK: - 并发注入包装（CAS 失败路径的确定性测试）

/// 转发全部 CullingStore 调用，仅在 applyDecisionStates 前执行一次可注入钩子
/// （模拟「预读之后、CAS 之前」的并发写入者），用于确定性覆盖 CAS 失败/回滚分支。
/// actor 隔离使其满足 Store 的 Sendable 约束，测试侧无锁、无检查豁免。
actor RacingCullingStore: CullingStore {
    private let base: any CullingStore
    private var beforeApply: (() async -> Void)?

    init(base: any CullingStore) {
        self.base = base
    }

    /// 设置一次性钩子（在首次 applyDecisionStates 前执行）。
    func setBeforeApplyDecisionStates(_ hook: @escaping () async -> Void) {
        beforeApply = hook
    }

    func decisions(sessionId: String) async throws -> [CullingDecisionLite] {
        try await base.decisions(sessionId: sessionId)
    }
    func decisionsFull(sessionId: String) async throws -> [CullingDecisionRecord] {
        try await base.decisionsFull(sessionId: sessionId)
    }
    func decision(sessionId: String, photoId: String) async throws -> CullingDecisionRecord? {
        try await base.decision(sessionId: sessionId, photoId: photoId)
    }
    func decisions(sessionId: String, photoIds: [String]) async throws -> [CullingDecisionRecord] {
        try await base.decisions(sessionId: sessionId, photoIds: photoIds)
    }
    func upsertDecision(sessionId: String, photoId: String, groupId: String, decision: String) async throws {
        try await base.upsertDecision(sessionId: sessionId, photoId: photoId, groupId: groupId, decision: decision)
    }
    func upsertDecisionState(
        sessionId: String, photoId: String, groupId: String, state: CullingDecisionState
    ) async throws {
        try await base.upsertDecisionState(sessionId: sessionId, photoId: photoId, groupId: groupId, state: state)
    }
    func upsertDecisions(sessionId: String, decisions: [CullingDecisionInput]) async throws {
        try await base.upsertDecisions(sessionId: sessionId, decisions: decisions)
    }
    func decisionsByResultPrefix(sessionId: String, resultId: Int64) async throws -> [CullingDecisionLite] {
        try await base.decisionsByResultPrefix(sessionId: sessionId, resultId: resultId)
    }
    func decisionCountsByResultPrefix(sessionId: String, resultId: Int64) async throws -> [CullingDecisionCount] {
        try await base.decisionCountsByResultPrefix(sessionId: sessionId, resultId: resultId)
    }
    func decisionCounts(sessionId: String) async throws -> [CullingDecisionCount] {
        try await base.decisionCounts(sessionId: sessionId)
    }
    func deleteDecisions(sessionId: String) async throws {
        try await base.deleteDecisions(sessionId: sessionId)
    }
    func deleteDecisions(sessionId: String, groupId: String) async throws {
        try await base.deleteDecisions(sessionId: sessionId, groupId: groupId)
    }
    func restoreDecisions(_ decisions: [CullingRestoreInput]) async throws {
        try await base.restoreDecisions(decisions)
    }
    func applyDecisionStates(
        sessionId: String, writes: [CullingDecisionWrite], expectedRevision: Int
    ) async throws -> Bool {
        let hook = beforeApply
        beforeApply = nil
        if let hook { await hook() }
        return try await base.applyDecisionStates(
            sessionId: sessionId, writes: writes, expectedRevision: expectedRevision)
    }
    func appendHistory(
        sessionId: String, entries: [CullingHistoryEntry]
    ) async throws -> CullingHistoryOperation {
        try await base.appendHistory(sessionId: sessionId, entries: entries)
    }
    func setHistoryUndone(sessionId: String, operationId: Int, undone: Bool) async throws {
        try await base.setHistoryUndone(sessionId: sessionId, operationId: operationId, undone: undone)
    }
    func historyOperation(sessionId: String, operationId: Int) async throws -> CullingHistoryOperation? {
        try await base.historyOperation(sessionId: sessionId, operationId: operationId)
    }
    func historyList(sessionId: String, limit: Int) async throws -> [CullingHistoryOperation] {
        try await base.historyList(sessionId: sessionId, limit: limit)
    }
}

// MARK: - 夹具

struct CullingRuntimeHarness {
    let db: SQLiteDatabase
    let sessionId: String
    let runtime: CullingRuntime
    let cache: CullingSessionCache
    let photoStore: SQLitePhotoStore
    let queryStore: SQLiteCullingQueryStore
    /// 直接构造的 SQLiteCullingStore，或 wrapCullingStore 注入的包装（并发测试）。
    let cullingStore: any CullingStore
    let metadataStore: SQLiteMetadataStore
    let similarityStore: SQLiteSimilarityStore
    let writebackStore: SQLiteWritebackStore
    let faceStore: SQLiteFaceStore
    let personStore: SQLitePersonStore
    let jobStore: SQLiteJobStore
    let sessionStore: SQLiteSessionStore
    let loader: CullingLookupLoader
    let sync: FakeCullingSyncPort
    let mutations: FakeCullingMutationPort
    let writeback: FakeCullingWritebackPort

    func decision(_ photoId: String) async throws -> CullingDecisionRecord? {
        try await cullingStore.decision(sessionId: sessionId, photoId: photoId)
    }
}

/// 建已迁移库 + 会话 + Runtime（真实 Store 单连接 + fake 端口）。
func makeCullingRuntimeHarness(
    writeOutbox: Bool = false,
    history: Bool = true,
    cache: CullingSessionCache = CullingSessionCache(),
    wrapCullingStore: (@Sendable (any CullingStore) -> any CullingStore)? = nil
) async throws -> CullingRuntimeHarness {
    let db = try await makeMigratedStore(path: storeTempPath("culling-runtime"))
    try await insertSession(db, "session")

    let photoStore = SQLitePhotoStore(database: db)
    let similarityStore = SQLiteSimilarityStore(database: db)
    let writebackStore = SQLiteWritebackStore(database: db)
    let metadataStore = SQLiteMetadataStore(database: db)
    let sqliteCullingStore = SQLiteCullingStore(database: db)
    let cullingStore: any CullingStore = wrapCullingStore?(sqliteCullingStore) ?? sqliteCullingStore
    let faceStore = SQLiteFaceStore(database: db)
    let personStore = SQLitePersonStore(database: db)
    let jobStore = SQLiteJobStore(database: db)
    let sessionStore = SQLiteSessionStore(database: db)
    let queryStore = SQLiteCullingQueryStore(database: db, photoStore: photoStore)

    let sync = FakeCullingSyncPort()
    let mutations = FakeCullingMutationPort(
        writebackStore: writeOutbox ? writebackStore : nil,
        connection: writeOutbox ? db : nil
    )
    let writeback = FakeCullingWritebackPort()

    let loader = CullingLookupLoader(
        cullingStore: history ? cullingStore : nil,
        metadataStore: metadataStore,
        writebackStore: writebackStore,
        similarityStore: similarityStore,
        jobStore: jobStore,
        faceStore: faceStore,
        personStore: personStore
    )
    let runtime = CullingRuntime(
        dependencies: CullingRuntime.Dependencies(
            photoStore: photoStore,
            queryStore: queryStore,
            cullingStore: history ? cullingStore : nil,
            metadataStore: metadataStore,
            similarityStore: similarityStore,
            writebackStore: writebackStore,
            sessionStore: sessionStore,
            jobStore: jobStore,
            faceStore: faceStore,
            personStore: personStore,
            metadataSync: sync,
            metadataMutations: mutations,
            writeback: writeback,
            getNumber: { _, defaultValue in defaultValue }
        ),
        cache: cache
    )

    return CullingRuntimeHarness(
        db: db, sessionId: "session", runtime: runtime, cache: cache,
        photoStore: photoStore, queryStore: queryStore, cullingStore: cullingStore,
        metadataStore: metadataStore, similarityStore: similarityStore,
        writebackStore: writebackStore, faceStore: faceStore, personStore: personStore,
        jobStore: jobStore, sessionStore: sessionStore, loader: loader,
        sync: sync, mutations: mutations, writeback: writeback
    )
}

// MARK: - 照片 / 资产

/// 照片行（默认路径按 id 区分，避免 session+filepath 唯一索引冲突）。
@discardableResult
func insertCullingPhoto(
    _ db: SQLiteDatabase,
    id: String,
    sessionId: String = "session",
    filepath: String? = nil,
    assetId: String? = nil,
    assetFileId: String? = nil,
    width: Int = 100,
    height: Int = 100
) async throws -> Int64 {
    let path = filepath ?? "/shoot/\(id).jpg"
    try await db.run(
        """
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
          result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'pending', '{}', '{}', ?, ?, ?, ?,
          '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """,
        [
            .text(id), .text(sessionId), .text(path),
            .text((path as NSString).lastPathComponent),
            assetId.map { .text($0) } ?? .null,
            assetFileId.map { .text($0) } ?? .null,
            .int(Int64(width)), .int(Int64(height)),
        ]
    )
    return try await db.scalarInt("SELECT rowid FROM photos WHERE id = ?", [.text(id)]) ?? 0
}

/// RAW/JPEG 变体对（RAW 行后插入；共享 asset 与 asset_files 外键行）。
func insertCullingVariantPair(
    _ db: SQLiteDatabase,
    assetId: String,
    sessionId: String = "session"
) async throws {
    try await insertAsset(db, id: assetId)
    try await insertAssetFile(db, id: "\(assetId)-raw", normalizedPath: "/shoot/\(assetId).NEF")
    try await insertAssetFile(db, id: "\(assetId)-jpg", normalizedPath: "/shoot/\(assetId).jpg")
    try await insertCullingPhoto(
        db, id: "\(assetId)-raw", sessionId: sessionId,
        filepath: "/shoot/\(assetId).NEF", assetId: assetId, assetFileId: "\(assetId)-raw"
    )
    try await insertCullingPhoto(
        db, id: "\(assetId)-jpg", sessionId: sessionId,
        filepath: "/shoot/\(assetId).jpg", assetId: assetId, assetFileId: "\(assetId)-jpg"
    )
}

// MARK: - 决策 / 相似度 / 分析 / outbox

func insertCullingDecision(
    _ db: SQLiteDatabase,
    photoId: String,
    sessionId: String = "session",
    decision: String = "pending",
    rating: Int64 = 0,
    colorLabel: String = "None",
    revision: Int64 = 0,
    groupId: String = "ungrouped"
) async throws {
    try await db.run(
        """
        INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, rating,
          color_label, decision_source, revision, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 'manual', ?,
          '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """,
        [
            .text(sessionId), .text(photoId), .text(groupId), .text(decision),
            .int(rating), .text(colorLabel), .int(revision),
        ]
    )
}

@discardableResult
func insertCullingSimilarityResult(
    _ harness: CullingRuntimeHarness,
    memberships: [SimilarityMembership],
    groupsJson: String = #"{"groups":[]}"#,
    statsJson: String = #"{"totalGroups":1}"#,
    threshold: Int = 10,
    minGroupSize: Int = 2
) async throws -> Int64 {
    try await harness.similarityStore.replaceResult(
        sessionId: harness.sessionId,
        groupsJson: groupsJson,
        statsJson: statsJson,
        threshold: threshold,
        minGroupSize: minGroupSize,
        memberships: memberships
    )
}

/// asset_analysis 技术质量行（JOIN photos 经 asset_file_id；updated_at 决定首行）。
/// photo_id 有外键（REFERENCES photos(id)），必须是真实照片 id。
func insertCullingQuality(
    _ db: SQLiteDatabase,
    photoId: String,
    assetFileId: String,
    resultJSON: String,
    updatedAt: String = "2026-01-01T00:00:00.000Z",
    analysisType: String = "technical_quality"
) async throws {
    try await db.run(
        """
        INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json,
          input_fingerprint, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', ?)
        """,
        [
            .text(photoId), .text(assetFileId),
            .text(analysisType), .text(resultJSON), .text("fp-\(photoId)-\(updatedAt)"), .text(updatedAt),
        ]
    )
}

func insertCullingFaceObservation(
    _ db: SQLiteDatabase,
    photoId: String,
    sessionId: String = "session",
    x: Double = 0.1,
    y: Double = 0.1,
    w: Double = 0.5,
    h: Double = 0.5,
    signature: String = ""
) async throws {
    try await db.run(
        """
        INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h,
          embedding, confidence, analysis_signature)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0.9, ?)
        """,
        [
            .text(photoId), .text(sessionId), .real(x), .real(y), .real(w), .real(h),
            .blob(Data([0, 0, 0, 0])), .text(signature),
        ]
    )
}

func insertCullingPerson(_ db: SQLiteDatabase, id: String, name: String) async throws {
    try await db.run(
        "INSERT INTO persons (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
        [
            .text(id), .text(name),
            .text("2026-01-01T00:00:00.000Z"), .text("2026-01-01T00:00:00.000Z"),
        ]
    )
}

func linkCullingPerson(
    _ db: SQLiteDatabase,
    personId: String,
    photoId: String,
    sessionId: String = "session"
) async throws {
    try await db.run(
        """
        INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
        VALUES (?, ?, ?, '[]', 0.9, '2026-01-01T00:00:00.000Z')
        """,
        [.text(personId), .text(photoId), .text(sessionId)]
    )
}

/// 元数据缓存行（rating/label/keywords）。
func insertCullingMetadata(
    _ harness: CullingRuntimeHarness,
    photoId: String,
    rating: Int64 = 0,
    label: String? = nil,
    keywords: [String] = []
) async throws {
    try await harness.metadataStore.upsertMetadata(
        photoId: photoId,
        sessionId: harness.sessionId,
        data: MetadataCacheInput(rating: rating, label: label, keywords: keywords)
    )
}

/// outbox 行（mergeOutboxPatch 建行 + 关联会话；status 可选改写）。
@discardableResult
func insertCullingOutbox(
    _ harness: CullingRuntimeHarness,
    photoId: String,
    patch: [String: JSONValue] = ["rating": .number(5)],
    status: String? = nil
) async throws -> OutboxRecord {
    let row = try await harness.db.queryOne("SELECT filepath FROM photos WHERE id = ?", [.text(photoId)])
    let filepath = row?.text(at: 0) ?? ""
    let merged = try await harness.writebackStore.mergeOutboxPatch(
        xmpPath: TSPath.xmpSidecarPath(filepath),
        sessionId: harness.sessionId,
        photoPath: filepath,
        patch: .object(patch),
        dirtyFields: ["rating"]
    )
    guard let status, status != merged.status else { return merged }
    try await harness.writebackStore.markOutboxStatus(
        xmpPath: merged.xmpPath, status: status, errorMessage: ""
    )
    let refreshed = try await harness.writebackStore.outboxEntry(xmpPath: merged.xmpPath)
    return try #require(refreshed)
}

/// WritebackItem 夹具（writeback 命令面断言用）。
func makeCullingWritebackItem(
    id: Int?,
    photoId: String,
    keywords: [String] = []
) -> WritebackItem {
    WritebackItem(
        id: id, photoId: photoId, photoPath: "/shoot/\(photoId).jpg",
        sessionId: "session", module: "culling", keywords: keywords,
        attributes: nil, xmpPath: "/shoot/\(photoId).xmp", backupPath: "",
        xmpStatus: "pending", errorMessage: "", attemptCount: 0, lastAttemptAt: ""
    )
}
