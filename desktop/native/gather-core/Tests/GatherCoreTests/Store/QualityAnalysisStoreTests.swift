// Tests/GatherCoreTests/Store/QualityAnalysisStoreTests.swift
// W2c Store 测试：JobStore.upsertQualityResults / cachedQualityResults / latestQualityResults
// （原 Services/QualityService.swift 340-363/384-390/421-428 行内联 SQL 的 Store 化）。
// 断言重点：JOIN photos 的 asset_file 共享语义、updated_at DESC 取最新、模型过滤、
// INSERT OR REPLACE 幂等、单事务回滚、空参数短路、400 分块。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/QualityAnalysisStore (W2c)")
struct QualityAnalysisStoreTests {
    // MARK: - Fixtures

    private func makeStore() async throws -> (store: SQLiteJobStore, database: SQLiteDatabase) {
        let database = try await makeMigratedStore(path: storeTempPath("quality-analysis"))
        try await insertSession(database, "s1")
        try await insertAssetFile(database, id: "af1", normalizedPath: "/assets/af1.jpg")
        try await insertAssetFile(database, id: "af2", normalizedPath: "/assets/af2.jpg")
        return (SQLiteJobStore(database: database), database)
    }

    private func insertQualityPhoto(
        _ database: SQLiteDatabase,
        photoId: String,
        assetFileId: String?,
        sessionId: String = "s1"
    ) async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
              result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES (?, ?, ?, ?, '', 'pending', '{}', '{}', NULL, ?, 100, 100,
              '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [
                .text(photoId), .text(sessionId), .text("/shoot/\(photoId).jpg"),
                .text("\(photoId).jpg"), assetFileId.map { SQLiteValue.text($0) } ?? .null,
            ]
        )
    }

    @discardableResult
    private func upsertQuality(
        _ store: SQLiteJobStore,
        photoId: String,
        assetFileId: String,
        resultJson: String,
        fingerprint: String,
        updatedAt: String,
        modelId: String = "technical-quality",
        modelVersion: String = "1",
        warningsJson: String = "[]"
    ) async throws -> QualityAnalysisUpsert {
        let insert = QualityAnalysisUpsert(
            photoId: photoId, assetFileId: assetFileId, resultJson: resultJson,
            warningsJson: warningsJson, modelId: modelId, modelVersion: modelVersion,
            inputFingerprint: fingerprint, updatedAt: updatedAt
        )
        try await store.upsertQualityResults([insert])
        return insert
    }

    private static let baseline = [
        QualityAnalysisUpsert(
            photoId: "p1", assetFileId: "af1", resultJson: #"{"qualityScore":0.5}"#,
            warningsJson: #"["ok"]"#, modelId: "technical-quality", modelVersion: "1",
            inputFingerprint: "fp-1", updatedAt: "2026-01-01T00:00:00.000Z"
        ),
        QualityAnalysisUpsert(
            photoId: "p1", assetFileId: "af1", resultJson: #"{"qualityScore":0.9}"#,
            warningsJson: "[]", modelId: "technical-quality", modelVersion: "1",
            inputFingerprint: "fp-2", updatedAt: "2026-06-01T00:00:00.000Z"
        ),
    ]

    // MARK: - latestQualityResults

    @Test("latestQualityResults：JOIN 字段齐全、变体共享 asset_file 行、无资产文件照片不返回")
    func latestQualityJoinAndEmpty() async throws {
        let (store, database) = try await makeStore()
        try await insertQualityPhoto(database, photoId: "p1", assetFileId: "af1")
        try await insertQualityPhoto(database, photoId: "p2", assetFileId: "af1")
        try await insertQualityPhoto(database, photoId: "p3", assetFileId: "af2")
        try await insertQualityPhoto(database, photoId: "p4", assetFileId: nil)
        try await upsertQuality(
            store, photoId: "p1", assetFileId: "af1", resultJson: #"{"qualityScore":0.75}"#,
            fingerprint: "fp-1", updatedAt: "2026-01-01T00:00:00.000Z", warningsJson: #"["w"]"#
        )

        #expect(try await store.latestQualityResults(photoIds: []).isEmpty)

        let single = try #require(try await store.latestQualityResults(photoIds: ["p1"]).first)
        #expect(single.requestedPhotoId == "p1")
        #expect(single.assetFileId == "af1")
        #expect(single.resultJson == #"{"qualityScore":0.75}"#)
        #expect(single.warningsJson == #"["w"]"#)
        #expect(single.modelId == "technical-quality")
        #expect(single.modelVersion == "1")
        #expect(single.inputFingerprint == "fp-1")
        #expect(single.updatedAt == "2026-01-01T00:00:00.000Z")

        // RAW/JPEG 变体共享 asset_file_id → 同一分析行为两张照片各返回一次。
        let variants = try await store.latestQualityResults(photoIds: ["p1", "p2"])
        #expect(Set(variants.map(\.requestedPhotoId)) == ["p1", "p2"])
        #expect(variants.allSatisfy { $0.assetFileId == "af1" })

        #expect(try await store.latestQualityResults(photoIds: ["p3"]).isEmpty)
        #expect(try await store.latestQualityResults(photoIds: ["p4"]).isEmpty, "asset_file_id NULL 无 JOIN 行")
        #expect(try await store.latestQualityResults(photoIds: ["ghost"]).isEmpty)
    }

    @Test("latestQualityResults：同照片多行按 updated_at DESC 排序（首行即最新）")
    func latestQualityOrdering() async throws {
        let (store, database) = try await makeStore()
        try await insertQualityPhoto(database, photoId: "p1", assetFileId: "af1")
        try await store.upsertQualityResults(Self.baseline)

        let rows = try await store.latestQualityResults(photoIds: ["p1"])
        #expect(rows.count == 2)
        #expect(rows.map(\.inputFingerprint) == ["fp-2", "fp-1"], "updated_at DESC")
        #expect(rows[0].updatedAt == "2026-06-01T00:00:00.000Z")
        #expect(rows[0].resultJson == #"{"qualityScore":0.9}"#)
    }

    @Test("latestQualityResults：不过滤 model（非 technical-quality 行也返回），空参数 []")
    func latestQualityNoModelFilter() async throws {
        let (store, database) = try await makeStore()
        try await insertQualityPhoto(database, photoId: "p1", assetFileId: "af1")
        try await upsertQuality(
            store, photoId: "p1", assetFileId: "af1", resultJson: "{}",
            fingerprint: "fp-x", updatedAt: "2026-02-01T00:00:00.000Z", modelId: "other-model"
        )
        let rows = try await store.latestQualityResults(photoIds: ["p1"])
        #expect(rows.count == 1)
        #expect(rows[0].modelId == "other-model")
    }

    // MARK: - cachedQualityResults

    @Test("cachedQualityResults：model/version 精确过滤 + updated_at DESC")
    func cachedQualityFiltering() async throws {
        let (store, database) = try await makeStore()
        try await insertQualityPhoto(database, photoId: "p1", assetFileId: "af1")
        try await store.upsertQualityResults(Self.baseline)
        try await upsertQuality(
            store, photoId: "p1", assetFileId: "af1", resultJson: "{}",
            fingerprint: "fp-other", updatedAt: "2026-07-01T00:00:00.000Z",
            modelId: "other-model", modelVersion: "9"
        )

        let cached = try await store.cachedQualityResults(
            photoIds: ["p1"], modelId: "technical-quality", modelVersion: "1"
        )
        #expect(cached.map(\.inputFingerprint) == ["fp-2", "fp-1"], "模型匹配 + updated_at DESC")
        #expect(cached.allSatisfy { $0.modelId == "technical-quality" && $0.modelVersion == "1" })

        #expect(try await store.cachedQualityResults(
            photoIds: ["p1"], modelId: "technical-quality", modelVersion: "2"
        ).isEmpty)

        #expect(try await store.cachedQualityResults(
            photoIds: [], modelId: "technical-quality", modelVersion: "1"
        ).isEmpty)
    }

    // MARK: - upsertQualityResults

    @Test("upsertQualityResults：同唯一键重复写入为 OR REPLACE（结果更新、行数不变）")
    func upsertReplacesSameUniqueKey() async throws {
        let (store, database) = try await makeStore()
        try await insertQualityPhoto(database, photoId: "p1", assetFileId: "af1")
        try await upsertQuality(
            store, photoId: "p1", assetFileId: "af1", resultJson: "old",
            fingerprint: "fp-1", updatedAt: "2026-01-01T00:00:00.000Z"
        )
        try await upsertQuality(
            store, photoId: "p1", assetFileId: "af1", resultJson: "new",
            fingerprint: "fp-1", updatedAt: "2026-02-01T00:00:00.000Z"
        )
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM asset_analysis") == 1)
        let row = try #require(try await store.latestQualityResults(photoIds: ["p1"]).first)
        #expect(row.resultJson == "new")
        #expect(row.updatedAt == "2026-02-01T00:00:00.000Z")
        let createdAt = try await database.queryOne("SELECT created_at FROM asset_analysis")?.text("created_at")
        #expect(createdAt == "2026-02-01T00:00:00.000Z", "created_at 与 updated_at 同取 updatedAt")
    }

    @Test("upsertQualityResults：单事务回滚（FK 失败行使整批不落库，含已执行的替换）")
    func upsertRollsBackWholeBatch() async throws {
        let (store, database) = try await makeStore()
        try await insertQualityPhoto(database, photoId: "p1", assetFileId: "af1")
        try await upsertQuality(
            store, photoId: "p1", assetFileId: "af1", resultJson: "original",
            fingerprint: "fp-1", updatedAt: "2026-01-01T00:00:00.000Z"
        )

        await #expect(throws: SQLiteFailure.self) {
            try await store.upsertQualityResults([
                QualityAnalysisUpsert(
                    photoId: "p1", assetFileId: "af1", resultJson: "clobbered", warningsJson: "[]",
                    modelId: "technical-quality", modelVersion: "1",
                    inputFingerprint: "fp-1", updatedAt: "2026-03-01T00:00:00.000Z"
                ),
                QualityAnalysisUpsert(
                    photoId: "p1", assetFileId: "missing-af", resultJson: "{}", warningsJson: "[]",
                    modelId: "technical-quality", modelVersion: "1",
                    inputFingerprint: "fp-bad", updatedAt: "2026-03-01T00:00:00.000Z"
                ),
            ])
        }
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM asset_analysis") == 1)
        let kept = try #require(try await store.latestQualityResults(photoIds: ["p1"]).first)
        #expect(kept.resultJson == "original", "部分提交：REPLACE 未回滚")
        #expect(kept.updatedAt == "2026-01-01T00:00:00.000Z")
    }

    @Test("upsertQualityResults：空参数 no-op")
    func upsertEmptyIsNoop() async throws {
        let (store, database) = try await makeStore()
        try await store.upsertQualityResults([])
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM asset_analysis") == 0)
    }

    // MARK: - 分块

    @Test("latestQualityResults：401 个 photoId 跨 400 分块全量返回（共享同一 asset_file）")
    func latestChunkOver400() async throws {
        let (store, database) = try await makeStore()
        let total = 401
        try await database.transaction { db in
            for index in 0..<total {
                try db.run(
                    """
                    INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
                      result, asset_id, asset_file_id, width, height, created_at, updated_at)
                    VALUES (?, 's1', ?, ?, '', 'pending', '{}', '{}', NULL, 'af1', 100, 100,
                      '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                    """,
                    [
                        .text("p-\(index)"), .text("/shoot/p-\(index).jpg"),
                        .text("p-\(index).jpg"),
                    ]
                )
            }
        }
        try await upsertQuality(
            store, photoId: "p-0", assetFileId: "af1", resultJson: "{}",
            fingerprint: "fp-1", updatedAt: "2026-01-01T00:00:00.000Z"
        )

        let ids = (0..<total).map { "p-\($0)" }
        let rows = try await store.latestQualityResults(photoIds: ids)
        #expect(rows.count == total, "共享 asset_file 的每张照片各返回一行，跨块无遗漏")
        #expect(Set(rows.map(\.requestedPhotoId)) == Set(ids))
    }
}
