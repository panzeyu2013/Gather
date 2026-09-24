// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Quality/QualityRuntimeGetTests.swift
// W2c：QualityRuntime.get 行为测试（承接旧 Services/QualityServiceTests.swift
// 的 get / 相对排名用例，并锁定设计 §2.4 的两处行为变化：
// ⑦ get 按请求序返回；② loadSimilarityGroups 排除 precomputed 档）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 支撑

private struct QualityGetEnv {
    let db: SQLiteDatabase
    let runtime: QualityRuntime
    let sessionId: String
}

private func makeQualityGetEnv() async throws -> QualityGetEnv {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-quality-get-\(UUID().uuidString).sqlite").path
    let db = try await makeMigratedStore(path: path)
    let session = try await SQLiteSessionStore(database: db).create(
        name: "Quality", source: "folder", sourcePath: "", truncatedImport: false
    )
    let runtime = QualityRuntime(
        photoStore: SQLitePhotoStore(database: db),
        jobStore: SQLiteJobStore(database: db),
        similarityStore: SQLiteSimilarityStore(database: db),
        faceStore: SQLiteFaceStore(database: db)
    )
    return QualityGetEnv(db: db, runtime: runtime, sessionId: session.id)
}

private func seedGetPhoto(
    _ db: SQLiteDatabase,
    photoId: String,
    sessionId: String,
    assetFileId: String
) async throws {
    let filepath = "/vault/\(photoId).jpg"
    try await insertAssetFile(db, id: assetFileId, normalizedPath: filepath)
    _ = try await db.run("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', ?, 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """, [
            .text(photoId), .text(sessionId), .text(filepath),
            .text((filepath as NSString).lastPathComponent), .text(assetFileId),
        ])
}

/// 写入一条 technical_quality 历史结果（result_json 用真实 QualityResult 编码）。
private func insertAnalysisRow(
    _ db: SQLiteDatabase,
    photoId: String,
    assetFileId: String,
    score: Double,
    updatedAt: String,
    fingerprint: String? = nil
) async throws {
    let payload = try JSONEncoder().encode(QualityResult(
        photoId: photoId, status: .succeeded, qualityScore: score,
        sharpness: score, exposure: 1, warnings: [],
        modelId: "test", modelVersion: "1",
        inputFingerprint: fingerprint ?? "fp-\(photoId)-\(updatedAt)",
        updatedAt: updatedAt
    ))
    _ = try await db.run("""
        INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json, warnings_json, model_id, model_version, input_fingerprint, created_at, updated_at)
        VALUES (?, ?, 'technical_quality', ?, '[]', 'test', '1', ?, '2026-01-01T00:00:00.000Z', ?)
        """, [
            .text(photoId), .text(assetFileId),
            .text(String(data: payload, encoding: .utf8) ?? "{}"),
            .text(fingerprint ?? "fp-\(photoId)-\(updatedAt)"), .text(updatedAt),
        ])
}

/// 写入一条 similarity_results + 成员行；stats_json 可标记 precomputed 档。
@discardableResult
private func insertSimilarityGroup(
    _ db: SQLiteDatabase,
    sessionId: String,
    memberPhotoIds: [String],
    statsJson: String = "{}",
    createdAt: String
) async throws -> Int64 {
    _ = try await db.run("""
        INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
        VALUES (?, '[]', ?, 8, 2, ?)
        """, [.text(sessionId), .text(statsJson), .text(createdAt)])
    let resultId = await db.lastInsertRowID
    for photoId in memberPhotoIds {
        _ = try await db.run("""
            INSERT INTO similarity_result_members (result_id, session_id, group_index, photo_id)
            VALUES (?, ?, 0, ?)
            """, [.int(resultId), .text(sessionId), .text(photoId)])
    }
    return resultId
}

// MARK: - get

@Suite("QualityRuntime get（W2c）")
struct QualityRuntimeGetTests {
    @Test("returns the latest stored row per photo and dedupes requested ids")
    func latestPerPhoto() async throws {
        let env = try await makeQualityGetEnv()
        try await seedGetPhoto(env.db, photoId: "p1", sessionId: env.sessionId, assetFileId: "af-1")
        try await seedGetPhoto(env.db, photoId: "p2", sessionId: env.sessionId, assetFileId: "af-2")
        // p1 两条历史行（旧 updatedAt 的旧分）；p2 一条。
        try await insertAnalysisRow(env.db, photoId: "p1", assetFileId: "af-1", score: 0.4, updatedAt: "2026-01-01T00:00:00.000Z")
        try await insertAnalysisRow(env.db, photoId: "p1", assetFileId: "af-1", score: 0.9, updatedAt: "2026-01-02T00:00:00.000Z")
        try await insertAnalysisRow(env.db, photoId: "p2", assetFileId: "af-2", score: 0.5, updatedAt: "2026-01-01T00:00:00.000Z")

        let results = try await env.runtime.get(sessionId: env.sessionId)

        #expect(results.count == 2)
        let p1 = try #require(results.first { $0.photoId == "p1" })
        #expect(p1.qualityScore == 0.9)
        // 未在会话中的 id 被过滤；重复 id 去重。
        let subset = try await env.runtime.get(sessionId: env.sessionId, photoIds: ["p1", "p1", "nope"])
        #expect(subset.count == 1)
        #expect(subset[0].photoId == "p1")
    }

