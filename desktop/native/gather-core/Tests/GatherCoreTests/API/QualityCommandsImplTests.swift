// Tests/GatherCoreTests/API/QualityCommandsImplTests.swift
// R5：quality 域命令实现直测（批次 B3）。
// 覆盖旧路由分支语义：get 最新评分结果；analyze 建 quality.score 作业
// （dedupeKey / checkpoint 逐字）且不等完成；photoIds 提供但为空 →
// INVALID_PARAM:photoIds 门控。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/QualityCommandsImpl (R5)")
struct QualityCommandsImplTests {
    private struct Harness {
        let impl: QualityCommandsImpl
        let db: SQLiteDatabase
        let sessionId: String
        let path: String
    }

    private func makeHarness() async throws -> Harness {
        let path = storeTempPath("quality-commands")
        let db = try await makeMigratedStore(path: path)
        let session = try await SQLiteSessionStore(database: db).create(
            name: "Quality", source: "manual", sourcePath: "", truncatedImport: false)
        let runtime = QualityRuntime(
            photoStore: SQLitePhotoStore(database: db),
            jobStore: SQLiteJobStore(database: db),
            similarityStore: SQLiteSimilarityStore(database: db),
            faceStore: SQLiteFaceStore(database: db)
        )
        let runner = JobRunner(jobStore: SQLiteJobStore(database: db))
        await runner.registerExecutor(type: .qualityScore) { _, _ in nil }
        return Harness(
            impl: QualityCommandsImpl(quality: runtime, jobs: runner),
            db: db, sessionId: session.id, path: path
        )
    }

    private func seedPhoto(
        _ db: SQLiteDatabase, photoId: String, sessionId: String, assetFileId: String
    ) async throws {
        let filepath = "/vault/\(photoId).jpg"
        try await insertAssetFile(db, id: assetFileId, normalizedPath: filepath)
        _ = try await db.run("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
              asset_file_id, width, height, created_at, updated_at)
            VALUES (?, ?, ?, ?, '', 'ready', ?, 100, 80,
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """, [
                .text(photoId), .text(sessionId), .text(filepath),
                .text((filepath as NSString).lastPathComponent), .text(assetFileId),
            ])
    }

    private func insertQualityRow(
        _ db: SQLiteDatabase, photoId: String, assetFileId: String, score: Double
    ) async throws {
        let payload = try JSONEncoder().encode(QualityResult(
            photoId: photoId, status: .succeeded, qualityScore: score,
            sharpness: score, exposure: 1, warnings: [],
            modelId: "test", modelVersion: "1",
            inputFingerprint: "fp-\(photoId)",
            updatedAt: "2026-01-01T00:00:00.000Z"
        ))
        _ = try await db.run("""
            INSERT INTO asset_analysis
              (photo_id, asset_file_id, analysis_type, result_json, warnings_json,
               model_id, model_version, input_fingerprint, created_at, updated_at)
            VALUES (?, ?, 'technical_quality', ?, '[]', 'test', '1', ?,
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """, [
                .text(photoId), .text(assetFileId),
                .text(String(data: payload, encoding: .utf8) ?? "{}"),
                .text("fp-\(photoId)"),
            ])
    }

    @Test("get returns the latest quality result through the runtime")
    func getReturnsLatestResult() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await seedPhoto(
            harness.db, photoId: "p1", sessionId: harness.sessionId, assetFileId: "af-1")
        try await insertQualityRow(
            harness.db, photoId: "p1", assetFileId: "af-1", score: 0.77)

        let results = try await harness.impl.get(
            QualityGetParams(sessionId: harness.sessionId, photoIds: ["p1"]))

        #expect(results.count == 1)
        #expect(results.first?.photoId == "p1")
        #expect(results.first?.qualityScore == 0.77)
    }

    @Test("analyze creates a quality.score job for an explicit photo subset")
    func analyzeCreatesJobForSubset() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }

        let job = try await harness.impl.analyze(QualityAnalyzeParams(
            sessionId: harness.sessionId, photoIds: ["p2", "p1"]))

        #expect(job.type == .qualityScore)
        #expect(job.scopeType == "session")
        #expect(job.scopeId == harness.sessionId)
        #expect(job.dedupeKey == "quality.score:\(harness.sessionId):p1,p2")
        #expect(job.status == .queued)
        #expect(job.checkpoint["photoIds"] == .array([.string("p1"), .string("p2")]))
    }

    @Test("analyze creates an all-photos job when photoIds is nil")
    func analyzeCreatesJobForAll() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }

        let job = try await harness.impl.analyze(
            QualityAnalyzeParams(sessionId: harness.sessionId))

        #expect(job.dedupeKey == "quality.score:\(harness.sessionId):all")
        #expect(job.checkpoint["photoIds"] == .null)
    }

    @Test("analyze rejects an explicitly empty photoIds with INVALID_PARAM:photoIds")
    func analyzeRejectsEmptyPhotoIds() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }

        await #expect(throws: QualityCommandsError.invalidParam("photoIds")) {
            try await harness.impl.analyze(
                QualityAnalyzeParams(sessionId: harness.sessionId, photoIds: []))
        }
        #expect(String(describing: QualityCommandsError.invalidParam("photoIds")) == "INVALID_PARAM:photoIds")
    }
}
