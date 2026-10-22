// desktop/native/gather-core/Tests/GatherCoreTests/Services/FaceKeywordingServiceTests.swift
// FaceKwService + PersonRepo（人脸库桥接）+ 写回接缝 行为测试（Phase 3.5）。
// TS 源（用例逐一对应）:
//   tests/unit/services/face-kw/face-parameters.test.ts
//   tests/unit/services/face-kw/face-kw-observations.test.ts
//   tests/unit/services/face-kw/face-binding-migration.test.ts
//   tests/unit/services/face-kw/face-run-record.test.ts
//   （无 TS 单测的 fkw.merge / remove_member / getClusters / 写回命令与
//   person CRUD 按 face-kw.ipc.ts / person.ipc.ts 契约补测）
// 差异说明：
// - TS 用 vi.mock 替换推理 worker / 聚类 worker / 仓库；Swift 侧经注入的
//   inferenceProvider / clusterProvider / decodeProvider 对齐，仓库为真实
//   临时 SQLite（迁移已跑）。推理部分注入 fake，不跑 Vision。
// - 观察保留用例（TS face-kw-observations）以真实仓库断言库内状态等价于
//   mock 调用断言（replace/upsert 未调用 ↔ 旧观察仍在、状态表为空）。
// - run-record 的「写入失败」用例：TS 让 replaceObservationsByPhoto mock
//   抛错；Swift 用 ALTER TABLE DROP COLUMN embedding 使替换插入必然失败，
//   其余读路径不受影响。

import Dispatch
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
@testable import GatherDelivery

// MARK: - 支撑

// AsyncGate 已抽到 Tests/GatherTestSupport/AsyncGate.swift（GatherTestSupport target 共享）。

/// 线程安全布尔旗标（provider 进入断言用）。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set() {
        lock.lock()
        _value = true
        lock.unlock()
    }
}

/// 轮询等待条件成立（避免固定 sleep）。
private func waitUntil(
    timeoutMs: Double = 5000,
    _ condition: () throws -> Bool
) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutMs / 1000)
    while Date() < deadline {
        if try condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return try condition()
}

/// 线程安全说明（Swift 6 `Sendable`）：全部存储属性构造后不可变，Task 会按值
/// 捕获整个 harness；DBConnection 自带连接锁，FaceKwService 的并发调用由会话
/// 占用槽串行化。结构无锁、无写者，故标注 `@unchecked`（不可变性即此处承诺）。
private struct FaceKwHarness: @unchecked Sendable {
    let db: DBConnection
    let service: FaceKwService
    let sessionRepo: SessionRepo
    let faceRepo: FaceRepo
    let personRepo: PersonRepo
    let sessionId: String
    /// photo-1 的文件路径（真实临时文件；其余照片为插入行）。
    let photoPath: String
}

/// 建真实照片文件 + 已迁移库 + 服务。默认注入 fake 解码（TS 的 imageService
/// mock 语义）；推理默认返回单脸 [10,20,30,40] / 0.95 / [0.5,0.6]。
private func makeFaceKwHarness(
    photoCount: Int = 1,
    inference: FaceKwService.FaceInferenceProvider? = nil,
    cluster: FaceKwService.FaceClusterProvider? = nil,
    writeback: FaceWritebackProvider? = nil,
    delivery: (any FaceKwDeliveryPort)? = nil,
    settings: [String: Double] = [:],
    settingsProvider: ((String, Double) -> Double)? = nil,
    stringSettings: [String: String] = [:]
) throws -> FaceKwHarness {
    let db = try makeTestDB()
    let sessionRepo = SessionRepo(connection: db)
    let session = try sessionRepo.create(name: "Run", source: "folder")
    let dir = try makeTempDir()
    var photoPath = ""
    for i in 1...photoCount {
        let path = try writeTempFile(in: dir, name: "photo\(i).jpg")
        try insertPhoto(db, id: "photo-\(i)", sessionId: session.id, filepath: path)
        if i == 1 { photoPath = path }
    }
    let service = FaceKwService(
        photoRepo: PhotoRepo(connection: db),
        sessionRepo: sessionRepo,
        faceRepo: FaceRepo(connection: db),
        personRepo: PersonRepo(connection: db),
        connection: db,
        getNumber: { key, defaultValue in
            // settingsProvider 优先：供"同一次运行中改设置"的用例（见 FaceAlgorithmWiringTests）。
            if let settingsProvider { return settingsProvider(key, defaultValue) }
            return settings[key] ?? defaultValue
        },
        getString: { key, defaultValue in
            // 字符串设置（模型路径/版本/增量开关）此前无法注入，导致"服务是否真的读设置"没有覆盖。
            stringSettings[key] ?? defaultValue
        },
        decodeProvider: { _, _ in Data("jpeg".utf8) },
        inferenceProvider: inference ?? defaultFakeInference(),
        clusterProvider: cluster ?? { entries, eps, minPts, options, onProgress, isCancelled in
            try FaceClusterer.clusterEmbeddings(
                entries: entries,
                eps: eps,
                minPts: minPts,
                coreQualityFloor: options.coreQualityFloor,
                retryMinSamples: options.retryMinSamples,
                onProgress: onProgress,
                isCancelled: isCancelled)
        },
        writebackProvider: writeback,
        delivery: delivery
    )
    return FaceKwHarness(
        db: db, service: service, sessionRepo: sessionRepo,
        faceRepo: FaceRepo(connection: db), personRepo: PersonRepo(connection: db),
        sessionId: session.id, photoPath: photoPath
    )
}

/// 默认 fake 推理：每图一个成功脸。
private func defaultFakeInference() -> FaceKwService.FaceInferenceProvider {
    { images, _, _ in
        images.map { _ in
            FaceInferenceItem(observations: [
                FaceInferenceObservation(bbox: [10, 20, 30, 40], confidence: 0.95, embedding: [0.5, 0.6]),
            ])
        }
    }
}

/// 建一个 face_clusters 行 + 成员（photoId 需已存在于 photos）。
@discardableResult
private func seedCluster(
    _ db: DBConnection,
    id: Int64,
    sessionId: String,
    label: String = "Person 1",
    status: String = "unbound",
    members: [(photoId: String, bbox: [Double], confidence: Double)] = []
) throws -> Int64 {
    _ = try db.prepare("""
        INSERT INTO face_clusters (id, session_id, label, status, thumbnail_path)
        VALUES (?, ?, ?, ?, '')
      """).run([.int(id), .text(sessionId), .text(label), .text(status)])
    for member in members {
        let bboxJSON = try JSONValue.stringify(JSONValue.array(member.bbox.map { JSONValue.real($0) }))
        _ = try db.prepare("""
            INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence, observation_id)
            VALUES (?, ?, ?, ?, ?, NULL)
          """).run([
            .int(id), .text(sessionId), .text(member.photoId), .text(bboxJSON), .real(member.confidence),
        ])
    }
    return id
}

/// 绑定角色到集群（faceRepo.updateBinding 的测试便捷封装）。
private func bind(_ harness: FaceKwHarness, clusterId: Int64, roleName: String, keywords: [String] = []) throws {
    try harness.faceRepo.updateBinding(clusterId: clusterId, roleName: roleName, keywords: keywords)
}

private func runRow(_ db: DBConnection, _ sessionId: String) throws -> DBRow? {
    try db.prepare(
        "SELECT kind, photo_count, index_seq, params_json, started_at, finished_at, status FROM analysis_runs WHERE session_id = ?"
    ).get([.text(sessionId)])
}

private let analysisSignatureForDefaults = FaceKwService.makeAnalysisSignature(
    detectorPath: "det.onnx", encoderPath: "enc.onnx",
    primaryDetectionSize: 640, secondaryDetectionSize: 128,
    confidenceThreshold: 0.5, encoderInputSize: 112, embeddingDim: 512,
    previewMaxDimension: 2048, embeddingSpec: try! FaceEmbeddingModelFactory.spec(modelPath: "", modelVersion: "").signature
)

// MARK: - 参数校验（TS: face-parameters.test.ts）

@Suite("face clustering parameter validation")
struct FaceClusteringParameterTests {
    // TS: it.each —— eps: NaN/-0.1/1.1（无效），minPts: 0/1.5（无效）。
    // 注意 Swift Testing 的 arguments 是笛卡尔积，TS it.each 是成对 zip，
    // 故用元组数组保证逐 case 对应。
    @Test(arguments: [
        (Double.nan, 2.0),
        (-0.1, 2.0),
        (1.1, 2.0),
        (0.6, 0.0),
        (0.6, 1.5),
    ])
    func rejectsInvalid(_ pair: (eps: Double, minPts: Double)) throws {
        #expect(throws: FaceKwServiceError.self) {
            try validateFaceClusteringParameters(eps: pair.eps, minPts: pair.minPts)
        }
    }

    @Test("accepts supported similarity and minimum-sample values")
    func acceptsValid() {
        #expect(throws: Never.self) { try validateFaceClusteringParameters(eps: 0.6, minPts: 1) }
        #expect(throws: Never.self) { try validateFaceClusteringParameters(eps: 1, minPts: 2.0) }
    }
}

// MARK: - analyze 观察保留（TS: face-kw-observations.test.ts 前两个用例）

@Suite("FaceKwService.analyze observation retention")
struct FaceKwObservationRetentionTests {
    @Test("keeps previous observations when re-inference for a photo fails")
    func keepsObservationsOnFailedInference() async throws {
        let harness = try makeFaceKwHarness(
            inference: { images, _, _ in
                images.map { _ in FaceInferenceItem(error: "inference failed") }
            }
        )
        let oldIds = try harness.faceRepo.replaceObservationsByPhoto(sessionId: harness.sessionId, photoId: "photo-1", observations: [
            FaceObservationInput(
                photoId: "photo-1", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4,
                embedding: [0.1, 0.2, 0.3], confidence: 0.9,
                sourceFileSize: 1, sourceFileMtimeMs: 1, analysisSignature: "old"),
        ])

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")

        #expect(result.status == "failed")
        #expect(result.detectionFailures == 1)
        // 旧观察必须存活于失败推理。
        let observations = try harness.faceRepo.getObservations(harness.sessionId)
        #expect(observations.count == 1)
        #expect(observations[0].id == oldIds[0])
        #expect(observations[0].confidence == 0.9)
        // 状态未写入。
        #expect(try harness.faceRepo.getAnalysisStates(harness.sessionId).isEmpty)
    }

