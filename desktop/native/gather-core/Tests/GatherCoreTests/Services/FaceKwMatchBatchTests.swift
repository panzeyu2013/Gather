// desktop/native/gather-core/Tests/GatherCoreTests/Services/FaceKwMatchBatchTests.swift
// Cut 5 / 5c-1：FaceKwService.matchClustersAgainstLibrary 批量化（去 N+1）的生产路径守门。
//
// 两类断言：
// 1. **DB 查询计数**（SQLite 官方 trace 探针，不改生产 DB 层）：
//    成员 / feedback 必须在簇循环外一次读完 —— C=1 与 C=8 的 SELECT 数必须相同，
//    且不得再出现 "FROM face_cluster_members WHERE cluster_id" 这种每簇查询。
// 2. **逐位一致**：对同一份库/成员/feedback，批量生产路径写入的
//    matched_person_id / match_confidence 必须与旧逐簇循环（bestScoresPerPerson +
//    中位数 + FaceIdentityPolicy.decide）完全相同（Double 精确相等）。
//
// 说明：本文件的"旧逐簇循环"只冻结调用顺序与聚合，不复制匹配数学（数学仍走生产
// 同一 FaceMatcher.bestScoresPerPerson）；因此它证明的是**批量化没有改动语义**。

import CSQLite
import Foundation
import Testing
import GatherTestSupport

@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication

// MARK: - SQL 计数探针（sqlite3_trace_v2；生产 DB 层零改动）

private final class SQLStatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []

    func record(_ sql: String) {
        lock.lock()
        statements.append(sql)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        statements.removeAll()
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return statements
    }
}

/// SQLITE_TRACE_STMT 回调：P = sqlite3_stmt*，X = 未展开 SQL 文本（sqlite3.h:3642-3652）。
private func sqlTraceCallback(
    _ mask: UInt32,
    _ context: UnsafeMutableRawPointer?,
    _ prepared: UnsafeMutableRawPointer?,
    _ text: UnsafeMutableRawPointer?
) -> Int32 {
    guard mask == UInt32(SQLITE_TRACE_STMT), let context else { return 0 }
    let counter = Unmanaged<SQLStatementCounter>.fromOpaque(context).takeUnretainedValue()
    if let text {
        counter.record(String(cString: text.assumingMemoryBound(to: CChar.self)))
    } else if let prepared {
        if let sql = sqlite3_sql(OpaquePointer(prepared)) {
            counter.record(String(cString: sql))
        }
    }
    return 0
}

private func isSelect(_ sql: String) -> Bool {
    sql.drop(while: { $0.isWhitespace }).uppercased().hasPrefix("SELECT")
}

/// 在探针下执行 body，返回已执行的 SELECT 文本（含绑定参数的原始 SQL）。
private func captureSelects<T>(
    db: DBConnection,
    _ body: () throws -> T
) throws -> (result: T, selects: [String]) {
    let counter = SQLStatementCounter()
    let handle = db.rawHandle
    let rc = sqlite3_trace_v2(
        handle, UInt32(SQLITE_TRACE_STMT), sqlTraceCallback,
        Unmanaged.passUnretained(counter).toOpaque())
    guard rc == SQLITE_OK else { throw DBError.message("sqlite3_trace_v2 安装失败: rc=\(rc)") }
    defer { _ = sqlite3_trace_v2(handle, 0, nil, nil) }
    counter.reset()
    let result = try body()
    return (result, counter.snapshot().filter(isSelect))
}

// MARK: - 夹具

private let matchBatchSignature = "{\"embeddingSpec\":\"test-spec-batch\"}"
/// B 阶段快照算出的模型空间（生产调用点由 FaceKwService 传入，避免重读 observations）。
private let matchBatchModelSpace = FaceIdentityPolicy.modelSpace(
    analysisSignature: matchBatchSignature)

private struct WrittenMatch: Equatable {
    let personId: String
    let confidence: Double?
}

private struct MatchBatchFixture {
    let db: DBConnection
    let service: FaceKwService
    let faceRepo: FaceRepo
    let personRepo: PersonRepo
    let sessionId: String
    let queries: [(clusterId: Int64, embeddings: [[Float]])]
    let library: [LibraryEmbedding]
    let margin: Double
}

