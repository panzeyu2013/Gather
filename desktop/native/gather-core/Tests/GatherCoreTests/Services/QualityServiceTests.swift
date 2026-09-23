// desktop/native/gather-core/Tests/GatherCoreTests/Services/QualityServiceTests.swift
// QualityService 行为测试（Phase 3.6）。
// TS 源: tests/unit/services/quality/quality-service.test.ts（用例逐一对应）+
// quality.service.ts 行为基线（缓存命中/失败路径/人脸区域/相对排名）。
// 差异说明：
// - TS 用 sharp 真解码；Swift 侧经注入的 imageProvider 返回灰度像素网格
//   （等价 sharp .greyscale().raw()），避免真解码慢路径。
// - 相对排名用例经 get() 全链路断言（TS 直接调私有方法，行为等价）。

import Foundation
import Testing
@testable import GatherCore

/// 临时文件库 + 同库 PhotoStore（store 读必须与旧连接同文件）。
private struct QualityEnv {
    let db: DBConnection
    let photoStore: any PhotoStore
    let sessionStore: any SessionStore
}

private func makeQualityEnv() async throws -> QualityEnv {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-quality-\(UUID().uuidString).sqlite").path
    let db = try await makeMigratedLegacyDB(path: path)
    return QualityEnv(db: db, photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: path)), sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: path)))
}




private func makeTempPhotoStore() async throws -> any PhotoStore {
    let (database, _) = try await makeMigratedStoreDatabase(label: "photos")
    return SQLitePhotoStore(database: database)
}


private func makeTempJobStore() async throws -> any JobStore {
    let (database, _) = try await makeMigratedStoreDatabase(label: "jobs")
    return SQLiteJobStore(database: database)
}


// MARK: - 支撑

/// 照片 + 资产文件行种子（photos.asset_file_id 外键）。
private func seedPhotoWithAssetFile(
    _ db: DBConnection,
    photoId: String,
    sessionId: String,
    filepath: String,
    assetFileId: String,
    width: Int = 100,
    height: Int = 80
) throws {
    try insertAssetFile(db, id: assetFileId, normalizedPath: filepath)
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
          result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', '{}', '{}', NULL, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([
        .text(photoId), .text(sessionId), .text(filepath),
        .text((filepath as NSString).lastPathComponent), .text(assetFileId),
        .int(Int64(width)), .int(Int64(height)),
    ])
}

/// 无资产文件照片（analyze 必须产出 QUALITY_NO_ASSET_FILE failed 结果）。
private func seedPhotoWithoutAssetFile(
    _ db: DBConnection,
    photoId: String,
    sessionId: String,
    filepath: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
          result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', '{}', '{}', NULL, NULL, 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([
        .text(photoId), .text(sessionId), .text(filepath),
        .text((filepath as NSString).lastPathComponent),
    ])
}

/// 8x8 灰度像素（前 4 行棋盘格 0/255、后 4 行均匀 128）：
/// 全图 sharpness ≈ 0.321、exposure ≈ 1，人脸框区域（0,0,50,20 分析坐标）
/// 裁剪为 4 行棋盘格（横向梯度每格 255 / 归一化常数 510 → subjectSharpness
/// 恰为 0.5），眼部子区同为棋盘格（eyeSharpness = 0.5 →
/// closedEyeRisk = 1 - 0.5/(0.5*1.15) ≈ 0.13）。
private func checkerboardPreview8x8() -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: 64)
    for y in 0..<8 {
        for x in 0..<8 {
            pixels[y * 8 + x] = y < 4 ? (x % 2 == 0 ? 0 : 255) : 128
        }
    }
    return pixels
}

private struct QualityHarness {
    let db: DBConnection
    let jobStore: any JobStore
    let service: QualityService
    let sessionId: String
}

