// Tests/GatherCoreTests/Store/FaceStoreTests.swift
// R1：FaceStore 观察/分析状态/复用测试（端口自 FaceRepoTests 前 6 个用例）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/FaceStore (R1)")
struct FaceStoreTests {
    private func makeStore() async throws -> (SQLiteFaceStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "face")
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        for id in ["p1", "p2"] {
            try await database.run(
                """
                INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
                VALUES (?, 's1', ?, ?, 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text(id), .text("/v/\(id).jpg"), .text("\(id).jpg")]
            )
        }
        return (SQLiteFaceStore(database: database), database, path)
    }

    private func observation(photoId: String, embedding: [Float] = [0.5, -0.25, 1.0]) -> FaceObservationInput {
        FaceObservationInput(
            photoId: photoId,
            bboxX: 1.5, bboxY: 2.5, bboxW: 100.0, bboxH: 200.0,
            embedding: embedding,
            confidence: 0.95,
            sourceFileSize: 1234,
            sourceFileMtimeMs: 1_700_000_000_123.5,
            analysisSignature: "sig-1"
        )
    }

    private func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    @Test func saveAndGetObservations() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let ids = try await store.saveObservations(
            sessionId: "s1", observations: [observation(photoId: "p1"), observation(photoId: "p2")]
        )
        #expect(ids == [1, 2])

        let rows = try await store.observations(sessionId: "s1")
        #expect(rows.count == 2)
        #expect(rows[0].photoId == "p1")
        #expect(rows[0].bboxX == 1.5)
        #expect(rows[0].sourceFileSize == 1234)
        #expect(rows[0].analysisSignature == "sig-1")
        #expect(rows[0].embedding.count == 12, "Float32 × 3")
        #expect(floats(from: rows[0].embedding) == [0.5, -0.25, 1.0])
        #expect(rows[1].id == 2)

        let counts = try await store.countsByPhoto(sessionId: "s1", photoIds: ["p1", "p2", "missing"])
        #expect(counts == ["p1": 1, "p2": 1])
        #expect(try await store.countsByPhoto(sessionId: "s1", photoIds: []).isEmpty)
        _ = database
    }

    @Test func replaceObservationsByPhoto() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        _ = try await store.saveObservations(sessionId: "s1", observations: [observation(photoId: "p1")])
        let newIDs = try await store.replaceObservationsByPhoto(sessionId: "s1", photoId: "p1", observations: [
            observation(photoId: "p1", embedding: [0.1]),
            observation(photoId: "p1", embedding: [0.2]),
        ])
        #expect(newIDs.count == 2)
        let rows = try await store.observations(sessionId: "s1")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.photoId == "p1" })
    }

    @Test func deleteObservationsVariants() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        _ = try await store.saveObservations(
            sessionId: "s1", observations: [observation(photoId: "p1"), observation(photoId: "p2")]
        )
        try await store.upsertAnalysisState(sessionId: "s1", photoId: "p1", sourceFileSize: 1, sourceFileMtimeMs: 2, analysisSignature: "s")
        try await store.upsertClusterSignature(sessionId: "s1", signature: "sig")

        try await store.deleteObservationsByPhoto(sessionId: "s1", photoId: "p1")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM face_observations") == 1)
        try await store.deleteAnalysisStateByPhoto(sessionId: "s1", photoId: "p1")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM face_analysis_state") == 0)

        try await store.deleteObservationsBySession("s1")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM face_observations") == 0)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM face_cluster_state") == 0)
    }

    @Test func analysisStateAndClusterSignature() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        #expect(try await store.analysisStates(sessionId: "s1").isEmpty)
        #expect(try await store.clusterSignature(sessionId: "s1") == nil)

        try await store.upsertAnalysisState(sessionId: "s1", photoId: "p1", sourceFileSize: 100, sourceFileMtimeMs: 200.5, analysisSignature: "a")
        var states = try await store.analysisStates(sessionId: "s1")
        #expect(states["p1"] == FaceAnalysisStateRecord(sourceFileSize: 100, sourceFileMtimeMs: 200.5, analysisSignature: "a"))

        try await store.upsertAnalysisState(sessionId: "s1", photoId: "p1", sourceFileSize: 101, sourceFileMtimeMs: 201.5, analysisSignature: "b")
        states = try await store.analysisStates(sessionId: "s1")
        #expect(states["p1"]?.analysisSignature == "b")
        #expect(states.count == 1)

        try await store.upsertClusterSignature(sessionId: "s1", signature: "cluster-v1")
        #expect(try await store.clusterSignature(sessionId: "s1") == "cluster-v1")
        try await store.upsertClusterSignature(sessionId: "s1", signature: "cluster-v2")
        #expect(try await store.clusterSignature(sessionId: "s1") == "cluster-v2")
    }

    @Test func updateEmbedding() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let ids = try await store.saveObservations(
            sessionId: "s1", observations: [observation(photoId: "p1", embedding: [0.0, 0.0])]
        )
        try await store.updateEmbedding(observationId: ids[0], embedding: [9.9, -8.8])
        let row = try await store.observations(sessionId: "s1")[0]
        #expect(floats(from: row.embedding) == [9.9, -8.8])
    }

    @Test func reuseObservationsForAssetFile() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await database.run(
            """
            INSERT INTO asset_files (id, volume_id, normalized_path, filename, created_at, updated_at)
            VALUES ('f1', 'dev:1', '/v/p1.jpg', 'p1.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        try await database.run("UPDATE photos SET asset_file_id = 'f1' WHERE id IN ('p1', 'p2')")

        _ = try await store.saveObservations(sessionId: "s1", observations: [observation(photoId: "p1")])
        try await store.upsertAnalysisState(
            sessionId: "s1", photoId: "p1", sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5, analysisSignature: "sig-1"
        )

        let batch = try await store.reuseObservations(
            sessionId: "s1",
            targets: [
                FaceReuseTargetInput(photoId: "p2", assetFileId: "f1", sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5),
                FaceReuseTargetInput(photoId: "nope", assetFileId: "f1", sourceFileSize: 999, sourceFileMtimeMs: 0),
            ],
            analysisSignature: "sig-1"
        )
        #expect(batch["p2"] == FaceReuseResult(reused: true, faceCount: 1))
        #expect(batch["nope"] == nil, "文件状态不匹配的目标不在结果中")
        let p2Rows = try await store.observations(sessionId: "s1").filter { $0.photoId == "p2" }
        #expect(p2Rows.count == 1)
        #expect(p2Rows[0].sessionId == "s1")
        #expect(p2Rows[0].analysisSignature == "sig-1")

        let single = try await store.reuseObservations(
            sessionId: "s1", photoId: "p2", sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5, analysisSignature: "sig-1"
        )
        #expect(single.reused)
        #expect(single.faceCount == 1)

        let miss = try await store.reuseObservations(
            sessionId: "s1", photoId: "p2", sourceFileSize: 1, sourceFileMtimeMs: 1, analysisSignature: "other"
        )
        #expect(miss.reused == false)
    }
}