    @Test("replaces previous observations atomically after a successful inference")
    func replacesObservationsOnSuccess() async throws {
        let harness = try makeFaceKwHarness()

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")

        #expect(result.status == "done")
        #expect(result.detectionFailures == 0)
        let observations = try harness.faceRepo.getObservations(harness.sessionId)
        #expect(observations.count == 1)
        #expect(observations[0].photoId == "photo-1")
        #expect(observations[0].bboxX == 10)
        #expect(observations[0].bboxY == 20)
        #expect(observations[0].bboxW == 30)
        #expect(observations[0].bboxH == 40)
        #expect(observations[0].confidence == 0.95)
        let state = try harness.faceRepo.getAnalysisStates(harness.sessionId)
        #expect(state["photo-1"]?.analysisSignature == analysisSignatureForDefaults)
        // 终态真相源是 analysis_runs（sessions.analysis_status 无人写）。
        #expect(try runRow(harness.db, harness.sessionId)?[6].textValue == "ok")
    }
}

// MARK: - analyze run 记录（TS: face-run-record.test.ts）

@Suite("FaceKwService analysis run records")
struct FaceKwRunRecordTests {
    @Test("writes a face run row at entry and finalizes it to ok")
    func runRowFinalizesOk() async throws {
        let harness = try makeFaceKwHarness()

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx",
            eps: 0.6, minPts: 2)

        #expect(result.status == "done")
        let row = try runRow(harness.db, harness.sessionId)!
        #expect(row[0].textValue == "face")
        #expect(row[1].intValue == 1)
        #expect(row[2].intValue == 0)
        #expect(row[3].textValue != "")
        #expect(row[4].textValue != "")  // started_at
        #expect(row[5].textValue != "")  // finished_at
        #expect(row[6].textValue == "ok")
        let params = try JSONValue.parse(row[3].textValue ?? "{}")
        #expect(params["detectorPath"] == .string("det.onnx"))
        #expect(params["encoderPath"] == .string("enc.onnx"))
        #expect(params["eps"] == .number(0.6))
        #expect(params["minPts"] == .number(2))
    }

    @Test("finalizes the run as failed when every detection fails")
    func runRowFinalizesFailed() async throws {
        let harness = try makeFaceKwHarness()
        // 使 replaceObservationsByPhoto 的写入必然失败（INSERT 触发器 ABORT）；
        // 读路径（getObservations / 状态）不受影响——等价 TS mock 抛错。
        // 注：S5a 后 getObservations 显式投影 embedding，DROP COLUMN 会先让读失败，
        // 无法再用作“只坏写入”的替身。
        try harness.db.exec("""
            CREATE TRIGGER fail_face_observation_insert
            BEFORE INSERT ON face_observations
            BEGIN SELECT RAISE(ABORT, 'forced insert failure'); END;
            """)

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")

        #expect(result.status == "failed")
        let row = try runRow(harness.db, harness.sessionId)!
        #expect(row[6].textValue == "failed")
        #expect(row[5].textValue != "")
    }
}

// MARK: - analyze 流程（缓存 / 取消 / 占用 / 进度 / 空结果）

@Suite("FaceKwService.analyze flow")
struct FaceKwAnalyzeFlowTests {
    @Test("serves cached clusters without re-inference when nothing changed")
    func cachedClustersEarlyReturn() async throws {
        let probe = LockedFlag()
        let harness = try makeFaceKwHarness(inference: { images, _, _ in
            probe.set()
            throw FaceKwServiceError.analysisRunning
        })
        _ = try harness.faceRepo.replaceObservationsByPhoto(sessionId: harness.sessionId, photoId: "photo-1", observations: [
            FaceObservationInput(
                photoId: "photo-1", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4,
                embedding: [0.1, 0.2, 0.3], confidence: 0.9),
        ])
        guard let stat = tsStat(harness.photoPath) else {
            Issue.record("photo file stat failed")
            return
        }
        try harness.faceRepo.upsertAnalysisState(
            sessionId: harness.sessionId, photoId: "photo-1",
            sourceFileSize: stat.size, sourceFileMtimeMs: stat.mtimeMs,
            analysisSignature: analysisSignatureForDefaults)
        // 聚类签名（缓存键）含质量门槛与二遍阈值：用生产同一构造函数，避免格式漂移导致
        // 该用例悄悄退化为"重聚类"（本测试断言的是缓存快路径）。
        let seededClusterOptions = FaceKwService.clusterOptions(from: { _, defaultValue in defaultValue })
        try harness.faceRepo.upsertClusterSignature(
            sessionId: harness.sessionId,
            signature: FaceKwService.clusterSignature(eps: 0.65, minPts: 2, options: seededClusterOptions))
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])

        var phases: [String] = []
        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx",
            onProgress: { _, _, phase in phases.append(phase) })

        #expect(result.status == "done")
        #expect(probe.value == false)  // 推理未被调用
        #expect(phases.contains("face.cached-clusters"))
        #expect(try runRow(harness.db, harness.sessionId)?[6].textValue == "ok")
    }

    @Test("cancels an in-flight analysis and reports cancelled")
    func cancelsInFlightAnalysis() async throws {
        let gate = AsyncGate()
        let entered = LockedFlag()
        let harness = try makeFaceKwHarness(inference: { images, _, _ in
            entered.set()
            await gate.wait()
            return images.map { _ in FaceInferenceItem(observations: []) }
        })

        let task = Task {
            try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        }
        _ = try waitUntil { entered.value }
        harness.service.cancel(sessionId: harness.sessionId)
        gate.release()

        let result = try await task.value
        #expect(result.status == "cancelled")
        // 取消的 run 以 'failed' 终态（run 记录只区分 ok/failed）；取消态由
        // analysis_jobs 表达，sessions.analysis_status 已不再写入。
        #expect(try runRow(harness.db, harness.sessionId)?[6].textValue == "failed")
    }

    @Test("rejects a second analyze while one is running")
    func rejectsConcurrentAnalysis() async throws {
        let gate = AsyncGate()
        let harness = try makeFaceKwHarness(inference: { images, _, _ in
            await gate.wait()
            return images.map { _ in FaceInferenceItem(observations: []) }
        })

        let task = Task {
            try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        }
        _ = try waitUntil {
            try runRow(harness.db, harness.sessionId)?[6].textValue == "running"
        }

        await #expect(throws: FaceKwServiceError.analysisRunning) {
            try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        }

        gate.release()
        _ = try await task.value
    }

    @Test("reports detect/cluster progress phases in order")
    func reportsProgressPhases() async throws {
        let harness = try makeFaceKwHarness(photoCount: 2)
        var phases: [String] = []
        var lastDetect: (current: Int, total: Int) = (0, 0)
        var sawClusterProgress = false

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx",
            onProgress: { current, total, phase in
                phases.append(phase)
                if phase == "face.detect" { lastDetect = (current, total) }
                if phase == "face.cluster" && total > 0 { sawClusterProgress = true }
            })

        #expect(result.status == "done")
        #expect(phases.first == "face.init")
        #expect(phases.contains("face.detect"))
        #expect(phases.contains("face.cluster"))
        #expect(phases.contains("face.done"))
        #expect(lastDetect == (2, 2))
        #expect(sawClusterProgress)
    }

    @Test("clears stale clusters when a completed analysis has no faces")
    func clearsClustersOnEmptyResult() async throws {
        let harness = try makeFaceKwHarness(inference: { images, _, _ in
            images.map { _ in FaceInferenceItem(observations: []) }
        })
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")

        #expect(result.status == "done")
        #expect(try harness.faceRepo.getClusters(harness.sessionId).isEmpty)
    }

    @Test("keeps clusters and bindings when the run is reported failed")
    func keepsClustersOnFailedRun() async throws {
        let harness = try makeFaceKwHarness(inference: { images, _, _ in
            images.map { _ in FaceInferenceItem(error: "all failed") }
        })
        // 全零 embedding 的观察：聚类输入为空（TS 的 some(value !== 0) 过滤）。
        _ = try harness.faceRepo.replaceObservationsByPhoto(sessionId: harness.sessionId, photoId: "photo-1", observations: [
            FaceObservationInput(
                photoId: "photo-1", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4,
                embedding: [0, 0, 0], confidence: 0.9),
        ])
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try bind(harness, clusterId: 1, roleName: "Alice", keywords: ["kw"])

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")

        #expect(result.status == "failed")
        // 全失败 run 不摧毁用户已绑定的集群与角色名。
        // includeMembers 才加载 binding（TS face.repo.getClusters 同款）。
        let clusters = try harness.faceRepo.getClusters(harness.sessionId, includeMembers: true)
        #expect(clusters.count == 1)
        #expect(clusters[0].binding?.roleName == "Alice")
        #expect(clusters[0].binding?.keywords == ["kw"])
    }

    @Test("throws SESSION_NOT_FOUND for an unknown session")
    func throwsSessionNotFound() async throws {
        let harness = try makeFaceKwHarness()
        await #expect(throws: FaceKwServiceError.sessionNotFound) {
            try await harness.service.analyze(
                sessionId: "missing", detectorPath: "det.onnx", encoderPath: "enc.onnx")
        }
    }

    @Test("throws FACE_NO_PHOTOS for an empty session")
    func throwsNoPhotos() async throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "Empty", source: "folder")
        let service = FaceKwService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: sessionRepo,
            faceRepo: FaceRepo(connection: db),
            personRepo: PersonRepo(connection: db),
            connection: db,
            decodeProvider: { _, _ in Data("jpeg".utf8) },
            inferenceProvider: defaultFakeInference()
        )
        await #expect(throws: FaceKwServiceError.noPhotos) {
            try await service.analyze(
                sessionId: session.id, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        }
    }

    @Test("rejects invalid clustering parameters before anything else")
    func throwsInvalidParameters() async throws {
        let harness = try makeFaceKwHarness()
        await #expect(throws: FaceKwServiceError.epsInvalid) {
            try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "d", encoderPath: "e", eps: -0.1)
        }
        await #expect(throws: FaceKwServiceError.minClusterInvalid) {
            try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "d", encoderPath: "e", minPts: 0)
        }
    }
}

