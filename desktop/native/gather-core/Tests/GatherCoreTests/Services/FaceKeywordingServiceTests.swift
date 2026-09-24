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

import Foundation
import Testing
@testable import GatherCore

private func makeTempPhotoStore() async throws -> any PhotoStore {
    let (database, _) = try await makeMigratedStoreDatabase(label: "photos")
    return SQLitePhotoStore(database: database)
}


// MARK: - 支撑

/// 幂等等待门（swift-testing 并行下 Task 调度延迟明显，避免固定 sleep）。
private final class AsyncGate {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        let mustWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if released { return false }
            return true
        }()
        guard mustWait else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

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

private struct FaceKwHarness {
    let db: DBConnection
    let service: FaceKwService
    let sessionStore: any SessionStore
    let faceStore: SQLiteFaceStore
    let personStore: SQLitePersonStore
    let sessionId: String
    /// photo-1 的文件路径（真实临时文件；其余照片为插入行）。
    let photoPath: String
}


/// 测试用人物库：person 路径实际使用的 harness 走文件库（见 makeFaceKwHarness）；
/// 仅需满足初始化的构造点用一个独立文件库（不触库）。
private func makeTestPersonStore() throws -> SQLitePersonStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-fkw-person-\(UUID().uuidString).sqlite").path
    return SQLitePersonStore(database: try SQLiteDatabase(path: path))
}

