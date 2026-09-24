// Tests/GatherCoreTests/API/FaceCommandsImplTests.swift
// R5：face 域命令实现直测（批次 B6）。14 个方法各自覆盖正常路径与至少一个
// 错误/门控路径：
// - analyze：显式参数作业形状（dedupeKey / checkpoint）/ 设置缺省只参与校验而
//   dedupeKey 走旧硬编码回退 / 非法设置缺省拒绝且不建作业；
// - cancel_analysis：取消排队作业 / 未知会话静默；
// - recluster：设置缺省重聚类并落库 / 非法 eps 拒绝 / 无观察拒绝；
// - clusters：FaceClusterData → FaceCluster 字段与绑定映射 / 未知会话空数组；
// - bind：角色名归一化 + 关键词去重落库 / 空角色名与未知簇错误；
// - unbind：确认门控 FKW_UNBIND_CONFIRM_REQUIRED / 移除关键词与解绑；
// - merge：并入目标簇 / 自合并 FACE_SELF_MERGE；
// - remove_member：移除成员行 / 未知成员 FKW_CLUSTER_MEMBER_NOT_FOUND；
// - preview：FaceKwWritebackPreview → WritebackPreview 映射与 options 下传 /
//   未注入写回 Provider 的真实失败态；
// - writeback：确认门控 WRITEBACK_CONFIRM_REQUIRED / 条目与结果双向映射、nil items；
// - confirm_sync：转发会话 / Provider 缺失失败；
// - confirm_cleanup / cleanup：确认门控 FKW_CLEANUP_CONFIRM_REQUIRED / 结果映射；
// - models_status：设置项路径与缺省路径。
// 基座：真实迁移库 + SQLite Store + FaceKeywordingRuntime + JobRunner；
// 写回 Provider 用 actor 替身（actor 隔离天然满足 Sendable，无需非安全标注）。
import Foundation
import Testing
@testable import GatherCore

// MARK: - 替身

/// 写回 Provider 替身：actor 隔离天然 Sendable；记录入参供断言。
private actor FaceCommandsWritebackStub: FaceWritebackProvider {
    private let removedKeywords: [String]
    private let previewResult: FaceKwWritebackPreview
    private let executeResult: FaceKwWritebackResult
    private let cleanupResult: FaceKwCleanupResult
    private(set) var removedEntries: [FaceKeywordEntry] = []
    private(set) var previewOptions: FaceKwWritebackOptions?
    private(set) var executedItems: [FaceKwWritebackItem] = []
    private(set) var syncedSessionIds: [String] = []
    private(set) var cleanupCalls: [String] = []

    init(
        removedKeywords: [String] = [],
        previewResult: FaceKwWritebackPreview = FaceKwWritebackPreview(
            items: [], totalCount: 0, affectedPhotos: 0),
        executeResult: FaceKwWritebackResult = FaceKwWritebackResult(
            totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [],
            failedItems: [], report: ""),
        cleanupResult: FaceKwCleanupResult = FaceKwCleanupResult(deletedCount: 0, errors: [])
    ) {
        self.removedKeywords = removedKeywords
        self.previewResult = previewResult
        self.executeResult = executeResult
        self.cleanupResult = cleanupResult
    }

    func removeOwnedFaceKeywords(
        sessionId: String, entries: [FaceKeywordEntry]
    ) async throws -> [String] {
        removedEntries = entries
        return removedKeywords
    }

    func preview(
        sessionId: String,
        options: FaceKwWritebackOptions?,
        boundPhotoIds: Set<String>,
        additions: [String: [String]]
    ) async throws -> FaceKwWritebackPreview {
        previewOptions = options
        return previewResult
    }

    func execute(sessionId: String, items: [FaceKwWritebackItem]) async throws -> FaceKwWritebackResult {
        executedItems = items
        return executeResult
    }

    func confirmSync(sessionId: String) async throws {
        syncedSessionIds.append(sessionId)
    }

    func cleanup(sessionId: String) async throws -> FaceKwCleanupResult {
        cleanupCalls.append(sessionId)
        return cleanupResult
    }
}

