// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Quality/QualityRuntimeAnalyzeTests.swift
// W2c：QualityRuntime.analyze 行为测试（承接旧 Services/QualityServiceTests.swift
// 的 analyze 语义：评分落库 / 缓存命中 / 子集 / 失败 / 人脸 / 进度 / 取消，
// 新增 QualityInvalidationPort 提交后接线断言）。
//
// 差异说明：
// - 服务 → actor：注入 PhotoStore / JobStore / SimilarityStore / FaceStore
//   （同一 SQLiteDatabase actor 实例，与断言用连接同库）；
// - 图像/stat 仍经注入 provider，避免真解码慢路径；
// - 进度帧与 checkpoint 形状与旧实现逐字一致（quality.scoring +
//   nextPhotoIndex + photoIds）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 支撑

/// 线程安全计数器（provider 调用次数等断言用）。
private final class AnalyzeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// 记录失效调用的端口实现（Quality -> Culling 解耦端口）。
private actor InvalidationSpy: QualityInvalidationPort {
    private var sessions: [String] = []

    func invalidateQualityLookup(sessionId: String) async {
        sessions.append(sessionId)
    }

    func recorded() -> [String] { sessions }
}

private struct QualityRuntimeEnv {
    let db: SQLiteDatabase
    let jobStore: any JobStore
    let runtime: QualityRuntime
    let sessionId: String
}

/// 照片 + 资产文件行种子（photos.asset_file_id 外键）。
private func seedQualityPhoto(
    _ db: SQLiteDatabase,
    photoId: String,
    sessionId: String,
    filepath: String,
    assetFileId: String,
    width: Int = 100,
    height: Int = 80
) async throws {
    try await insertAssetFile(db, id: assetFileId, normalizedPath: filepath)
    _ = try await db.run("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
          result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', '{}', '{}', NULL, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """, [
            .text(photoId), .text(sessionId), .text(filepath),
            .text((filepath as NSString).lastPathComponent), .text(assetFileId),
            .int(Int64(width)), .int(Int64(height)),
        ])
}

/// 无资产文件照片（analyze 必须产出 QUALITY_NO_ASSET_FILE failed 结果）。
private func seedQualityPhotoWithoutAssetFile(
    _ db: SQLiteDatabase,
    photoId: String,
    sessionId: String,
    filepath: String
) async throws {
    _ = try await db.run("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
          result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', '{}', '{}', NULL, NULL, 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """, [
            .text(photoId), .text(sessionId), .text(filepath),
            .text((filepath as NSString).lastPathComponent),
        ])
}

/// 8x8 灰度像素（前 4 行棋盘格 0/255、后 4 行均匀 128）：
/// 全图 sharpness 约 0.321、exposure 约 1，人脸框区域（0,0,50,20 分析坐标）
/// 裁剪为 4 行棋盘格（横向梯度每格 255 / 归一化常数 510 → subjectSharpness
/// 恰为 0.5），眼部子区同为棋盘格（eyeSharpness = 0.5 →
/// closedEyeRisk = 1 - 0.5/(0.5*1.15) 约 0.13）。
private func checkerboardPreview8x8() -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: 64)
    for y in 0..<8 {
        for x in 0..<8 {
            pixels[y * 8 + x] = y < 4 ? (x % 2 == 0 ? 0 : 255) : 128
        }
    }
    return pixels
}

private func makeQualityRuntimeEnv(
    imageProvider: @escaping QualityRuntime.ImageMetricsProvider = { _, _ in
        ([UInt8](repeating: 128, count: 16), 4, 4)
    },
    statProvider: @escaping QualityRuntime.StatProvider = QualityRuntime.defaultStat,
    invalidation: (any QualityInvalidationPort)? = nil
) async throws -> QualityRuntimeEnv {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-quality-rt-\(UUID().uuidString).sqlite").path
    let db = try await makeMigratedStore(path: path)
    let session = try await SQLiteSessionStore(database: db).create(
        name: "Quality", source: "folder", sourcePath: "", truncatedImport: false
    )
    let jobStore = SQLiteJobStore(database: db)
    let runtime = QualityRuntime(
        photoStore: SQLitePhotoStore(database: db),
        jobStore: jobStore,
        similarityStore: SQLiteSimilarityStore(database: db),
        faceStore: SQLiteFaceStore(database: db),
        imageProvider: imageProvider,
        statProvider: statProvider,
        invalidation: invalidation
    )
    return QualityRuntimeEnv(db: db, jobStore: jobStore, runtime: runtime, sessionId: session.id)
}

// MARK: - analyze