// MARK: - 绑定迁移（TS: face-binding-migration.test.ts）

@Suite("FaceKwService binding migration across re-clustering")
struct FaceKwBindingMigrationTests {
    /// 建会话 + 观察（p1/p2）+ 旧集群与绑定。
    private func makeMigrationHarness(
        bindings: [(clusterId: Int64, roleName: String, keywords: [String], photoIds: [String])],
        clusterResult: [[(observationId: Int, photoId: String)]]
    ) throws -> (db: DBConnection, service: FaceKwService, faceRepo: FaceRepo, sessionId: String) {
        let db = try makeTestDB()
        let sessionId = "session-1"
        try insertSession(db, sessionId)
        for id in ["p1", "p2", "p3", "p4"] {
            try insertPhoto(db, id: id, sessionId: sessionId, filepath: "/photos/\(id).jpg")
        }
        let faceRepo = FaceRepo(connection: db)
        let obs1 = try faceRepo.replaceObservationsByPhoto(sessionId: sessionId, photoId: "p1", observations: [
            FaceObservationInput(photoId: "p1", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4, embedding: [0.1, 0.2, 0.3], confidence: 0.9),
        ])
        let obs2 = try faceRepo.replaceObservationsByPhoto(sessionId: sessionId, photoId: "p2", observations: [
            FaceObservationInput(photoId: "p2", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4, embedding: [0.1, 0.2, 0.3], confidence: 0.9),
        ])
        // 观测 id 由 seedCluster 的成员行引用，这里不再单独持有。
        _ = (obs1, obs2)
        for binding in bindings {
            try seedCluster(
                db, id: binding.clusterId, sessionId: sessionId, label: "Person \(binding.clusterId)",
                status: "bound",
                members: binding.photoIds.map { (photoId: $0, bbox: [1, 2, 3, 4], confidence: 0.9) })
            try faceRepo.updateBinding(clusterId: binding.clusterId, roleName: binding.roleName, keywords: binding.keywords)
        }
        let service = FaceKwService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            faceRepo: faceRepo,
            personRepo: PersonRepo(connection: db),
            connection: db,
            clusterProvider: { entries, _, _, _, _, _ in
                FaceClusterResult(
                    clusters: clusterResult.map { group in
                        group.compactMap { entry in
                            entries.first { $0.observationId == entry.observationId }
                        }
                    },
                    noise: []
                )
            }
        )
        return (db, service, faceRepo, sessionId)
    }

    @Test("re-attaches a binding to the new cluster with the largest member overlap")
    func reattachesToLargestOverlap() async throws {
        // 新库自增：两条观察 id 为 1/2。
        let harness = try makeMigrationHarness(
            bindings: [(clusterId: 7, roleName: "Alice", keywords: ["kw"], photoIds: ["p1", "p2"])],
            clusterResult: [
                // 新集群 1 保留 Alice 的两条观察；新集群 2 是陌生人（不在库内）。
                [(observationId: 1, photoId: "p1"), (observationId: 2, photoId: "p2")],
                [(observationId: 12, photoId: "p3")],
            ]
        )

        try await harness.service.recluster(sessionId: harness.sessionId, eps: 0.6, minPts: 2)

        let bindings = try harness.faceRepo.getBindingsBySession(harness.sessionId)
        #expect(bindings.count == 1)
        #expect(bindings[0].roleName == "Alice")
        #expect(bindings[0].keywords == ["kw"])
        // 绑定落在保留 p1/p2 的新集群上。
        let memberPhotos = Set(try harness.faceRepo.getClusterMembers(bindings[0].clusterId).map(\.photoId))
        #expect(memberPhotos == ["p1", "p2"])
    }

    @Test("manual identities remain separate even when automatic clustering would merge them")
    func largerOverlapWinsCompetition() async throws {
        let harness = try makeMigrationHarness(
            bindings: [
                (clusterId: 1, roleName: "Alice", keywords: [], photoIds: ["p1", "p3"]),
                (clusterId: 2, roleName: "Bob", keywords: [], photoIds: ["p2", "p4"]),
            ],
            clusterResult: [
                // 新集群吸收 Alice（p1）与 Bob（p2），但 Bob 的第二条观察消失：
                // Alice 的重叠 2 获胜。
                [
                    (observationId: 1, photoId: "p1"),
                    (observationId: 2, photoId: "p2"),
                    (observationId: 12, photoId: "p3"),
                ],
            ]
        )

        try await harness.service.recluster(sessionId: harness.sessionId, eps: 0.6, minPts: 2)

        let bindings = try harness.faceRepo.getBindingsBySession(harness.sessionId)
        #expect(bindings.count == 2)
        #expect(Set(bindings.map(\.roleName)) == ["Alice", "Bob"])
        #expect(bindings[0].keywords == [])
    }

    @Test("manual identity survives automatic clustering classifying its faces as noise")
    func dropsVanishedBinding() async throws {
        let harness = try makeMigrationHarness(
            bindings: [(clusterId: 7, roleName: "Alice", keywords: ["kw"], photoIds: ["p1"])],
            clusterResult: [
                [(observationId: 2, photoId: "p2")],
            ]
        )

        try await harness.service.recluster(sessionId: harness.sessionId, eps: 0.6, minPts: 2)

        #expect(try harness.faceRepo.getBindingsBySession(harness.sessionId).first?.roleName == "Alice")
    }
}

// MARK: - clusters 读取与集群命令

@Suite("FaceKwService.getClusters shape")
struct FaceKwGetClustersTests {
    @Test("truncates members to the preview window and maps binding fields")
    func truncatesMembersAndMapsBinding() throws {
        let db = try makeTestDB()
        let sessionId = "session-1"
        try insertSession(db, sessionId)
        // 成员数刻意超过预览窗口上限（12），才能验证"截断但仍报全量 size"。
        for i in 1...14 {
            try insertPhoto(db, id: "photo-\(i)", sessionId: sessionId, filepath: "/photos/photo-\(i).jpg")
        }
        let faceRepo = FaceRepo(connection: db)
        try seedCluster(
            db, id: 1, sessionId: sessionId, label: "Person 1", status: "bound",
            members: (1...14).map { (photoId: "photo-\($0)", bbox: [Double($0), 2, 3, 4], confidence: 0.9) })
        try faceRepo.updateBinding(clusterId: 1, roleName: "Alice", keywords: ["kw1", "kw2"])

        let service = FaceKwService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            faceRepo: faceRepo,
            personRepo: PersonRepo(connection: db),
            connection: db
        )
        let clusters = try service.getClusters(sessionId: sessionId)

        #expect(clusters.count == 1)
        let cluster = clusters[0]
        #expect(cluster.id == 1)
        #expect(cluster.sessionId == sessionId)
        #expect(cluster.label == "Person 1")
        #expect(cluster.size == 14, "size 是全量成员数，不受预览截断影响")
        #expect(cluster.status == "bound")
        #expect(cluster.thumbnailBase64 == "")
        #expect(cluster.binding?.roleName == "Alice")
        #expect(cluster.binding?.keywords == ["kw1", "kw2"])
        // 网格卡片只渲染前 maxPreviewMembers 个成员（FaceKwService 内，当前 12）：
        // 载荷裁剪，不影响聚类/绑定语义。
        #expect(cluster.members.count == 12)
        #expect(cluster.thumbnailPhotoId == "photo-1")
        #expect(cluster.members[0].memberId == 1)
        #expect(cluster.members[0].filename == "photo-1.jpg")
        #expect(cluster.members[0].bbox == [1, 2, 3, 4])
        #expect(cluster.members[0].confidence == 0.9)
    }
}

@Suite("FaceKwService cluster commands")
struct FaceKwClusterCommandTests {
    @Test("binds a cluster with normalized role and deduped keywords, bridging the person library")
    func bindNormalizesAndBridges() throws {
        let harness = try makeFaceKwHarness()
        try seedCluster(harness.db, id: 7, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])

        try harness.service.bindCluster(
            sessionId: harness.sessionId, clusterId: 7, roleName: " Alice ", keywords: ["kw1", "kw1", ""])

