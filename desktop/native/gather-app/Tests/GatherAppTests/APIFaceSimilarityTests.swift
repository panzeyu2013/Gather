// desktop/native/gather-app/Tests/GatherAppTests/APIFaceSimilarityTests.swift
// Cut 1 / B4a：LiveFaceAPI（13 方法）与 LiveSimilarityAPI（10 方法）的行为测试。
//
// 覆盖：
// - face：clusters/bind 的绑定投影、analyze 的 job 建单（dedupeKey/checkpoint）、
//   modelsStatus 的 FaceInferenceConfig + 文件存在性、unbind 的 Confirmed 边界、
//   preview/writeback 的接缝类型搬运、参数错误（INVALID_PARAM / FACE_EPS_INVALID /
//   FACE_SELF_MERGE）；
// - similarity：result 的阈值/最近结果、analyze 与 recluster 的 job 语义
//   （checkpoint.operation 分派）、writeback 的 Confirmed + hasResult +
//   pending 匹配、retryFailedWriteback/cleanup/confirmSync 固定 module、
//   SIM_PREVIEW_REQUIRED / SIM_PREVIEW_STALE / SIM_THRESHOLD_NO_RESULTS 错误路径。
//
// 夹具用内存 SQLite + 迁移 + 真实服务（FaceKwService / SimilarityService /
// WritebackService）+ fake 端口，不触碰真实文件系统与 XMP；job 执行器用 stub
// 替换推理/聚类（与旧命令面 的 executor 契约一致），从而只断言 API 边界的
// job 形状与等待语义。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

// MARK: - Fake 端口

/// FaceWritebackProvider 的替身：记录 unbind/execute 的入参，返回注入结果。
private final class FaceTestWritebackProvider: FaceWritebackProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var removeEntriesStorage: [[FaceKeywordEntry]] = []
    private var executeCallsStorage: [[FaceKwWritebackItem]] = []
    private var confirmCallsStorage: [String] = []
    private var previewCallsStorage: [FaceKwWritebackOptions?] = []

    var removedKeywords: [String] = []
    var preview = FaceKwWritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    var executeResult = FaceKwWritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0,
        errors: [], failedItems: [], report: ""
    )
    var cleanupResult = FaceKwCleanupResult(deletedCount: 0, errors: [])

    var removeEntries: [[FaceKeywordEntry]] {
        lock.withLock { removeEntriesStorage }
    }

    var executeCalls: [[FaceKwWritebackItem]] {
        lock.withLock { executeCallsStorage }
    }

    var confirmCalls: [String] {
        lock.withLock { confirmCallsStorage }
    }

    var previewCalls: [FaceKwWritebackOptions?] {
        lock.withLock { previewCallsStorage }
    }

    func removeOwnedFaceKeywords(
        sessionId: String,
        entries: [FaceKeywordEntry]
    ) async throws -> [String] {
        lock.withLock { removeEntriesStorage.append(entries) }
        return removedKeywords
    }

    func preview(
        sessionId: String,
        options: FaceKwWritebackOptions?,
        boundPhotoIds: Set<String>,
        additions: [String: [String]]
    ) async throws -> FaceKwWritebackPreview {
        lock.withLock { previewCallsStorage.append(options) }
        return preview
    }

    func execute(
        sessionId: String,
        items: [FaceKwWritebackItem]
    ) async throws -> FaceKwWritebackResult {
        lock.withLock { executeCallsStorage.append(items) }
        return executeResult
    }

    func confirmSync(sessionId: String) async throws {
        lock.withLock { confirmCallsStorage.append(sessionId) }
    }

    func cleanup(sessionId: String) async throws -> FaceKwCleanupResult {
        cleanupResult
    }
}

/// XMPProvider 的替身：只记录写入，不做文件 IO。
private final class FaceSimXMPProvider: XMPProvider, @unchecked Sendable {
    var keywords: [String: [String]] = [:]
    private(set) var written: [(photoPath: String, keywords: [String]?)] = []

    func readKeywords(photoPath: String) async throws -> [String] {
        keywords[photoPath] ?? []
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        MetadataWriteAttributes()
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        written.append((photoPath, attributes.keywords))
    }