    @Test("returns results in requested order（设计 §2.4 ⑦）")
    func requestOrder() async throws {
        let env = try await makeQualityGetEnv()
        try await seedGetPhoto(env.db, photoId: "p1", sessionId: env.sessionId, assetFileId: "af-1")
        try await seedGetPhoto(env.db, photoId: "p2", sessionId: env.sessionId, assetFileId: "af-2")
        try await insertAnalysisRow(env.db, photoId: "p1", assetFileId: "af-1", score: 0.4, updatedAt: "2026-01-01T00:00:00.000Z")
        try await insertAnalysisRow(env.db, photoId: "p2", assetFileId: "af-2", score: 0.5, updatedAt: "2026-01-01T00:00:00.000Z")

        let ordered = try await env.runtime.get(sessionId: env.sessionId, photoIds: ["p2", "p1", "p2"])
        #expect(ordered.map(\.photoId) == ["p2", "p1"])

        // photoIds == nil：按会话投影序（导入序）。
        let all = try await env.runtime.get(sessionId: env.sessionId)
        #expect(all.map(\.photoId) == ["p1", "p2"])
    }

    @Test("returns empty for a session without stored results")
    func emptyWhenNoResults() async throws {
        let env = try await makeQualityGetEnv()
        #expect(try await env.runtime.get(sessionId: env.sessionId).isEmpty)
        #expect(try await env.runtime.get(sessionId: "unknown").isEmpty)
    }

    @Test("assigns relative ranks only inside persisted similarity groups")
    func ranksInsideGroupsOnly() async throws {
        let env = try await makeQualityGetEnv()
        let now = "2026-07-30T10:00:00.000Z"
        for id in ["p1", "p2", "p3"] {
            try await seedGetPhoto(env.db, photoId: id, sessionId: env.sessionId, assetFileId: "af-\(id)")
        }
        try await insertSimilarityGroup(env.db, sessionId: env.sessionId, memberPhotoIds: ["p1", "p2"], createdAt: now)
        try await insertAnalysisRow(env.db, photoId: "p1", assetFileId: "af-p1", score: 0.4, updatedAt: now)
        try await insertAnalysisRow(env.db, photoId: "p2", assetFileId: "af-p2", score: 0.9, updatedAt: now)
        try await insertAnalysisRow(env.db, photoId: "p3", assetFileId: "af-p3", score: 1.0, updatedAt: now)

        let results = try await env.runtime.get(sessionId: env.sessionId)

        #expect(results.first { $0.photoId == "p2" }?.relativeRank == 1)
        #expect(results.first { $0.photoId == "p1" }?.relativeRank == 2)
        // p3 不在组内：无相对排名。
        #expect(results.first { $0.photoId == "p3" }?.relativeRank == nil)
    }

    @Test("ignores newer precomputed tier rows when loading similarity groups（设计 §2.4 ②）")
    func precomputedRowsIgnored() async throws {
        let env = try await makeQualityGetEnv()
        let now = "2026-07-30T10:00:00.000Z"
        for id in ["p1", "p2", "p3"] {
            try await seedGetPhoto(env.db, photoId: id, sessionId: env.sessionId, assetFileId: "af-\(id)")
        }
        // 正常结果（p1/p2）在前，precomputed 档（p3）在后（id 更大）。
        try await insertSimilarityGroup(env.db, sessionId: env.sessionId, memberPhotoIds: ["p1", "p2"], createdAt: now)
        try await insertSimilarityGroup(
            env.db, sessionId: env.sessionId, memberPhotoIds: ["p3"],
            statsJson: "{\"precomputed\":true}", createdAt: now
        )
        try await insertAnalysisRow(env.db, photoId: "p1", assetFileId: "af-p1", score: 0.4, updatedAt: now)
        try await insertAnalysisRow(env.db, photoId: "p2", assetFileId: "af-p2", score: 0.9, updatedAt: now)
        try await insertAnalysisRow(env.db, photoId: "p3", assetFileId: "af-p3", score: 1.0, updatedAt: now)

        let results = try await env.runtime.get(sessionId: env.sessionId)

        // latestResult 排除 precomputed 档：排名仍由 p1/p2 组决定。
        #expect(results.first { $0.photoId == "p2" }?.relativeRank == 1)
        #expect(results.first { $0.photoId == "p1" }?.relativeRank == 2)
        #expect(results.first { $0.photoId == "p3" }?.relativeRank == nil)
    }
}
