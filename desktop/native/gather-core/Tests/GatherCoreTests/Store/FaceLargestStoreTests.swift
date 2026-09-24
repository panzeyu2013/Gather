// Tests/GatherCoreTests/Store/FaceLargestStoreTests.swift
// W2c Store 测试：FaceStore.largestFacePerPhoto（原 Services/QualityService.swift 443-469
// 行 getFacesBatch 内联 SQL 的 Store 化）。
// 断言重点：每照片取面积最大行、session 隔离、空参数 [:]、400 分块、无观察照片不出现。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/FaceLargest (W2c)")
struct FaceLargestStoreTests {
    private func makeStore() async throws -> (store: SQLiteFaceStore, database: SQLiteDatabase) {
        let database = try await makeMigratedStore(path: storeTempPath("face-largest"))
        try await insertSession(database, "s1")
        try await insertSession(database, "s2")
        return (SQLiteFaceStore(database: database), database)
    }

    private func insertObservation(
        _ database: SQLiteDatabase,
        photoId: String,
        sessionId: String = "s1",
        x: Double,
        y: Double,
        w: Double,
        h: Double,
        signature: String
    ) async throws {
        try await database.run(
            """
            INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h,
              embedding, confidence, source_file_size, source_file_mtime_ms, analysis_signature)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0.9, 0, 0, ?)
            """,
            [
                .text(photoId), .text(sessionId), .real(x), .real(y),
                .real(w), .real(h), .blob(Data([0])), .text(signature),
            ]
        )
    }

    @Test("largestFacePerPhoto：每照片取面积最大行（插入序无关），无观察照片不出现")
    func largestPerPhoto() async throws {
        let (store, database) = try await makeStore()
        for id in ["p1", "p2", "p3"] {
            try await insertPhoto(database, id: id, sessionId: "s1")
        }
        // p1：先小后大 —— 面积降序首行必须是大的那行。
        try await insertObservation(database, photoId: "p1", x: 1, y: 2, w: 10, h: 10, signature: "small")
        try await insertObservation(database, photoId: "p1", x: 5, y: 6, w: 100, h: 80, signature: "large")
        // p2：单行。
        try await insertObservation(database, photoId: "p2", x: 0.5, y: 0.5, w: 50, h: 40, signature: "medium")

        #expect(try await store.largestFacePerPhoto(sessionId: "s1", photoIds: []).isEmpty)

        let faces = try await store.largestFacePerPhoto(sessionId: "s1", photoIds: ["p1", "p2", "p3"])
        #expect(Set(faces.keys) == ["p1", "p2"])
        #expect(faces["p3"] == nil, "无观察照片不产生键")
        #expect(faces["p1"] == FaceObservationBox(x: 5, y: 6, w: 100, h: 80, analysisSignature: "large"))
        #expect(faces["p2"] == FaceObservationBox(x: 0.5, y: 0.5, w: 50, h: 40, analysisSignature: "medium"))

        // 插入序反转为「先大后小」，答案不变。
        try await insertObservation(database, photoId: "p3", x: 9, y: 9, w: 90, h: 70, signature: "big")
        try await insertObservation(database, photoId: "p3", x: 1, y: 1, w: 10, h: 10, signature: "tiny")
        let again = try await store.largestFacePerPhoto(sessionId: "s1", photoIds: ["p3"])
        #expect(again["p3"]?.analysisSignature == "big")
    }

    @Test("largestFacePerPhoto：session 隔离；未知 photoId 忽略")
    func sessionScoping() async throws {
        let (store, database) = try await makeStore()
        for id in ["p1", "p2"] {
            try await insertPhoto(database, id: id, sessionId: "s1")
        }
        try await insertPhoto(database, id: "p4", sessionId: "s2")
        try await insertObservation(database, photoId: "p1", x: 0, y: 0, w: 20, h: 20, signature: "s1-face")
        try await insertObservation(
            database, photoId: "p4", sessionId: "s2", x: 0, y: 0, w: 30, h: 30, signature: "s2-face"
        )

        #expect(try await store.largestFacePerPhoto(sessionId: "s1", photoIds: ["p4"]).isEmpty)
        let s2 = try await store.largestFacePerPhoto(sessionId: "s2", photoIds: ["p4"])
        #expect(s2["p4"]?.analysisSignature == "s2-face")

        let mixed = try await store.largestFacePerPhoto(sessionId: "s1", photoIds: ["p1", "p2", "ghost"])
        #expect(Set(mixed.keys) == ["p1"])
        #expect(mixed["p1"]?.w == 20)
    }

    @Test("largestFacePerPhoto：401 个 photoId 跨 400 分块全量返回")
    func chunkOver400() async throws {
        let (store, database) = try await makeStore()
        let total = 401
        try await database.transaction { db in
            for index in 0..<total {
                try db.run(
                    """
                    INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
                      result, asset_id, asset_file_id, width, height, created_at, updated_at)
                    VALUES (?, 's1', ?, ?, '', 'pending', '{}', '{}', NULL, NULL, 100, 100,
                      '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                    """,
                    [
                        .text("p-\(index)"), .text("/shoot/p-\(index).jpg"),
                        .text("p-\(index).jpg"),
                    ]
                )
                try db.run(
                    """
                    INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h,
                      embedding, confidence, source_file_size, source_file_mtime_ms, analysis_signature)
                    VALUES (?, 's1', 0, 0, ?, 10, ?, 0.9, 0, 0, ?)
                    """,
                    [
                        .text("p-\(index)"), .real(Double(index % 7) + 1),
                        .blob(Data([0])), .text("sig-\(index)"),
                    ]
                )
            }
        }

        let ids = (0..<total).map { "p-\($0)" }
        let faces = try await store.largestFacePerPhoto(sessionId: "s1", photoIds: ids)
        #expect(faces.count == total, "400 + 1 两块必须都读到")
        #expect(faces["p-400"]?.analysisSignature == "sig-400", "第二块（索引 400）必须返回")
        #expect(faces["p-0"]?.analysisSignature == "sig-0")
    }
}
