// Tests/GatherCoreTests/Runtime/Culling/CullingLookupLoaderTests.swift
// W2b 步骤 3：CullingLookupLoader 行为测试（真实临时库 + Store）。
// 覆盖设计 §3 的语义修正：分块/排序/JSON 守卫逐段对照旧 buildRichLookup，
// 以及「数据库读错误一律上抛（无 try? 静默降级）」。

import Foundation
import Testing
@testable import GatherCore

@Suite("Runtime/CullingLookupLoader (W2b)")
struct CullingLookupLoaderTests {

    private func photoRows(_ harness: CullingRuntimeHarness) async throws -> [CullingPhotoRow] {
        try await harness.photoStore.getBySession(sessionId: harness.sessionId)
            .map { CullingPhotoRow(row: $0) }
    }

    // MARK: - decisions

    @Test("loadDecisions：会话模式全量、页模式只取给定照片（photoId 键控）")
    func loadDecisionsSessionAndPageModes() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        try await insertCullingPhoto(harness.db, id: "p3")
        try await insertCullingDecision(harness.db, photoId: "p1", decision: "keep", rating: 4, revision: 2)
        try await insertCullingDecision(harness.db, photoId: "p2", decision: "reject", revision: 1)
        let photos = try await photoRows(harness)

        let session = try await harness.loader.loadDecisions(
            photos: photos, sessionId: harness.sessionId, mode: .session)
        #expect(Set(session.keys) == ["p1", "p2"])
        #expect(session["p1"]?.rating == 4)
        #expect(session["p1"]?.revision == 2)

        let page = try await harness.loader.loadDecisions(
            photos: [photos[0]], sessionId: harness.sessionId, mode: .page)
        #expect(Set(page.keys) == ["p1"], "页模式不返回未请求照片")