        let bindings = try harness.faceRepo.getBindingsBySession(harness.sessionId)
        #expect(bindings.count == 1)
        #expect(bindings[0].roleName == "Alice")
        #expect(bindings[0].keywords == ["kw1"])
        #expect(try harness.faceRepo.getClusters(harness.sessionId)[0].status == "bound")
        // 人物库桥接。
        let persons = try harness.personRepo.list()
        #expect(persons.count == 1)
        #expect(persons[0].name == "Alice")
        #expect(try harness.personRepo.getPhotosWithDetails(personId: persons[0].id).photos.count == 1)
    }

    @Test("throws FKW_CLUSTER_NOT_FOUND and FKW_CLUSTER_NOT_IN_SESSION on bind")
    func bindClusterErrors() throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let sessionA = try sessionRepo.create(name: "A", source: "folder")
        let sessionB = try sessionRepo.create(name: "B", source: "folder")
        let faceRepo = FaceRepo(connection: db)
        try seedCluster(db, id: 1, sessionId: sessionA.id)
        let service = FaceKwService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: sessionRepo,
            faceRepo: faceRepo,
            personRepo: PersonRepo(connection: db),
            connection: db
        )
        #expect(throws: FaceKwServiceError.clusterNotFound) {
            try service.bindCluster(sessionId: sessionA.id, clusterId: 99, roleName: "Alice", keywords: [])
        }
        #expect(throws: FaceKwServiceError.clusterNotInSession) {
            try service.bindCluster(sessionId: sessionB.id, clusterId: 1, roleName: "Alice", keywords: [])
        }
        #expect(throws: FaceKwServiceError.roleNameEmpty) {
            try service.bindCluster(sessionId: sessionA.id, clusterId: 1, roleName: "   ", keywords: [])
        }
    }

    @Test("unbinds a cluster and reconciles the person library")
    func unbindsAndReconciles() throws {
        let harness = try makeFaceKwHarness()
        try seedCluster(harness.db, id: 7, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try bind(harness, clusterId: 7, roleName: "Alice", keywords: ["kw"])
        try harness.service.bindCluster(sessionId: harness.sessionId, clusterId: 7, roleName: "Alice", keywords: ["kw"])
        let personId = try harness.personRepo.list()[0].id

        try harness.service.unbindCluster(sessionId: harness.sessionId, clusterId: 7)

        #expect(try harness.faceRepo.getBindingsBySession(harness.sessionId).isEmpty)
        #expect(try harness.faceRepo.getClusters(harness.sessionId)[0].status == "unbound")
        // 人物库对账：绑定移除后链接摘除。
        #expect(try harness.personRepo.getPhotosWithDetails(personId: personId).photos.isEmpty)
    }

    @Test("merges clusters moving members and dropping the source binding")
    func mergesClusters() throws {
        let harness = try makeFaceKwHarness(photoCount: 2)
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try seedCluster(harness.db, id: 2, sessionId: harness.sessionId,
                        members: [(photoId: "photo-2", bbox: [5, 6, 7, 8], confidence: 0.8)])
        try bind(harness, clusterId: 1, roleName: "Alice", keywords: [])

        try harness.service.mergeClusters(sessionId: harness.sessionId, sourceId: 1, targetId: 2)

        let targetMembers = try harness.faceRepo.getClusterMembers(2).map(\.photoId)
        #expect(targetMembers == ["photo-1", "photo-2"])
        #expect(try harness.faceRepo.getClusterMembers(1).isEmpty)
        #expect(try harness.faceRepo.getBindingsBySession(harness.sessionId).isEmpty)
    }

    @Test("validates merge inputs")
    func mergeErrors() throws {
        let harness = try makeFaceKwHarness()
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId)
        try seedCluster(harness.db, id: 2, sessionId: harness.sessionId)
        let otherSession = try harness.sessionRepo.create(name: "Other", source: "folder")
        _ = try harness.db.prepare("""
            INSERT INTO face_clusters (id, session_id, label, status, thumbnail_path)
            VALUES (50, ?, 'x', 'unbound', '')
          """).run([.text(otherSession.id)])
        #expect(throws: FaceKwServiceError.selfMerge) {
            try harness.service.mergeClusters(sessionId: harness.sessionId, sourceId: 1, targetId: 1)
        }
        #expect(throws: FaceKwServiceError.clusterNotFound) {
            try harness.service.mergeClusters(sessionId: harness.sessionId, sourceId: 1, targetId: 99)
        }
        #expect(throws: FaceKwServiceError.clusterNotInSession) {
            try harness.service.mergeClusters(sessionId: harness.sessionId, sourceId: 1, targetId: 50)
        }
    }

    @Test("removes a member and deletes the cluster when it was the last one")
    func removesMember() throws {
        let harness = try makeFaceKwHarness(photoCount: 2)
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId,
                        members: [
                            (photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9),
                            (photoId: "photo-2", bbox: [5, 6, 7, 8], confidence: 0.8),
                        ])
        try harness.service.removeMember(sessionId: harness.sessionId, clusterId: 1, memberId: 1)
        #expect(try harness.faceRepo.getClusterMembers(1).map(\.photoId) == ["photo-2"])
        #expect(try harness.faceRepo.getClusters(harness.sessionId)[0].memberCount == 1)

        try harness.service.removeMember(sessionId: harness.sessionId, clusterId: 1, memberId: 2)
        #expect(try harness.faceRepo.getClusters(harness.sessionId).isEmpty)
    }

    @Test("validates removeMember inputs")
    func removeMemberErrors() throws {
        let harness = try makeFaceKwHarness()
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        #expect(throws: FaceKwServiceError.clusterNotFound) {
            try harness.service.removeMember(sessionId: harness.sessionId, clusterId: 99, memberId: 1)
        }
        #expect(throws: FaceKwServiceError.clusterMemberNotFound) {
            try harness.service.removeMember(sessionId: harness.sessionId, clusterId: 1, memberId: 99)
        }
    }

    @Test("recluster validates and requires observations")
    func reclusterErrors() async throws {
        let harness = try makeFaceKwHarness()
        await #expect(throws: FaceKwServiceError.epsInvalid) {
            try await harness.service.recluster(sessionId: harness.sessionId, eps: 1.5, minPts: 2)
        }
        await #expect(throws: FaceKwServiceError.sessionNotFound) {
            try await harness.service.recluster(sessionId: "missing", eps: 0.6, minPts: 2)
        }
        await #expect(throws: FaceKwServiceError.noObservations) {
            try await harness.service.recluster(sessionId: harness.sessionId, eps: 0.6, minPts: 2)
        }
    }
}

// MARK: - 写回（经注入 Provider）

private final class FakeWritebackProvider: FaceWritebackProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _removedEntries: [FaceKeywordEntry] = []
    private var _previewArgs: (options: FaceKwWritebackOptions?, boundPhotoIds: Set<String>, additions: [String: [String]])?
    private var _executedItems: [FaceKwWritebackItem] = []
    private var _syncedSessionIds: [String] = []
    private var _cleanupCalls: [String] = []

    var removedKeywords: [String] = ["Alice"]
    var previewResult = FaceKwWritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    var executeResult = FaceKwWritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0, errors: [], failedItems: [], report: "")
    var cleanupResult = FaceKwCleanupResult(deletedCount: 0, errors: [])

    var removedEntries: [FaceKeywordEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _removedEntries
    }

    var previewArgs: (options: FaceKwWritebackOptions?, boundPhotoIds: Set<String>, additions: [String: [String]])? {
        lock.lock()
        defer { lock.unlock() }
        return _previewArgs
    }

    var executedItems: [FaceKwWritebackItem] {
        lock.lock()
        defer { lock.unlock() }
        return _executedItems
    }

    var syncedSessionIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _syncedSessionIds
    }

    var cleanupCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _cleanupCalls
    }

    /// 同步锁临界区辅助（Swift 6：async 上下文不得直接 lock/unlock）。
    private func setRemovedEntries(_ entries: [FaceKeywordEntry]) {
        lock.lock()
        defer { lock.unlock() }
        _removedEntries = entries
    }

    private func setPreviewArgs(
        options: FaceKwWritebackOptions?, boundPhotoIds: Set<String>, additions: [String: [String]]
    ) {
        lock.lock()
        defer { lock.unlock() }
        _previewArgs = (options, boundPhotoIds, additions)
    }

    private func setExecutedItems(_ items: [FaceKwWritebackItem]) {
        lock.lock()
        defer { lock.unlock() }
        _executedItems = items
    }

    private func appendSyncedSessionId(_ sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        _syncedSessionIds.append(sessionId)
    }

    private func appendCleanupCall(_ sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        _cleanupCalls.append(sessionId)
    }

    func removeOwnedFaceKeywords(sessionId: String, entries: [FaceKeywordEntry]) async throws -> [String] {
        setRemovedEntries(entries)
        return removedKeywords
    }

    func preview(
        sessionId: String,
        options: FaceKwWritebackOptions?,
        boundPhotoIds: Set<String>,
        additions: [String: [String]]
    ) async throws -> FaceKwWritebackPreview {
        setPreviewArgs(options: options, boundPhotoIds: boundPhotoIds, additions: additions)
        return previewResult
    }

    func execute(sessionId: String, items: [FaceKwWritebackItem]) async throws -> FaceKwWritebackResult {
        setExecutedItems(items)
        return executeResult
    }

    func confirmSync(sessionId: String) async throws {
        appendSyncedSessionId(sessionId)
    }

    func cleanup(sessionId: String) async throws -> FaceKwCleanupResult {
        appendCleanupCall(sessionId)
        return cleanupResult
    }
}

/// FaceKwDeliveryPort 的替身（S5c-2b-2）：confirm/cleanup/镜像的服务层路由
/// 由这些用例验证；真实 coordinator 的 DB/文件语义在 DeliveryCoordinatorTests 覆盖。
private final class FakeFaceKwDelivery: FaceKwDeliveryPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _confirmCalls: [String] = []
    private var _cleanupCalls: [String] = []
    private var _mirrorItems: [DeliveryWritebackMirrorItem] = []

    var confirmResult = DeliveryConfirmSummary(
        scope: .module, confirmedLinks: 1, deliveriesSynced: 1, itemsSynced: 1,
        unconfirmedSessionIds: []
    )
    var confirmError: Error?
    var cleanupResult = DeliveryCleanupSummary(
        deletedCount: 0, conflictedCount: 0, skippedCount: 0, errors: []
    )
    var mirrorErrors: [String] = []

    var confirmCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _confirmCalls
    }

    var cleanupCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _cleanupCalls
    }

    var mirroredItems: [DeliveryWritebackMirrorItem] {
        lock.lock()
        defer { lock.unlock() }
        return _mirrorItems
    }

    func confirmFaceKeyword(sessionId: String) throws -> DeliveryConfirmSummary {
        lock.lock()
        _confirmCalls.append(sessionId)
        lock.unlock()
        if let confirmError { throw confirmError }
        return confirmResult
    }

    func cleanupFaceKeyword(sessionId: String) async throws -> DeliveryCleanupSummary {
        appendCleanupCall(sessionId)
        return cleanupResult
    }

    private func appendCleanupCall(_ sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        _cleanupCalls.append(sessionId)
    }

    func mirrorFaceKeywordWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        lock.lock()
        _mirrorItems.append(contentsOf: items)
        lock.unlock()
        return DeliveryMirrorSummary(deliveryCount: 1, itemCount: items.count, errors: mirrorErrors)
    }

    func replayPendingDeliveries() async throws -> DeliveryReplaySummary {
        DeliveryReplaySummary(appliedCount: 0, skippedCount: 0, failedCount: 0, errors: [])
    }
}