/// 建真实照片文件 + 已迁移库 + 服务。默认注入 fake 解码（TS 的 imageService
/// mock 语义）；推理默认返回单脸 [10,20,30,40] / 0.95 / [0.5,0.6]。
private func makeFaceKwHarness(
    photoCount: Int = 1,
    inference: FaceKwService.FaceInferenceProvider? = nil,
    cluster: FaceKwService.FaceClusterProvider? = nil,
    writeback: FaceWritebackProvider? = nil,
    settings: [String: Double] = [:]
) async throws -> FaceKwHarness {
    // workspace 之外的 person 路径已切到 Store：文件库供两条连接共享。
    let dbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-fkw-\(UUID().uuidString).sqlite").path
    let db = try await makeMigratedLegacyDB(path: dbPath)
    let sessionStore = try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath))
    let session = try await SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)).create(name: "Run", source: "folder", sourcePath: "")
    let dir = try makeTempDir()
    var photoPath = ""
    for i in 1...photoCount {
        let path = try writeTempFile(in: dir, name: "photo\(i).jpg")
        try insertPhoto(db, id: "photo-\(i)", sessionId: session.id, filepath: path)
        if i == 1 { photoPath = path }
    }
    let service = FaceKwService(
        photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
        sessionStore: sessionStore,
        faceStore: SQLiteFaceStore(database: try SQLiteDatabase(path: dbPath)),
        personStore: SQLitePersonStore(database: try SQLiteDatabase(path: dbPath)),
        database: try SQLiteDatabase(path: dbPath),
        getNumber: { key, defaultValue in settings[key] ?? defaultValue },
        decodeProvider: { _, _ in Data("jpeg".utf8) },
        inferenceProvider: inference ?? defaultFakeInference(),
        clusterProvider: cluster ?? { entries, eps, minPts, onProgress in
            try FaceClusterer.clusterEmbeddings(
                entries: entries, eps: eps, minPts: minPts, onProgress: onProgress)
        },
        writebackProvider: writeback
    )
    return FaceKwHarness(
        db: db, service: service, sessionStore: sessionStore,
        faceStore: SQLiteFaceStore(database: try SQLiteDatabase(path: dbPath)),
        personStore: SQLitePersonStore(database: try SQLiteDatabase(path: dbPath)),
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
    memberCount: Int64? = nil,
    status: String = "unbound",
    members: [(photoId: String, bbox: [Double], confidence: Double)] = []
) throws -> Int64 {
    let count = memberCount ?? Int64(members.count)
    _ = try db.prepare("""
        INSERT INTO face_clusters (id, session_id, label, member_count, status, thumbnail_base64, thumbnail_path)
        VALUES (?, ?, ?, ?, ?, '', '')
      """).run([.int(id), .text(sessionId), .text(label), .int(count), .text(status)])
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

/// 绑定角色到集群（faceStore.updateBinding 的测试便捷封装）。
private func bind(_ harness: FaceKwHarness, clusterId: Int64, roleName: String, keywords: [String] = []) async throws {
    try await harness.faceStore.updateBinding(clusterId: clusterId, roleName: roleName, keywords: keywords)
}

private func runRow(_ db: DBConnection, _ sessionId: String) async throws -> DBRow? {
    try db.prepare(
        "SELECT kind, photo_count, index_seq, params, started_at, finished_at, status FROM analysis_runs WHERE session_id = ?"
    ).get([.text(sessionId)])
}

private let analysisSignatureForDefaults = FaceKwService.makeAnalysisSignature(
    detectorPath: "det.onnx", encoderPath: "enc.onnx",
    primaryDetectionSize: 640, secondaryDetectionSize: 128,
    confidenceThreshold: 0.5, encoderInputSize: 112, embeddingDim: 512,
    previewMaxDimension: 2048
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
        let harness = try await makeFaceKwHarness(
            inference: { images, _, _ in
                images.map { _ in FaceInferenceItem(error: "inference failed") }
            }
        )
        let oldIds = try await harness.faceStore.saveObservations(sessionId: harness.sessionId, observations: [
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
        let observations = try await harness.faceStore.observations(sessionId: harness.sessionId)
        #expect(observations.count == 1)
        #expect(observations[0].id == oldIds[0])
        #expect(observations[0].confidence == 0.9)
        // 状态未写入。
        #expect(try await harness.faceStore.analysisStates(sessionId: harness.sessionId).isEmpty)
    }

    @Test("replaces previous observations atomically after a successful inference")
    func replacesObservationsOnSuccess() async throws {
        let harness = try await makeFaceKwHarness()

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")

        #expect(result.status == "done")
        #expect(result.detectionFailures == 0)
        let observations = try await harness.faceStore.observations(sessionId: harness.sessionId)
        #expect(observations.count == 1)
        #expect(observations[0].photoId == "photo-1")
        #expect(observations[0].bboxX == 10)
        #expect(observations[0].bboxY == 20)
        #expect(observations[0].bboxW == 30)
        #expect(observations[0].bboxH == 40)
        #expect(observations[0].confidence == 0.95)
        let state = try await harness.faceStore.analysisStates(sessionId: harness.sessionId)
        #expect(state["photo-1"]?.analysisSignature == analysisSignatureForDefaults)
        #expect(try await harness.sessionStore.get(id: harness.sessionId)?.analysisStatus == "done")
    }
}

// MARK: - analyze run 记录（TS: face-run-record.test.ts）

@Suite("FaceKwService analysis run records")
struct FaceKwRunRecordTests {
    @Test("writes a face run row at entry and finalizes it to ok")
    func runRowFinalizesOk() async throws {
        let harness = try await makeFaceKwHarness()

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx",
            eps: 0.6, minPts: 2)

        #expect(result.status == "done")
        let row = try await runRow(harness.db, harness.sessionId)!
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
        let harness = try await makeFaceKwHarness()
        // 使 replaceObservationsByPhoto 的写入必然失败（embedding 列不存在）；
        // 读路径（getObservations / 状态）不受影响——等价 TS mock 抛错。
        _ = try harness.db.prepare("ALTER TABLE face_observations DROP COLUMN embedding").run([])

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")

        #expect(result.status == "failed")
        let row = try await runRow(harness.db, harness.sessionId)!
        #expect(row[6].textValue == "failed")
        #expect(row[5].textValue != "")
        #expect(try await harness.sessionStore.get(id: harness.sessionId)?.analysisStatus == "failed")
    }
}

// MARK: - analyze 流程（缓存 / 取消 / 占用 / 进度 / 空结果）

@Suite("FaceKwService.analyze flow")
struct FaceKwAnalyzeFlowTests {
    @Test("serves cached clusters without re-inference when nothing changed")
    func cachedClustersEarlyReturn() async throws {
        let probe = LockedFlag()
        let harness = try await makeFaceKwHarness(inference: { images, _, _ in
            probe.set()
            throw FaceKwServiceError.analysisRunning
        })
        _ = try await harness.faceStore.saveObservations(sessionId: harness.sessionId, observations: [
            FaceObservationInput(
                photoId: "photo-1", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4,
                embedding: [0.1, 0.2, 0.3], confidence: 0.9),
        ])
        guard let stat = tsStat(harness.photoPath) else {
            Issue.record("photo file stat failed")
            return
        }
        try await harness.faceStore.upsertAnalysisState(
            sessionId: harness.sessionId, photoId: "photo-1",
            sourceFileSize: stat.size, sourceFileMtimeMs: stat.mtimeMs,
            analysisSignature: analysisSignatureForDefaults)
        try await harness.faceStore.upsertClusterSignature(sessionId: harness.sessionId, signature: "0.6:2")
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])

        var phases: [String] = []
        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx",
            onProgress: { _, _, phase in phases.append(phase) })

        #expect(result.status == "done")
        #expect(probe.value == false)  // 推理未被调用
        #expect(phases.contains("face.cached-clusters"))
        #expect(try await harness.sessionStore.get(id: harness.sessionId)?.analysisStatus == "done")
        #expect(try await runRow(harness.db, harness.sessionId)?[6].textValue == "ok")
    }

    @Test("cancels an in-flight analysis and writes cancelled status")
    func cancelsInFlightAnalysis() async throws {
        let gate = AsyncGate()
        let entered = LockedFlag()
        let harness = try await makeFaceKwHarness(inference: { images, _, _ in
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
        #expect(try await harness.sessionStore.get(id: harness.sessionId)?.analysisStatus == "cancelled")
        // 取消的 run 以 'failed' 终态（sessions.analysis_status 为 'cancelled'，
        // 与 TS 语义一致）。
        #expect(try await runRow(harness.db, harness.sessionId)?[6].textValue == "failed")
    }

    @Test("rejects a second analyze while one is running")
    func rejectsConcurrentAnalysis() async throws {
        let gate = AsyncGate()
        let harness = try await makeFaceKwHarness(inference: { images, _, _ in
            await gate.wait()
            return images.map { _ in FaceInferenceItem(observations: []) }
        })

        let task = Task {
            try await harness.service.analyze(
                sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")
        }
        // 轮询等待 running（Store 读为 async，waitUntil 仅支持同步条件）。
        let runningDeadline = Date().addingTimeInterval(5)
        while Date() < runningDeadline {
            let status = try await harness.sessionStore.get(id: harness.sessionId)?.analysisStatus
            if status == "running" { break }
            try? await Task.sleep(for: .milliseconds(20))
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
        let harness = try await makeFaceKwHarness(photoCount: 2)
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
        let harness = try await makeFaceKwHarness(inference: { images, _, _ in
            images.map { _ in FaceInferenceItem(observations: []) }
        })
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")

        #expect(result.status == "done")
        #expect(try await harness.faceStore.clusters(sessionId: harness.sessionId, includeMembers: false).isEmpty)
    }

    @Test("keeps clusters and bindings when the run is reported failed")
    func keepsClustersOnFailedRun() async throws {
        let harness = try await makeFaceKwHarness(inference: { images, _, _ in
            images.map { _ in FaceInferenceItem(error: "all failed") }
        })
        // 全零 embedding 的观察：聚类输入为空（TS 的 some(value !== 0) 过滤）。
        _ = try await harness.faceStore.saveObservations(sessionId: harness.sessionId, observations: [
            FaceObservationInput(
                photoId: "photo-1", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4,
                embedding: [0, 0, 0], confidence: 0.9),
        ])
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try await bind(harness, clusterId: 1, roleName: "Alice", keywords: ["kw"])

        let result = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx")

        #expect(result.status == "failed")
        // 全失败 run 不摧毁用户已绑定的集群与角色名。
        // includeMembers 才加载 binding（TS face.repo.getClusters 同款）。
        let clusters = try await harness.faceStore.clusters(sessionId: harness.sessionId, includeMembers: true)
        #expect(clusters.count == 1)
        #expect(clusters[0].binding?.roleName == "Alice")
        #expect(clusters[0].binding?.keywords == ["kw"])
    }

    @Test("throws SESSION_NOT_FOUND for an unknown session")
    func throwsSessionNotFound() async throws {
        let harness = try await makeFaceKwHarness()
        await #expect(throws: FaceKwServiceError.sessionNotFound) {
            try await harness.service.analyze(
                sessionId: "missing", detectorPath: "det.onnx", encoderPath: "enc.onnx")
        }
    }

    @Test("throws FACE_NO_PHOTOS for an empty session")
    func throwsNoPhotos() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fkw-face-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedLegacyDB(path: dbPath)
        let sessionStore = try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath))
        let session = try await SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)).create(name: "Empty", source: "folder")
        let service = FaceKwService(
            photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
            sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
            faceStore: SQLiteFaceStore(database: try SQLiteDatabase(path: dbPath)),
            personStore: try makeTestPersonStore(),
            database: try SQLiteDatabase(path: dbPath),
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
        let harness = try await makeFaceKwHarness()
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
    ) async throws -> (db: DBConnection, service: FaceKwService, faceStore: SQLiteFaceStore, sessionId: String) {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fkw-face-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedLegacyDB(path: dbPath)
        let sessionId = "session-1"
        try insertSession(db, sessionId)
        for id in ["p1", "p2", "p3", "p4"] {
            try insertPhoto(db, id: id, sessionId: sessionId, filepath: "/photos/\(id).jpg")
        }
        let faceStore = SQLiteFaceStore(database: try SQLiteDatabase(path: dbPath))
        let obs = try await faceStore.saveObservations(sessionId: sessionId, observations: [
            FaceObservationInput(photoId: "p1", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4, embedding: [0.1, 0.2, 0.3], confidence: 0.9),
            FaceObservationInput(photoId: "p2", bboxX: 1, bboxY: 2, bboxW: 3, bboxH: 4, embedding: [0.1, 0.2, 0.3], confidence: 0.9),
        ])
        let observationIds = [Int(obs[0]), Int(obs[1])]
        for binding in bindings {
            try seedCluster(
                db, id: binding.clusterId, sessionId: sessionId, label: "Person \(binding.clusterId)",
                memberCount: Int64(binding.photoIds.count), status: "bound",
                members: binding.photoIds.map { (photoId: $0, bbox: [1, 2, 3, 4], confidence: 0.9) })
            try await faceStore.updateBinding(clusterId: binding.clusterId, roleName: binding.roleName, keywords: binding.keywords)
        }
        let service = FaceKwService(
            photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
            sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
            faceStore: faceStore,
            personStore: try makeTestPersonStore(),
            database: try SQLiteDatabase(path: dbPath),
            clusterProvider: { entries, _, _, _ in
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
        return (db, service, faceStore, sessionId)
    }

    @Test("re-attaches a binding to the new cluster with the largest member overlap")
    func reattachesToLargestOverlap() async throws {
        // 新库自增：两条观察 id 为 1/2。
        let harness = try await makeMigrationHarness(
            bindings: [(clusterId: 7, roleName: "Alice", keywords: ["kw"], photoIds: ["p1", "p2"])],
            clusterResult: [
                // 新集群 1 保留 Alice 的两条观察；新集群 2 是陌生人（不在库内）。
                [(observationId: 1, photoId: "p1"), (observationId: 2, photoId: "p2")],
                [(observationId: 12, photoId: "p3")],
            ]
        )

        try await harness.service.recluster(sessionId: harness.sessionId, eps: 0.6, minPts: 2)

        let bindings = try await harness.faceStore.bindingsBySession(harness.sessionId)
        #expect(bindings.count == 1)
        #expect(bindings[0].roleName == "Alice")
        #expect(bindings[0].keywords == ["kw"])
        // 绑定落在保留 p1/p2 的新集群上。
        let memberPhotos = Set(try await harness.faceStore.clusterMembers(clusterId: bindings[0].clusterId).map(\.photoId))
        #expect(memberPhotos == ["p1", "p2"])
    }

    @Test("lets the binding with the larger overlap win when two compete for one cluster")
    func largerOverlapWinsCompetition() async throws {
        let harness = try await makeMigrationHarness(
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

        let bindings = try await harness.faceStore.bindingsBySession(harness.sessionId)
        #expect(bindings.count == 1)
        #expect(bindings[0].roleName == "Alice")
        #expect(bindings[0].keywords == [])
    }

    @Test("drops a binding whose faces vanished from the new result")
    func dropsVanishedBinding() async throws {
        let harness = try await makeMigrationHarness(
            bindings: [(clusterId: 7, roleName: "Alice", keywords: ["kw"], photoIds: ["p1"])],
            clusterResult: [
                [(observationId: 2, photoId: "p2")],
            ]
        )

        try await harness.service.recluster(sessionId: harness.sessionId, eps: 0.6, minPts: 2)

        #expect(try await harness.faceStore.bindingsBySession(harness.sessionId).isEmpty)
    }
}

// MARK: - clusters 读取与集群命令

@Suite("FaceKwService.getClusters shape")
struct FaceKwGetClustersTests {
    @Test("truncates members to the preview window and maps binding fields")
    func truncatesMembersAndMapsBinding() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fkw-face-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedLegacyDB(path: dbPath)
        let sessionId = "session-1"
        try insertSession(db, sessionId)
        for i in 1...5 {
            try insertPhoto(db, id: "photo-\(i)", sessionId: sessionId, filepath: "/photos/photo-\(i).jpg")
        }
        let faceStore = SQLiteFaceStore(database: try SQLiteDatabase(path: dbPath))
        try seedCluster(
            db, id: 1, sessionId: sessionId, label: "Person 1", memberCount: 5, status: "bound",
            members: (1...5).map { (photoId: "photo-\($0)", bbox: [Double($0), 2, 3, 4], confidence: 0.9) })
        try await faceStore.updateBinding(clusterId: 1, roleName: "Alice", keywords: ["kw1", "kw2"])

        let service = FaceKwService(
            photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
            sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
            faceStore: faceStore,
            personStore: try makeTestPersonStore(),
            database: try SQLiteDatabase(path: dbPath)
        )
        let clusters = try await service.getClusters(sessionId: sessionId)

        #expect(clusters.count == 1)
        let cluster = clusters[0]
        #expect(cluster.id == 1)
        #expect(cluster.sessionId == sessionId)
        #expect(cluster.label == "Person 1")
        #expect(cluster.size == 5)
        #expect(cluster.status == "bound")
        #expect(cluster.thumbnailBase64 == "")
        #expect(cluster.binding?.roleName == "Alice")
        #expect(cluster.binding?.keywords == ["kw1", "kw2"])
        // 网格卡片只渲染前 4 个成员（ClusterThumb 的 MAX_PREVIEW_MEMBERS）。
        #expect(cluster.members.count == 4)
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
    func bindNormalizesAndBridges() async throws {
        let harness = try await makeFaceKwHarness()
        try seedCluster(harness.db, id: 7, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])

        try await harness.service.bindCluster(
            sessionId: harness.sessionId, clusterId: 7, roleName: " Alice ", keywords: ["kw1", "kw1", ""])

        let bindings = try await harness.faceStore.bindingsBySession(harness.sessionId)
        #expect(bindings.count == 1)
        #expect(bindings[0].roleName == "Alice")
        #expect(bindings[0].keywords == ["kw1"])
        #expect(try await harness.faceStore.clusters(sessionId: harness.sessionId, includeMembers: false)[0].status == "bound")
        // 人物库桥接。
        let persons = try await harness.personStore.list()
        #expect(persons.count == 1)
        #expect(persons[0].name == "Alice")
        #expect(try await harness.personStore.getPhotos(personId: persons[0].id).count == 1)
    }

    @Test("throws FKW_CLUSTER_NOT_FOUND and FKW_CLUSTER_NOT_IN_SESSION on bind")
    func bindClusterErrors() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fkw-face-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedLegacyDB(path: dbPath)
        let sessionStore = try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath))
        let sessionA = try await SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)).create(name: "A", source: "folder")
        let sessionB = try await SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)).create(name: "B", source: "folder")
        let faceStore = SQLiteFaceStore(database: try SQLiteDatabase(path: dbPath))
        try seedCluster(db, id: 1, sessionId: sessionA.id, memberCount: 0)
        let service = FaceKwService(
            photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
            sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
            faceStore: faceStore,
            personStore: try makeTestPersonStore(),
            database: try SQLiteDatabase(path: dbPath)
        )
        await await #expect(throws: FaceKwServiceError.clusterNotFound) {
            try await service.bindCluster(sessionId: sessionA.id, clusterId: 99, roleName: "Alice", keywords: [])
        }
        await await #expect(throws: FaceKwServiceError.clusterNotInSession) {
            try await service.bindCluster(sessionId: sessionB.id, clusterId: 1, roleName: "Alice", keywords: [])
        }
        await #expect(throws: FaceKwServiceError.roleNameEmpty) {
            try await service.bindCluster(sessionId: sessionA.id, clusterId: 1, roleName: "   ", keywords: [])
        }
    }

    @Test("unbinds a cluster and reconciles the person library")
    func unbindsAndReconciles() async throws {
        let harness = try await makeFaceKwHarness()
        try seedCluster(harness.db, id: 7, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try await bind(harness, clusterId: 7, roleName: "Alice", keywords: ["kw"])
        try await harness.service.bindCluster(sessionId: harness.sessionId, clusterId: 7, roleName: "Alice", keywords: ["kw"])
        let personId = try await harness.personStore.list()[0].id

        try await harness.service.unbindCluster(sessionId: harness.sessionId, clusterId: 7)

        #expect(try await harness.faceStore.bindingsBySession(harness.sessionId).isEmpty)
        #expect(try await harness.faceStore.clusters(sessionId: harness.sessionId, includeMembers: false)[0].status == "unbound")
        // 人物库对账：绑定移除后链接摘除。
        #expect(try await harness.personStore.getPhotos(personId: personId).isEmpty)
    }

    @Test("merges clusters moving members and dropping the source binding")
    func mergesClusters() async throws {
        let harness = try await makeFaceKwHarness(photoCount: 2)
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try seedCluster(harness.db, id: 2, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-2", bbox: [5, 6, 7, 8], confidence: 0.8)])
        try await bind(harness, clusterId: 1, roleName: "Alice", keywords: [])

        try await harness.service.mergeClusters(sessionId: harness.sessionId, sourceId: 1, targetId: 2)

        let targetMembers = try await harness.faceStore.clusterMembers(clusterId: 2).map(\.photoId)
        #expect(targetMembers == ["photo-1", "photo-2"])
        #expect(try await harness.faceStore.clusterMembers(clusterId: 1).isEmpty)
        #expect(try await harness.faceStore.bindingsBySession(harness.sessionId).isEmpty)
    }

    @Test("validates merge inputs")
    func mergeErrors() async throws {
        let harness = try await makeFaceKwHarness()
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId, memberCount: 0)
        try seedCluster(harness.db, id: 2, sessionId: harness.sessionId, memberCount: 0)
        let otherSession = try await harness.sessionStore.create(name: "Other", source: "folder")
        _ = try harness.db.prepare("""
            INSERT INTO face_clusters (id, session_id, label, member_count, status, thumbnail_base64, thumbnail_path)
            VALUES (50, ?, 'x', 0, 'unbound', '', '')
          """).run([.text(otherSession.id)])
        await #expect(throws: FaceKwServiceError.selfMerge) {
            try await harness.service.mergeClusters(sessionId: harness.sessionId, sourceId: 1, targetId: 1)
        }
        await #expect(throws: FaceKwServiceError.clusterNotFound) {
            try await harness.service.mergeClusters(sessionId: harness.sessionId, sourceId: 1, targetId: 99)
        }
        await #expect(throws: FaceKwServiceError.clusterNotInSession) {
            try await harness.service.mergeClusters(sessionId: harness.sessionId, sourceId: 1, targetId: 50)
        }
    }

    @Test("removes a member and deletes the cluster when it was the last one")
    func removesMember() async throws {
        let harness = try await makeFaceKwHarness(photoCount: 2)
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId, memberCount: 2,
                        members: [
                            (photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9),
                            (photoId: "photo-2", bbox: [5, 6, 7, 8], confidence: 0.8),
                        ])
        try await harness.service.removeMember(sessionId: harness.sessionId, clusterId: 1, memberId: 1)
        #expect(try await harness.faceStore.clusterMembers(clusterId: 1).map(\.photoId) == ["photo-2"])
        #expect(try await harness.faceStore.clusters(sessionId: harness.sessionId, includeMembers: false)[0].memberCount == 1)

        try await harness.service.removeMember(sessionId: harness.sessionId, clusterId: 1, memberId: 2)
        #expect(try await harness.faceStore.clusters(sessionId: harness.sessionId, includeMembers: false).isEmpty)
    }

    @Test("validates removeMember inputs")
    func removeMemberErrors() async throws {
        let harness = try await makeFaceKwHarness()
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        await #expect(throws: FaceKwServiceError.clusterNotFound) {
            try await harness.service.removeMember(sessionId: harness.sessionId, clusterId: 99, memberId: 1)
        }
        await #expect(throws: FaceKwServiceError.clusterMemberNotFound) {
            try await harness.service.removeMember(sessionId: harness.sessionId, clusterId: 1, memberId: 99)
        }
    }

    @Test("recluster validates and requires observations")
    func reclusterErrors() async throws {
        let harness = try await makeFaceKwHarness()
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

    func removeOwnedFaceKeywords(sessionId: String, entries: [FaceKeywordEntry]) async throws -> [String] {
        lock.lock()
        _removedEntries = entries
        lock.unlock()
        return removedKeywords
    }

    func preview(
        sessionId: String,
        options: FaceKwWritebackOptions?,
        boundPhotoIds: Set<String>,
        additions: [String: [String]]
    ) async throws -> FaceKwWritebackPreview {
        lock.lock()
        _previewArgs = (options, boundPhotoIds, additions)
        lock.unlock()
        return previewResult
    }

    func execute(sessionId: String, items: [FaceKwWritebackItem]) async throws -> FaceKwWritebackResult {
        lock.lock()
        _executedItems = items
        lock.unlock()
        return executeResult
    }

    func confirmSync(sessionId: String) async throws {
        lock.lock()
        _syncedSessionIds.append(sessionId)
        lock.unlock()
    }

    func cleanup(sessionId: String) async throws -> FaceKwCleanupResult {
        lock.lock()
        _cleanupCalls.append(sessionId)
        lock.unlock()
        return cleanupResult
    }
}