// MARK: - 基座

private struct FaceCommandsHarness {
    let impl: FaceCommandsImpl
    let jobs: JobRunner
    let faceStore: SQLiteFaceStore
    let db: SQLiteDatabase
    let sessionId: String
    let photoPath: String
    let dbPath: String
    let dir: String

    func cleanup() {
        removeStoreFiles(dbPath)
        try? FileManager.default.removeItem(atPath: dir)
    }
}

private func makeFaceCommandsHarness(
    settings: [String: String] = [:],
    writeback: FaceWritebackProvider? = nil,
    cluster: FaceKeywordingRuntime.FaceClusterProvider? = nil
) async throws -> FaceCommandsHarness {
    let (db, dbPath) = try await makeMigratedStoreDatabase(label: "face-commands")
    let sessionStore = SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath))
    let session = try await sessionStore.create(name: "Face Commands", source: "folder")
    let dir = try makeTempDir()
    let photoPath = try writeTempFile(in: dir, name: "photo-a.jpg")
    try await insertPhoto(db, id: "p1", sessionId: session.id, filepath: photoPath)
    try await insertPhoto(db, id: "p2", sessionId: session.id, filepath: dir + "/photo-b.jpg")

    let faceStore = SQLiteFaceStore(database: try SQLiteDatabase(path: dbPath))
    let runtime = FaceKeywordingRuntime(dependencies: FaceKeywordingRuntime.Dependencies(
        photoStore: SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
        sessionStore: sessionStore,
        faceStore: faceStore,
        personStore: SQLitePersonStore(database: try SQLiteDatabase(path: dbPath)),
        analysisRunStore: SQLiteAnalysisRunStore(database: try SQLiteDatabase(path: dbPath)),
        getNumber: { key, defaultValue in
            guard let raw = settings[key], let parsed = Double(raw) else { return defaultValue }
            return parsed
        },
        clusterProvider: cluster ?? { entries, eps, minPts, onProgress in
            try FaceClusterer.clusterEmbeddings(
                entries: entries, eps: eps, minPts: minPts, onProgress: onProgress)
        },
        writebackProvider: writeback
    ))
    let jobs = JobRunner(jobStore: SQLiteJobStore(database: try SQLiteDatabase(path: dbPath)))
    let impl = FaceCommandsImpl(
        face: runtime,
        jobs: jobs,
        settings: SettingsSnapshot(values: settings)
    )
    return FaceCommandsHarness(
        impl: impl,
        jobs: jobs,
        faceStore: faceStore,
        db: db,
        sessionId: session.id,
        photoPath: photoPath,
        dbPath: dbPath,
        dir: dir
    )
}

/// 建 face_clusters 行 + 成员（成员 id 由 SQLite 自增）。
private func seedFaceCommandCluster(
    _ db: SQLiteDatabase,
    id: Int64,
    sessionId: String,
    label: String = "Person 1",
    status: String = "unbound",
    members: [(photoId: String, bbox: [Double], confidence: Double)] = []
) async throws {
    _ = try await db.run("""
        INSERT INTO face_clusters
         (id, session_id, label, member_count, status, thumbnail_base64, thumbnail_path)
        VALUES (?, ?, ?, ?, ?, '', '')
        """, [.int(id), .text(sessionId), .text(label), .int(Int64(members.count)), .text(status)])
    for member in members {
        let bboxJSON = try JSONValue.stringify(JSONValue.array(member.bbox.map { JSONValue.real($0) }))
        _ = try await db.run("""
            INSERT INTO face_cluster_members
             (cluster_id, session_id, photo_id, bbox, confidence, observation_id)
            VALUES (?, ?, ?, ?, ?, NULL)
            """, [
                .int(id), .text(sessionId), .text(member.photoId),
                .text(bboxJSON), .real(member.confidence),
            ])
    }
}