private func makeWritebackItem(photoId: String, id: Int64? = nil) -> FaceKwWritebackItem {
    FaceKwWritebackItem(
        id: id,
        photoId: photoId,
        photoPath: "/photos/\(photoId).jpg",
        sessionId: "session-1",
        module: "face_kw",
        keywords: ["Alice"],
        xmpPath: "/photos/\(photoId).xmp",
        backupPath: "",
        xmpStatus: "ready",
        errorMessage: "",
        attemptCount: 0,
        lastAttemptAt: ""
    )
}

@Suite("FaceKwService writeback commands")
struct FaceKwWritebackTests {
    @Test("fkw.unbind requires confirmation")
    func unbindRequiresConfirmation() async throws {
        let writeback = FakeWritebackProvider()
        let harness = try makeFaceKwHarness(writeback: writeback)
        await #expect(throws: FaceKwServiceError.unbindConfirmRequired) {
            _ = try await harness.service.unbind(sessionId: harness.sessionId, clusterId: 1, confirmed: false)
        }
    }

    @Test("fkw.unbind requires the cluster to exist")
    func unbindClusterNotFound() async throws {
        let writeback = FakeWritebackProvider()
        let harness = try makeFaceKwHarness(writeback: writeback)
        await #expect(throws: FaceKwServiceError.clusterNotFound) {
            _ = try await harness.service.unbind(sessionId: harness.sessionId, clusterId: 99, confirmed: true)
        }
    }

    @Test("fkw.unbind removes owned keywords through the provider and unbinds")
    func unbindRemovesOwnedKeywords() async throws {
        let writeback = FakeWritebackProvider()
        writeback.removedKeywords = ["Alice", "kw1"]
        let harness = try makeFaceKwHarness(writeback: writeback)
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try bind(harness, clusterId: 1, roleName: "Alice", keywords: ["kw1"])

        let result = try await harness.service.unbind(sessionId: harness.sessionId, clusterId: 1, confirmed: true)

        #expect(result.done == true)
        #expect(result.removedKeywords == ["Alice", "kw1"])
        #expect(writeback.removedEntries.count == 1)
        #expect(writeback.removedEntries[0].photoId == "photo-1")
        #expect(writeback.removedEntries[0].xmpPath == TSPath.xmpSidecarPath(harness.photoPath))
        #expect(writeback.removedEntries[0].keywords == ["Alice", "kw1"])
        // 服务层 unbind 已执行。
        #expect(try harness.faceRepo.getBindingsBySession(harness.sessionId).isEmpty)
    }

    @Test("fkw.unbind filters keywords protected by other bound clusters")
    func unbindFiltersProtectedKeywords() async throws {
        let writeback = FakeWritebackProvider()
        let harness = try makeFaceKwHarness(writeback: writeback)
        // 两个集群共享 photo-1：B（Bob）的绑定保护 "Bob"；A 的 Alice 关键词
        // 里也有 "Bob"——解除 A 时 "Bob" 必须被过滤。
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try seedCluster(harness.db, id: 2, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [5, 6, 7, 8], confidence: 0.8)])
        try bind(harness, clusterId: 1, roleName: "Alice", keywords: ["Bob"])
        try bind(harness, clusterId: 2, roleName: "Bob", keywords: [])

        _ = try await harness.service.unbind(sessionId: harness.sessionId, clusterId: 1, confirmed: true)

        #expect(writeback.removedEntries[0].keywords == ["Alice"])
        #expect(try harness.faceRepo.getBindingsBySession(harness.sessionId).count == 1)
        #expect(try harness.faceRepo.getBindingsBySession(harness.sessionId)[0].roleName == "Bob")
    }

    @Test("fkw.preview builds additions and forwards them to the provider")
    func previewForwardsAdditions() async throws {
        let writeback = FakeWritebackProvider()
        writeback.previewResult = FaceKwWritebackPreview(items: [], totalCount: 1, affectedPhotos: 1)
        let harness = try makeFaceKwHarness(writeback: writeback)
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try bind(harness, clusterId: 1, roleName: "Alice", keywords: ["kw1", "kw1", "kw2"])

        let result = try await harness.service.preview(
            sessionId: harness.sessionId, options: FaceKwWritebackOptions(createAlbums: true))

        #expect(result == writeback.previewResult)
        let args = writeback.previewArgs
        #expect(args?.boundPhotoIds == ["photo-1"])
        #expect(args?.additions == ["photo-1": ["Alice", "kw1", "kw2"]])
        #expect(args?.options == FaceKwWritebackOptions(createAlbums: true))
    }

    @Test("fkw.writeback requires confirmation and passes items through")
    func writebackConfirmationAndPassthrough() async throws {
        let writeback = FakeWritebackProvider()
        writeback.executeResult = FaceKwWritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0, errors: [], failedItems: [], report: "ok")
        let harness = try makeFaceKwHarness(writeback: writeback)
        let item = makeWritebackItem(photoId: "photo-1")

        await #expect(throws: FaceKwServiceError.writebackConfirmRequired) {
            _ = try await harness.service.writeback(
                sessionId: harness.sessionId, confirmed: false, items: [item])
        }

        // nil items 等价 TS 的 `params.items ?? []`。
        let result = try await harness.service.writeback(
            sessionId: harness.sessionId, confirmed: true, items: nil)
        #expect(result == writeback.executeResult)
        #expect(writeback.executedItems.isEmpty)

        _ = try await harness.service.writeback(
            sessionId: harness.sessionId, confirmed: true, items: [item])
        #expect(writeback.executedItems.count == 1)
        #expect(writeback.executedItems[0].photoId == "photo-1")
    }

    @Test("fkw.confirm_sync routes to the delivery coordinator")
    func confirmSyncReturnsTrue() async throws {
        let delivery = FakeFaceKwDelivery()
        let harness = try makeFaceKwHarness(delivery: delivery)

        let result = try await harness.service.confirmSync(sessionId: harness.sessionId)

        #expect(result == true)
        #expect(delivery.confirmCalls == [harness.sessionId])
    }

    @Test("fkw.confirm_sync maps coordinator gates to the legacy XMP codes")
    func confirmSyncMapsLegacyCodes() async throws {
        let delivery = FakeFaceKwDelivery()
        delivery.confirmError = DeliveryCoordinatorError.confirmIncomplete(blockers: ["item:failed=1"])
        let incomplete = try makeFaceKwHarness(delivery: delivery)

        await #expect(throws: DeliveryError.confirmIncomplete) {
            _ = try await incomplete.service.confirmSync(sessionId: incomplete.sessionId)
        }

        delivery.confirmError = DeliveryCoordinatorError.reloadNotAcknowledged(sessionId: "x")
        await #expect(throws: DeliveryError.confirmRequiresSync) {
            _ = try await incomplete.service.confirmSync(sessionId: incomplete.sessionId)
        }

        delivery.confirmError = nil
        delivery.confirmResult = DeliveryConfirmSummary(
            scope: .module, confirmedLinks: 1, deliveriesSynced: 0, itemsSynced: 0,
            unconfirmedSessionIds: ["session-2"]
        )
        await #expect(throws: DeliveryError.otherSessionNotConfirmed(sessionId: "session-2")) {
            _ = try await incomplete.service.confirmSync(sessionId: incomplete.sessionId)
        }
    }

    @Test("fkw.cleanup requires confirmation and returns the cleanup result")
    func cleanupConfirmationAndResult() async throws {
        let delivery = FakeFaceKwDelivery()
        delivery.cleanupResult = DeliveryCleanupSummary(
            deletedCount: 3, conflictedCount: 0, skippedCount: 0, errors: []
        )
        let harness = try makeFaceKwHarness(delivery: delivery)

        await #expect(throws: FaceKwServiceError.cleanupConfirmRequired) {
            _ = try await harness.service.cleanup(sessionId: harness.sessionId, confirmed: false)
        }
        let result = try await harness.service.cleanup(sessionId: harness.sessionId, confirmed: true)
        #expect(result.deletedCount == 3)
        #expect(result.errors.isEmpty)
        #expect(delivery.cleanupCalls == [harness.sessionId])
    }

    @Test("fkw.cleanup：外部冲突按路径回填 XMP_EXTERNALLY_MODIFIED")
    func cleanupMapsConflictToLegacyCode() async throws {
        let delivery = FakeFaceKwDelivery()
        delivery.cleanupResult = DeliveryCleanupSummary(
            deletedCount: 0, conflictedCount: 1, skippedCount: 0, errors: [],
            conflictedXmpPaths: ["/photos/photo-1.xmp"]
        )
        let harness = try makeFaceKwHarness(delivery: delivery)

        let result = try await harness.service.cleanup(
            sessionId: harness.sessionId, confirmed: true
        )
        #expect(result.deletedCount == 0)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].contains("XMP_EXTERNALLY_MODIFIED"))
        #expect(result.errors[0].contains("/photos/photo-1.xmp"))
    }

    @Test("fkw.writeback mirrors executed items into the delivery port")
    func writebackMirrorsIntoDelivery() async throws {
        let writeback = FakeWritebackProvider()
        writeback.executeResult = FaceKwWritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0, errors: [], failedItems: [], report: "ok"
        )
        let delivery = FakeFaceKwDelivery()
        let harness = try makeFaceKwHarness(writeback: writeback, delivery: delivery)

        let result = try await harness.service.writeback(
            sessionId: harness.sessionId,
            confirmed: true,
            items: [makeWritebackItem(photoId: "photo-1", id: 9)]
        )

        #expect(result.errors.isEmpty)
        #expect(delivery.mirroredItems.count == 1)
        let mirrored = delivery.mirroredItems[0]
        #expect(mirrored.photoId == "photo-1")
        #expect(mirrored.xmpPath == "/photos/photo-1.xmp")
        #expect(mirrored.status == .written)
        #expect(mirrored.keywords == ["Alice"])
    }
}