private func makeWritebackItem(photoId: String) -> FaceKwWritebackItem {
    FaceKwWritebackItem(
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
        let harness = try await makeFaceKwHarness(writeback: writeback)
        await #expect(throws: FaceKwServiceError.unbindConfirmRequired) {
            _ = try await harness.service.unbind(sessionId: harness.sessionId, clusterId: 1, confirmed: false)
        }
    }

    @Test("fkw.unbind requires the cluster to exist")
    func unbindClusterNotFound() async throws {
        let writeback = FakeWritebackProvider()
        let harness = try await makeFaceKwHarness(writeback: writeback)
        await await #expect(throws: FaceKwServiceError.clusterNotFound) {
            _ = try await harness.service.unbind(sessionId: harness.sessionId, clusterId: 99, confirmed: true)
        }
    }

    @Test("fkw.unbind removes owned keywords through the provider and unbinds")
    func unbindRemovesOwnedKeywords() async throws {
        let writeback = FakeWritebackProvider()
        writeback.removedKeywords = ["Alice", "kw1"]
        let harness = try await makeFaceKwHarness(writeback: writeback)
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try await bind(harness, clusterId: 1, roleName: "Alice", keywords: ["kw1"])

        let result = try await harness.service.unbind(sessionId: harness.sessionId, clusterId: 1, confirmed: true)

        #expect(result.done == true)
        #expect(result.removedKeywords == ["Alice", "kw1"])
        #expect(writeback.removedEntries.count == 1)
        #expect(writeback.removedEntries[0].photoId == "photo-1")
        #expect(writeback.removedEntries[0].xmpPath == TSPath.xmpSidecarPath(harness.photoPath))
        #expect(writeback.removedEntries[0].keywords == ["Alice", "kw1"])
        // 服务层 unbind 已执行。
        #expect(try await harness.faceStore.bindingsBySession(harness.sessionId).isEmpty)
    }

    @Test("fkw.unbind filters keywords protected by other bound clusters")
    func unbindFiltersProtectedKeywords() async throws {
        let writeback = FakeWritebackProvider()
        let harness = try await makeFaceKwHarness(writeback: writeback)
        // 两个集群共享 photo-1：B（Bob）的绑定保护 "Bob"；A 的 Alice 关键词
        // 里也有 "Bob"——解除 A 时 "Bob" 必须被过滤。
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try seedCluster(harness.db, id: 2, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [5, 6, 7, 8], confidence: 0.8)])
        try await bind(harness, clusterId: 1, roleName: "Alice", keywords: ["Bob"])
        try await bind(harness, clusterId: 2, roleName: "Bob", keywords: [])

        _ = try await harness.service.unbind(sessionId: harness.sessionId, clusterId: 1, confirmed: true)

        #expect(writeback.removedEntries[0].keywords == ["Alice"])
        #expect(try await harness.faceStore.bindingsBySession(harness.sessionId).count == 1)
        #expect(try await harness.faceStore.bindingsBySession(harness.sessionId)[0].roleName == "Bob")
    }

    @Test("fkw.preview builds additions and forwards them to the provider")
    func previewForwardsAdditions() async throws {
        let writeback = FakeWritebackProvider()
        writeback.previewResult = FaceKwWritebackPreview(items: [], totalCount: 1, affectedPhotos: 1)
        let harness = try await makeFaceKwHarness(writeback: writeback)
        try seedCluster(harness.db, id: 1, sessionId: harness.sessionId, memberCount: 1,
                        members: [(photoId: "photo-1", bbox: [1, 2, 3, 4], confidence: 0.9)])
        try await bind(harness, clusterId: 1, roleName: "Alice", keywords: ["kw1", "kw1", "kw2"])

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
        let harness = try await makeFaceKwHarness(writeback: writeback)
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

    @Test("fkw.confirm_sync returns true after provider sync")
    func confirmSyncReturnsTrue() async throws {
        let writeback = FakeWritebackProvider()
        let harness = try await makeFaceKwHarness(writeback: writeback)

        let result = try await harness.service.confirmSync(sessionId: harness.sessionId)

        #expect(result == true)
        #expect(writeback.syncedSessionIds == [harness.sessionId])
    }

    @Test("fkw.cleanup requires confirmation and returns the cleanup result")
    func cleanupConfirmationAndResult() async throws {
        let writeback = FakeWritebackProvider()
        writeback.cleanupResult = FaceKwCleanupResult(deletedCount: 3, errors: [])
        let harness = try await makeFaceKwHarness(writeback: writeback)

        await #expect(throws: FaceKwServiceError.cleanupConfirmRequired) {
            _ = try await harness.service.cleanup(sessionId: harness.sessionId, confirmed: false)
        }
        let result = try await harness.service.cleanup(sessionId: harness.sessionId, confirmed: true)
        #expect(result == writeback.cleanupResult)
        #expect(writeback.cleanupCalls == [harness.sessionId])
    }
}