/// 3 人物 × 4 维库（P0/P1 各两条样本，P2 一条正交样本）+ N 个簇。
/// 每簇一张照片、一条观测（只为 modelSpace 判定）、一个成员行。
/// 库写入走 personRepo.saveEmbeddings（与生产同一读口径 getAllEmbeddings）。
private func makeMatchBatchFixture(
    clusterCount: Int,
    seedLibrary: Bool = true,
    rejection: [(clusterIndex: Int, personIndex: Int?)] = [],
    margin: Double = 0.01
) throws -> MatchBatchFixture {
    let db = try makeTestDB()
    let sessionRepo = SessionRepo(connection: db)
    let session = try sessionRepo.create(name: "Match", source: "folder")
    let librarySession = try sessionRepo.create(name: "Library", source: "folder")
    let faceRepo = FaceRepo(connection: db)
    let personRepo = PersonRepo(connection: db)

    // 库样本（personIndex 指向下面创建的 3 个身份；真实 person id 是 UUID，
    // 参照实现必须用同一批 UUID，否则 matched_person_id 不可比）。
    let libraryRows: [(personIndex: Int, embedding: [Float])] = [
        (0, [1, 0, 0, 0]),
        (0, [0.98, 0.02, 0, 0]),
        (1, [0, 1, 0, 0]),
        (1, [0.02, 0.98, 0, 0]),
        (2, [0, 0, 1, 0]),
    ]
    var library: [LibraryEmbedding] = []
    var personIds: [String] = []
    if seedLibrary {
        try insertPhoto(db, id: "library-photo", sessionId: librarySession.id)
        let observationIds = try faceRepo.replaceObservationsByPhoto(
            sessionId: librarySession.id, photoId: "library-photo",
            observations: libraryRows.map { row in
                FaceObservationInput(
                    photoId: "library-photo", bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.2,
                    embedding: row.embedding, confidence: 1,
                    analysisSignature: matchBatchSignature, quality: 1)
            })
        let thresholds = [0.5, 0.7, 0.65]
        for (index, name) in ["P0", "P1", "P2"].enumerated() {
            let id = try personRepo.create(name: name)
            _ = try personRepo.update(
                id: id, fields: PersonUpdateFields(matchThreshold: thresholds[index]))
            personIds.append(id)
        }
        try personRepo.saveEmbeddings(embeddings: libraryRows.enumerated().map { index, row in
            SaveEmbeddingInput(
                personId: personIds[row.personIndex], embedding: row.embedding,
                photoId: "library-photo", sessionId: librarySession.id,
                faceObservationId: observationIds[index])
        })
        library = libraryRows.map {
            LibraryEmbedding(personId: personIds[$0.personIndex], embedding: $0.embedding)
        }
    }

    // 夹具的查询语义锚点（按簇下标）：0≈P0、1≈P1、2≈P0（配 rejected P0）、
    // 3≈P0（配无 personId 的 rejected ⇒ 整簇跳过）、4 与三人全正交 ⇒ 无匹配。
    func queryEmbedding(_ clusterIndex: Int) -> [Float] {
        switch clusterIndex {
        case 0, 2, 3: return [0.99, 0.01, 0, 0]
        case 1: return [0.01, 0.99, 0, 0]
        default: return [0, 0, 0, 1]
        }
    }

    var queries: [(clusterId: Int64, embeddings: [[Float]])] = []
    for index in 0..<clusterCount {
        let clusterId = Int64(index + 1)
        let photoId = "photo-\(index)"
        try insertPhoto(db, id: photoId, sessionId: session.id)
        // 观测只用于 modelSpace 判定（匹配查询向量由调用方直接传入）。
        _ = try faceRepo.replaceObservationsByPhoto(
            sessionId: session.id, photoId: photoId,
            observations: [
                FaceObservationInput(
                    photoId: photoId, bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.2,
                    embedding: queryEmbedding(index), confidence: 0.95,
                    analysisSignature: matchBatchSignature, quality: 1)
            ])
        _ = try db.prepare("""
            INSERT INTO face_clusters (id, session_id, label, status, thumbnail_path)
            VALUES (?, ?, 'Person', 'unbound', '')
            """).run([.int(clusterId), .text(session.id)])
        _ = try db.prepare("""
            INSERT INTO face_cluster_members
             (cluster_id, session_id, photo_id, bbox, confidence, observation_id)
            VALUES (?, ?, ?, ?, ?, NULL)
            """).run([
                .int(clusterId), .text(session.id), .text(photoId),
                .text("[0.1,0.1,0.2,0.2]"), .real(0.95),
            ])
        queries.append((clusterId: clusterId, embeddings: [queryEmbedding(index)]))
    }
    if seedLibrary {
        let feedbackRepo = FaceFeedbackRepo(connection: db)
        for item in rejection {
            try feedbackRepo.record(
                sessionId: session.id, photoId: "photo-\(item.clusterIndex)",
                bbox: [0.1, 0.1, 0.2, 0.2],
                personId: item.personIndex.map { personIds[$0] },
                confirmed: false)
        }
    }

    let service = FaceKwService(
        photoRepo: PhotoRepo(connection: db), sessionRepo: sessionRepo,
        faceRepo: faceRepo, personRepo: personRepo, connection: db,
        getNumber: { key, defaultValue in
            key == "face_match_margin" ? margin : defaultValue
        })
    return MatchBatchFixture(
        db: db, service: service, faceRepo: faceRepo, personRepo: personRepo,
        sessionId: session.id, queries: queries, library: library, margin: margin)
}