// MARK: - 人物库 CRUD（person.ipc.ts 契约）

@Suite("PersonRepo CRUD and bridge")
struct PersonLibraryTests {
    private func makePersonHarness() throws -> (db: DBConnection, repo: PersonRepo, sessionId: String, photoIds: [String]) {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "Run", source: "folder")
        for i in 1...3 {
            try insertPhoto(db, id: "photo-\(i)", sessionId: session.id, filepath: "/photos/photo-\(i).jpg")
        }
        return (db, PersonRepo(connection: db), session.id, ["photo-1", "photo-2", "photo-3"])
    }

    @Test("create/get/update/listWithCounts/delete roundtrip")
    func crudRoundtrip() throws {
        let (db, repo, _, _) = try makePersonHarness()
        let id = try repo.create(name: "Alice", keywords: ["kw1"])

        let person = try repo.get(id: id)!
        #expect(person.name == "Alice")
        #expect(((try? JSONValue.parse(person.keywords)) as JSONValue?)?.arrayValue == ["kw1"])

        try repo.update(id: id, fields: PersonUpdateFields(name: "Alice B.", keywords: ["kw1", "kw2"], notes: "note", matchThreshold: 0.6))
        let updated = try repo.get(id: id)!
        #expect(updated.name == "Alice B.")
        #expect(updated.notes == "note")
        #expect(updated.matchThreshold == 0.6)

        let withCounts = try repo.listWithCounts()
        #expect(withCounts.count == 1)
        #expect(withCounts[0].photoCount == 0)
        #expect(withCounts[0].sessionCount == 0)

        try repo.delete(id: id)
        #expect(try repo.get(id: id) == nil)
        #expect(try repo.list().isEmpty)
        _ = db
    }

    @Test("upsertByName merges keywords and addPhotos links photos")
    func upsertAndAddPhotos() throws {
        let (_, repo, sessionId, photoIds) = try makePersonHarness()
        let first = try repo.upsertByName(name: "Alice", keywords: ["kw1"])
        let again = try repo.upsertByName(name: "Alice", keywords: ["kw2"])
        #expect(first == again)
        let person = try repo.get(id: first)!
        #expect(((try? JSONValue.parse(person.keywords)) as JSONValue?)?.arrayValue == ["kw1", "kw2"])

        try repo.addPhotos(personId: first, sessionId: sessionId, photos: [
            PersonPhotoInput(photoId: photoIds[0], faceBbox: [1, 2, 3, 4], confidence: 0.9),
            PersonPhotoInput(photoId: photoIds[1], faceBbox: [5, 6, 7, 8], confidence: 0.8),
        ])
        let photos = try repo.getPhotosWithDetails(personId: first).photos.map(\.photo)
        #expect(photos.map(\.photoId) == ["photo-1", "photo-2"])
        #expect(try repo.countPhotos(personId: first) == 2)
        #expect(try repo.getSessionCount(personId: first) == 1)
        #expect(try repo.listWithCounts()[0].photoCount == 2)

        try repo.removePhoto(personId: first, photoId: "photo-1")
        #expect(try repo.getPhotosWithDetails(personId: first).photos.map(\.photo.photoId) == ["photo-2"])
    }

    @Test("merge transfers photos to the target and deletes the source")
    func mergeTransfersPhotos() throws {
        let (_, repo, sessionId, photoIds) = try makePersonHarness()
        let alice = try repo.create(name: "Alice")
        let bob = try repo.create(name: "Bob")
        try repo.addPhotos(personId: alice, sessionId: sessionId, photos: [
            PersonPhotoInput(photoId: photoIds[0], faceBbox: [1, 2, 3, 4], confidence: 0.9),
        ])
        try repo.addPhotos(personId: bob, sessionId: sessionId, photos: [
            PersonPhotoInput(photoId: photoIds[1], faceBbox: [5, 6, 7, 8], confidence: 0.8),
        ])

        try repo.merge(sourceId: alice, targetId: bob)

        #expect(try repo.get(id: alice) == nil)
        #expect(Set(try repo.getPhotosWithDetails(personId: bob).photos.map(\.photo.photoId)) == ["photo-1", "photo-2"])
    }

    @Test("reconcileSession mirrors role bindings into person_photos and back")
    func reconcileSessionMirrorsBindings() throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "Run", source: "folder")
        try insertPhoto(db, id: "photo-1", sessionId: session.id, filepath: "/photos/photo-1.jpg")
        let faceRepo = FaceRepo(connection: db)
        let personRepo = PersonRepo(connection: db)
        try seedCluster(db, id: 1, sessionId: session.id,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try faceRepo.updateBinding(clusterId: 1, roleName: "Alice", keywords: [])

        try personRepo.reconcileSession(sessionId: session.id)

        let persons = try personRepo.list()
        #expect(persons.count == 1)
        #expect(persons[0].name == "Alice")
        #expect(try personRepo.getPhotosWithDetails(personId: persons[0].id).photos.count == 1)

        // 绑定消失后对账摘除链接。
        try faceRepo.deleteBinding(clusterId: 1)
        try personRepo.reconcileSession(sessionId: session.id)
        #expect(try personRepo.getPhotosWithDetails(personId: persons[0].id).photos.isEmpty)
    }
}
// MARK: - 跨会话重识别（person_embeddings + FaceMatcher 端到端）

/// 一个库两个会话、每会话两张照片。向量由测试注入（测试夹具，不是产品逻辑）：
/// 同一人物 → 会话内两两 cosine = 1.0（>= eps 0.6，成 2 人脸簇）；跨会话对
/// Alice 库中向量的 cosine 同为 1.0（>= persons.match_threshold 0.65 → 出建议）。
private struct CrossSessionHarness {
    let db: DBConnection
    let service: FaceKwService
    let faceRepo: FaceRepo
    let personRepo: PersonRepo
    let sessionA: String
    let sessionB: String
}

private func makeCrossSessionHarness(
    embedding: [Double] = [1, 0, 0, 0]
) throws -> CrossSessionHarness {
    let db = try makeTestDB()
    let sessionRepo = SessionRepo(connection: db)
    let sessionA = try sessionRepo.create(name: "A", source: "folder")
    let sessionB = try sessionRepo.create(name: "B", source: "folder")
    let dir = try makeTempDir()
    for (sessionId, prefix) in [(sessionA.id, "a"), (sessionB.id, "b")] {
        for index in 1...2 {
            let path = try writeTempFile(in: dir, name: "\(prefix)\(index).jpg")
            try insertPhoto(db, id: "\(prefix)-\(index)", sessionId: sessionId, filepath: path)
        }
    }
    let faceRepo = FaceRepo(connection: db)
    let personRepo = PersonRepo(connection: db)
    let service = FaceKwService(
        photoRepo: PhotoRepo(connection: db),
        sessionRepo: sessionRepo,
        faceRepo: faceRepo,
        personRepo: personRepo,
        connection: db,
        decodeProvider: { _, _ in Data("jpeg".utf8) },
        inferenceProvider: { images, _, _ in
            images.map { _ in
                FaceInferenceItem(observations: [
                    FaceInferenceObservation(bbox: [1, 2, 3, 4], confidence: 0.95, embedding: embedding),
                ])
            }
        }
    )
    return CrossSessionHarness(
        db: db, service: service, faceRepo: faceRepo, personRepo: personRepo,
        sessionA: sessionA.id, sessionB: sessionB.id
    )
}