    func backup(photoPath: String) async throws -> String { "" }

    func restore(photoPath: String, backupPath: String) async throws {}

    func fileExists(_ path: String) -> Bool { false }

    func removeFile(_ path: String) async throws {}
}

/// MetadataMutationPort 的替身：记录入队字段（execute 的 Phase 1 会调用）。
private final class FaceSimMutationPort: MetadataMutationPort, @unchecked Sendable {
    private(set) var queued: [(photoId: String, values: [String: JSONValue], source: MetadataMutationSource)] = []

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        queued.append((photoId, values, source))
        return MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending"
        )
    }

    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending"
        )
    }
}

// MARK: - 夹具

private enum FaceSimilarityFixtureError: Error {
    case missingPendingWritebackItem
}

private struct FaceSimilarityFixture {
    let db: DBConnection
    let sessionId: String
    let photoIds: [String]
    let photoRepo: PhotoRepo
    let faceRepo: FaceRepo
    let similarityRepo: SimilarityResultRepo
    let settingsService: SettingsService
    let jobService: JobService
    let faceProvider: FaceTestWritebackProvider
    let faceAPI: LiveFaceAPI
    let similarityAPI: LiveSimilarityAPI
    let xmp: FaceSimXMPProvider

    init() throws {
        let db = try makeGatherTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "B4a", source: "test")
        // 新 confirm 门禁读 sessions.reload_acked_at（与生产 C1 ack 同列）。
        _ = try db.prepare("UPDATE sessions SET reload_acked_at = ? WHERE id = ?")
            .run([.text("2026-01-01T00:00:00.000Z"), .text(session.id)])
        let photoRepo = PhotoRepo(connection: db)
        let photoIds = try photoRepo.addPhotos(
            sessionId: session.id,
            filepaths: [
                PhotoAddInput(filepath: "/shoot/a.jpg", width: 100, height: 100),
                PhotoAddInput(filepath: "/shoot/b.jpg", width: 100, height: 100),
            ],
            "test"
        ).ids