@Suite("QualityRuntime analyze（W2c）")
struct QualityRuntimeAnalyzeTests {
    @Test("scores, stores and returns results for a session photo")
    func scoresAndStores() async throws {
        let env = try await makeQualityRuntimeEnv()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try await seedQualityPhoto(env.db, photoId: "p1", sessionId: env.sessionId, filepath: filepath, assetFileId: "af-1")
        let stat = try QualityRuntime.defaultStat(filepath)

        let results = try await env.runtime.analyze(sessionId: env.sessionId)

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
        let stored = try await env.runtime.get(sessionId: env.sessionId)
        #expect(stored.count == 1)
        #expect(stored[0].photoId == "p1")
        #expect(stored[0].qualityScore == 0.25)
    }

    @Test("reuses the cached row on fingerprint match without decoding again")
    func cacheHitSkipsDecode() async throws {
        let calls = AnalyzeCallCounter()
        let env = try await makeQualityRuntimeEnv(imageProvider: { _, _ in
            calls.increment()
            return ([UInt8](repeating: 128, count: 16), 4, 4)
        })
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try await seedQualityPhoto(env.db, photoId: "p1", sessionId: env.sessionId, filepath: filepath, assetFileId: "af-1")

        let first = try await env.runtime.analyze(sessionId: env.sessionId)
        #expect(first[0].status == .succeeded)

        let second = try await env.runtime.analyze(sessionId: env.sessionId)
        #expect(second.count == 1)
        #expect(second[0].photoId == "p1")
        #expect(second[0].status == .succeeded)
        // 缓存命中：不再解码（stat 指纹精确匹配），且不产生新写入。
        #expect(calls.value == 1)
        let count = try await rowCount(env.db, "SELECT COUNT(*) FROM asset_analysis WHERE photo_id = 'p1'")
        #expect(count == 1)
    }

    @Test("analyzes only the requested photo subset")
    func subsetAnalysis() async throws {
        let env = try await makeQualityRuntimeEnv()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p1 = try writeTempFile(in: dir, name: "a.jpg")
        let p2 = try writeTempFile(in: dir, name: "b.jpg")
        try await seedQualityPhoto(env.db, photoId: "p1", sessionId: env.sessionId, filepath: p1, assetFileId: "af-1")
        try await seedQualityPhoto(env.db, photoId: "p2", sessionId: env.sessionId, filepath: p2, assetFileId: "af-2")

        let results = try await env.runtime.analyze(sessionId: env.sessionId, photoIds: ["p1"])

        #expect(results.count == 1)
        #expect(results[0].photoId == "p1")
        let stored = try await env.runtime.get(sessionId: env.sessionId)
        // 子集分析只落库 p1（p2 无任何分析行）。
        #expect(Set(stored.map(\.photoId)) == ["p1"])
    }

    @Test("returns a failed result with QUALITY_NO_ASSET_FILE and skips the insert")
    func noAssetFileFails() async throws {
        let env = try await makeQualityRuntimeEnv()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try await seedQualityPhotoWithoutAssetFile(env.db, photoId: "p1", sessionId: env.sessionId, filepath: filepath)

        let results = try await env.runtime.analyze(sessionId: env.sessionId)

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
        #expect(try await rowCount(env.db, "SELECT COUNT(*) FROM asset_analysis") == 0)
    }

    @Test("records a failed row with the decode error message when the image provider throws")
    func imageFailureRecordsFailedRow() async throws {
        struct DecodeBoom: Error, CustomStringConvertible {
            var description: String { "decode exploded" }
        }
        let env = try await makeQualityRuntimeEnv(imageProvider: { _, _ in throw DecodeBoom() })
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try await seedQualityPhoto(env.db, photoId: "p1", sessionId: env.sessionId, filepath: filepath, assetFileId: "af-1")

        let results = try await env.runtime.analyze(sessionId: env.sessionId)

        #expect(results[0].status == .failed)
        #expect(results[0].errorMessage == "decode exploded")
        #expect(results[0].warnings == ["analysis_failed"])
        // failed 行带 failed:<photo.updatedAt> 指纹落库。
        let row = try await env.db.queryOne("""
            SELECT input_fingerprint FROM asset_analysis
            WHERE photo_id = 'p1' AND analysis_type = 'technical_quality'
            """)
        #expect(row?.text(at: 0)?.hasPrefix("failed:") == true)
    }