@Suite("FaceKwService cross-session re-identification")
struct FaceKwCrossSessionTests {
    @Test("suggests the person bound in another session, then binds to that same identity")
    func crossSessionSuggestionAndBind() async throws {
        let harness = try makeCrossSessionHarness()

        // 会话 A：分析 → 绑定 Alice（bind 必须把两张脸的向量写进 person_embeddings）。
        let resultA = try await harness.service.analyze(
            sessionId: harness.sessionA, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        #expect(resultA.status == "done")
        let clustersA = try harness.service.getClusters(sessionId: harness.sessionA)
        #expect(clustersA.count == 1)
        #expect(clustersA[0].size == 2)
        try harness.service.bindCluster(
            sessionId: harness.sessionA, clusterId: Int64(clustersA[0].id),
            roleName: "Alice", keywords: ["family"])

        let alice = try #require(try harness.personRepo.list().first { $0.name == "Alice" })
        #expect(try harness.personRepo.getAllEmbeddings().filter { $0.personId == alice.id }.count == 2,
                "bind 必须把该簇成员的观察向量写入 person_embeddings")

        // 会话 B：分析 → 用库匹配出建议（只是建议，不是绑定）。
        let resultB = try await harness.service.analyze(
            sessionId: harness.sessionB, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        #expect(resultB.status == "done")
        let clustersB = try harness.service.getClusters(sessionId: harness.sessionB)
        #expect(clustersB.count == 1)
        #expect(clustersB[0].binding == nil)
        #expect(clustersB[0].matchedPersonId == alice.id)
        #expect(clustersB[0].matchedPersonName == "Alice")
        #expect((clustersB[0].matchConfidence ?? 0) > 0.99)

        // 用户确认绑定 → 复用同一身份（不产生第二个 Alice），投影合并为 4 张。
        try harness.service.bindCluster(
            sessionId: harness.sessionB, clusterId: Int64(clustersB[0].id),
            roleName: "Alice", keywords: ["family"])
        #expect(try harness.personRepo.list().filter { $0.name == "Alice" }.count == 1)
        #expect(try harness.personRepo.countPhotos(personId: alice.id) == 4)
        #expect(try harness.personRepo.getPhotosWithDetails(personId: alice.id, sessionIds: [harness.sessionB]).photos.count == 2)
        #expect(try harness.personRepo.getAllEmbeddings().filter { $0.personId == alice.id }.count == 4)

        // recluster 与 analyze 共用 clusterStoredObservations：绑定迁移回来后
        // 身份链接必须保持（建议不得覆盖显式绑定）。
        try await harness.service.recluster(sessionId: harness.sessionB, eps: 0.6, minPts: 2)
        let reclustered = try harness.service.getClusters(sessionId: harness.sessionB)
        #expect(reclustered.count == 1)
        #expect(reclustered[0].binding?.roleName == "Alice")
        #expect(reclustered[0].matchedPersonId == alice.id)
    }
}

// MARK: - 算法改造接线（质量核心点 / 歧义 margin / 嵌入规格签名）

/// 可在运行中修改的设置箱（`@unchecked Sendable` 依据：唯一可变状态就是 values 本身，
/// 只在 lock 临界区内读写；服务侧只读调用）。
private final class MutableSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double]

    init(_ values: [String: Double] = [:]) {
        self.values = values
    }

    func value(_ key: String, _ defaultValue: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? defaultValue
    }

    func set(_ key: String, _ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

@Suite("face algorithm wiring")
struct FaceAlgorithmWiringTests {
    /// 两张照片、同一向量、指定质量：核心点质量门槛的最小场景。
    private func makeQualityHarness(
        _ settings: MutableSettings,
        quality: Double
    ) throws -> FaceKwHarness {
        try makeFaceKwHarness(
            photoCount: 2,
            inference: { images, _, _ in
                images.map { _ in
                    FaceInferenceItem(observations: [
                        FaceInferenceObservation(
                            bbox: [10, 20, 30, 40], confidence: 0.95,
                            embedding: [0.5, 0.6],
                            quality: quality, faceSizePx: 40, rollDegrees: 0),
                    ])
                }
            },
            settingsProvider: { key, defaultValue in settings.value(key, defaultValue) })
    }

    @Test("face_core_quality：低质量脸不成簇但不丢观测；门槛归零后同一批观测成簇")
    func coreQualityFloorGatesClustering() async throws {
        let settings = MutableSettings(["face_core_quality": 0.5])
        let harness = try makeQualityHarness(settings, quality: 0.2)

        _ = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        // 质量 0.2 < 门槛 0.5：没有核心点 → 零簇。
        #expect(try harness.service.getClusters(sessionId: harness.sessionId).isEmpty)
        // 观测照常入库（门槛只影响"谁能带簇"，不丢数据），且质量分如实落库。
        let observations = try harness.faceRepo.getObservations(harness.sessionId)
        #expect(observations.count == 2)
        #expect(observations.allSatisfy { abs($0.quality - 0.2) < 1e-9 })

        // 门槛归零 → 同一批观测（无需重新推理）重聚类出 1 簇 2 成员。
        // 该例同时证明聚类签名包含质量门槛：否则缓存快路径会直接返回旧（空）簇。
        settings.set("face_core_quality", 0)
        _ = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        let clusters = try harness.service.getClusters(sessionId: harness.sessionId)
        #expect(clusters.count == 1)
        #expect(clusters.first?.members.count == 2)
    }

    @Test("face_match_margin：近似并列的双人库不再自动绑定；margin=0 时绑定最接近者")
    func personMatchMarginAvoidsAmbiguousBinding() async throws {
        /// 返回该次运行后簇的建议绑定人物 id（nil = 未绑定）与 Alice 的 id。
        func run(margin: Double) async throws -> (matched: String?, aliceId: String) {
            let settings = MutableSettings(["face_match_margin": margin])
            // 两张照片：DBSCAN 需要 ≥2 个点才能成簇（单点脸是噪声，不会有簇可匹配）。
            let harness = try makeFaceKwHarness(
                photoCount: 2,
                settingsProvider: { key, defaultValue in settings.value(key, defaultValue) })
            let alice = try harness.personRepo.create(name: "Alice")
            let bob = try harness.personRepo.create(name: "Bob")
            let librarySession = try SessionRepo(connection: harness.db).create(name: "Library", source: "folder")
            try insertPhoto(harness.db, id: "library-face", sessionId: librarySession.id, filepath: "/tmp/library.jpg")
            let spec = try FaceEmbeddingModelFactory.spec(modelPath: "", modelVersion: "")
            let signature = "{\"embeddingSpec\":\"\(spec.signature)\"}"
            let vectors: [[Double]] = [[0.5, 0.6], [0.51, 0.59]]
            let ids = try harness.faceRepo.replaceObservationsByPhoto(sessionId: librarySession.id,
                photoId: "library-face", observations: vectors.map { vector in
                    FaceObservationInput(photoId: "library-face", bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.3,
                        embedding: vector.map(Float.init), confidence: 1, analysisSignature: signature, quality: 1)
                })
            try harness.personRepo.saveEmbeddings(embeddings: [alice, bob].enumerated().map { index, person in
                SaveEmbeddingInput(personId: person, embedding: vectors[index].map(Float.init), photoId: "library-face",
                    sessionId: librarySession.id, faceObservationId: ids[index])
            })
            _ = try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
            let cluster = try harness.faceRepo.getClusters(harness.sessionId).first
            return (cluster?.matchedPersonId, alice)
        }

        // 差距 < margin：不猜（PhotoPrism MATCH_MARGIN 语义），留给人工审核。
        let ambiguous = try await run(margin: 0.01)
        #expect(ambiguous.matched == nil)
        // margin = 0：与改造前语义一致，绑定最接近者（回归护栏）。
        let decided = try await run(margin: 0)
        #expect(decided.matched == decided.aliceId)
    }

    @Test("分析签名包含 embedding 规格：换对齐/模型指纹必然让旧观测过期")
    func analysisSignatureTracksEmbeddingSpec() throws {
        func signature(_ spec: String) -> String {
            FaceKwService.makeAnalysisSignature(
                detectorPath: "det.onnx", encoderPath: "enc.onnx",
                primaryDetectionSize: 640, secondaryDetectionSize: 128,
                confidenceThreshold: 0.5, encoderInputSize: 112, embeddingDim: 512,
                previewMaxDimension: 2048, embeddingSpec: spec)
        }
        #expect(signature("vision-v1") != signature("vision-v2"))
        // 生产走 FaceEncoder.embeddingSpec；测试里的默认签名常量必须与之一致，
        // 否则"缓存快路径"用例会悄悄退化成重推理。
        #expect(signature(try FaceEmbeddingModelFactory.spec(modelPath: "", modelVersion: "").signature) == analysisSignatureForDefaults)
    }
}


// MARK: - 编码全失败：不得摧毁既有状态（对抗审查阻断项 2）

/// 对抗审查阻断项 2 的回归：模型不可用/输入不受支持时，逐脸嵌入会全部抛错。
/// 旧行为是「静默跳过 → 这张照片被当成没有脸 → 删旧观测 + 写 analysis_state（永不重试）
/// + 重聚类 clearOnEmpty 连带清掉旧簇与人工绑定」。本套件钉死修复后的行为。
@Suite("人脸编码全失败保护")
struct FaceEncodingFailureGuardTests {
    @Test("编码全失败：保留旧观测与旧分析状态，run 报 failed 且失败数可见")
    func allEncodingsFailedKeepsPreviousState() async throws {
        let harness = try makeFaceKwHarness(inference: { images, _, _ in
            // 每张图检测到 3 张脸，但一张也编码不出来。
            images.map { _ in FaceInferenceItem(observations: [], encodingFailures: 3) }
        })
        let inserted = try harness.faceRepo.replaceObservationsByPhoto(
            sessionId: harness.sessionId, photoId: "photo-1",
            observations: [FaceObservationInput(
                photoId: "photo-1", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4,
                embedding: [0.1, 0.2, 0.3], confidence: 0.9,
                sourceFileSize: 1, sourceFileMtimeMs: 1, analysisSignature: "old")])

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")

        #expect(result.status == "failed", "全部人脸编码失败 = 整次运行失败")
        #expect(result.encodingFailures == 3, "失败数必须上报（此前恒 0）")
        let observations = try harness.faceRepo.getObservations(harness.sessionId)
        #expect(observations.map(\.id) == inserted, "旧观测必须原样保留（不能被空结果替换）")
        #expect(observations.first?.analysisSignature == "old")
        #expect(
            try harness.faceRepo.getAnalysisStates(harness.sessionId)["photo-1"] == nil,
            "编码全失败不能写 analysis_state，否则这张照片永远不再重试")

        // 再跑一次：没有 analysis_state ⇒ 这张照片必须**重新**被处理（旧行为写下了状态行，
        // 第二次运行会直接跳过它，失败从此静默）。这是"永不重试"症状的直接回归断言。
        let second = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        #expect(second.encodingFailures == 3, "失败照片必须在下次运行重试")
        #expect(
            try harness.faceRepo.getObservations(harness.sessionId).map(\.id) == inserted,
            "重试期间旧观测仍不得被替换")
    }


    @Test("配置了不可加载的模型路径：分析直接失败（服务真的读设置，不是硬编码 Vision）")
    func unloadableConfiguredModelFailsAnalysis() async throws {
        // 对抗审查缺口：此前没有任何用例设置过 face_embedding_model_path，
        // 于是"服务层把设置丢了、永远用内置 Vision"也能全绿。
        let missing = "/tmp/gather-missing-\(UUID().uuidString).mlmodelc"
        let harness = try makeFaceKwHarness(stringSettings: [
            FaceEmbeddingModelFactory.modelPathSetting: missing,
        ])
        await #expect(throws: FaceEmbeddingError.self) {
            _ = try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        }
        // 配置错误必须发生在"任何落库之前"：不能因为整批抛错就留下半截状态。
        #expect(try harness.faceRepo.getObservations(harness.sessionId).isEmpty)
        #expect(try harness.faceRepo.getAnalysisStates(harness.sessionId).isEmpty)
    }

    @Test("被手改成 inf 的重试阈值：分析不得崩溃（Int(inf) 曾直接 trap 进程）")
    func infiniteRetrySettingDoesNotTrap() async throws {
        let harness = try makeFaceKwHarness(settings: ["face_core_retry_min_samples": .infinity])
        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        #expect(result.status == "done", "非有限设置必须回退默认值，而不是让进程崩掉")
    }

    @Test("部分失败：成功的脸落库，但不写 analysis_state（失败的脸下次必须重试）")
    func partialEncodingFailureIsRetried() async throws {
        // 对抗验证 V1 探针 A 的场景：1 张成功 + 1 张失败。旧行为是写 state、丢弃失败的脸，
        // 第二次运行直接跳过这张照片 ⇒ 那些脸永远没有机会被处理。
        let calls = EncodingCallCounter()
        let harness = try makeFaceKwHarness(inference: { images, _, _ in
            calls.increment()
            return images.map { _ in
                FaceInferenceItem(
                    observations: [FaceInferenceObservation(
                        bbox: [10, 20, 30, 40], confidence: 0.95, embedding: [0.5, 0.6])],
                    encodingFailures: 1)
            }
        })
        let first = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        #expect(first.status == "done", "还有成功的脸，整次运行不算失败")
        #expect(first.encodingFailures == 1, "失败数必须上报（UI 据此提示而不是假装完成）")
        #expect(try harness.faceRepo.getObservations(harness.sessionId).count == 1, "成功的脸必须落库")
        #expect(
            try harness.faceRepo.getAnalysisStates(harness.sessionId)["photo-1"] == nil,
            "部分失败也不能写 analysis_state，否则失败的脸永不重试")
        let callsAfterFirst = calls.value
        _ = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        #expect(calls.value > callsAfterFirst, "第二次运行必须重新处理这张照片")
    }

    @Test("编码成功时正常写入（守卫不能把成功路径也挡掉）")
    func successfulEncodingStillPersists() async throws {
        let harness = try makeFaceKwHarness(inference: { images, _, _ in
            images.map { _ in
                FaceInferenceItem(observations: [FaceInferenceObservation(
                    bbox: [10, 20, 30, 40], confidence: 0.95, embedding: [0.5, 0.6])])
            }
        })
        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        #expect(result.status == "done")
        #expect(result.encodingFailures == 0)
        #expect(try harness.faceRepo.getObservations(harness.sessionId).count == 1)
        #expect(try harness.faceRepo.getAnalysisStates(harness.sessionId)["photo-1"] != nil)
    }
}