/// Protocol 侧写回条目 fixture（用于 writeback 入参映射断言）。
private func faceCommandProtocolItem(
    id: Int?,
    dirtyFields: [WritebackDirtyField] = [.keywords]
) -> WritebackItem {
    WritebackItem(
        id: id,
        photoId: "p1",
        photoPath: "/photos/p1.jpg",
        sessionId: "s",
        module: "face_kw",
        keywords: ["Alice"],
        attributes: WritebackAttributes(keywords: ["Alice"], rating: nil, label: "green"),
        xmpPath: "/photos/p1.xmp",
        backupPath: "",
        xmpStatus: "pending",
        errorMessage: "",
        attemptCount: 0,
        lastAttemptAt: "",
        preview: WritebackItemPreview(
            dirtyFields: dirtyFields,
            before: WritebackAttributes(),
            after: WritebackAttributes(keywords: ["Alice"]),
            source: "face_kw",
            sharedPhotoCount: 0,
            externalChanged: false,
            willCreate: true
        )
    )
}

/// 运行时接缝侧写回条目 fixture（用于结果映射断言）。
private func faceCommandRuntimeItem(id: Int64) -> FaceKwWritebackItem {
    FaceKwWritebackItem(
        id: id,
        photoId: "p1",
        photoPath: "/photos/p1.jpg",
        sessionId: "s",
        module: "face_kw",
        keywords: ["Alice"],
        attributes: FaceKwWritebackAttributes(keywords: ["Alice"]),
        xmpPath: "/photos/p1.xmp",
        backupPath: "",
        xmpStatus: "written",
        errorMessage: "",
        attemptCount: 0,
        lastAttemptAt: "",
        preview: FaceKwWritebackPreviewInfo(
            dirtyFields: ["keywords", "rating"],
            before: FaceKwWritebackAttributes(),
            after: FaceKwWritebackAttributes(keywords: ["Alice"]),
            source: "face_kw",
            sharedPhotoCount: 0,
            externalChanged: false,
            willCreate: true
        )
    )
}

// MARK: - 用例

@Suite("API/FaceCommandsImpl (R5)")
struct FaceCommandsImplTests {

    // MARK: analyze