/// 旧逐簇路径的冻结参照（与被批量化前的 matchClustersAgainstLibrary 同序同口径）。
/// 成员/feedback 仍按旧方式逐簇读，用来证明"批量读"没改判定。
private func legacyMatchRows(_ fixture: MatchBatchFixture) throws -> [Int64: WrittenMatch] {
    guard !fixture.library.isEmpty else { return [:] }
    let feedback = try FaceFeedbackRepo(connection: fixture.db).list(sessionId: fixture.sessionId)
    let summaries = try fixture.personRepo.summaries(
        ids: Array(Set(fixture.library.map(\.personId))))
    let libraryDim = fixture.library.first?.embedding.count ?? 0
    var result: [Int64: WrittenMatch] = [:]
    for cluster in fixture.queries {
        let members = try fixture.faceRepo.getClusterMembers(cluster.clusterId)
        let rejectedCorrections = feedback.filter { correction in
            correction.decision == "rejected" && members.contains { member in
                member.photoId == correction.photoId
                    && FaceIdentityPolicy.overlap(member.bbox, correction.bbox) >= 0.5
            }
        }
        if rejectedCorrections.contains(where: { $0.personId == nil }) { continue }
        let rejected = Set(rejectedCorrections.compactMap(\.personId))
        let queries = cluster.embeddings.filter { $0.count == libraryDim }
        guard !queries.isEmpty else { continue }
        var scores: [String: [Double]] = [:]
        for query in queries {
            for (personId, score) in try FaceMatcher.bestScoresPerPerson(
                query: query, library: fixture.library)
                where !rejected.contains(personId) {
                scores[personId, default: []].append(score)
            }
        }
        let aggregate = scores.mapValues { values -> Double in
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count % 2 == 0
                ? (sorted[middle - 1] + sorted[middle]) / 2
                : sorted[middle]
        }
        let decision = FaceIdentityPolicy.decide(
            scores: aggregate,
            thresholds: summaries.mapValues(\.matchThreshold),
            defaultThreshold: FaceKwService.defaultPersonMatchThreshold,
            margin: max(0, fixture.margin))
        if case let .accepted(personId, score) = decision {
            result[cluster.clusterId] = WrittenMatch(personId: personId, confidence: score)
        }
    }
    return result
}

/// 生产批量路径落库后的匹配列（只取已写入的簇）。
private func writtenMatchRows(_ fixture: MatchBatchFixture) throws -> [Int64: WrittenMatch] {
    var result: [Int64: WrittenMatch] = [:]
    for row in try fixture.faceRepo.getClusters(fixture.sessionId) {
        guard let personId = row.matchedPersonId else { continue }
        result[row.id] = WrittenMatch(personId: personId, confidence: row.matchConfidence)
    }
    return result
}

