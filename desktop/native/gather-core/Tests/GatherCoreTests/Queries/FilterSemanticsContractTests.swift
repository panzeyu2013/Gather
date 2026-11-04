// desktop/native/gather-core/Tests/GatherCoreTests/Queries/FilterSemanticsContractTests.swift
// #10：两套过滤模型的**语义契约**（不统一模型，只把差异钉住）。
//
// 背景：图库（FilterGroup → PhotoFilterQuery）与挑片（CullingPageFilter →
// CullingAssetPageQuery.filteredWhere）各有一套「过滤条件 → SQL」实现。逐字段对照后
// 结论是**不该合并**：真正重复的只有 13 行列规范化，分歧全在语义。
//
// 本文件的价值不是「断言它们一致」，而是：
// 1. 共享维度（星级 gte）上两页结果**必须**相同——这是用户能感知的一致性底线；
// 2. 已知分歧（空值口径、任一行 vs 首选行）**显式**断言当前行为，谁改了就会红，
//    逼改动者在提交信息里说明是修 bug 还是改语义；
// 3. 图库不认识的挑片专有维必须抛错（防止「假统一」）。
import Foundation
import Testing
import GatherProtocol
@testable import GatherPersistence

@Suite("过滤语义契约（图库 vs 挑片）")
struct FilterSemanticsContractTests {
    /// 夹具：一个含 RAW/JPEG 变体的资产 + 两张独立照片。
    ///
    /// - a1/p1（RAW）：rating=5、label=""（写回空色标的真实形态）
    /// - a1/p2（JPEG）：rating=0、label="Red"
    /// - p3：**没有** photo_metadata_cache 行（未抽取元数据）
    /// - p4：rating=0、label="None"（reset 写字面色标的真实形态）
    private func makeFixture() throws -> DBConnection {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s1")
        try queryInsertAsset(db, id: "a1")
        try queryInsertPhoto(db, id: "p1", sessionId: "s1", filepath: "/shots/p1.nef", assetId: "a1")
        try queryInsertPhoto(db, id: "p2", sessionId: "s1", filepath: "/shots/p2.jpg", assetId: "a1")
        try queryInsertPhoto(db, id: "p3", sessionId: "s1", filepath: "/shots/p3.jpg")
        try queryInsertPhoto(db, id: "p4", sessionId: "s1", filepath: "/shots/p4.jpg")
        try queryInsertCache(db, photoId: "p1", sessionId: "s1", rating: 5, label: "")
        try queryInsertCache(db, photoId: "p2", sessionId: "s1", rating: 0, label: "Red")
        try queryInsertCache(db, photoId: "p4", sessionId: "s1", rating: 0, label: "None")
        return db
    }

    private func galleryCount(_ db: DBConnection, _ rules: [FilterRule]) throws -> Int {
        let group = FilterGroup(logic: .and, conditions: rules.map(FilterCondition.rule))
        return try PhotoFilterQuery(connection: db).countGlobally(criteria: group)
    }

    private func cullingCount(_ db: DBConnection, _ filter: CullingPageFilter) throws -> Int {
        try CullingAssetPageQuery(connection: db).countFiltered(sessionId: "s1", filter: filter)
    }

    @Test("共享维度：星级 ≥5 两页同集合（一致性底线）")
    func ratingGteIsShared() throws {
        let db = try makeFixture()
        let gallery = try galleryCount(db, [
            FilterRule(field: "rating", operator: .gte, value: .number(5))])
        let culling = try cullingCount(db, CullingPageFilter(ratings: [5]))
        #expect(gallery == culling, "星级下限是两页共享语义，结果必须一致")
        #expect(gallery == 1)
    }

    @Test("已知分歧 1：未评级（rating=0）—— 计数相同但**集合不同**")
    func unratedCountsMatchButSetsDiffer() throws {
        let db = try makeFixture()
        let gallery = try galleryCount(db, [
            FilterRule(field: "rating", operator: .eq, value: .number(0))])
        let culling = try cullingCount(db, CullingPageFilter(ratings: [0]))
        // 两边都是 2，但**命中的不是同一批**：
        // - 图库「任一行命中即整组入选」→ a1（因为 JPEG 变体 p2 rating=0）+ p4；
        // - 挑片只看资产**首选行**（a1 首选 RAW p1，rating=5，排除）+ 无缓存行的 p3
        //   （COALESCE(NULLIF(rating,...),0)=0）+ p4。
        // 这正是「不能靠计数判断两页一致」的证据：断言集合需要 filterGloballyIDs /
        // pageSorted 的返回，留给 Step 2（届时口径统一后应变成真等集）。
        #expect(gallery == 2)
        #expect(culling == 2, "culling 实测 \(culling)")
    }

    @Test("已知分歧 2：无色标—— 图库只认字面 None，挑片把空串也算 None")
    func noneLabelDivergesOnEmptyString() throws {
        let db = try makeFixture()
        let gallery = try galleryCount(db, [
            FilterRule(field: "label", operator: .eq, value: .string("None"))])
        let culling = try cullingCount(db, CullingPageFilter(colorLabels: ["None"]))
        // 图库：只有 p4 的字面 "None" 命中 → 1；
        // 挑片：a1 首选行 p1 的 label="" 经 COALESCE(NULLIF(label,''),'None') 变成 None，
        // 加上无缓存行的 p3 也被 COALESCE 成 None，再加 p4 → 3。
        #expect(gallery == 1)
        #expect(culling == 3, "culling 实测 \(culling)")
    }

    @Test("挑片专有维在图库必须显式抛错（防假统一）")
    func cullingOnlyFieldThrowsInGallery() throws {
        let db = try makeFixture()
        #expect(throws: PhotoFilterQueryError.self) {
            _ = try galleryCount(db, [
                FilterRule(field: "pickState", operator: .eq, value: .string("reject"))])
        }
    }
}
