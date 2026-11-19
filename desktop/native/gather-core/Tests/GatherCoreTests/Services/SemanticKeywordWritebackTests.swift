// desktop/native/gather-core/Tests/GatherCoreTests/Services/SemanticKeywordWritebackTests.swift
// Wave4a / task-39（E2）：场景标签写回的**批级撤销**回归测试。
//
// 覆盖：apply 返回本批实际写到的 photoIds → 用这批 id 撤销只清本批 →
// 再次 apply 能恢复（apply→undo→apply 闭环），而不是清整个会话的 AI 场景子树。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherDelivery
@testable import GatherApplication

/// 纯路径夹具根（task-43）：本套的 XMP / mutation 全是内存 fake，
/// 照片路径不参与任何读盘；去掉每用例建临时目录 + 写占位字节 + 删除的 IO。
private let semanticFixtureRoot =
    FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-semantic-fixture", isDirectory: true).path

/// 内存 XMP：关键词按照片路径存；写/删都由 flush 闭包驱动。
/// 记录 keyword delta，flush 时一次性落到假 XMP（与真实交付链同路径：queue → flush → 回读）。
@Suite("场景标签写回批级撤销")
struct SemanticKeywordWritebackTests {
    private func labelsJSON(_ labels: [(String, Double)]) -> String {
        let objects = labels.map { label, confidence in
            "{\"label\":\"\(label)\",\"confidence\":\(confidence)}"
        }
        return "[" + objects.joined(separator: ",") + "]"
    }

    @Test("apply 返回本批 appliedPhotoIds；undo 只清本批；再次 apply 恢复（E2）")
    func applyUndoApply() async throws {
        let db = try makeTestDB()
        let dir = semanticFixtureRoot

        let sessionId = "s-1"
        try insertSession(db, sessionId)
        let pathA = (dir as NSString).appendingPathComponent("a.CR3")
        let pathB = (dir as NSString).appendingPathComponent("b.CR3")
        try insertPhoto(db, id: "p1", sessionId: sessionId, filepath: pathA)
        try insertPhoto(db, id: "p2", sessionId: sessionId, filepath: pathB)

        let cache = MetadataCacheRepo(connection: db)
        try cache.upsert(photoId: "p1", sessionId: sessionId, data: MetadataCacheInput(rating: 0))
        try cache.upsert(photoId: "p2", sessionId: sessionId, data: MetadataCacheInput(rating: 0))

        let semantics = PhotoSemanticsRepo(connection: db)
        for (photoId, label) in [("p1", "beach"), ("p2", "wedding")] {
            try semantics.upsert([PhotoSemanticsInsert(
                photoId: photoId, sessionId: sessionId,
                labelsJson: labelsJSON([(label, 0.9)]),
                feature: nil, featureDim: 0,
                modelVersion: "test", computedAt: "2026-01-01T00:00:00Z")])
        }

        let xmp = RecordingXMPProvider()
        let mutations = RecordingMetadataMutation()
        let paths = ["p1": pathA, "p2": pathB]
        let photoRepo = PhotoRepo(connection: db)
        let metadata = MetadataService(
            metadataCacheRepo: cache, xmp: xmp, photoRepo: photoRepo, transactions: db,
            mutations: mutations,
            flushPending: { _ in
                let entries = mutations.drainKeywordDeltas()
                for entry in entries {
                    guard let path = paths[entry.photoId] else { continue }
                    xmp.applyDelta(photoPath: path, added: entry.added, removed: entry.removed)
                }
                return WritebackResult(
                    totalAffected: entries.count, written: entries.count, failed: 0,
                    skipped: 0, errors: [], failedItems: [], report: "")
            })
        let keywords = KeywordRepo(connection: db)
        let indexSync = KeywordIndexSync(index: keywords, metadata: cache)
        let service = SemanticKeywordService(
            semantics: semantics, metadata: metadata, keywords: keywords,
            indexSync: indexSync, photoRepo: photoRepo)

        // ① 写回：本批覆盖两张照片，结果必须回传本批 photoIds。
        let first = try await service.apply(SemanticKeywordApplyInput(sessionId: sessionId))
        #expect(first.appliedPhotos == 2)
        #expect(first.keywordsAdded == 2)
        #expect(first.appliedPhotoIds.sorted() == ["p1", "p2"], "写回结果必须带本批照片 id")
        let planAfterWrite = try service.plan(SemanticKeywordPlanInput(sessionId: sessionId))
        #expect(planAfterWrite.totalAdditions == 0, "写完再预览应为幂等 0")

        // ② 只撤销本批中的 p1（模拟 UI 收到 appliedPhotoIds 后回传）：
        //    p2 的关键词必须保留，不能把整个会话的场景子树清空。
        let undo = try await service.apply(SemanticKeywordApplyInput(
            sessionId: sessionId, photoIds: ["p1"], remove: true))
        #expect(undo.appliedPhotos == 1)
        #expect(undo.appliedPhotoIds == ["p1"])
        #expect(undo.keywordsRemoved == 1)
        #expect(try keywords.photoKeywordPaths(photoId: "p2") == ["AI|场景|wedding"])
        #expect(try keywords.photoKeywordPaths(photoId: "p1").isEmpty)
        let planAfterUndo = try service.plan(SemanticKeywordPlanInput(sessionId: sessionId))
        #expect(planAfterUndo.totalAdditions == 1, "只有 p1 需要重写")
        let pendingForP1 = planAfterUndo.items.filter { $0.photoId == "p1" && !$0.alreadyPresent }
        #expect(pendingForP1.count == 1)

        // ③ 再写回 p1：闭环恢复。
        let second = try await service.apply(SemanticKeywordApplyInput(
            sessionId: sessionId, photoIds: ["p1"]))
        #expect(second.keywordsAdded == 1)
        #expect(second.appliedPhotoIds == ["p1"])
        #expect(try keywords.photoKeywordPaths(photoId: "p1") == ["AI|场景|beach"])
        let planFinal = try service.plan(SemanticKeywordPlanInput(sessionId: sessionId))
        #expect(planFinal.totalAdditions == 0)
    }
}
