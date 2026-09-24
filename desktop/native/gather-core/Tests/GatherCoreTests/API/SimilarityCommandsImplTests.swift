// Tests/GatherCoreTests/API/SimilarityCommandsImplTests.swift
// R5：similarity 域命令实现直测（批次 B5）。10 个方法各自覆盖正常路径与至少
// 一个错误/门控路径：
// - analyze：显式参数作业形状 / 设置缺省只参与校验 / 校验拒绝不建作业；
// - cancel_analysis：排队作业取消 / 未知会话静默；
// - recluster：设置缺省重聚类 / 无结果 / 小数阈值拒绝；
// - result：命中 / 无结果 nil / 损坏 stats 抛错；
// - preview_writeback：关键词归一化落 pending / 空 assignments 与空关键词拒绝 /
//   无结果两种码 / 组不在会话；
// - writeback：执行 pending 条目 / 确认与 itemIds 门控 / 阈值无结果 / 预览过期；
// - writeback_items：模块投影 / 未知会话为空；
// - retry_failed_writeback：确认门控 / 无失败项；
// - confirm_sync：会话转 done / 失败项挂起；
// - cleanup：确认门控 / 无 synced 行拒绝 / 干净会话空结果；
// - 错误码字符串与 gatherCode 逐字对齐旧分支。
// 基座：真实迁移库 + SQLite Store + SimilarityRuntime + WritebackRuntime
// （写回协调器 skipReloadAck 打开，与 Runtime 直测同形）。
import Foundation
import Testing
@testable import GatherCore

// MARK: - 替身

/// MetadataMutationPort 替身：按 photoId 查 filepath，复刻 queuePhotoValues 的
/// mergePatch 语义（source 注入 + dirty 过滤），与 Runtime 直测同形。
private struct SimCommandsMutationPort: MetadataMutationPort {
    let db: SQLiteDatabase
    let outbox: SQLiteWritebackStore

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) async throws -> MetadataMutationResult {
        let row = try await db.queryOne(
            "SELECT filepath FROM photos WHERE id = ? AND session_id = ?",
            [.text(photoId), .text(sessionId)])
        let photoPath = row?.text(at: 0) ?? photoId
        let xmpPath = TSPath.xmpSidecarPath(photoPath)
        let dirtyFields = values.keys
            .filter { ["rating", "label", "keywords"].contains($0) }
            .compactMap { MetadataField(rawValue: $0) }
        var patch = values
        patch["source"] = .string(source.rawValue)
        let merged = try await outbox.mergeOutboxPatch(
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

    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        try await queuePhotoValues(
            sessionId: sessionId, photoId: photoId, values: [:], source: source, schedule: false)
    }
}

// MARK: - 基座

private struct SimCommandsHarness {
    let impl: SimilarityCommandsImpl
    let jobs: JobRunner
    let runtime: SimilarityRuntime
    let writeback: WritebackRuntime
    let similarityStore: SQLiteSimilarityStore
    let writebackStore: any WritebackStore
    let sessionStore: any SessionStore
    let db: SQLiteDatabase
    let sessionId: String
    let photoId: String
    let photoPath: String
    let dbPath: String
    let dir: String

    func cleanup() {
        removeStoreFiles(dbPath)
        try? FileManager.default.removeItem(atPath: dir)
    }
}