        let empty = try await harness.loader.loadDecisions(
            photos: [], sessionId: harness.sessionId, mode: .page)
        #expect(empty.isEmpty)
    }

    // MARK: - 元数据 / summary 轻投影

    @Test("loadMetadata / loadSummaryCache：重列与轻投影各自正确，空参数不触库")
    func loadMetadataAndSummaryCache() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        try await insertCullingMetadata(
            harness, photoId: "p1", rating: 4, label: "Red", keywords: ["alpha", "beta"])
        try await insertCullingMetadata(harness, photoId: "p2", rating: 0)

        let rows = try await harness.loader.loadMetadata(photoIds: ["p1", "p2", "missing"])
        #expect(rows.count == 2)
        #expect(rows["p1"]?.keywords == ["alpha", "beta"])
        #expect(rows["p1"]?.label == "Red")
        #expect(rows["p2"]?.rating == 0)

        let summary = try await harness.loader.loadSummaryCache(photoIds: ["p1", "p2"])
        #expect(summary["p1"]?.rating == 4)
        #expect(summary["p1"]?.label == "Red")
        #expect(summary["p2"]?.rating == 0)

        #expect(try await harness.loader.loadMetadata(photoIds: []).isEmpty)
        #expect(try await harness.loader.loadSummaryCache(photoIds: []).isEmpty)
    }

    // MARK: - outbox

    @Test("loadOutbox：会话模式全量、页模式按 xmp 路径、空路径不触库")
    func loadOutboxSessionAndPageModes() async throws {
        let harness = try await makeCullingRuntimeHarness(writeOutbox: true)
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        let row1 = try await insertCullingOutbox(
            harness, photoId: "p1", patch: ["rating": .number(5)])
        let row2 = try await insertCullingOutbox(
            harness, photoId: "p2", patch: ["label": .string("Red")])
        let photos = try await photoRows(harness)

        let session = try await harness.loader.loadOutbox(
            sessionId: harness.sessionId, photos: photos, mode: .session)
        #expect(Set(session.keys) == [row1.xmpPath, row2.xmpPath])
        #expect(session[row1.xmpPath]?.patchJSON.contains("rating") == true)

        let page = try await harness.loader.loadOutbox(
            sessionId: harness.sessionId, photos: [photos[0]], mode: .page)
        #expect(page.keys.sorted() == [row1.xmpPath], "页模式只读本页 xmp 路径")

        #expect(try await harness.loader.loadOutbox(sessionId: harness.sessionId, xmpPaths: []).isEmpty)
    }

    // MARK: - 相似度会话查找

    @Test("loadSessionLookup / loadLatestSimilarity：无结果空映射、有结果 resultId:index 且已解析")
    func loadSessionLookupAndLatestSimilarity() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        try await insertCullingPhoto(harness.db, id: "p3")

        let none = try await harness.loader.loadSessionLookup(sessionId: harness.sessionId)
        #expect(none.resultRow == nil)
        #expect(none.similarityMap.isEmpty)
        #expect(none.groupIndexResolved == false, "空成员映射未解析 → 调用方回退 groups_json")
        #expect(none.analysesLoaded == false)
        #expect(try await harness.loader.loadLatestSimilarity(sessionId: harness.sessionId).isEmpty)

        let resultId = try await insertCullingSimilarityResult(harness, memberships: [
            SimilarityMembership(photoId: "p1", groupIndex: 0),
            SimilarityMembership(photoId: "p2", groupIndex: 0),
            SimilarityMembership(photoId: "p3", groupIndex: 1),
        ])
        let lookup = try await harness.loader.loadSessionLookup(sessionId: harness.sessionId)
        #expect(lookup.resultRow?.id == resultId)
        #expect(lookup.similarityMap["p1"] == "\(resultId):0")
        #expect(lookup.similarityMap["p3"] == "\(resultId):1")
        #expect(lookup.groupIndex == lookup.similarityMap, "成员映射非空时它本身就是组索引")
        #expect(lookup.groupIndexResolved)
        #expect(try await harness.loader.loadLatestSimilarity(sessionId: harness.sessionId)["p2"] == "\(resultId):0")
    }

    // MARK: - 分析（质量 / 人脸 / 人物）

    @Test("loadAnalyses：质量取最新合法行、损坏 JSON 跳过；人脸按 id 序；人物按名排序去重")
    func loadAnalysesMaps() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertAssetFile(harness.db, id: "af-p1", normalizedPath: "/shoot/p1.jpg")
        try await insertAssetFile(harness.db, id: "af-p2", normalizedPath: "/shoot/p2.jpg")
        try await insertCullingPhoto(harness.db, id: "p1", assetFileId: "af-p1")
        try await insertCullingPhoto(harness.db, id: "p2", assetFileId: "af-p2")

        // p1 两行：旧 failed、新 succeeded（updated_at DESC 首行即最新）。
        try await insertCullingQuality(
            harness.db, photoId: "p1", assetFileId: "af-p1",
            resultJSON: #"{"status":"failed","qualityScore":0.1}"#,
            updatedAt: "2026-01-01T00:00:00.000Z")
        try await insertCullingQuality(
            harness.db, photoId: "p1", assetFileId: "af-p1",
            resultJSON: #"{"status":"succeeded","qualityScore":0.9,"sharpness":0.8,"exposure":0.7,"warnings":["w"]}"#,
            updatedAt: "2026-01-03T00:00:00.000Z")
        // p2 只有损坏 JSON → 视为无质量（不抛错、不产生对象）。
        try await insertCullingQuality(
            harness.db, photoId: "p2", assetFileId: "af-p2", resultJSON: "not json",
            updatedAt: "2026-01-02T00:00:00.000Z")

        try await insertCullingFaceObservation(
            harness.db, photoId: "p1", x: 0.1, y: 0.2, w: 0.3, h: 0.4,
            signature: #"{"previewMaxDimension":2048}"#)
        try await insertCullingFaceObservation(
            harness.db, photoId: "p1", x: 0.5, y: 0.5, w: 0.1, h: 0.1, signature: "")
        try await insertCullingFaceObservation(
            harness.db, photoId: "p2", x: 0.2, y: 0.2, w: 0.2, h: 0.2,
            signature: #"{"previewMaxDimension":1000}"#)

        try await insertCullingPerson(harness.db, id: "person-b", name: "Bob")
        try await insertCullingPerson(harness.db, id: "person-a", name: "Alice")
        try await linkCullingPerson(harness.db, personId: "person-b", photoId: "p1")
        try await linkCullingPerson(harness.db, personId: "person-a", photoId: "p1")
        try await linkCullingPerson(harness.db, personId: "person-a", photoId: "p2")

        let photos = try await photoRows(harness)
        let analyses = try await harness.loader.loadAnalyses(
            photos: photos, sessionId: harness.sessionId, mode: .session)

        #expect(analyses.qualityByPhoto["p1"]?.status == .succeeded, "最新合法行胜出")
        #expect(analyses.qualityByPhoto["p1"]?.score == 0.9)
        #expect(analyses.qualityByPhoto["p1"]?.sharpness == 0.8)
        #expect(analyses.qualityByPhoto["p1"]?.warnings == ["w"])
        #expect(analyses.qualityByPhoto["p2"] == nil, "损坏 JSON 显式退化为无质量")

        #expect(analyses.facesByPhoto["p1"]?.count == 2)
        #expect(analyses.facesByPhoto["p1"]?.first == [0.1, 0.2, 0.3, 0.4], "Store 行序为 id 升序")
        #expect(analyses.analysisMaxByPhoto["p1"] == 2048, "首个可解析签名决定 max")
        #expect(analyses.analysisMaxByPhoto["p2"] == 1000)

        #expect(analyses.peopleByPhoto["p1"] == ["Alice", "Bob"], "按名排序且去重")
        #expect(analyses.peopleByPhoto["p2"] == ["Alice"])

        let empty = try await harness.loader.loadAnalyses(photos: [], sessionId: harness.sessionId, mode: .page)
        #expect(empty == CullingLookupAnalyses())
    }

    // MARK: - 页模式富查询

    @Test("loadPageLookup：决策/缓存/outbox/相似度/相对排名/linkedCounts 一次装配")
    func loadPageLookupAssemblesRichLookup() async throws {
        let harness = try await makeCullingRuntimeHarness(writeOutbox: true)
        try await insertAssetFile(harness.db, id: "af-p1", normalizedPath: "/shoot/p1.jpg")
        try await insertAssetFile(harness.db, id: "af-p2", normalizedPath: "/shoot/p2.jpg")
        try await insertCullingPhoto(harness.db, id: "p1", assetFileId: "af-p1")
        try await insertCullingPhoto(harness.db, id: "p2", assetFileId: "af-p2")
        try await insertCullingDecision(harness.db, photoId: "p1", decision: "keep", rating: 5, revision: 1)
        try await insertCullingMetadata(harness, photoId: "p1", rating: 5, keywords: ["kw"])
        let outbox = try await insertCullingOutbox(harness, photoId: "p1", patch: ["rating": .number(5)])
        let resultId = try await insertCullingSimilarityResult(harness, memberships: [
            SimilarityMembership(photoId: "p1", groupIndex: 0),
            SimilarityMembership(photoId: "p2", groupIndex: 0),
        ])
        try await insertCullingQuality(
            harness.db, photoId: "p1", assetFileId: "af-p1",
            resultJSON: #"{"status":"succeeded","qualityScore":0.5}"#)
        try await insertCullingQuality(
            harness.db, photoId: "p2", assetFileId: "af-p2",
            resultJSON: #"{"status":"succeeded","qualityScore":0.9}"#)
        try await insertCullingFaceObservation(harness.db, photoId: "p2", signature: "")

        let photos = try await photoRows(harness)
        let lookup = try await harness.loader.loadPageLookup(photos: photos, sessionId: harness.sessionId)

        #expect(Set(lookup.decisions.keys) == ["p1"])
        #expect(lookup.cacheRows["p1"]?.keywords == ["kw"])
        #expect(lookup.outboxByPath[outbox.xmpPath]?.xmpPath == outbox.xmpPath)
        #expect(lookup.similarityMap["p1"] == "\(resultId):0")
        #expect(lookup.qualityByPhoto["p1"]?.relativeRank == 2, "低分排后")
        #expect(lookup.qualityByPhoto["p2"]?.relativeRank == 1)
        #expect(lookup.facesByPhoto["p1"] == nil)
        #expect(lookup.facesByPhoto["p2"]?.count == 1)
        #expect(lookup.linkedCounts[TSPath.xmpSidecarPath("/shoot/p1.jpg")] == 1)
    }

    // MARK: - 组索引（groups_json 回退）

    @Test("CullingGroupIndex.build：groups_json 解析 resultId:index，损坏/无结果退化为空")
    func groupIndexBuild() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1", filepath: "/a.jpg")
        try await insertCullingPhoto(harness.db, id: "p2", filepath: "/b.jpg")
        let photos = try await photoRows(harness)

        #expect(CullingGroupIndex.build(photos: photos, resultRow: nil).isEmpty, "无结果 = 空索引")

        let resultId = try await insertCullingSimilarityResult(
            harness,
            memberships: [],
            groupsJson: #"{"groups":[{"images":[{"path":"/a.jpg"},{"path":"/b.jpg"}]}]}"#
        )
        let resultRow = try #require(await harness.similarityStore.latestResult(sessionId: harness.sessionId))
        let index = CullingGroupIndex.build(photos: photos, resultRow: resultRow)
        #expect(index == ["p1": "\(resultId):0", "p2": "\(resultId):0"])

        let corrupt = SimilarityResultRecord(
            id: 9, sessionId: harness.sessionId, groupsJson: "not json",
            statsJson: "{}", paramThreshold: 10, paramMinGroupSize: 2,
            createdAt: "2026-01-01T00:00:00.000Z")
        #expect(CullingGroupIndex.build(photos: photos, resultRow: corrupt).isEmpty, "损坏行退化为空索引")

        let mismatched = SimilarityResultRecord(
            id: 9, sessionId: harness.sessionId, groupsJson: #"{"groups":"nope"}"#,
            statsJson: "{}", paramThreshold: 10, paramMinGroupSize: 2,
            createdAt: "2026-01-01T00:00:00.000Z")
        #expect(CullingGroupIndex.build(photos: photos, resultRow: mismatched).isEmpty)
    }

    // MARK: - 无 try? 静默降级（数据库错误一律上抛）

    @Test("Store 读错误上抛：关闭连接后各装载方法抛错而不是返回空")
    func storeErrorsPropagateInsteadOfSilentEmpty() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        let photos = try await photoRows(harness)
        await harness.db.close()

        await #expect(throws: (any Error).self) {
            _ = try await harness.loader.loadMetadata(photoIds: ["p1"])
        }
        await #expect(throws: (any Error).self) {
            _ = try await harness.loader.loadSummaryCache(photoIds: ["p1"])
        }
        await #expect(throws: (any Error).self) {
            _ = try await harness.loader.loadSessionLookup(sessionId: harness.sessionId)
        }
        await #expect(throws: (any Error).self) {
            _ = try await harness.loader.loadAnalyses(
                photos: photos, sessionId: harness.sessionId, mode: .session)
        }
        await #expect(throws: (any Error).self) {
            _ = try await harness.loader.loadOutbox(
                sessionId: harness.sessionId, photos: photos, mode: .session)
        }
    }
}