private func makeHarness(
    imageProvider: @escaping QualityService.ImageMetricsProvider = { _, _ in
        ([UInt8](repeating: 128, count: 16), 4, 4)
    },
    statProvider: @escaping QualityService.StatProvider = QualityService.defaultStat
) async throws -> QualityHarness {
    let env = try await makeQualityEnv()
        let db = env.db
    let session = try await env.sessionStore.create(name: "Quality", source: "folder", sourcePath: "", truncatedImport: false)
    let service = QualityService(
        photoStore: env.photoStore,
        connection: db,
        imageProvider: imageProvider,
        statProvider: statProvider
    )
    let jobStore = try SQLiteJobStore(database: try SQLiteDatabase(
        path: FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-quality-\(UUID().uuidString).sqlite").path))
    return QualityHarness(db: db, jobStore: jobStore, service: service, sessionId: session.id)
}

// MARK: - 技术质量指标（TS quality-service.test.ts 逐条对应）

@Suite("technical quality metrics")
struct QualityMetricsTests {
    @Test("scores a flat image as low sharpness but valid exposure")
    func flatImage() {
        let result = metricFromPixels(data: [UInt8](repeating: 128, count: 16), width: 4, height: 4)
        #expect(result.sharpness == 0)
        #expect(result.exposure == 1)
    }

    @Test("detects both edges and exposure problems deterministically")
    func edgesAndExposure() {
        let pixels: [UInt8] = [
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255,
        ]
        let result = metricFromPixels(data: pixels, width: 4, height: 4)
        #expect(result.sharpness > 0)
        #expect(abs(result.exposure - 0.996) < 0.001)
    }

    @Test("returns zero metrics for degenerate sizes")
    func degenerateSizes() {
        let result = metricFromPixels(data: [128], width: 1, height: 1)
        #expect(result.sharpness == 0)
        #expect(result.exposure == 0)
    }
}

// MARK: - analyze

@Suite("QualityService analyze")
struct QualityAnalyzeTests {
    @Test("scores, stores and returns results for a session photo")
    func scoresAndStores() async throws {
        let harness = try await makeHarness()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try seedPhotoWithAssetFile(harness.db, photoId: "p1", sessionId: harness.sessionId, filepath: filepath, assetFileId: "af-1")
        let stat = try QualityService.defaultStat(filepath)

        let results = try await harness.service.analyze(sessionId: harness.sessionId)

        #expect(results.count == 1)
        let result = results[0]
        #expect(result.photoId == "p1")
        #expect(result.assetFileId == "af-1")
        #expect(result.status == .succeeded)
        #expect(result.qualityScore == 0.25) // 0*0.6 + 0*0.15 + 1*0.2 + 1*0.05
        #expect(result.sharpness == 0)
        #expect(result.exposure == 1)
        #expect(result.subjectSharpness == nil)
        #expect(result.faceQuality == nil)
        #expect(result.closedEyeRisk == nil)
        #expect(result.confidence == 0.55)
        #expect(result.warnings == ["motion_blur"])
        #expect(result.modelId == "technical-quality")
        #expect(result.modelVersion == "1")
        #expect(result.inputFingerprint == "\(stat.size):\(stat.mtimeMs.rounded())")
        #expect(result.relativeRank == nil)

        // 单事务落库：asset_analysis 行可被 get() 读回。
        let stored = try await harness.service.get(sessionId: harness.sessionId)
        #expect(stored.count == 1)
        #expect(stored[0].photoId == "p1")
        #expect(stored[0].qualityScore == 0.25)
    }

    @Test("reuses the cached row on fingerprint match without decoding again")
    func cacheHitSkipsDecode() async throws {
        let callLock = NSLock()
        var calls = 0
        let harness = try await makeHarness(imageProvider: { _, _ in
            callLock.lock()
            calls += 1
            callLock.unlock()
            return ([UInt8](repeating: 128, count: 16), 4, 4)
        })
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try seedPhotoWithAssetFile(harness.db, photoId: "p1", sessionId: harness.sessionId, filepath: filepath, assetFileId: "af-1")

        let first = try await harness.service.analyze(sessionId: harness.sessionId)
        #expect(first[0].status == .succeeded)

        let second = try await harness.service.analyze(sessionId: harness.sessionId)
        #expect(second.count == 1)
        #expect(second[0].photoId == "p1")
        #expect(second[0].status == .succeeded)
        // 缓存命中：不再解码（stat 指纹精确匹配），且不产生新写入。
        callLock.lock()
        let totalCalls = calls
        callLock.unlock()
        #expect(totalCalls == 1)
        let rowCount = try rowCount(harness.db, "SELECT COUNT(*) FROM asset_analysis WHERE photo_id = 'p1'")
        #expect(rowCount == 1)
    }

    @Test("analyzes only the requested photo subset")
    func subsetAnalysis() async throws {
        let harness = try await makeHarness()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p1 = try writeTempFile(in: dir, name: "a.jpg")
        let p2 = try writeTempFile(in: dir, name: "b.jpg")
        try seedPhotoWithAssetFile(harness.db, photoId: "p1", sessionId: harness.sessionId, filepath: p1, assetFileId: "af-1")
        try seedPhotoWithAssetFile(harness.db, photoId: "p2", sessionId: harness.sessionId, filepath: p2, assetFileId: "af-2")

        let results = try await harness.service.analyze(sessionId: harness.sessionId, photoIds: ["p1"])

        #expect(results.count == 1)
        #expect(results[0].photoId == "p1")
        let stored = try await harness.service.get(sessionId: harness.sessionId)
        // 子集分析只落库 p1（p2 无任何分析行）。
        #expect(Set(stored.map(\.photoId)) == ["p1"])
    }

    @Test("returns a failed result with QUALITY_NO_ASSET_FILE and skips the insert")
    func noAssetFileFails() async throws {
        let harness = try await makeHarness()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try seedPhotoWithoutAssetFile(harness.db, photoId: "p1", sessionId: harness.sessionId, filepath: filepath)

        let results = try await harness.service.analyze(sessionId: harness.sessionId)

        #expect(results.count == 1)
        let result = results[0]
        #expect(result.status == .failed)
        #expect(result.errorMessage == "QUALITY_NO_ASSET_FILE")
        #expect(result.qualityScore == 0)
        #expect(result.sharpness == 0)
        #expect(result.exposure == 0)
        #expect(result.warnings == ["analysis_failed"])
        #expect(result.modelId == "technical-quality")
        #expect(result.updatedAt != "")
        // 无资产文件行：不落库。
        let rowCount = try rowCount(harness.db, "SELECT COUNT(*) FROM asset_analysis")
        #expect(rowCount == 0)
    }

    @Test("records a failed row with the decode error message when the image provider throws")
    func imageFailureRecordsFailedRow() async throws {
        struct DecodeBoom: Error, CustomStringConvertible {
            var description: String { "decode exploded" }
        }
        let harness = try await makeHarness(imageProvider: { _, _ in throw DecodeBoom() })
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try seedPhotoWithAssetFile(harness.db, photoId: "p1", sessionId: harness.sessionId, filepath: filepath, assetFileId: "af-1")

        let results = try await harness.service.analyze(sessionId: harness.sessionId)

        #expect(results[0].status == .failed)
        #expect(results[0].errorMessage == "decode exploded")
        #expect(results[0].warnings == ["analysis_failed"])
        // failed 行带 "failed:<photo.updatedAt>" 指纹落库。
        let row = try harness.db.prepare("""
            SELECT input_fingerprint FROM asset_analysis WHERE photo_id = 'p1' AND analysis_type = 'technical_quality'
          """).get()
        #expect(row?[0].textValue?.hasPrefix("failed:") == true)
    }

    @Test("computes subject/eye metrics from the largest face observation")
    func faceRegionMetrics() async throws {
        let harness = try await makeHarness(imageProvider: { _, _ in (checkerboardPreview8x8(), 8, 8) })
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try seedPhotoWithAssetFile(harness.db, photoId: "p1", sessionId: harness.sessionId, filepath: filepath, assetFileId: "af-1")
        // 源 100x80，analysis 签名 previewMaxDimension=50 → 分析尺寸 50x40；
        // bbox 覆盖分析图 (0,0,50,20) → 预览 8x8 的 (0,0,8,4) = 前 4 行棋盘格。
        _ = try harness.db.prepare("""
            INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence, analysis_signature, created_at)
            VALUES ('p1', ?, 0, 0, 50, 20, X'00', 0.9, '{"previewMaxDimension":50}', '2026-01-01T00:00:00.000Z')
          """).run([.text(harness.sessionId)])

        let results = try await harness.service.analyze(sessionId: harness.sessionId)

        let result = results[0]
        #expect(result.status == .succeeded)
        #expect(result.subjectSharpness != nil)
        // 8x4 棋盘格：每格横向梯度 255、纵向 0 → 0.5（0.667 是错解，见
        // metricFromPixels 归一化常数 510）。
        #expect(abs(result.subjectSharpness! - 0.5) < 0.01)
        #expect(result.faceQuality == result.subjectSharpness)
        // 眼部 8x2 棋盘格 eyeSharpness = 0.5 → 1 - 0.5/(0.5*1.15) ≈ 0.13。
        #expect(abs(result.closedEyeRisk! - 0.13) < 0.01)
        #expect(result.confidence == 0.6)
        #expect(result.warnings.isEmpty)
        // 0.5*0.6 + 0.321*0.15 + 0.998*0.2 + 0.87*0.05 ≈ 0.591：人脸聚焦
        // 分明显高于平图基线（0.25）。
        #expect(result.qualityScore == 0.591)
    }

    @Test("emits progress frames with the photoIds checkpoint")
    func progressFrames() async throws {
        let harness = try await makeHarness()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for i in 0..<3 {
            let filepath = try writeTempFile(in: dir, name: "p\(i).jpg")
            try seedPhotoWithAssetFile(harness.db, photoId: "p\(i)", sessionId: harness.sessionId, filepath: filepath, assetFileId: "af-\(i)")
        }
        let jobStore = try await makeTempJobStore()
        let job = try await jobStore.create(JobCreateParams(
            type: .qualityScore, scopeType: "session", scopeId: harness.sessionId, dedupeKey: "d"
        ))
        // 模拟 JobService.execute 的接线：claim 租约 + 真实 updateProgress
        // 落库（TS 执行器语义），否则 checkpoint 不会持久化到 analysis_jobs。
        _ = try await jobStore.claim(id: job.id, leaseOwner: "test")
        let context = JobRunContext(
            signal: JobAbortSignal(),
            jobStore: jobStore,
            jobId: job.id,
            leaseOwner: "test",
            updateProgress: { id, owner, update in
                try await jobStore.updateProgress(id: id, leaseOwner: owner, update: update)
            },
            progressSink: nil
        )

        // 子集调用：checkpoint 必须保留 photoIds（TS 注释：执行器从
        // checkpoint.photoIds 恢复子集运行）。
        let results = try await harness.service.analyze(
            sessionId: harness.sessionId, photoIds: ["p0", "p1", "p2"], context: context)

        #expect(results.count == 3)
        let checkpoint = try try await jobStore.get(job.id)!.checkpoint
        #expect(checkpoint["nextPhotoIndex"]?.numberValue == 3)
        let photoIds = checkpoint["photoIds"]?.arrayElements?.compactMap(\.stringValue) ?? []
        #expect(Set(photoIds) == ["p0", "p1", "p2"])
    }

    @Test("propagates cancellation through throwIfCancelled")
    func cancellation() async throws {
        let harness = try await makeHarness()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try seedPhotoWithAssetFile(harness.db, photoId: "p1", sessionId: harness.sessionId, filepath: filepath, assetFileId: "af-1")
        let jobStore = try await makeTempJobStore()
        let job = try await jobStore.create(JobCreateParams(
            type: .qualityScore, scopeType: "session", scopeId: harness.sessionId, dedupeKey: "d"
        ))
        let signal = JobAbortSignal()
        signal.abort()
        let context = JobRunContext(
            signal: signal,
            jobStore: jobStore,
            jobId: job.id,
            leaseOwner: "test",
            updateProgress: { _, _, _ in true },
            progressSink: nil
        )

        await #expect(throws: JobCancelledError.self) {
            try await harness.service.analyze(sessionId: harness.sessionId, context: context)
        }
    }
}

// MARK: - get

@Suite("QualityService get")
struct QualityGetTests {
    @Test("returns the latest stored row per photo and dedupes requested ids")
    func latestPerPhoto() async throws {
        let env = try await makeQualityEnv()
        let db = env.db
        let session = try await env.sessionStore.create(name: "Quality", source: "folder", sourcePath: "", truncatedImport: false)
        try insertAssetFile(db, id: "af-1", normalizedPath: "/vault/a.jpg")
        try insertAssetFile(db, id: "af-2", normalizedPath: "/vault/b.jpg")
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, asset_file_id, width, height, created_at, updated_at)
            VALUES ('p1', ?, '/vault/a.jpg', 'a.jpg', '', 'ready', 'af-1', 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z'),
                   ('p2', ?, '/vault/b.jpg', 'b.jpg', '', 'ready', 'af-2', 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """).run([.text(session.id), .text(session.id)])
        let service = QualityService(photoStore: env.photoStore, connection: db)
        // p1 两条历史行（旧 updatedAt 的旧分）；p2 一条。
        let insertStmt = try db.prepare("""
            INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json, warnings_json, model_id, model_version, input_fingerprint, created_at, updated_at)
            VALUES (?, ?, 'technical_quality', ?, '[]', 'test', '1', ?, ?, ?)
          """)
        func insert(_ photoId: String, _ score: Double, _ updatedAt: String) throws {
            let fingerprint = "fp-\(photoId)-\(updatedAt)"
            let payload = try JSONEncoder().encode(QualityResult(
                photoId: photoId, status: .succeeded, qualityScore: score,
                sharpness: score, exposure: 1, warnings: [],
                modelId: "test", modelVersion: "1", inputFingerprint: fingerprint,
                updatedAt: updatedAt
            ))
            _ = try insertStmt.run([
                .text(photoId), .text(photoId == "p1" ? "af-1" : "af-2"),
                .text(String(data: payload, encoding: .utf8) ?? "{}"),
                .text(fingerprint), .text("2026-01-01T00:00:00.000Z"), .text(updatedAt),
            ])
        }
        try insert("p1", 0.4, "2026-01-01T00:00:00.000Z")
        try insert("p1", 0.9, "2026-01-02T00:00:00.000Z")
        try insert("p2", 0.5, "2026-01-01T00:00:00.000Z")

        let results = try await service.get(sessionId: session.id)

        #expect(results.count == 2)
        let p1 = try #require(results.first { $0.photoId == "p1" })
        #expect(p1.qualityScore == 0.9)
        // 未在会话中的 id 被过滤；重复 id 去重。
        let subset = try await service.get(sessionId: session.id, photoIds: ["p1", "p1", "nope"])
        #expect(subset.count == 1)
        #expect(subset[0].photoId == "p1")
    }

    @Test("returns empty for a session without stored results")
    func emptyWhenNoResults() async throws {
        let env = try await makeQualityEnv()
        let db = env.db
        let session = try await env.sessionStore.create(name: "Quality", source: "folder", sourcePath: "", truncatedImport: false)
        let service = QualityService(photoStore: env.photoStore, connection: db)
        #expect(try await service.get(sessionId: session.id).isEmpty)
        #expect(try await service.get(sessionId: "unknown").isEmpty)
    }
}

// MARK: - 相对排名（TS quality-service.test.ts 逐条对应）

@Suite("QualityService relative ranks")
struct QualityRelativeRankTests {
    @Test("assigns relative ranks only inside persisted similarity groups")
    func ranksInsideGroupsOnly() async throws {
        let env = try await makeQualityEnv()
        let db = env.db
        let session = try await env.sessionStore.create(name: "Quality", source: "folder", sourcePath: "", truncatedImport: false)
        let now = "2026-07-30T10:00:00.000Z"
        for (id, path) in [("p1", "/photos/p1.JPG"), ("p2", "/photos/p2.JPG"), ("p3", "/photos/p3.JPG")] {
            try insertAssetFile(db, id: "af-\(id)", normalizedPath: path)
            _ = try db.prepare("""
                INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_file_id, width, height, created_at, updated_at)
                VALUES (?, ?, ?, ?, '', 'ready', '{}', '{}', ?, 100, 80, ?, ?)
              """).run([
                .text(id), .text(session.id), .text(path), .text(path.split(separator: "/").last.map(String.init) ?? id),
                .text("af-\(id)"), .text(now), .text(now),
            ])
        }
        _ = try db.prepare("""
            INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES (?, '[]', '{}', 8, 2, ?)
          """).run([.text(session.id), .text(now)])
        let resultId = db.lastInsertRowid
        let insertMember = try db.prepare(
            "INSERT INTO similarity_result_members (result_id, session_id, group_index, photo_id) VALUES (?, ?, 0, ?)"
        )
        _ = try insertMember.run([.int(resultId), .text(session.id), .text("p1")])
        _ = try insertMember.run([.int(resultId), .text(session.id), .text("p2")])

        let insertAnalysis = try db.prepare("""
            INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json, warnings_json, model_id, model_version, input_fingerprint, created_at, updated_at)
            VALUES (?, ?, 'technical_quality', ?, '[]', 'test', '1', ?, ?, ?)
          """)
        let scores: [(String, String, Double)] = [("p1", "af-p1", 0.4), ("p2", "af-p2", 0.9), ("p3", "af-p3", 1.0)]
        for (photoId, assetFileId, score) in scores {
            let payload = try JSONEncoder().encode(QualityResult(
                photoId: photoId, status: .succeeded, qualityScore: score,
                sharpness: score, exposure: 1, warnings: [],
                modelId: "test", modelVersion: "1", inputFingerprint: "fp-\(photoId)", updatedAt: now
            ))
            _ = try insertAnalysis.run([
                .text(photoId), .text(assetFileId),
                .text(String(data: payload, encoding: .utf8) ?? "{}"),
                .text("fp-\(photoId)"), .text(now), .text(now),
            ])
        }

        let service = QualityService(photoStore: env.photoStore, connection: db)
        let results = try await service.get(sessionId: session.id)

        #expect(results.first { $0.photoId == "p2" }?.relativeRank == 1)
        #expect(results.first { $0.photoId == "p1" }?.relativeRank == 2)
        // p3 不在组内：无相对排名。
        #expect(results.first { $0.photoId == "p3" }?.relativeRank == nil)
    }
}
