// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceIdentityArchitectureTests.swift
// 人脸身份架构契约：阈值竞争、模型空间隔离、人工纠正与迁移原子性。
//
// 职责：
// 1. FaceIdentityPolicy：低于阈值的竞争者仍可造成 ambiguity；
// 2. 不同 embeddingSpec 的向量不得互相匹配；
// 3. 人工纠正（拒识/确认/关键词）在观测替换后仍持久，并可显式覆盖；
// 4. 身份迁移失败/取消不得发布半成品向量；聚类失败整体回滚并保留手工绑定；
// 5. 同名人物在 reconcile 时不得合并；
// 6. 内置 SFace 输出 128 维单位向量，且与独立参考向量余弦 > 0.9999。
//
// 边界：内存 SchemaV1 + 临时图片路径；解码/推理/聚类以闭包替身注入，只有
// bundledModelRunsRealCoreMLInference 走真实 CoreML（依赖 target 内模型资源）。
import Foundation
import CoreGraphics
import Testing
import GatherTestSupport
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis
@testable import GatherPersistence

@Suite(.serialized)
struct FaceIdentityArchitectureTests {
    @Test func competitorBelowItsThresholdStillCreatesAmbiguity() {
        #expect(FaceIdentityPolicy.decide(scores: ["A": 0.651, "B": 0.649],
            thresholds: ["A": 0.65, "B": 0.9], margin: 0.01) == .ambiguous)
        #expect(FaceIdentityPolicy.decide(scores: ["A": 0.8, "B": 0.6],
            thresholds: [:]) == .accepted(personId: "A", score: 0.8))
    }

    @Test func modelSpacesWithEqualDimensionsCannotMatch() throws {
        let db = try makeTestDB()
        defer { db.close() }
        try insertSession(db, "s")
        try insertPhoto(db, id: "p", sessionId: "s", filepath: "/tmp/p.jpg")
        let faces = FaceRepo(connection: db)
        let ids = try faces.replaceObservationsByPhoto(sessionId: "s", photoId: "p", observations: [
            FaceObservationInput(photoId: "p", bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.3,
                embedding: [1, 0], confidence: 0.9, analysisSignature: "{\"embeddingSpec\":\"model-A:weights-1\"}")
        ])
        let people = PersonRepo(connection: db)
        let personId = try people.create(name: "A")
        try people.saveEmbeddings(embeddings: [.init(personId: personId, embedding: [1, 0], photoId: "p",
            sessionId: "s", faceObservationId: ids[0])])
        #expect(try people.getAllEmbeddings(modelSpace: "model-A:weights-1").count == 1)
        #expect(try people.getAllEmbeddings(modelSpace: "model-A:weights-2").isEmpty)
        #expect(try people.getAllEmbeddings(modelSpace: "model-B:weights-1").isEmpty)
    }

    @Test func correctionsSurviveObservationReplacementAndCanBeExplicitlyOverridden() throws {
        let db = try makeTestDB()
        defer { db.close() }
        try insertSession(db, "s")
        try insertPhoto(db, id: "p", sessionId: "s", filepath: "/tmp/p.jpg")
        let person = try PersonRepo(connection: db).create(name: "A")
        let feedback = FaceFeedbackRepo(connection: db)
        let bbox = [0.1, 0.2, 0.2, 0.3]
        try feedback.record(sessionId: "s", photoId: "p", bbox: bbox, personId: person,
                            confirmed: false)
        _ = try FaceRepo(connection: db).replaceObservationsByPhoto(sessionId: "s", photoId: "p", observations: [])
        #expect(try feedback.list(sessionId: "s").first?.decision == "rejected")
        try feedback.record(sessionId: "s", photoId: "p", bbox: [0.105, 0.2, 0.2, 0.3],
                            personId: person, confirmed: true, keywords: ["bride"])
        let records = try feedback.list(sessionId: "s")
        #expect(records.count == 1)
        #expect(records.first?.decision == "confirmed")
        #expect(records.first?.keywords == ["bride"])
    }

    @Test("Failed or cancelled migration cannot publish prepared vectors", arguments: [false, true])
    func failedMigrationDoesNotPublishPartialVectors(cancellation: Bool) async throws {
        let db = try makeTestDB()
        defer { db.close() }
        let session = try SessionRepo(connection: db).create(name: "Migration", source: "folder")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let faces = FaceRepo(connection: db)
        for index in 1...2 {
            let path = try writeTempFile(in: dir, name: "\(index).jpg")
            try insertPhoto(db, id: "p\(index)", sessionId: session.id, filepath: path)
            _ = try faces.replaceObservationsByPhoto(sessionId: session.id, photoId: "p\(index)", observations: [
                FaceObservationInput(photoId: "p\(index)", bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.3,
                    embedding: [1, 0], confidence: 0.9, analysisSignature: "{\"embeddingSpec\":\"old\"}")
            ])
        }
        let before = try faces.getObservations(session.id).map(\.id)
        let service = FaceKwService(photoRepo: PhotoRepo(connection: db), sessionRepo: SessionRepo(connection: db),
            faceRepo: faces, personRepo: PersonRepo(connection: db), connection: db,
            getNumber: { key, fallback in key == "face_decode_concurrency" ? 2 : fallback },
            decodeProvider: { _, _ in Data([1]) }, inferenceProvider: { images, _, _ in
                images.enumerated().map { index, _ in
                    (index == 0 || cancellation) ? FaceInferenceItem(observations: [
                        FaceInferenceObservation(bbox: [0.1, 0.1, 0.2, 0.3], confidence: 0.9, embedding: [0, 1])
                    ]) : FaceInferenceItem(error: "failure")
                }
            })
        let result = try await service.analyze(sessionId: session.id, detectorPath: "d", encoderPath: "e",
            onProgress: { _, _, phase in
                if cancellation && phase == "face.cluster" { service.cancel(sessionId: session.id) }
            })
        #expect(result.status == (cancellation ? "cancelled" : "failed"))
        #expect(try faces.getObservations(session.id).map(\.id) == before)
        #expect(try faces.getObservations(session.id).allSatisfy {
            FaceIdentityPolicy.modelSpace(analysisSignature: $0.analysisSignature) == "old"
        })
        #expect(try faces.getAnalysisStates(session.id).isEmpty)
    }

    @Test("Migration preserves manual identity and rolls back if clustering fails", arguments: [false, true])
    func migrationPreservesIdentityOrRollsBack(clusterFailure: Bool) async throws {
        let db = try makeTestDB()
        defer { db.close() }
        let sessions = SessionRepo(connection: db)
        let session = try sessions.create(name: "Migration", source: "folder")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let faces = FaceRepo(connection: db)
        var members: [FaceClusterMemberInput] = []
        for index in 1...2 {
            let photoId = "p\(index)"
            let path = try writeTempFile(in: dir, name: "\(index).jpg")
            try insertPhoto(db, id: photoId, sessionId: session.id, filepath: path)
            let ids = try faces.replaceObservationsByPhoto(sessionId: session.id, photoId: photoId, observations: [
                FaceObservationInput(photoId: photoId, bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.3,
                    embedding: [1, 0], confidence: 0.9, analysisSignature: "{\"embeddingSpec\":\"old\"}", quality: 1)
            ])
            members.append(.init(photoId: photoId, photoPath: path, bbox: [0.1, 0.1, 0.2, 0.3],
                confidence: 0.9, observationId: ids[0]))
        }
        let clusterId = try faces.saveClusters(sessionId: session.id, clusters: [.init(label: "A", members: members)])[0]
        let people = PersonRepo(connection: db)
        let service = FaceKwService(photoRepo: PhotoRepo(connection: db), sessionRepo: sessions,
            faceRepo: faces, personRepo: people, connection: db,
            decodeProvider: { _, _ in Data([1]) }, inferenceProvider: { images, _, _ in
                images.map { _ in FaceInferenceItem(observations: [
                    FaceInferenceObservation(bbox: [0.1, 0.1, 0.2, 0.3], confidence: 0.9,
                        embedding: [0, 1], quality: 1)
                ]) }
            }, clusterProvider: { entries, eps, minPts, _, _, _ in
                if clusterFailure { throw DBError.message("Injected clustering failure") }
                return try FaceClusterer.clusterEmbeddings(entries: entries, eps: eps, minPts: minPts)
            })
        try service.bindCluster(sessionId: session.id, clusterId: clusterId, roleName: "A", keywords: ["bride"])
        let person = try #require(faces.getClusters(session.id).first?.matchedPersonId)
        let oldIds = try faces.getObservations(session.id).map(\.id)
        if clusterFailure {
            do {
                _ = try await service.analyze(sessionId: session.id, detectorPath: "d", encoderPath: "e")
                Issue.record("Expected clustering failure")
            } catch { #expect(error is DBError) }
            #expect(try faces.getObservations(session.id).map(\.id) == oldIds)
            #expect(try faces.getClusters(session.id).first?.id == clusterId)
            #expect(try people.getAllEmbeddings(modelSpace: "old").count == 2)
        } else {
            let result = try await service.analyze(sessionId: session.id, detectorPath: "d", encoderPath: "e")
            #expect(result.status == "done")
            #expect(try faces.getObservations(session.id).map(\.id) != oldIds)
            let restored = try #require(faces.getClusters(session.id, includeMembers: true).first)
            #expect(restored.matchedPersonId == person)
            #expect(restored.binding?.keywords == ["bride"])
            let spec = try FaceEmbeddingModelFactory.spec(modelPath: "", modelVersion: "")
            #expect(try people.getAllEmbeddings(modelSpace: spec.signature).count == 2)
            #expect(try people.getAllEmbeddings(modelSpace: "old").isEmpty)
            // Removing an incorrect face is durable across a subsequent full recluster.
            let member = try #require(restored.members?.first)
            try service.removeMember(sessionId: session.id, clusterId: restored.id, memberId: member.id)
            try await service.recluster(sessionId: session.id, eps: 0.6, minPts: 2)
            let review = try faces.getClusters(session.id, includeMembers: true).filter { $0.binding == nil }
            #expect(review.count == 1)
            #expect(review.first?.matchedPersonId == nil)
            #expect(review.first?.members?.first?.photoId == member.photoId)
        }
    }

    @Test func equalDisplayNamesDoNotMergeExplicitIdentitiesDuringReconciliation() throws {
        let db = try makeTestDB()
        defer { db.close() }
        try insertSession(db, "s")
        let people = PersonRepo(connection: db)
        let faces = FaceRepo(connection: db)
        let first = try people.create(name: "Same")
        let second = try people.create(name: "Same")
        for (index, person) in [first, second].enumerated() {
            let photo = "p\(index)"
            try insertPhoto(db, id: photo, sessionId: "s", filepath: "/tmp/\(photo).jpg")
            let ids = try faces.replaceObservationsByPhoto(sessionId: "s", photoId: photo, observations: [
                FaceObservationInput(photoId: photo, bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.3,
                    embedding: [1, 0], confidence: 0.9, analysisSignature: "{\"embeddingSpec\":\"model\"}", quality: 1)
            ])
            let cluster = try faces.saveClusters(sessionId: "s", clusters: [.init(label: "Same", members: [
                .init(photoId: photo, photoPath: "/tmp/\(photo).jpg", bbox: [0.1, 0.1, 0.2, 0.3],
                    confidence: 0.9, observationId: ids[0])
            ])])[0]
            try faces.updateBinding(clusterId: cluster, roleName: "Same", keywords: [])
            try faces.setClusterMatch(clusterId: cluster, personId: person, confidence: 1)
        }
        try people.reconcileSession(sessionId: "s")
        let library = try people.getAllEmbeddings(modelSpace: "model")
        #expect(library.count == 2)
        #expect(Set(library.map(\.personId)) == Set([first, second]))
        #expect(try people.getPhotosWithDetails(personId: first).photos.map { $0.photo.photoId } == ["p0"])
        #expect(try people.getPhotosWithDetails(personId: second).photos.map { $0.photo.photoId } == ["p1"])
    }

    // skip-owner: face-model
    // 到期：2027-06-30
    // 原因：加载 37MB SFace CoreML 包并跑真实推理，属夜间集成；默认 PR 只测纯逻辑。
    // 手动条件：GATHER_MODEL_TESTS=1 swift test --filter FaceIdentityArchitectureTests
    @Test(.enabled(if: IntegrationTestGate.modelTestsEnabled))
    func bundledModelRunsRealCoreMLInference() throws {
        let embedder = try FaceEmbeddingModelFactory.make(modelPath: "", modelVersion: "")
        let pixels = (0..<(112 * 112 * 4)).map { UInt8($0 % 256) }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: 112, height: 112, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 112 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let vector = try embedder.embed(alignedFace: image)
        #expect(vector.count == 128)
        #expect(vector.allSatisfy { $0.isFinite })
        #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.00001)
        let modelURL = try #require(FaceEmbeddingModelFactory.bundledModelURL)
        let referenceURL = modelURL.deletingLastPathComponent().appendingPathComponent("native_ramp_reference.json")
        let reference = try JSONDecoder().decode([Double].self, from: Data(contentsOf: referenceURL))
        #expect(reference.count == vector.count)
        let cosine = zip(reference, vector).reduce(0) { $0 + $1.0 * $1.1 }
        #expect(cosine > 0.9999, "The Swift Vision/CoreML image wrapper must agree with independent ONNX RGB output")
    }
}