    @Test("computes subject/eye metrics from the largest face observation")
    func faceRegionMetrics() async throws {
        let env = try await makeQualityRuntimeEnv(imageProvider: { _, _ in (checkerboardPreview8x8(), 8, 8) })
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try await seedQualityPhoto(env.db, photoId: "p1", sessionId: env.sessionId, filepath: filepath, assetFileId: "af-1")
        // 源 100x80，analysis 签名 previewMaxDimension=50 → 分析尺寸 50x40；
        // bbox 覆盖分析图 (0,0,50,20) → 预览 8x8 的 (0,0,8,4) = 前 4 行棋盘格。
        _ = try await env.db.run("""
            INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence, analysis_signature, created_at)
            VALUES ('p1', ?, 0, 0, 50, 20, X'00', 0.9, '{"previewMaxDimension":50}', '2026-01-01T00:00:00.000Z')
            """, [.text(env.sessionId)])

        let results = try await env.runtime.analyze(sessionId: env.sessionId)

        let result = results[0]
        #expect(result.status == .succeeded)
        #expect(result.subjectSharpness != nil)
        // 8x4 棋盘格：每格横向梯度 255、纵向 0 → 0.5。
        #expect(abs(result.subjectSharpness! - 0.5) < 0.01)
        #expect(result.faceQuality == result.subjectSharpness)
        // 眼部 8x2 棋盘格 eyeSharpness = 0.5 → 1 - 0.5/(0.5*1.15) 约 0.13。
        #expect(abs(result.closedEyeRisk! - 0.13) < 0.01)
        #expect(result.confidence == 0.6)
        #expect(result.warnings.isEmpty)
        // 0.5*0.6 + 0.321*0.15 + 0.998*0.2 + 0.87*0.05 约 0.591。
        #expect(result.qualityScore == 0.591)
    }

    @Test("emits progress frames with the photoIds checkpoint")
    func progressFrames() async throws {
        let env = try await makeQualityRuntimeEnv()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for i in 0..<3 {
            let filepath = try writeTempFile(in: dir, name: "p\(i).jpg")
            try await seedQualityPhoto(env.db, photoId: "p\(i)", sessionId: env.sessionId, filepath: filepath, assetFileId: "af-\(i)")
        }
        let job = try await env.jobStore.create(JobCreateParams(
            type: .qualityScore, scopeType: "session", scopeId: env.sessionId, dedupeKey: "d"
        ))
        // 模拟 JobRunnerContext 的接线：claim 租约 + 真实 updateProgress
        // 落库（TS 执行器语义），否则 checkpoint 不会持久化到 analysis_jobs。
        _ = try await env.jobStore.claim(id: job.id, leaseOwner: "test")
        let context = JobRunnerContext(
            signal: JobAbortSignal(),
            jobStore: env.jobStore,
            job: job,
            leaseOwner: "test",
            progressWriteIntervalMs: JobRunner.progressWriteIntervalMs,
            progressSink: nil
        )

        // 子集调用：checkpoint 必须保留 photoIds（TS 注释：执行器从
        // checkpoint.photoIds 恢复子集运行）。
        let results = try await env.runtime.analyze(
            sessionId: env.sessionId, photoIds: ["p0", "p1", "p2"], context: context)

        #expect(results.count == 3)
        let stored = try #require(try await env.jobStore.get(job.id))
        let checkpoint = try #require(stored.checkpoint)
        #expect(checkpoint["nextPhotoIndex"]?.numberValue == 3)
        let photoIds = checkpoint["photoIds"]?.arrayElements?.compactMap(\.stringValue) ?? []
        #expect(Set(photoIds) == ["p0", "p1", "p2"])
    }

    @Test("propagates cancellation through throwIfCancelled")
    func cancellation() async throws {
        let env = try await makeQualityRuntimeEnv()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try await seedQualityPhoto(env.db, photoId: "p1", sessionId: env.sessionId, filepath: filepath, assetFileId: "af-1")
        let job = try await env.jobStore.create(JobCreateParams(
            type: .qualityScore, scopeType: "session", scopeId: env.sessionId, dedupeKey: "d"
        ))
        let signal = JobAbortSignal()
        signal.abort()
        let context = JobRunnerContext(
            signal: signal,
            jobStore: env.jobStore,
            job: job,
            leaseOwner: "test",
            progressWriteIntervalMs: JobRunner.progressWriteIntervalMs,
            progressSink: nil
        )

        await #expect(throws: JobCancelledError.self) {
            try await env.runtime.analyze(sessionId: env.sessionId, context: context)
        }
        // 取消不写 asset_analysis。
        #expect(try await rowCount(env.db, "SELECT COUNT(*) FROM asset_analysis") == 0)
    }

    @Test("invalidates the quality lookup once per committed analyze")
    func invalidationPortCalledAfterCommit() async throws {
        let spy = InvalidationSpy()
        let env = try await makeQualityRuntimeEnv(invalidation: spy)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(in: dir, name: "photo.jpg")
        try await seedQualityPhoto(env.db, photoId: "p1", sessionId: env.sessionId, filepath: filepath, assetFileId: "af-1")

        _ = try await env.runtime.analyze(sessionId: env.sessionId)

        #expect(await spy.recorded() == [env.sessionId])
    }
}