struct FaceKwMatchBatchTests {
    // 生产路径写入的 matched_person_id/confidence 必须与旧逐簇循环逐位相同。
    @Test func batchMatchWritesSameRowsAsLegacyPerClusterLoop() throws {
        let fixture = try makeMatchBatchFixture(
            clusterCount: 5,
            rejection: [(clusterIndex: 2, personIndex: 0), (clusterIndex: 3, personIndex: nil)])

        try fixture.service.matchClustersAgainstLibrary(
            sessionId: fixture.sessionId, clusters: fixture.queries,
            modelSpace: matchBatchModelSpace)

        let written = try writtenMatchRows(fixture)
        let legacy = try legacyMatchRows(fixture)
        #expect(written == legacy, "批量落库必须与旧逐簇路径逐位一致（含 rejected/整簇跳过）")
        #expect(legacy.count >= 2, "夹具必须至少有两个簇真的绑定（否则断言空转）")

        // 语义锚点：无拒绝的簇绑定冠军；rejected 冠军 → 不猜；无 personId 的拒绝整簇不猜。
        #expect(fixture.queries.count == 5)
        #expect(written[1] != nil, "query≈P0 的簇必须绑定")
        #expect(written[2] != nil, "query≈P1 的簇必须绑定")
        #expect(written[3] == nil, "rejected 冠军且亚军不达阈值的簇不得绑定")
        #expect(written[4] == nil, "无 personId 的 rejected 必须整簇跳过")
        #expect(written[5] == nil, "正交查询必须无匹配")
    }

    // 空库：静默跳过，不写任何匹配（旧行为）。
    @Test func emptyLibraryLeavesClustersUnbound() throws {
        let fixture = try makeMatchBatchFixture(clusterCount: 2, seedLibrary: false)
        try fixture.service.matchClustersAgainstLibrary(
            sessionId: fixture.sessionId, clusters: fixture.queries,
            modelSpace: matchBatchModelSpace)
        #expect(try writtenMatchRows(fixture).isEmpty)
    }

    // 单簇：与参照逐位一致（批量 API 在最小输入上不得有特判差异）。
    @Test func singleClusterWritesSameRowAsLegacy() throws {
        let fixture = try makeMatchBatchFixture(clusterCount: 1)
        try fixture.service.matchClustersAgainstLibrary(
            sessionId: fixture.sessionId, clusters: fixture.queries,
            modelSpace: matchBatchModelSpace)
        let written = try writtenMatchRows(fixture)
        let legacy = try legacyMatchRows(fixture)
        #expect(written == legacy)
        #expect(written.count == 1)
    }

    // N+1 消除：SELECT 数不随簇数增长，且不再有"每簇成员查询"。
    @Test func matchReadsMembersAndFeedbackOncePerCall() throws {
        let one = try makeMatchBatchFixture(clusterCount: 1)
        let eight = try makeMatchBatchFixture(clusterCount: 8)

        let capturedOne = try captureSelects(db: one.db) {
            try one.service.matchClustersAgainstLibrary(
                sessionId: one.sessionId, clusters: one.queries,
                modelSpace: matchBatchModelSpace)
        }
        let capturedEight = try captureSelects(db: eight.db) {
            try eight.service.matchClustersAgainstLibrary(
                sessionId: eight.sessionId, clusters: eight.queries,
                modelSpace: matchBatchModelSpace)
        }

        print(
            "[N+1] matchClustersAgainstLibrary SELECT: C=1 → \(capturedOne.selects.count)，"
                + "C=8 → \(capturedEight.selects.count)；5c-1 = 7，旧实现 = 2C + 5")
        #expect(capturedEight.selects.count == capturedOne.selects.count,
            "SELECT 数必须与簇数无关：C=1 → \(capturedOne.selects.count)，C=8 → \(capturedEight.selects.count)")
        #expect(capturedEight.selects.count <= 4,
            "5c-2 固定 SELECT ≤ 4（库向量 / 簇+成员 / feedback / 人物阈值）：实测 \(capturedEight.selects.count)")
        #expect(capturedEight.selects.filter { $0.contains("face_identity_feedback") }.count == 1,
            "feedback 必须一次读完（旧实现每簇重读整表）")
        #expect(!capturedEight.selects.contains { $0.contains("FROM face_cluster_members WHERE cluster_id") },
            "不得再出现每簇成员查询（旧 N+1）")
        // 成员必须走 IN 批量读取（getClusters(includeMembers:) 的分块查询）。
        #expect(capturedEight.selects.contains { $0.contains("face_cluster_members") && $0.contains("IN") },
            "成员必须一次 IN 批量读取")
    }
}