/// 推理调用计数（部分失败用例要证明"下次真的重试"）。
private final class EncodingCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

// MARK: - Cut 5 / 5c-2：analyze 三阶段 A/B/C 边界

/// 线程安全会话句柄（B 阶段自定义 clusterProvider 需要在闭包里 bump index_seq）。
private final class SessionHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var repo: SessionRepo?
    private var sessionId = ""

    func set(_ repo: SessionRepo, sessionId: String) {
        lock.lock()
        self.repo = repo
        self.sessionId = sessionId
        lock.unlock()
    }

    func bumpIndexSeq() throws {
        lock.lock()
        let repo = self.repo
        let sessionId = self.sessionId
        lock.unlock()
        guard let repo else { return }
        _ = try repo.bumpIndexSeq(id: sessionId)
    }
}

private func observationFloats(_ data: Data) -> [Float] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// 同步等待（Swift 6 禁止在 async 上下文直接 DispatchSemaphore.wait；
/// 自定义 clusterProvider 是同步闭包，经这个非 async 辅助函数等待）。
private func waitForGate(_ gate: DispatchSemaphore, timeout: TimeInterval = 5) {
    _ = gate.wait(timeout: .now() + timeout)
}

private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 2) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

/// 默认假推理的向量：每图一张脸 [0.5, 0.6]。
private let stageBoundaryEmbedding: [Float] = [0.5, 0.6]

@Suite("FaceKwService stage boundaries (A/B/C)")
struct FaceKwStageBoundaryTests {
    private func blockingClusterProvider(
        gate: DispatchSemaphore, entered: LockedFlag
    ) -> FaceKwService.FaceClusterProvider {
        { entries, eps, minPts, options, onProgress, isCancelled in
            entered.set()
            waitForGate(gate)
            try isCancelled?()
            return try FaceClusterer.clusterEmbeddings(
                entries: entries, eps: eps, minPts: minPts,
                coreQualityFloor: options.coreQualityFloor,
                retryMinSamples: options.retryMinSamples,
                onProgress: onProgress)
        }
    }

    @Test("A commits observations; B cancellation keeps old clusters and clears the signature")
    func bCancellationKeepsObservationsAndOldClusters() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = LockedFlag()
        let harness = try makeFaceKwHarness(
            cluster: blockingClusterProvider(gate: gate, entered: entered))
        try seedCluster(
            harness.db, id: 1, sessionId: harness.sessionId,
            members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try bind(harness, clusterId: 1, roleName: "Alice")

        let task = Task {
            try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        }
        _ = try waitUntil { entered.value }
        harness.service.cancel(sessionId: harness.sessionId)
        gate.signal()
        let result = try await task.value

        #expect(result.status == "cancelled")
        // A：观测与 checkpoint（face_analysis_state）已提交。
        let observations = try harness.faceRepo.getObservations(harness.sessionId)
        #expect(observations.count == 1)
        #expect(observationFloats(observations[0].embedding) == stageBoundaryEmbedding)
        #expect(try harness.faceRepo.getAnalysisStates(harness.sessionId)["photo-1"] != nil)
        // B 未进入 C：簇 / 成员 / 绑定都还是旧的。
        let clusters = try harness.faceRepo.getClusters(harness.sessionId, includeMembers: true)
        #expect(clusters.count == 1)
        #expect(clusters[0].id == 1)
        #expect(clusters[0].binding?.roleName == "Alice")
        #expect(clusters[0].members?.map(\.photoId) == ["photo-1"])
        // 观测新、簇旧 → 签名必须失效，否则下一次 analyze 会走缓存快路径。
        #expect(try harness.faceRepo.getClusterSignature(harness.sessionId) == nil)
    }

    @Test("index_seq changed before C fails with the workspace message and leaves no half clusters")
    func indexSeqChangeBeforeCommitRollsBack() async throws {
        let box = SessionHandleBox()
        let harness = try makeFaceKwHarness(photoCount: 2, cluster: { entries, eps, minPts, options, onProgress, _ in
            try box.bumpIndexSeq()
            return try FaceClusterer.clusterEmbeddings(
                entries: entries, eps: eps, minPts: minPts,
                coreQualityFloor: options.coreQualityFloor,
                retryMinSamples: options.retryMinSamples,
                onProgress: onProgress)
        })
        box.set(harness.sessionRepo, sessionId: harness.sessionId)
        try seedCluster(
            harness.db, id: 1, sessionId: harness.sessionId,
            members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])

        do {
            _ = try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
            Issue.record("Expected the index_seq guard to reject the commit")
        } catch {
            #expect(String(describing: error).contains("工作区内容已变化"))
        }

        // C 事务整体回滚：旧簇原样保留，没有"半套"新簇。
        let clusters = try harness.faceRepo.getClusters(harness.sessionId, includeMembers: true)
        #expect(clusters.count == 1)
        #expect(clusters[0].id == 1)
        #expect(clusters[0].members?.map(\.photoId) == ["photo-1"])
        #expect(try harness.faceRepo.getClusterSignature(harness.sessionId) == nil)
        // A 的成果保留：两张照片的新观测与分析状态都已提交。
        #expect(try harness.faceRepo.getObservations(harness.sessionId).count == 2)
        #expect(try harness.faceRepo.getAnalysisStates(harness.sessionId).count == 2)
    }

    @Test("a concurrent read completes in <= 50 ms while B is clustering (no DB lock held)")
    func concurrentReadStaysResponsiveDuringClustering() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = LockedFlag()
        let harness = try makeFaceKwHarness(
            photoCount: 2, cluster: blockingClusterProvider(gate: gate, entered: entered))

        let task = Task {
            try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        }
        _ = try waitUntil { entered.value }

        // 取 3 次最小值以降低调度抖动；旧实现把聚类放在 connection.transaction 内，
        // 这里的读会一直阻塞到 gate 释放（> 1 s），断言会硬失败。
        var bestMs = Double.infinity
        for _ in 0..<3 {
            let done = DispatchSemaphore(value: 0)
            let start = DispatchTime.now()
            DispatchQueue.global().async {
                _ = try? harness.sessionRepo.getIndexSeq(id: harness.sessionId)
                done.signal()
            }
            #expect(waitForSignal(done))
            let elapsedMs = Double(
                DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            bestMs = min(bestMs, elapsedMs)
        }
        gate.signal()
        let result = try await task.value

        #expect(result.status == "done")
        print("[5c-2] B 阶段聚类期间并发读延迟（3 次取最小）= \(bestMs) ms")
        #expect(
            bestMs <= 50,
            "B 阶段聚类期间并发读延迟必须 ≤ 50 ms（实测 \(bestMs) ms）")
    }

    @Test("identical recluster replays the committed clusters without churning ids")
    func reclusterReplaysIdenticalClusterState() async throws {
        let harness = try makeFaceKwHarness(photoCount: 2)
        _ = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        let before = try harness.faceRepo.getClusters(harness.sessionId, includeMembers: true)
        #expect(before.count == 1)
        #expect(before[0].members?.count == 2)

        try await harness.service.recluster(sessionId: harness.sessionId, eps: 0.65, minPts: 2)
        let after = try harness.faceRepo.getClusters(harness.sessionId, includeMembers: true)

        #expect(after.map(\.id) == before.map(\.id), "状态逐行一致时 C 只推进签名，不重插簇行")
        #expect(
            after.map { $0.members?.map(\.photoId) } == before.map { $0.members?.map(\.photoId) },
            "重放不得改变成员划分")
    }
}