    @Test("analyze creates the face.analyze job and returns the awaited counts")
    func analyzeCreatesJobAndReturnsCounts() async throws {
        let harness = try await makeFaceCommandsHarness(settings: [
            "detector_model_path": "custom/detector.onnx",
            "encoder_model_path": "custom/encoder.onnx",
        ])
        defer { harness.cleanup() }
        await harness.jobs.registerExecutor(type: .faceAnalyze) { _, _ in
            FaceAnalysisResult(status: "done", detectionFailures: 1, encodingFailures: 2)
        }
        _ = await harness.jobs.start()

        let result = try await harness.impl.analyze(FkwAnalyzeParams(
            sessionId: harness.sessionId, eps: 0.5, minSamples: 3))

        #expect(result.status == "done")
        #expect(result.detectionFailures == 1)
        #expect(result.encodingFailures == 2)
        let jobs = try await harness.jobs.list()
        #expect(jobs.count == 1)
        let job = try #require(jobs.first)
        #expect(job.type == .faceAnalyze)
        #expect(job.scopeType == "session")
        #expect(job.scopeId == harness.sessionId)
        #expect(job.dedupeKey
            == "face.analyze:\(harness.sessionId):custom/detector.onnx:custom/encoder.onnx:0.5:3.0")
        #expect(job.checkpoint["detectorPath"] == .string("custom/detector.onnx"))
        #expect(job.checkpoint["encoderPath"] == .string("custom/encoder.onnx"))
        #expect(job.checkpoint["eps"] == .number(0.5))
        #expect(job.checkpoint["minSamples"] == .number(3))
        #expect(job.status == .succeeded)
    }

    @Test("analyze keeps settings defaults out of the dedupe key and checkpoint")
    func analyzeKeepsSettingsDefaultsOutOfDedupeKey() async throws {
        let harness = try await makeFaceCommandsHarness(settings: [
            "default_eps": "0.5",
            "default_min_samples": "2",
        ])
        defer { harness.cleanup() }
        await harness.jobs.registerExecutor(type: .faceAnalyze) { _, _ in
            FaceAnalysisResult(status: "done", detectionFailures: 0, encodingFailures: 0)
        }
        _ = await harness.jobs.start()

        _ = try await harness.impl.analyze(FkwAnalyzeParams(sessionId: harness.sessionId))

        let job = try #require(try await harness.jobs.list().first)
        #expect(job.dedupeKey
            == "face.analyze:\(harness.sessionId):models/face_detector.onnx:models/face_encoder.onnx:0.6:2.0")
        #expect(job.checkpoint["eps"] == JSONValue.null)
        #expect(job.checkpoint["minSamples"] == JSONValue.null)
        #expect(job.checkpoint["detectorPath"] == .string("models/face_detector.onnx"))
        #expect(job.checkpoint["encoderPath"] == .string("models/face_encoder.onnx"))
    }

    @Test("analyze rejects invalid settings defaults before creating a job")
    func analyzeRejectsInvalidSettingsDefaults() async throws {
        let harness = try await makeFaceCommandsHarness(settings: ["default_eps": "1.5"])
        defer { harness.cleanup() }

        await #expect(throws: FaceKwError.epsInvalid) {
            _ = try await harness.impl.analyze(FkwAnalyzeParams(sessionId: harness.sessionId))
        }
        let jobs = try await harness.jobs.list()
        #expect(jobs.isEmpty)
    }

    // MARK: cancel_analysis

    @Test("cancel_analysis cancels the scoped queued job and stays silent for unknown sessions")
    func cancelAnalysisCancelsQueuedJobAndStaysSilent() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }
        await harness.jobs.registerExecutor(type: .faceAnalyze) { _, _ in
            FaceAnalysisResult(status: "done", detectionFailures: 0, encodingFailures: 0)
        }
        // 未 start：create 只入队，cancel 走 queued 终态路径。
        _ = try await harness.jobs.create(JobCreateParams(
            type: .faceAnalyze,
            scopeType: "session",
            scopeId: harness.sessionId,
            dedupeKey: "face.analyze:\(harness.sessionId)"))

        try await harness.impl.cancelAnalysis(
            FkwCancelAnalysisParams(sessionId: harness.sessionId))
        try await harness.impl.cancelAnalysis(FkwCancelAnalysisParams(sessionId: "ghost"))

        let jobs = try await harness.jobs.list()
        #expect(jobs.count == 1)
        #expect(jobs.first?.status == .cancelled)
    }

    // MARK: recluster

    @Test("recluster re-clusters stored observations")
    func reclusterReclustersStoredObservations() async throws {
        let harness = try await makeFaceCommandsHarness(cluster: { entries, _, _, _ in
            FaceClusterResult(clusters: [entries], noise: [])
        })
        defer { harness.cleanup() }
        _ = try await harness.faceStore.saveObservations(
            sessionId: harness.sessionId,
            observations: [
                FaceObservationInput(
                    photoId: "p1", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4,
                    embedding: [0.1, 0.2], confidence: 0.9),
                FaceObservationInput(
                    photoId: "p2", bboxX: 5, bboxY: 6, bboxW: 7, bboxH: 8,
                    embedding: [0.3, 0.4], confidence: 0.8),
            ])

        try await harness.impl.recluster(
            sessionId: harness.sessionId, eps: 0.6, minSamples: 2)

        let clusters = try await harness.faceStore.clusters(
            sessionId: harness.sessionId, includeMembers: true)
        #expect(clusters.count == 1)
        #expect(clusters.first?.memberCount == 2)
    }

    @Test("recluster rejects invalid settings defaults")
    func reclusterRejectsInvalidSettingsDefaults() async throws {
        let harness = try await makeFaceCommandsHarness(settings: ["default_eps": "1.5"])
        defer { harness.cleanup() }

        await #expect(throws: FaceKwError.epsInvalid) {
            try await harness.impl.recluster(sessionId: harness.sessionId, eps: nil, minSamples: nil)
        }
    }

    @Test("recluster requires stored observations")
    func reclusterRequiresStoredObservations() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }

        await #expect(throws: FaceKwError.noObservations) {
            try await harness.impl.recluster(sessionId: harness.sessionId, eps: 0.6, minSamples: 2)
        }
    }

    // MARK: clusters

    @Test("clusters maps FaceClusterData into the protocol FaceCluster shape")
    func clustersMapsProtocolShape() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }
        try await seedFaceCommandCluster(
            harness.db, id: 1, sessionId: harness.sessionId,
            members: [(photoId: "p1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try await harness.faceStore.updateBinding(
            clusterId: 1, roleName: "Alice", keywords: ["kw1"])

        let clusters = try await harness.impl.clusters(
            FkwClustersParams(sessionId: harness.sessionId))

        #expect(clusters.count == 1)
        let cluster = try #require(clusters.first)
        #expect(cluster.id == 1)
        #expect(cluster.sessionId == harness.sessionId)
        #expect(cluster.label == "Person 1")
        #expect(cluster.size == 1)
        #expect(cluster.status == "bound")
        #expect(cluster.thumbnailBase64 == "")
        #expect(cluster.binding == BindingData(clusterId: 1, roleName: "Alice", keywords: ["kw1"]))
        #expect(cluster.members.count == 1)
        #expect(cluster.members.first?.photoId == "p1")
        #expect(cluster.members.first?.filename == "photo-a.jpg")
        #expect(cluster.syncedToLibrary == nil)
        #expect(cluster.matchedPersonId == nil)
    }

    @Test("clusters returns an empty list for an unknown session")
    func clustersReturnsEmptyForUnknownSession() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }

        let clusters = try await harness.impl.clusters(FkwClustersParams(sessionId: "ghost"))
        #expect(clusters.isEmpty)
    }

    // MARK: bind

    @Test("bind stores the normalized role name and deduplicated keywords")
    func bindStoresNormalizedBinding() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }
        try await seedFaceCommandCluster(
            harness.db, id: 1, sessionId: harness.sessionId,
            members: [(photoId: "p1", bbox: [1, 2, 3, 4], confidence: 0.9)])

        try await harness.impl.bind(FkwBindParams(
            sessionId: harness.sessionId,
            clusterId: 1,
            roleName: "  Alice  ",
            keywords: ["kw1", "kw1", "kw2"]
        ))

        let bindings = try await harness.faceStore.bindingsBySession(harness.sessionId)
        #expect(bindings.count == 1)
        #expect(bindings.first?.roleName == "Alice")
        #expect(bindings.first?.keywords == ["kw1", "kw2"])
        let clusters = try await harness.faceStore.clusters(sessionId: harness.sessionId)
        #expect(clusters.first?.status == "bound")
    }

    @Test("bind surfaces runtime role-name and cluster lookups failures")
    func bindSurfacesRuntimeErrors() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }
        try await seedFaceCommandCluster(
            harness.db, id: 1, sessionId: harness.sessionId,
            members: [(photoId: "p1", bbox: [1, 2, 3, 4], confidence: 0.9)])

        await #expect(throws: FaceKwError.roleNameEmpty) {
            try await harness.impl.bind(FkwBindParams(
                sessionId: harness.sessionId, clusterId: 1, roleName: "   ", keywords: []))
        }
        await #expect(throws: FaceKwError.clusterNotFound) {
            try await harness.impl.bind(FkwBindParams(
                sessionId: harness.sessionId, clusterId: 99, roleName: "Alice", keywords: []))
        }
    }

    // MARK: unbind

    @Test("unbind requires confirmation with FKW_UNBIND_CONFIRM_REQUIRED")
    func unbindRequiresConfirmation() async throws {
        let writeback = FaceCommandsWritebackStub()
        let harness = try await makeFaceCommandsHarness(writeback: writeback)
        defer { harness.cleanup() }

        await #expect(throws: FaceCommandsError.unbindConfirmRequired) {
            _ = try await harness.impl.unbind(FkwUnbindParams(
                sessionId: harness.sessionId, clusterId: 1, confirmed: false))
        }
        #expect(String(describing: FaceCommandsError.unbindConfirmRequired)
            == "FKW_UNBIND_CONFIRM_REQUIRED")
        #expect(FaceCommandsError.unbindConfirmRequired.gatherCode
            == GatherErrorCode.FKW_UNBIND_CONFIRM_REQUIRED)
    }

    @Test("unbind removes owned keywords through the provider and drops the binding")
    func unbindRemovesKeywordsAndBinding() async throws {
        let writeback = FaceCommandsWritebackStub(removedKeywords: ["Alice", "kw1"])
        let harness = try await makeFaceCommandsHarness(writeback: writeback)
        defer { harness.cleanup() }
        try await seedFaceCommandCluster(
            harness.db, id: 1, sessionId: harness.sessionId,
            members: [(photoId: "p1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try await harness.faceStore.updateBinding(
            clusterId: 1, roleName: "Alice", keywords: ["kw1"])

        let result = try await harness.impl.unbind(FkwUnbindParams(
            sessionId: harness.sessionId, clusterId: 1, confirmed: true))

        #expect(result.done)
        #expect(result.removedKeywords == ["Alice", "kw1"])
        let entries = await writeback.removedEntries
        #expect(entries.count == 1)
        #expect(entries.first?.photoId == "p1")
        #expect(entries.first?.keywords == ["Alice", "kw1"])
        let bindings = try await harness.faceStore.bindingsBySession(harness.sessionId)
        #expect(bindings.isEmpty)
    }

    // MARK: merge / remove_member

    @Test("merge moves the source members into the target cluster")
    func mergeMergesSourceIntoTarget() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }
        try await seedFaceCommandCluster(
            harness.db, id: 1, sessionId: harness.sessionId,
            members: [(photoId: "p1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try await seedFaceCommandCluster(
            harness.db, id: 2, sessionId: harness.sessionId, label: "Person 2",
            members: [(photoId: "p2", bbox: [5, 6, 7, 8], confidence: 0.8)])

        try await harness.impl.merge(FkwMergeParams(
            sessionId: harness.sessionId, source: 1, target: 2))

        let clusters = try await harness.faceStore.clusters(sessionId: harness.sessionId)
        #expect(clusters.count == 1)
        #expect(clusters.first?.id == 2)
        #expect(clusters.first?.memberCount == 2)
    }

    @Test("merge rejects a self merge with FACE_SELF_MERGE")
    func mergeRejectsSelfMerge() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }

        await #expect(throws: FaceKwError.selfMerge) {
            try await harness.impl.merge(FkwMergeParams(
                sessionId: harness.sessionId, source: 1, target: 1))
        }
    }

    @Test("remove_member deletes the member row")
    func removeMemberDeletesMemberRow() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }
        try await seedFaceCommandCluster(
            harness.db, id: 1, sessionId: harness.sessionId,
            members: [
                (photoId: "p1", bbox: [1, 2, 3, 4], confidence: 0.9),
                (photoId: "p2", bbox: [5, 6, 7, 8], confidence: 0.8),
            ])
        let row = try await harness.db.queryOne(
            "SELECT id FROM face_cluster_members WHERE photo_id = 'p1'")
        let memberId = Int(row?.int("id") ?? 0)

        try await harness.impl.removeMember(FkwRemoveMemberParams(
            sessionId: harness.sessionId, clusterId: 1, memberId: memberId))

        let members = try await harness.faceStore.clusterMembers(clusterId: 1)
        #expect(members.count == 1)
        #expect(members.first?.photoId == "p2")
    }

    @Test("remove_member surfaces FKW_CLUSTER_MEMBER_NOT_FOUND")
    func removeMemberRejectsUnknownMember() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }
        try await seedFaceCommandCluster(
            harness.db, id: 1, sessionId: harness.sessionId,
            members: [(photoId: "p1", bbox: [1, 2, 3, 4], confidence: 0.9)])

        await #expect(throws: FaceKwError.clusterMemberNotFound) {
            try await harness.impl.removeMember(FkwRemoveMemberParams(
                sessionId: harness.sessionId, clusterId: 1, memberId: 999))
        }
    }

    // MARK: preview / writeback / confirm_sync / cleanup

    @Test("preview maps the runtime preview and forwards writeback options")
    func previewMapsRuntimePreviewAndOptions() async throws {
        let writeback = FaceCommandsWritebackStub(previewResult: FaceKwWritebackPreview(
            items: [faceCommandRuntimeItem(id: 3)], totalCount: 1, affectedPhotos: 1))
        let harness = try await makeFaceCommandsHarness(writeback: writeback)
        defer { harness.cleanup() }
        try await seedFaceCommandCluster(
            harness.db, id: 1, sessionId: harness.sessionId,
            members: [(photoId: "p1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try await harness.faceStore.updateBinding(
            clusterId: 1, roleName: "Alice", keywords: ["kw1"])

        let preview = try await harness.impl.preview(FkwPreviewParams(
            sessionId: harness.sessionId, options: WritebackOptions(createAlbums: true)))

        #expect(preview.totalCount == 1)
        #expect(preview.affectedPhotos == 1)
        #expect(preview.items.count == 1)
        let item = try #require(preview.items.first)
        #expect(item.id == 3)
        #expect(item.attributes == WritebackAttributes(keywords: ["Alice"]))
        #expect(item.preview?.dirtyFields == [.keywords, .rating])
        #expect(item.preview?.willCreate == true)
        let options = await writeback.previewOptions
        #expect(options == FaceKwWritebackOptions(createAlbums: true))
    }

    @Test("preview surfaces the missing writeback provider failure")
    func previewSurfacesMissingWritebackProvider() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }

        await #expect(throws: FaceKwError.writebackProviderMissing) {
            _ = try await harness.impl.preview(FkwPreviewParams(sessionId: harness.sessionId))
        }
    }

    @Test("writeback requires confirmation with WRITEBACK_CONFIRM_REQUIRED")
    func writebackRequiresConfirmation() async throws {
        let writeback = FaceCommandsWritebackStub()
        let harness = try await makeFaceCommandsHarness(writeback: writeback)
        defer { harness.cleanup() }

        await #expect(throws: FaceCommandsError.writebackConfirmRequired) {
            _ = try await harness.impl.writeback(FkwWritebackParams(
                sessionId: harness.sessionId, confirmed: nil))
        }
        #expect(String(describing: FaceCommandsError.writebackConfirmRequired)
            == "WRITEBACK_CONFIRM_REQUIRED")
        #expect(FaceCommandsError.writebackConfirmRequired.gatherCode
            == GatherErrorCode.WRITEBACK_CONFIRM_REQUIRED)
        let items = await writeback.executedItems
        #expect(items.isEmpty, "门控失败不应触达 Provider")
    }

    @Test("writeback maps items in both directions and defaults nil items to empty")
    func writebackMapsItemsAndResult() async throws {
        let writeback = FaceCommandsWritebackStub(executeResult: FaceKwWritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0, errors: [],
            failedItems: [faceCommandRuntimeItem(id: 9)], report: "ok"))
        let harness = try await makeFaceCommandsHarness(writeback: writeback)
        defer { harness.cleanup() }

        let result = try await harness.impl.writeback(FkwWritebackParams(
            sessionId: harness.sessionId, confirmed: true, items: [faceCommandProtocolItem(id: 7)]))

        #expect(result.written == 1)
        #expect(result.report == "ok")
        #expect(result.failedItems.count == 1)
        #expect(result.failedItems.first?.preview?.dirtyFields == [.keywords, .rating])
        let executed = await writeback.executedItems
        #expect(executed.count == 1)
        #expect(executed.first?.id == 7)
        #expect(executed.first?.attributes?.label == "green")
        #expect(executed.first?.preview?.dirtyFields == ["keywords"])

        // nil items 等价旧语义的空数组。
        _ = try await harness.impl.writeback(FkwWritebackParams(
            sessionId: harness.sessionId, confirmed: true, items: nil))
        let afterNil = await writeback.executedItems
        #expect(afterNil.isEmpty)
    }

    @Test("confirm_sync forwards the session to the writeback provider")
    func confirmSyncForwardsSession() async throws {
        let writeback = FaceCommandsWritebackStub()
        let harness = try await makeFaceCommandsHarness(writeback: writeback)
        defer { harness.cleanup() }

        try await harness.impl.confirmSync(FkwConfirmSyncParams(
            sessionId: harness.sessionId, confirmed: true))

        let synced = await writeback.syncedSessionIds
        #expect(synced == [harness.sessionId])
    }

    @Test("confirm_sync surfaces the missing writeback provider failure")
    func confirmSyncSurfacesMissingWritebackProvider() async throws {
        let harness = try await makeFaceCommandsHarness()
        defer { harness.cleanup() }

        await #expect(throws: FaceKwError.writebackProviderMissing) {
            try await harness.impl.confirmSync(FkwConfirmSyncParams(sessionId: harness.sessionId))
        }
    }

    @Test("confirm_cleanup requires confirmation and maps the cleanup result")
    func confirmCleanupRequiresConfirmationAndMapsResult() async throws {
        let writeback = FaceCommandsWritebackStub(cleanupResult: FaceKwCleanupResult(
            deletedCount: 3, errors: ["e1"]))
        let harness = try await makeFaceCommandsHarness(writeback: writeback)
        defer { harness.cleanup() }

        await #expect(throws: FaceCommandsError.cleanupConfirmRequired) {
            _ = try await harness.impl.confirmCleanup(FkwConfirmCleanupParams(
                sessionId: harness.sessionId, confirmed: false))
        }
        #expect(String(describing: FaceCommandsError.cleanupConfirmRequired)
            == "FKW_CLEANUP_CONFIRM_REQUIRED")
        #expect(FaceCommandsError.cleanupConfirmRequired.gatherCode
            == GatherErrorCode.FKW_CLEANUP_CONFIRM_REQUIRED)
        let callsBefore = await writeback.cleanupCalls
        #expect(callsBefore.isEmpty, "门控失败不应触达 Provider")

        let result = try await harness.impl.confirmCleanup(FkwConfirmCleanupParams(
            sessionId: harness.sessionId, confirmed: true))
        #expect(result.deletedCount == 3)
        #expect(result.errors == ["e1"])
        let calls = await writeback.cleanupCalls
        #expect(calls == [harness.sessionId])
    }

    @Test("cleanup requires confirmation and maps the cleanup result")
    func cleanupRequiresConfirmationAndMapsResult() async throws {
        let writeback = FaceCommandsWritebackStub(cleanupResult: FaceKwCleanupResult(
            deletedCount: 2, errors: []))
        let harness = try await makeFaceCommandsHarness(writeback: writeback)
        defer { harness.cleanup() }

        await #expect(throws: FaceCommandsError.cleanupConfirmRequired) {
            _ = try await harness.impl.cleanup(FkwCleanupParams(
                sessionId: harness.sessionId, confirmed: nil))
        }

        let result = try await harness.impl.cleanup(FkwCleanupParams(
            sessionId: harness.sessionId, confirmed: true))
        #expect(result.deletedCount == 2)
        #expect(result.errors.isEmpty)
        let calls = await writeback.cleanupCalls
        #expect(calls == [harness.sessionId])
    }

    // MARK: models_status

    @Test("models_status reports settings paths with present models")
    func modelsStatusUsesSettingsPaths() async throws {
        let defaults = try await makeFaceCommandsHarness()
        defer { defaults.cleanup() }
        let plain = try await defaults.impl.modelsStatus()
        #expect(plain.detectorPresent)
        #expect(plain.encoderPresent)
        #expect(plain.detectorPath == "models/face_detector.onnx")
        #expect(plain.encoderPath == "models/face_encoder.onnx")

        let custom = try await makeFaceCommandsHarness(settings: [
            "detector_model_path": "custom/detector.onnx",
            "encoder_model_path": "custom/encoder.onnx",
        ])
        defer { custom.cleanup() }
        let configured = try await custom.impl.modelsStatus()
        #expect(configured.detectorPath == "custom/detector.onnx")
        #expect(configured.encoderPath == "custom/encoder.onnx")
    }
}
