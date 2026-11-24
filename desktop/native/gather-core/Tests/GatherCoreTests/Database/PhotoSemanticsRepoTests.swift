// desktop/native/gather-core/Tests/GatherCoreTests/Database/PhotoSemanticsRepoTests.swift
// P0-3 / P1：photo_semantics 的模型版本过滤与分批清理（真库 SQL）回归锚点。
//
// 覆盖：① 只取当前版本（indexedPhotoIds 2 参 + SemanticIndex.vectors 端到端）；
// ② clearStaleRows 清掉旧版本后 indexedPhotoIds 不再含它们，当前版本行保留（幂等）；
// ③ 2,100 行旧版本分 2 批清（批大小 2,000，每批一个隐式事务）；
// ④ 中途被打断：已提交的批不回滚，只有当前批回滚（"每批一事务"的边界证据）。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

@Suite("photo_semantics 版本过滤与分批清理")
struct PhotoSemanticsRepoTests {
    private static let current = ImageSemanticsExtractor.modelVersion
    private static let legacy = "vision.fp0"

    private func makeRepo() throws -> (db: DBConnection, repo: PhotoSemanticsRepo) {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        return (db, PhotoSemanticsRepo(connection: db))
    }

    /// 批量建照片行：一次事务，避免 2,100 行逐条 autocommit（约为其 1/N 耗时）。
    private func insertPhotos(_ db: DBConnection, ids: [String]) throws {
        try db.transaction {
            for id in ids { try insertPhoto(db, id: id, sessionId: "s1") }
        }
    }

    private func semanticsRow(_ photoId: String, modelVersion: String) -> PhotoSemanticsInsert {
        let vector: [Float] = [1, 0, 0]
        return PhotoSemanticsInsert(
            photoId: photoId, sessionId: "s1",
            labelsJson: SemanticIndex.encodeLabels([
                SemanticLabel(label: "beach", confidence: 0.9),
            ]),
            feature: SemanticFeatureCodec.encode(vector), featureDim: vector.count,
            modelVersion: modelVersion, computedAt: "2026-11-24T00:00:00.000Z")
    }

    @Test("只取当前版本：vectors() 不混旧版本，indexedPhotoIds(2 参) 同口径")
    func onlyCurrentModelVersion() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try insertPhotos(db, ids: ["p1", "p2"])
        try repo.upsert([
            semanticsRow("p1", modelVersion: Self.current),
            semanticsRow("p2", modelVersion: Self.legacy),
        ])

        #expect(try repo.indexedPhotoIds(sessionId: "s1") == ["p1", "p2"])
        #expect(
            try repo.indexedPhotoIds(sessionId: "s1", modelVersion: Self.current) == ["p1"],
            "2 参重载只算 model_version 相符的行")
        let index = SemanticIndex(store: repo)
        let decoded = try index.vectors(sessionId: "s1")
        #expect(decoded.vectors.map(\.photoId) == ["p1"], "vectors() 不能混两种向量空间")
        #expect(decoded.skipped == 1, "旧版本行计入 skipped")
    }

    @Test("clearStaleRows 清掉旧版本：indexedPhotoIds 不再含它们，当前版本行保留")
    func clearStaleRowsDropsLegacyRows() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try insertPhotos(db, ids: ["keep", "old1", "old2"])
        try repo.upsert([
            semanticsRow("keep", modelVersion: Self.current),
            semanticsRow("old1", modelVersion: Self.legacy),
            semanticsRow("old2", modelVersion: "vision.fp-1"),
        ])

        #expect(try repo.clearStaleRows(sessionId: "s1", keepingModelVersion: Self.current) == 2)
        #expect(try repo.indexedPhotoIds(sessionId: "s1") == ["keep"], "旧版本行已被清掉")
        #expect(try repo.count(sessionId: "s1") == 1)
        #expect(
            try repo.clearStaleRows(sessionId: "s1", keepingModelVersion: Self.current) == 0,
            "再跑一次必须幂等（0 行可删）")
    }

    @Test("2,100 行旧版本一次清完：批大小 2,000 → 恰好 2 批")
    func clearStaleRowsInTwoBatches() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        let legacyIds = (0..<2_100).map { "legacy\($0)" }
        try insertPhotos(db, ids: legacyIds + ["keep"])
        try repo.upsert(
            legacyIds.map { semanticsRow($0, modelVersion: Self.legacy) }
                + [semanticsRow("keep", modelVersion: Self.current)])

        #expect(try repo.clearStaleRows(sessionId: "s1", keepingModelVersion: Self.current) == 2_100)
        #expect(try repo.indexedPhotoIds(sessionId: "s1") == ["keep"])
        #expect(try repo.count(sessionId: "s1") == 1)
    }

    @Test("中途被打断：第一批 2,000 行已提交、第二批整批回滚")
    func clearStaleRowsCommitsPerBatch() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        let legacyIds = (0..<2_100).map { "legacy\($0)" }
        try insertPhotos(db, ids: legacyIds)
        try repo.upsert(legacyIds.map { semanticsRow($0, modelVersion: Self.legacy) })

        // 触发器：第 2,001 次删除（第二批的第一行）中止语句，模拟"清到一半被打断"。
        try db.exec("""
            CREATE TABLE delete_probe (n INTEGER NOT NULL);
            INSERT INTO delete_probe VALUES (0);
            CREATE TRIGGER trg_probe AFTER DELETE ON photo_semantics
            BEGIN
                UPDATE delete_probe SET n = n + 1;
                SELECT RAISE(ABORT, 'probe') WHERE (SELECT n FROM delete_probe) = 2001;
            END;
            """)
        #expect(throws: DBError.self) {
            _ = try repo.clearStaleRows(sessionId: "s1", keepingModelVersion: Self.current)
        }
        // 第二批那条 DELETE（连同触发器的计数）整体回滚 → 计数停在第 2,000。
        #expect(try rowCount(db, "SELECT n FROM delete_probe") == 2_000, "批大小 2,000")
        #expect(try repo.count(sessionId: "s1") == 100, "已提交的第一批不回滚")
    }
}