private func makeSimCommandsHarness(
    settings: [String: String] = [:]
) async throws -> SimCommandsHarness {
    let dbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-sim-cmd-\(UUID().uuidString).sqlite").path
    let db = try await makeMigratedStore(path: dbPath)
    let sessionStore = SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath))
    let session = try await sessionStore.create(
        name: "Sim Commands", source: "folder", sourcePath: "", truncatedImport: false)
    let dir = try makeTempDir()
    let photoPath = try writeTempFile(in: dir, name: "photo-a.jpg")
    let secondPhotoPath = try writeTempFile(in: dir, name: "photo-b.jpg")
    try await insertPhoto(db, id: "p1", sessionId: session.id, filepath: photoPath)
    try await insertPhoto(db, id: "p2", sessionId: session.id, filepath: secondPhotoPath)

    let similarityStore = SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath))
    let runtime = SimilarityRuntime(
        dependencies: SimilarityRuntime.Dependencies(
            photoStore: SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
            sessionStore: sessionStore,
            similarityStore: similarityStore,
            jobStore: SQLiteJobStore(database: try SQLiteDatabase(path: dbPath)),
            getNumber: { key, defaultValue in
                guard let raw = settings[key], let parsed = Double(raw) else { return defaultValue }
                return parsed
            }
        )
    )
    let jobs = JobRunner(jobStore: SQLiteJobStore(database: try SQLiteDatabase(path: dbPath)))
    let xmp = FakeFSXMPProvider()
    let outbox = try SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath))
    let coordinator = MetadataSyncRuntime(
        writebackStore: SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath)),
        xmp: xmp,
        sessionStore: SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
        getNumber: { _, defaultValue in defaultValue },
        skipReloadAck: true
    )
    let writebackStore = try SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath))
    let writeback = WritebackRuntime(
        writebackStore: writebackStore,
        xmp: xmp,
        photoStore: SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
        sessionStore: SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
        metadataSync: coordinator,
        metadataMutations: SimCommandsMutationPort(db: db, outbox: outbox),
        metadataStore: nil,
        assetResolver: nil
    )
    let impl = SimilarityCommandsImpl(
        similarity: runtime,
        jobs: jobs,
        writeback: writeback,
        settings: SettingsSnapshot(values: settings)
    )
    return SimCommandsHarness(
        impl: impl,
        jobs: jobs,
        runtime: runtime,
        writeback: writeback,
        similarityStore: similarityStore,
        writebackStore: writebackStore,
        sessionStore: sessionStore,
        db: db,
        sessionId: session.id,
        photoId: "p1",
        photoPath: photoPath,
        dbPath: dbPath,
        dir: dir
    )
}

// MARK: - fixture / 等待

private func simCommandsSeedResult(
    _ harness: SimCommandsHarness,
    groupsJson: String,
    statsJson: String = #"{"totalGroups":1,"totalUngrouped":0,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#,
    threshold: Int = 10,
    minGroupSize: Int = 2,
    memberships: [SimilarityMembership] = []
) async throws {
    _ = try await harness.similarityStore.replaceResult(
        sessionId: harness.sessionId,
        groupsJson: groupsJson,
        statsJson: statsJson,
        threshold: threshold,
        minGroupSize: minGroupSize,
        memberships: memberships
    )
}

private func simCommandsGroupsJson(paths: [String]) -> String {
    let images = paths.map { "{\"path\":\"\($0)\",\"representative\":true}" }
        .joined(separator: ",")
    return "{\"groups\":[{\"id\":1,\"label\":\"Group 1\",\"count\":\(paths.count),\"images\":["
        + images + "]}],\"ungrouped\":[]}"
}

