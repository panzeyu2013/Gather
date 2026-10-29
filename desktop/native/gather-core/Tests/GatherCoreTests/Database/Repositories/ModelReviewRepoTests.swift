// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/ModelReviewRepoTests.swift
// 模型级初审结果仓储：asset_analysis（analysis_type = 'model_review'）的读写口径。
//
// 覆盖此前 0 行执行的 ModelReviewRepo：空输入短路、批量事务写入、
// 按照片取最新（updated_at DESC, id DESC）、analysis_type 隔离、
// 401 个 id 的分块路径，以及照片未绑定 asset_file 时 JOIN 不命中。
//
// 注：`latestByAssetFile` 已在 main 的收口评审中确认零引用后删除
// （见 docs/reviews/final-review-2026-10-29.md），本套件只覆盖保留的 `latest`。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherPersistence

struct ModelReviewRepoTests {
    private func makeRepo() throws -> (DBConnection, ModelReviewRepo) {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        try insertAssetFile(db, id: "af1", normalizedPath: "/vault/p1.CR3")
        try insertAssetFile(db, id: "af2", normalizedPath: "/vault/p2.CR3")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        // 仓储通过 photos.asset_file_id JOIN asset_analysis；夹具默认不写该列。
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'af1' WHERE id = 'p1'").run()
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'af2' WHERE id = 'p2'").run()
        return (db, ModelReviewRepo(connection: db))
    }

    private func insert(
        _ repo: ModelReviewRepo,
        photoId: String = "p1",
        assetFileId: String = "af1",
        json: String,
        warnings: String = "[]",
        fingerprint: String = "f1",
        updatedAt: String
    ) throws {
        try repo.insertResults(
            [ModelReviewInsert(
                photoId: photoId, assetFileId: assetFileId, resultJson: json,
                warningsJson: warnings, fingerprint: fingerprint, updatedAt: updatedAt)],
            modelId: "model-review", modelVersion: "1"
        )
    }

    @Test("空输入短路：不建语句、不写行，查询都返回空")
    func emptyInputsAreNoOps() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.insertResults([], modelId: "model-review", modelVersion: "1")
        #expect(try repo.latest(photoIds: []).isEmpty)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM asset_analysis") == 0)
    }

    @Test("批量写入并按照片取最新：updated_at DESC 首行；warnings/指纹原样落库")
    func insertsBatchAndReturnsNewestPerPhoto() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.insertResults([
            ModelReviewInsert(
                photoId: "p1", assetFileId: "af1", resultJson: "{\"version\":1}",
                warningsJson: "[\"eyes_closed_suspected\"]", fingerprint: "old",
                updatedAt: "2026-01-01T00:00:00.000Z"),
            ModelReviewInsert(
                photoId: "p2", assetFileId: "af2", resultJson: "{\"version\":1}",
                warningsJson: "[]", fingerprint: "f2",
                updatedAt: "2026-01-01T00:00:00.000Z"),
        ], modelId: "model-review", modelVersion: "1")
        try insert(repo, json: "{\"version\":2}", fingerprint: "new",
                   updatedAt: "2026-01-02T00:00:00.000Z")

        let latest = try repo.latest(photoIds: ["p1", "p2"])
        #expect(latest["p1"]?.json == "{\"version\":2}")
        #expect(latest["p1"]?.fingerprint == "new")
        #expect(latest["p2"]?.json == "{\"version\":1}")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM asset_analysis") == 3)

        // 元数据列：换模型/换版本不会覆盖 analysis_type 语义。
        let raw = try db.prepare(
            "SELECT analysis_type, model_id, warnings_json FROM asset_analysis WHERE input_fingerprint = 'old'"
        ).get()
        #expect(raw?[0].textValue == "model_review")
        #expect(raw?[1].textValue == "model-review")
        #expect(raw?[2].textValue == "[\"eyes_closed_suspected\"]")
    }

    @Test("analysis_type 隔离：quality 行不会被当作 model_review")
    func latestIgnoresOtherAnalysisTypes() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try db.prepare("""
            INSERT INTO asset_analysis (
              photo_id, asset_file_id, analysis_type, result_json, warnings_json,
              model_id, model_version, input_fingerprint, created_at, updated_at
            ) VALUES ('p1', 'af1', 'quality', '{"q":1}', '[]',
                      'quality', '1', 'q', '2026-01-01T00:00:00.000Z',
                      '2026-03-01T00:00:00.000Z')
        """).run()

        #expect(try repo.latest(photoIds: ["p1"]).isEmpty)
    }

    @Test("未绑定 asset_file 的照片不 JOIN 命中（不把别的资产结果串进来）")
    func unboundPhotoIsNotJoined() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try db.prepare("UPDATE photos SET asset_file_id = NULL WHERE id = 'p2'").run()
        try insert(repo, photoId: "p2", assetFileId: "af2", json: "{}",
                   updatedAt: "2026-01-01T00:00:00.000Z")

        #expect(try repo.latest(photoIds: ["p2"]).isEmpty)
    }

    @Test("401 个 id 走分块路径：命中仍返回，未命中不报错")
    func chunkedLookupsHandleMoreThanOneChunk() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try insert(repo, json: "{\"ok\":true}", updatedAt: "2026-01-01T00:00:00.000Z")

        let photoIds = ["p1"] + (0..<400).map { "missing-\($0)" }
        #expect(photoIds.count == 401)
        #expect(try repo.latest(photoIds: photoIds)["p1"]?.json == "{\"ok\":true}")
    }
}
