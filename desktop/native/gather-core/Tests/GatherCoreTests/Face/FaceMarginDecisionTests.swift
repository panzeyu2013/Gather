// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceMarginDecisionTests.swift
// C 组（相近身份 + face_match_margin）**生产路径**行为测试。
//
// 旧版用 7 轮 analyze + precision@K/覆盖率曲线评估 margin 的“质量取舍”；
// 那是 benchmark 的职责，不是 PR correctness 信号。本文件只保留一条最小场景：
//   · 清楚样本：margin=0 与 margin=0.01 都必须绑定 P0；
//   · 近并列样本：margin=0 绑定其中一个（同分按 personId 字典序破平），margin=0.01 必须拒绑。
// 断言的是生产落库的 matched_person_id，而不是测试自己复刻的规则。

import Foundation
import Testing
import GatherTestSupport

@testable import GatherProtocol
@testable import GatherAnalysis
@testable import GatherApplication
@testable import GatherPersistence

private struct ProductionMarginResult {
    let bound: [Int: String]
    let personIds: [String]
    let clusterCount: Int
}

/// 用真实 FaceKwService 跑一次 analyze，返回生产落库的 query → person 绑定。
private func runProductionMargin(
    margin: Double,
    personNames: [String],
    library: [(personIndex: Int, embedding: [Float])],
    queries: [[Float]]
) async throws -> ProductionMarginResult {
    let db = try makeTestDB()
    let sessionRepo = SessionRepo(connection: db)
    let session = try sessionRepo.create(name: "MarginRun", source: "folder")
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let librarySession = try sessionRepo.create(name: "Library", source: "folder")
    let libraryPhoto = "library-photo"
    try insertPhoto(
        db, id: libraryPhoto, sessionId: librarySession.id,
        filepath: try writeTempFile(in: dir, name: "library.jpg"))

    var pathToEmbedding: [String: [Double]] = [:]
    var photoIdToQueryIndex: [String: Int] = [:]
    for (index, query) in queries.enumerated() {
        for copy in 0..<2 {
            let path = try writeTempFile(in: dir, name: "q\(index)-\(copy).jpg")
            let photoId = "photo-\(index)-\(copy)"
            try insertPhoto(db, id: photoId, sessionId: session.id, filepath: path)
            pathToEmbedding[path] = query.map(Double.init)
            photoIdToQueryIndex[photoId] = index
        }
    }

    let personRepo = PersonRepo(connection: db)
    var personIds: [String] = []
    for name in personNames {
        let personId = try personRepo.create(name: name)
        _ = try personRepo.update(
            id: personId, fields: PersonUpdateFields(matchThreshold: 0.6))
        personIds.append(personId)
    }

    let faceRepo = FaceRepo(connection: db)
    let model = try FaceEmbeddingModelFactory.spec(modelPath: "", modelVersion: "")
    let signature = "{\"embeddingSpec\":\"\(model.signature)\"}"
    let observationIds = try faceRepo.replaceObservationsByPhoto(
        sessionId: librarySession.id, photoId: libraryPhoto,
        observations: library.map { item in
            FaceObservationInput(
                photoId: libraryPhoto, bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.3,
                embedding: item.embedding, confidence: 1, analysisSignature: signature,
                quality: 1)
        })
    try personRepo.saveEmbeddings(embeddings: library.enumerated().map { index, item in
        SaveEmbeddingInput(
            personId: personIds[item.personIndex], embedding: item.embedding,
            photoId: libraryPhoto, sessionId: librarySession.id,
            faceObservationId: observationIds[index])
    })

    let service = FaceKwService(
        photoRepo: PhotoRepo(connection: db),
        sessionRepo: sessionRepo,
        faceRepo: faceRepo,
        personRepo: personRepo,
        connection: db,
        getNumber: { key, defaultValue in
            key == "face_match_margin" ? margin : defaultValue
        },
        getString: { _, defaultValue in defaultValue },
        decodeProvider: { path, _ in Data(path.utf8) },
        inferenceProvider: { images, _, _ in
            images.map { data in
                let path = String(decoding: data, as: UTF8.self)
                guard let embedding = pathToEmbedding[path] else {
                    return FaceInferenceItem(observations: [])
                }
                return FaceInferenceItem(observations: [
                    FaceInferenceObservation(
                        bbox: [10, 20, 30, 40], confidence: 0.95, embedding: embedding,
                        quality: 1.0, faceSizePx: 40, rollDegrees: 0)
                ])
            }
        })

    _ = try await service.analyze(
        sessionId: session.id, detectorPath: "det.onnx", encoderPath: "enc.onnx",
        eps: 0.99, minPts: 2)

    let clusters = try faceRepo.getClusters(session.id, includeMembers: true)
    var bound: [Int: String] = [:]
    for cluster in clusters {
        let queryIndices = Set((cluster.members ?? []).compactMap { photoIdToQueryIndex[$0.photoId] })
        guard queryIndices.count == 1, let queryIndex = queryIndices.first,
              let personId = cluster.matchedPersonId else { continue }
        bound[queryIndex] = personId
    }
    return ProductionMarginResult(
        bound: bound, personIds: personIds, clusterCount: clusters.count)
}

struct FaceMarginDecisionTests {
    @Test func marginRuleUsesProductionBindingDecisions() async throws {
        #expect(FaceKwService.defaultPersonMatchThreshold == 0.65)
        // margin 边界：gap == margin 仍接受，严格小于才拒（IdentityPolicy.swift）。
        let thresholds = ["P0": 0.6, "P1": 0.6]
        let scores = ["P0": 0.8, "P1": 0.7955]
        #expect(
            FaceIdentityPolicy.decide(
                scores: scores, thresholds: thresholds, margin: 0.0045)
                == .accepted(personId: "P0", score: 0.8))
        #expect(
            FaceIdentityPolicy.decide(
                scores: scores, thresholds: thresholds, margin: 0.0046)
                == .ambiguous)

        // P0/P1 正交；近并列查询在两边的分数完全相等（0.7071）。
        let library: [(personIndex: Int, embedding: [Float])] = [
            (0, [1, 0, 0, 0]),
            (1, [0, 1, 0, 0]),
        ]
        let queries: [[Float]] = [
            [0.99, 0.01, 0, 0],                    // 清楚样本
            [0.70710678, 0.70710678, 0, 0],        // 近并列样本
        ]

        let base = try await runProductionMargin(
            margin: 0, personNames: ["P0", "P1"], library: library, queries: queries)
        #expect(base.clusterCount == 2, "每个 query 的两张照片必须形成独立簇")
        #expect(base.bound[0] == base.personIds[0], "清楚样本必须绑定 P0")
        #expect(base.bound[1] != nil, "margin=0：近并列样本绑定其中一个身份")
        if let nearTie = base.bound[1] {
            #expect(
                [base.personIds[0], base.personIds[1]].contains(nearTie),
                "margin=0 只能绑定 P0/P1")
        }

        let gated = try await runProductionMargin(
            margin: 0.01, personNames: ["P0", "P1"], library: library, queries: queries)
        #expect(gated.clusterCount == 2, "margin 只影响绑定，不影响聚类")
        #expect(gated.bound[0] == gated.personIds[0], "清楚样本在 margin=0.01 下仍绑定 P0")
        #expect(gated.bound[1] == nil, "margin=0.01：近并列样本必须歧义拒绑")
    }
}