        let faceRepo = FaceRepo(connection: db)
        let personRepo = PersonRepo(connection: db)
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))

        // 簇：两个成员同簇，供 clusters/bind/unbind 用例。
        _ = try faceRepo.saveClusters(
            sessionId: session.id,
            clusters: [
                FaceClusterInput(
                    label: "A",
                    members: [
                        FaceClusterMemberInput(
                            photoId: photoIds[0], photoPath: "/shoot/a.jpg",
                            bbox: [0.1, 0.1, 0.3, 0.3], confidence: 0.9
                        ),
                        FaceClusterMemberInput(
                            photoId: photoIds[1], photoPath: "/shoot/b.jpg",
                            bbox: [0.2, 0.2, 0.4, 0.4], confidence: 0.8
                        ),
                    ]
                )
            ]
        )

        let faceProvider = FaceTestWritebackProvider()
        let faceKwService = FaceKwService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            faceRepo: faceRepo,
            personRepo: personRepo,
            connection: db,
            writebackProvider: faceProvider
        )

        let similarityRepo = SimilarityResultRepo(connection: db)

        let xmp = FaceSimXMPProvider()
        // S5c-2b-3b-2a：写回持久化层是交付模型，execute 直接 xmp 写盘
        // （MetadataSyncPort 已随旧同步栈删除）。
        let writebackService = WritebackService(
            deliveryRepo: DeliveryRepo(connection: db),
            xmp: xmp,
            photoRepo: photoRepo,
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            connection: db,
            keywordOrigins: nil,
            assetResolver: nil
        )
        // S5c-2b-3b-1：API 只依赖 SimilarityService；写回执行器经生产同款
        // bridge（module=similarity）注入，验证的是真实接缝而不是桩。
        let similarityService = SimilarityService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            similarityResultRepo: similarityRepo,
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            connection: db,
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            },
            writebackProvider: SimilarityWritebackBridge(writebackService: writebackService)
        )

        // 执行器替身：只满足 waitForResult 的完成语义，不跑真实推理/聚类。
        jobService.registerExecutor(type: .faceAnalyze) { _, _ in
            FaceAnalysisResult(status: "done", detectionFailures: 0, encodingFailures: 0)
        }
        jobService.registerExecutor(type: .similarityAnalyze) { _, _ in true }
        jobService.start()

        self.db = db
        self.sessionId = session.id
        self.photoIds = photoIds
        self.photoRepo = photoRepo
        self.faceRepo = faceRepo
        self.similarityRepo = similarityRepo
        self.settingsService = settingsService
        self.jobService = jobService
        self.faceProvider = faceProvider
        self.faceAPI = LiveFaceAPI(
            faceKwService: faceKwService,
            jobService: jobService,
            settingsService: settingsService
        )
        self.similarityAPI = LiveSimilarityAPI(
            similarityService: similarityService,
            jobService: jobService,
            settingsService: settingsService
        )
        self.xmp = xmp
    }

    /// 预置一份相似度结果（成员表是组结构的权威来源）。
    func seedSimilarityResult(threshold: Int) throws {
        let stats = SimilarityResultStats(
            totalGroups: 1,
            totalUngrouped: 1,
            threshold: Double(threshold),
            minGroupSize: 2,
            groupingMode: .global
        )
        let data = try JSONEncoder().encode(stats)
        let statsJSON = String(decoding: data, as: UTF8.self)
        _ = try similarityRepo.replace(
            sessionId: sessionId,
            groupsJson: "{\"groups\":[]}",
            statsJson: statsJSON,
            threshold: threshold,
            minGroupSize: 2,
            memberships: [(photoId: photoIds[0], groupIndex: 0)]
        )
    }

    /// 预置一条 pending 交付项（deliveries + delivery_items + delivery_sessions），
    /// 返回 (delivery_items.id, xmpPath)。
    func seedPendingWritebackItem() throws -> (id: Int, xmpPath: String) {
        let deliveryRepo = DeliveryRepo(connection: db)
        let xmpPath = TSPath.xmpSidecarPath("/shoot/b.jpg")
        _ = try deliveryRepo.createOrGet(xmpPath: xmpPath, photoPath: "/shoot/b.jpg")
        _ = try deliveryRepo.upsertItem(
            xmpPath: xmpPath,
            photoId: photoIds[1],
            module: .similarity,
            keywords: ["beach"],
            status: .pending
        )
        _ = try deliveryRepo.linkSession(xmpPath: xmpPath, sessionId: sessionId)
        guard let row = try deliveryRepo
            .listItems(sessionId: sessionId, module: .similarity, status: .pending)
            .first
        else {
            throw FaceSimilarityFixtureError.missingPendingWritebackItem
        }
        return (Int(row.id), xmpPath)
    }

    func jobs(ofType type: AnalysisJobType) throws -> [AnalysisJobData] {
        try jobService.list(includeCheckpoint: true).filter { $0.type == type }
    }
}

// MARK: - 错误捕获辅助

private func apiGatherError<T>(_ body: () async throws -> T) async -> GatherError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