private func simCommandsWaitForJob(
    _ jobs: JobRunner,
    scopeId: String,
    status: AnalysisJobStatus,
    timeoutMs: Double = 5_000
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutMs / 1000)
    while Date() < deadline {
        let rows = (try? await jobs.list()) ?? []
        if rows.contains(where: { $0.scopeId == scopeId && $0.status == status }) {
            return true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}

// MARK: - 用例

@Suite("API/SimilarityCommandsImpl (R5)")
struct SimilarityCommandsImplTests {
    @Test("analyze creates the similarity job with explicit params and awaits it")
    func analyzeCreatesJobWithExplicitParams() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }
        await harness.jobs.registerExecutor(type: .similarityAnalyze) { _, _ in true }
        _ = await harness.jobs.start()

        try await harness.impl.analyze(SimAnalyzeParams(
            sessionId: harness.sessionId,
            threshold: 12,
            minGroupSize: 3,
            groupingMode: .sequential))

        let jobs = try await harness.jobs.list()
        #expect(jobs.count == 1)
        let job = try #require(jobs.first)
        #expect(job.type == .similarityAnalyze)
        #expect(job.scopeType == "session")
        #expect(job.scopeId == harness.sessionId)
        #expect(job.dedupeKey == "similarity.analyze:\(harness.sessionId):12.0:3.0:sequential")
        #expect(job.checkpoint["threshold"] == .number(12))
        #expect(job.checkpoint["minGroupSize"] == .number(3))
        #expect(job.checkpoint["groupingMode"] == .string("sequential"))
        #expect(job.status == .succeeded)
    }

    @Test("analyze keeps settings defaults out of the dedupe key")
    func analyzeUsesSettingsDefaultsOnlyForValidation() async throws {
        let harness = try await makeSimCommandsHarness(
            settings: ["default_threshold": "12", "default_min_group_size": "3"])
        defer { harness.cleanup() }
        await harness.jobs.registerExecutor(type: .similarityAnalyze) { _, _ in true }
        _ = await harness.jobs.start()

        try await harness.impl.analyze(SimAnalyzeParams(sessionId: harness.sessionId))

        let jobs = try await harness.jobs.list()
        let job = try #require(jobs.first)
        #expect(job.dedupeKey == "similarity.analyze:\(harness.sessionId):default:default:global")
        #expect(job.checkpoint["threshold"] == JSONValue.null)
        #expect(job.checkpoint["minGroupSize"] == JSONValue.null)
        #expect(job.checkpoint["groupingMode"] == .string("global"))
    }

    @Test("analyze rejects invalid settings defaults before creating a job")
    func analyzeRejectsInvalidSettingsDefaults() async throws {
        let harness = try await makeSimCommandsHarness(settings: ["default_threshold": "65"])
        defer { harness.cleanup() }

        await #expect(throws: SimilarityError.thresholdInvalid) {
            try await harness.impl.analyze(SimAnalyzeParams(sessionId: harness.sessionId))
        }
        let jobs = try await harness.jobs.list()
        #expect(jobs.isEmpty)
    }

    @Test("cancel_analysis cancels the scoped queued job without touching the session")
    func cancelAnalysisCancelsQueuedJob() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }
        // P0-3：create 前置要求 executor 已注册（未注册即抛
        // executorNotRegistered），本用例只验证排队作业的取消，故注册 stub。
        await harness.jobs.registerExecutor(type: .similarityAnalyze) { _, _ in true }
        _ = try await harness.jobs.create(JobCreateParams(
            type: .similarityAnalyze,
            scopeType: "session",
            scopeId: harness.sessionId,
            dedupeKey: "similarity.analyze:\(harness.sessionId):default:default:global"))

        try await harness.impl.cancelAnalysis(SimCancelAnalysisParams(sessionId: harness.sessionId))

        #expect(await simCommandsWaitForJob(
            harness.jobs, scopeId: harness.sessionId, status: .cancelled))
        let session = try await harness.sessionStore.get(id: harness.sessionId)
        #expect(session?.analysisStatus == "idle")
    }

    @Test("cancel_analysis is silent for unknown sessions")
    func cancelAnalysisIsSilentForUnknownSession() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        try await harness.impl.cancelAnalysis(SimCancelAnalysisParams(sessionId: "ghost"))

        let jobs = try await harness.jobs.list()
        #expect(jobs.isEmpty)
    }

    @Test("recluster resolves settings defaults and stores the new result")
    func reclusterUsesSettingsDefaults() async throws {
        let harness = try await makeSimCommandsHarness(settings: ["default_threshold": "6"])
        defer { harness.cleanup() }
        try await simCommandsSeedResult(harness, groupsJson: #"{"groups":[],"ungrouped":[]}"#)
        let hash = String(repeating: "0", count: 16)
        try await harness.similarityStore.upsertHashes(sessionId: harness.sessionId, hashes: [
            SimilarityHashUpsert(photoId: "p1", hashHex: hash, fileSize: 0, fileMtimeMs: 0),
            SimilarityHashUpsert(photoId: "p2", hashHex: hash, fileSize: 0, fileMtimeMs: 0),
        ])

        let result = try await harness.impl.recluster(SimReclusterParams(sessionId: harness.sessionId))

        #expect(result.stats.threshold == 6)
        #expect(result.stats.groupingMode == SimilarityGroupingMode.global)
        #expect(result.groups.count == 1)
        #expect(result.groups.first?.images.count == 2)
    }

    @Test("recluster throws noResults without a stored result")
    func reclusterWithoutResultsThrows() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        await #expect(throws: SimilarityError.noResults) {
            _ = try await harness.impl.recluster(SimReclusterParams(
                sessionId: harness.sessionId, threshold: 10, minGroupSize: 2))
        }
    }

    @Test("recluster rejects fractional thresholds before store access")
    func reclusterRejectsFractionalThreshold() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }
        try await simCommandsSeedResult(harness, groupsJson: #"{"groups":[],"ungrouped":[]}"#)

        await #expect(throws: SimilarityError.thresholdInvalid) {
            _ = try await harness.impl.recluster(SimReclusterParams(
                sessionId: harness.sessionId, threshold: 10.5, minGroupSize: 2))
        }
    }

    @Test("result returns the stored result and nil when missing")
    func resultReturnsStoredResult() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        let empty = try await harness.impl.result(SimResultParams(sessionId: harness.sessionId))
        #expect(empty == nil)

        try await simCommandsSeedResult(
            harness, groupsJson: simCommandsGroupsJson(paths: [harness.photoPath]))
        let result = try await harness.impl.result(SimResultParams(sessionId: harness.sessionId))
        #expect(result?.groups.first?.images.map { $0.path } == [harness.photoPath])
        #expect(result?.stats.threshold == 10)
        #expect(result?.ungrouped.isEmpty == true)

        let ghost = try await harness.impl.result(SimResultParams(sessionId: "ghost"))
        #expect(ghost == nil)
    }

    @Test("result throws on corrupt stored stats")
    func resultThrowsOnCorruptStats() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }
        _ = try await harness.similarityStore.replaceResult(
            sessionId: harness.sessionId,
            groupsJson: #"{"groups":[]}"#,
            statsJson: "NOT VALID JSON",
            threshold: 10,
            minGroupSize: 2,
            memberships: []
        )

        await #expect(throws: (any Error).self) {
            _ = try await harness.impl.result(SimResultParams(sessionId: harness.sessionId))
        }
    }

    @Test("preview_writeback normalizes keywords and persists pending rows")
    func previewWritebackMergesKeywords() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }
        try await simCommandsSeedResult(
            harness, groupsJson: simCommandsGroupsJson(paths: [harness.photoPath]))

        let preview = try await harness.impl.previewWriteback(SimPreviewWritebackParams(
            sessionId: harness.sessionId,
            assignments: [SimilarityKeywordAssignment(
                groupId: 1, keywords: [" groupA ", "", "groupA", "portrait"])]
        ))

        #expect(preview.totalCount == 1)
        #expect(preview.affectedPhotos == 1)
        #expect(preview.items.count == 1)
        #expect(preview.items.first?.photoId == "p1")
        #expect(preview.items.first?.keywords == ["groupA", "portrait"])

        let items = try await harness.impl.writebackItems(
            SimWritebackItemsParams(sessionId: harness.sessionId))
        #expect(items.first(where: { $0.photoId == "p1" })?.xmpStatus == "pending")
    }

    @Test("preview_writeback rejects empty assignments")
    func previewWritebackRejectsEmptyAssignments() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        await #expect(throws: SimilarityCommandsError.writebackEmpty) {
            _ = try await harness.impl.previewWriteback(SimPreviewWritebackParams(
                sessionId: harness.sessionId, assignments: []))
        }
    }

    @Test("preview_writeback rejects assignments without keywords")
    func previewWritebackRejectsEmptyKeywords() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        await #expect(throws: SimilarityCommandsError.writebackInvalidItem) {
            _ = try await harness.impl.previewWriteback(SimPreviewWritebackParams(
                sessionId: harness.sessionId,
                assignments: [SimilarityKeywordAssignment(groupId: 1, keywords: ["  ", ""])]
            ))
        }
    }

    @Test("preview_writeback distinguishes missing analysis from missing threshold tier")
    func previewWritebackWithoutResult() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }
        let assignment = SimilarityKeywordAssignment(groupId: 1, keywords: ["portrait"])

        await #expect(throws: SimilarityCommandsError.analysisMissing) {
            _ = try await harness.impl.previewWriteback(SimPreviewWritebackParams(
                sessionId: harness.sessionId, assignments: [assignment]))
        }
        await #expect(throws: SimilarityCommandsError.thresholdNoResults) {
            _ = try await harness.impl.previewWriteback(SimPreviewWritebackParams(
                sessionId: harness.sessionId, assignments: [assignment], threshold: 12))
        }
    }

    @Test("preview_writeback rejects groups outside the analysis result")
    func previewWritebackRejectsMissingGroup() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }
        try await simCommandsSeedResult(
            harness, groupsJson: simCommandsGroupsJson(paths: [harness.photoPath]))

        await #expect(throws: WritebackPlannerError.groupNotInSession) {
            _ = try await harness.impl.previewWriteback(SimPreviewWritebackParams(
                sessionId: harness.sessionId,
                assignments: [SimilarityKeywordAssignment(groupId: 99, keywords: ["portrait"])]
            ))
        }
    }

    @Test("writeback executes the pending items selected by itemIds")
    func writebackExecutesPendingItems() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }
        _ = try await harness.writeback.preview(
            sessionId: harness.sessionId, module: "similarity", photoIds: ["p1"])
        let pending = try await harness.impl.writebackItems(
            SimWritebackItemsParams(sessionId: harness.sessionId))
        let target = try #require(pending.first(where: { $0.photoId == "p1" }))
        let itemId = try #require(target.id)

        let result = try await harness.impl.writeback(SimWritebackParams(
            sessionId: harness.sessionId, itemIds: [itemId], confirmed: true))

        #expect(result.written == 1)
        #expect(result.failed == 0)
        #expect(result.errors.isEmpty)
        let after = try await harness.impl.writebackItems(
            SimWritebackItemsParams(sessionId: harness.sessionId))
        #expect(after.first(where: { $0.photoId == "p1" })?.xmpStatus == "written")
    }

    @Test("writeback gates confirmation, empty itemIds and threshold tiers")
    func writebackGates() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        await #expect(throws: SimilarityCommandsError.writebackConfirmRequired) {
            _ = try await harness.impl.writeback(SimWritebackParams(
                sessionId: harness.sessionId, itemIds: [1], confirmed: false))
        }
        await #expect(throws: SimilarityCommandsError.previewRequired) {
            _ = try await harness.impl.writeback(SimWritebackParams(
                sessionId: harness.sessionId, itemIds: [], confirmed: true))
        }
        await #expect(throws: SimilarityCommandsError.thresholdNoResults) {
            _ = try await harness.impl.writeback(SimWritebackParams(
                sessionId: harness.sessionId, itemIds: [1], confirmed: true, threshold: 12))
        }
    }

    @Test("writeback rejects itemIds that no longer match the pending preview")
    func writebackRejectsStalePreview() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }
        _ = try await harness.writeback.preview(
            sessionId: harness.sessionId, module: "similarity", photoIds: ["p1"])

        await #expect(throws: SimilarityCommandsError.previewStale) {
            _ = try await harness.impl.writeback(SimWritebackParams(
                sessionId: harness.sessionId, itemIds: [999_999], confirmed: true))
        }
    }

    @Test("writeback_items projects module rows and stays empty for unknown sessions")
    func writebackItemsProjection() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        let ghost = try await harness.impl.writebackItems(
            SimWritebackItemsParams(sessionId: "ghost"))
        #expect(ghost.isEmpty)

        _ = try await harness.writeback.preview(
            sessionId: harness.sessionId, module: "similarity", photoIds: ["p1"])
        let items = try await harness.impl.writebackItems(
            SimWritebackItemsParams(sessionId: harness.sessionId))
        #expect(items.count == 1)
        #expect(items.first?.photoId == "p1")
        #expect(items.first?.module == "similarity")
    }

    @Test("retry_failed_writeback requires confirmation")
    func retryFailedWritebackRequiresConfirmation() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        await #expect(throws: SimilarityCommandsError.retryConfirmRequired) {
            _ = try await harness.impl.retryFailedWriteback(SimRetryFailedWritebackParams(
                sessionId: harness.sessionId, confirmed: false))
        }
    }

    @Test("retry_failed_writeback reports an empty retry set")
    func retryFailedWritebackWithoutFailures() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        let result = try await harness.impl.retryFailedWriteback(
            SimRetryFailedWritebackParams(sessionId: harness.sessionId, confirmed: true))

        #expect(result.totalAffected == 0)
        #expect(result.written == 0)
        #expect(result.failed == 0)
        #expect(result.report == "No failed items to retry")
    }

    @Test("confirm_sync marks the session done and refuses pending failures")
    func confirmSyncMarksSessionAndRejectsFailures() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        try await harness.impl.confirmSync(SimConfirmSyncParams(sessionId: harness.sessionId))
        let session = try await harness.sessionStore.get(id: harness.sessionId)
        #expect(session?.writebackStatus == "done")

        _ = try await harness.writeback.preview(
            sessionId: harness.sessionId, module: "similarity", photoIds: ["p1"])
        let rows = try await harness.writeback.getItems(
            sessionId: harness.sessionId, module: "similarity")
        let row = try #require(rows.first(where: { $0.photoId == "p1" }))
        let itemId = try #require(row.id)
        try await harness.writebackStore.updateWritebackStatus(
            itemId: Int64(itemId), status: "failed", error: "boom")

        await #expect(throws: WritebackRuntimeError.failuresPending) {
            try await harness.impl.confirmSync(SimConfirmSyncParams(sessionId: harness.sessionId))
        }
    }

    @Test("cleanup gates confirmation and refuses items without synced rows")
    func cleanupGatesAndRefusesUnconfirmedRows() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        await #expect(throws: SimilarityCommandsError.cleanupConfirmRequired) {
            _ = try await harness.impl.cleanup(SimCleanupParams(
                sessionId: harness.sessionId, confirmed: false))
        }

        _ = try await harness.writeback.preview(
            sessionId: harness.sessionId, module: "similarity", photoIds: ["p1"])
        await #expect(throws: WritebackRuntimeError.cleanupRequiresLoaded) {
            _ = try await harness.impl.cleanup(SimCleanupParams(
                sessionId: harness.sessionId, confirmed: true))
        }
    }

    @Test("cleanup returns an empty result for a clean session")
    func cleanupReturnsEmptyResult() async throws {
        let harness = try await makeSimCommandsHarness()
        defer { harness.cleanup() }

        let result = try await harness.impl.cleanup(SimCleanupParams(
            sessionId: harness.sessionId, confirmed: true))

        #expect(result.deletedCount == 0)
        #expect(result.errors.isEmpty)
    }

    @Test("command error codes and descriptions match the legacy strings")
    func errorCodesMatchLegacyStrings() {
        #expect(SimilarityCommandsError.writebackEmpty.description == "SIM_WRITEBACK_EMPTY")
        #expect(SimilarityCommandsError.writebackInvalidItem.description == "SIM_WRITEBACK_INVALID_ITEM")
        #expect(SimilarityCommandsError.analysisMissing.description == "SIM_ANALYSIS_MISSING")
        #expect(SimilarityCommandsError.thresholdNoResults.description == "SIM_THRESHOLD_NO_RESULTS")
        #expect(SimilarityCommandsError.previewRequired.description == "SIM_PREVIEW_REQUIRED")
        #expect(SimilarityCommandsError.previewStale.description == "SIM_PREVIEW_STALE")
        #expect(SimilarityCommandsError.writebackConfirmRequired.description == "WRITEBACK_CONFIRM_REQUIRED")
        #expect(SimilarityCommandsError.retryConfirmRequired.description == "WRITEBACK_RETRY_CONFIRM_REQUIRED")
        #expect(SimilarityCommandsError.cleanupConfirmRequired.description == "WRITEBACK_CLEANUP_CONFIRM_REQUIRED")
        #expect(SimilarityCommandsError.writebackEmpty.gatherCode == .SIM_WRITEBACK_EMPTY)
        #expect(SimilarityCommandsError.writebackInvalidItem.gatherCode == .SIM_WRITEBACK_INVALID_ITEM)
        #expect(SimilarityCommandsError.analysisMissing.gatherCode == .SIM_ANALYSIS_MISSING)
        #expect(SimilarityCommandsError.thresholdNoResults.gatherCode == .SIM_THRESHOLD_NO_RESULTS)
        #expect(SimilarityCommandsError.previewRequired.gatherCode == .SIM_PREVIEW_REQUIRED)
        #expect(SimilarityCommandsError.previewStale.gatherCode == .SIM_PREVIEW_STALE)
        #expect(SimilarityCommandsError.writebackConfirmRequired.gatherCode == .WRITEBACK_CONFIRM_REQUIRED)
        #expect(SimilarityCommandsError.retryConfirmRequired.gatherCode == .WRITEBACK_RETRY_CONFIRM_REQUIRED)
        #expect(SimilarityCommandsError.cleanupConfirmRequired.gatherCode == .WRITEBACK_CLEANUP_CONFIRM_REQUIRED)
    }
}