private func syncGatherError<T>(_ body: () throws -> T) -> GatherError? {
    do {
        _ = try body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

// MARK: - Face 用例

@Suite("B4a Live Face API")
struct APIFaceTests {
    @Test("clusters/bind：绑定后簇清单带 roleName 与关键词")
    func clustersAndBind() async throws {
        let fixture = try FaceSimilarityFixture()
        let clusters = try await fixture.faceAPI.clusters(fixture.sessionId)
        let cluster = try #require(clusters.first)
        #expect(cluster.binding == nil)
        #expect(cluster.size == 2)

        try await fixture.faceAPI.bind(
            FaceBindInput(
                sessionId: fixture.sessionId,
                clusterId: cluster.id,
                roleName: "新郎",
                keywords: ["groom"]
            )
        )
        let bound = try #require(try await fixture.faceAPI.clusters(fixture.sessionId).first)
        #expect(bound.binding?.roleName == "新郎")
        #expect(bound.binding?.keywords == ["groom"])
    }

    @Test("analyze：建 faceAnalyze job，dedupeKey/checkpoint 沿用旧命令面")
    func analyzeCreatesJob() async throws {
        let fixture = try FaceSimilarityFixture()
        let result = try await fixture.faceAPI.analyze(
            FaceAnalyzeInput(sessionId: fixture.sessionId, eps: 0.5, minSamples: 3)
        )
        #expect(result.status == "done")

        let job = try #require(try fixture.jobs(ofType: .faceAnalyze).first)
        #expect(job.scopeId == fixture.sessionId)
        #expect(
            job.dedupeKey
                == "face.analyze:\(fixture.sessionId):models/face_detector.onnx:"
                + "models/face_encoder.onnx:0.5:3.0"
        )
        #expect(job.checkpoint["eps"]?.numberValue == 0.5)
        #expect(job.checkpoint["minSamples"]?.numberValue == 3)
        #expect(job.checkpoint["detectorPath"]?.stringValue == "models/face_detector.onnx")
    }

    @Test("modelsStatus：走 FaceInferenceConfig，按文件存在性判定")
    func modelsStatusReadsConfig() async throws {
        let fixture = try FaceSimilarityFixture()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-b4a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("face.mlmodelc")
        try Data([0x00]).write(to: model)

        try fixture.settingsService.set(
            FaceEmbeddingModelFactory.modelPathSetting,
            value: model.path
        )
        let present = try await fixture.faceAPI.modelsStatus()
        #expect(present.modelsPresent)
        #expect(present.fallbackToOnnxEnabled == false)
        #expect(present.downloading == false)
        #expect(present.provider == FaceProvider.vision.rawValue)

        try fixture.settingsService.set(
            FaceEmbeddingModelFactory.modelPathSetting,
            value: dir.appendingPathComponent("missing.mlmodelc").path
        )
        let missing = try await fixture.faceAPI.modelsStatus()
        #expect(missing.modelsPresent == false)
    }

    @Test("unbind：只经 Confirmed<T> 进入写回提供者，返回 removedKeywords")
    func unbindThroughConfirmed() async throws {
        let fixture = try FaceSimilarityFixture()
        let cluster = try #require(try await fixture.faceAPI.clusters(fixture.sessionId).first)
        try await fixture.faceAPI.bind(
            FaceBindInput(
                sessionId: fixture.sessionId,
                clusterId: cluster.id,
                roleName: "新娘",
                keywords: ["bride"]
            )
        )
        fixture.faceProvider.removedKeywords = ["bride"]

        let result = try await fixture.faceAPI.unbind(
            Confirmed(
                FaceUnbindInput(sessionId: fixture.sessionId, clusterId: cluster.id),
                source: .test
            )
        )
        #expect(result.done)
        #expect(result.removedKeywords == ["bride"])
        #expect(fixture.faceProvider.removeEntries.count == 1)
        let after = try #require(try await fixture.faceAPI.clusters(fixture.sessionId).first)
        #expect(after.binding == nil)
    }

    @Test("preview/writeback：FaceKw 接缝类型与 Protocol Writeback 类型双向搬运")
    func previewAndWritebackAdaptTypes() async throws {
        let fixture = try FaceSimilarityFixture()
        fixture.faceProvider.preview = FaceKwWritebackPreview(
            items: [
                FaceKwWritebackItem(
                    id: 7,
                    photoId: fixture.photoIds[0],
                    photoPath: "/shoot/a.jpg",
                    sessionId: fixture.sessionId,
                    module: "face_kw",
                    keywords: ["groom"],
                    attributes: FaceKwWritebackAttributes(keywords: ["groom"], rating: 5, label: "red"),
                    xmpPath: "/shoot/a.xmp",
                    backupPath: "",
                    xmpStatus: "pending",
                    errorMessage: "",
                    attemptCount: 0,
                    lastAttemptAt: "",
                    preview: FaceKwWritebackPreviewInfo(
                        dirtyFields: ["keywords"],
                        before: FaceKwWritebackAttributes(keywords: []),
                        after: FaceKwWritebackAttributes(keywords: ["groom"]),
                        source: "face_kw",
                        sharedPhotoCount: 1,
                        externalChanged: false,
                        willCreate: true
                    )
                )
            ],
            totalCount: 1,
            affectedPhotos: 1
        )
        let preview = try await fixture.faceAPI.preview(
            FacePreviewInput(sessionId: fixture.sessionId, options: WritebackOptions(addPrefix: true))
        )
        #expect(preview.totalCount == 1)
        #expect(preview.items.first?.id == 7)
        #expect(preview.items.first?.attributes?.rating == 5)
        #expect(preview.items.first?.preview?.dirtyFields == [.keywords])
        let previewOptions = try #require(fixture.faceProvider.previewCalls.first)
        #expect(previewOptions?.addPrefix == true)

        fixture.faceProvider.executeResult = FaceKwWritebackResult(
            totalAffected: 1, written: 0, failed: 1, skipped: 0,
            errors: ["boom"],
            failedItems: [
                FaceKwWritebackItem(
                    id: 9, photoId: fixture.photoIds[1], photoPath: "/shoot/b.jpg",
                    sessionId: fixture.sessionId, module: "face_kw", keywords: ["x"],
                    attributes: nil, xmpPath: "/shoot/b.xmp", backupPath: "",
                    xmpStatus: "failed", errorMessage: "boom", attemptCount: 1,
                    lastAttemptAt: ""
                )
            ],
            report: "Written: 0, Failed: 1, Skipped: 0"
        )
        let writebackResult = try await fixture.faceAPI.writeback(
            Confirmed(
                FaceWritebackInput(
                    sessionId: fixture.sessionId,
                    items: [
                        WritebackItem(
                            id: 5, photoId: fixture.photoIds[0], photoPath: "/shoot/a.jpg",
                            sessionId: fixture.sessionId, module: "face_kw", keywords: ["groom"],
                            xmpPath: "/shoot/a.xmp", backupPath: "", xmpStatus: "pending",
                            errorMessage: "", attemptCount: 0, lastAttemptAt: ""
                        )
                    ]
                ),
                source: .test
            )
        )
        #expect(writebackResult.failed == 1)
        #expect(writebackResult.failedItems.first?.id == 9)
        #expect(fixture.faceProvider.executeCalls.first?.first?.id == 5)
    }

    @Test("错误路径：裸 sessionId 与输入构造期校验统一 GatherError")
    func faceValidationErrors() async throws {
        let fixture = try FaceSimilarityFixture()

        let blank = await apiGatherError { try await fixture.faceAPI.clusters("   ") }
        #expect(blank?.code == .INVALID_PARAM)
        #expect(blank?.params["field"] == "sessionId")

        let badEps = await apiGatherError {
            try await fixture.faceAPI.analyze(FaceAnalyzeInput(sessionId: fixture.sessionId, eps: 1.5))
        }
        #expect(badEps?.code == .FACE_EPS_INVALID)

        let selfMerge = syncGatherError {
            try FaceMergeInput(sessionId: fixture.sessionId, source: 1, target: 1)
        }
        #expect(selfMerge?.code == .FACE_SELF_MERGE)

        // 脏设置（default_eps = 2）在 API 边界显式失败，不落到 executor。
        try fixture.settingsService.set("default_eps", value: "2")
        let dirtySettings = await apiGatherError {
            try await fixture.faceAPI.analyze(FaceAnalyzeInput(sessionId: fixture.sessionId))
        }
        #expect(dirtySettings?.code == .FACE_EPS_INVALID)
        #expect(try fixture.jobs(ofType: .faceAnalyze).isEmpty)
    }
}

// MARK: - Similarity 用例

@Suite("B4a Live Similarity API")
struct APISimilarityTests {
    @Test("result：按阈值查询与最近结果，无结果返回 nil")
    func resultReadsStoredResult() async throws {
        let fixture = try FaceSimilarityFixture()
        #expect(
            try await fixture.similarityAPI.result(
                SimilarityResultQuery(sessionId: fixture.sessionId)
            ) == nil
        )

        try fixture.seedSimilarityResult(threshold: 16)
        let byThreshold = try #require(
            try await fixture.similarityAPI.result(
                SimilarityResultQuery(sessionId: fixture.sessionId, threshold: 16)
            )
        )
        #expect(byThreshold.groups.count == 1)
        #expect(byThreshold.groups.first?.images.first?.path == "/shoot/a.jpg")
        let latest = try #require(
            try await fixture.similarityAPI.result(
                SimilarityResultQuery(sessionId: fixture.sessionId)
            )
        )
        #expect(latest.stats.totalGroups == 1)
    }

    @Test("analyze：建 similarityAnalyze job，checkpoint 保留显式参数")
    func analyzeCreatesJob() async throws {
        let fixture = try FaceSimilarityFixture()
        let ok = try await fixture.similarityAPI.analyze(
            SimilarityAnalyzeInput(
                sessionId: fixture.sessionId,
                threshold: 8,
                minGroupSize: 3,
                groupingMode: .sequential
            )
        )
        #expect(ok)

        let job = try #require(try fixture.jobs(ofType: .similarityAnalyze).first)
        #expect(job.scopeId == fixture.sessionId)
        #expect(
            job.dedupeKey
                == "similarity.analyze:\(fixture.sessionId):8.0:3.0:sequential"
        )
        #expect(job.checkpoint["threshold"]?.numberValue == 8)
        #expect(job.checkpoint["minGroupSize"]?.numberValue == 3)
        #expect(job.checkpoint["groupingMode"]?.stringValue == "sequential")
        #expect(job.checkpoint["operation"] == nil)
    }

    @Test("analyze 缺省参数：dedupeKey 用 default，checkpoint 写 null")
    func analyzeDefaultsToSettings() async throws {
        let fixture = try FaceSimilarityFixture()
        try fixture.settingsService.set("default_threshold", value: "12")
        try fixture.settingsService.set("default_min_group_size", value: "4")

        _ = try await fixture.similarityAPI.analyze(
            SimilarityAnalyzeInput(sessionId: fixture.sessionId)
        )
        let job = try #require(try fixture.jobs(ofType: .similarityAnalyze).first)
        #expect(
            job.dedupeKey
                == "similarity.analyze:\(fixture.sessionId):default:default:global"
        )
        #expect(job.checkpoint["threshold"] == .null)
        #expect(job.checkpoint["minGroupSize"] == .null)
    }

    @Test("recluster：checkpoint.operation=recluster，完成后读回结果")
    func reclusterCarriesOperation() async throws {
        let fixture = try FaceSimilarityFixture()
        try fixture.seedSimilarityResult(threshold: 16)

        let result = try await fixture.similarityAPI.recluster(
            SimilarityAnalyzeInput(
                sessionId: fixture.sessionId,
                threshold: 16,
                minGroupSize: 2
            )
        )
        #expect(result?.groups.count == 1)

        let job = try #require(try fixture.jobs(ofType: .similarityAnalyze).first)
        #expect(job.checkpoint["operation"]?.stringValue == "recluster")
        #expect(
            job.dedupeKey
                == "similarity.recluster:\(fixture.sessionId):16.0:2.0:global"
        )
    }

    @Test("writeback：Confirmed + hasResult + pending 匹配才执行")
    func writebackThroughConfirmed() async throws {
        let fixture = try FaceSimilarityFixture()
        try fixture.seedSimilarityResult(threshold: 16)
        let item = try fixture.seedPendingWritebackItem()

        let result = try await fixture.similarityAPI.writeback(
            Confirmed(
                SimilarityWritebackInput(
                    sessionId: fixture.sessionId,
                    itemIds: [item.id],
                    threshold: 16
                ),
                source: .test
            )
        )
        #expect(result.written == 1)
        #expect(result.failed == 0)
        // S5c-2b-3b-2a：execute 直接写盘；旧 flushSession 端口已删除。
    }

    @Test("preview：result→plan→SimilarityService.previewWriteback/persistKeywords，交付项落库")
    func previewUsesSimilarityServiceSeam() async throws {
        let fixture = try FaceSimilarityFixture()
        try fixture.seedSimilarityResult(threshold: 16)

        let preview = try await fixture.similarityAPI.previewWriteback(
            SimilarityPreviewWritebackInput(
                sessionId: fixture.sessionId,
                assignments: [SimilarityKeywordAssignment(groupId: 1, keywords: ["beach"])],
                threshold: 16
            )
        )
        #expect(preview.totalCount == 1)
        #expect(preview.items.first?.keywords == ["beach"])

        // 交付行由 preview 建（两条照片），只有命中计划的一条被 persistKeywords 合并。
        let deliveryRepo = DeliveryRepo(connection: fixture.db)
        let items = try deliveryRepo.listItems(
            sessionId: fixture.sessionId, module: .similarity)
        #expect(items.count == 2)
        let planned = try #require(items.first { $0.xmpPath == preview.items.first?.xmpPath })
        #expect(planned.keywordList == ["beach"])
        let unplanned = try #require(items.first { $0.xmpPath != planned.xmpPath })
        #expect(unplanned.keywordList.isEmpty)

        // writebackItems 读同一交付投影（不再走 WritebackService.getItems）。
        let listed = try await fixture.similarityAPI.writebackItems(fixture.sessionId)
        #expect(listed.count == 2)
    }

    @Test("lifecycle：retry/cleanup/confirmSync 走交付 coordinator，不再直连旧 sync 端口")
    func lifecycleUsesDeliveryModel() async throws {
        let fixture = try FaceSimilarityFixture()

        _ = try await fixture.similarityAPI.retryFailedWriteback(
            Confirmed(SessionReference(sessionId: fixture.sessionId), source: .test)
        )
        let cleanup = try await fixture.similarityAPI.cleanup(
            Confirmed(SessionReference(sessionId: fixture.sessionId), source: .test)
        )
        #expect(cleanup.deletedCount == 0)
        #expect(cleanup.errors.isEmpty)

        let confirmed = try await fixture.similarityAPI.confirmSync(fixture.sessionId)
        #expect(confirmed)
    }

    @Test("错误路径：SIM_PREVIEW_REQUIRED / STALE / THRESHOLD_NO_RESULTS / INVALID_PARAM")
    func similarityValidationErrors() async throws {
        let fixture = try FaceSimilarityFixture()
        try fixture.seedSimilarityResult(threshold: 16)
        let item = try fixture.seedPendingWritebackItem()

        let emptyItems = syncGatherError {
            try SimilarityWritebackInput(sessionId: fixture.sessionId, itemIds: [])
        }
        #expect(emptyItems?.code == .SIM_PREVIEW_REQUIRED)

        // 阈值有结果校验先于 pending 匹配。
        let noResults = await apiGatherError {
            try await fixture.similarityAPI.writeback(
                Confirmed(
                    SimilarityWritebackInput(
                        sessionId: fixture.sessionId,
                        itemIds: [item.id],
                        threshold: 32
                    ),
                    source: .test
                )
            )
        }
        #expect(noResults?.code == .SIM_THRESHOLD_NO_RESULTS)

        // 预览过期：itemIds 与 pending 行不一致。
        let stale = await apiGatherError {
            try await fixture.similarityAPI.writeback(
                Confirmed(
                    SimilarityWritebackInput(
                        sessionId: fixture.sessionId,
                        itemIds: [item.id + 999],
                        threshold: 16
                    ),
                    source: .test
                )
            )
        }
        #expect(stale?.code == .SIM_PREVIEW_STALE)

        let blankSession = await apiGatherError {
            try await fixture.similarityAPI.writebackItems("  ")
        }
        #expect(blankSession?.code == .INVALID_PARAM)
        #expect(blankSession?.params["field"] == "sessionId")

        let badThreshold = syncGatherError {
            try SimilarityResultQuery(sessionId: fixture.sessionId, threshold: 65)
        }
        #expect(badThreshold?.code == .INVALID_PARAM)

        // 分析参数脏设置同样在 API 边界显式失败。
        try fixture.settingsService.set("default_threshold", value: "99")
        let dirty = await apiGatherError {
            try await fixture.similarityAPI.analyze(
                SimilarityAnalyzeInput(sessionId: fixture.sessionId)
            )
        }
        #expect(dirty?.code == .SIM_THRESHOLD_INVALID)
        #expect(try fixture.jobs(ofType: .similarityAnalyze).isEmpty)
    }
}
