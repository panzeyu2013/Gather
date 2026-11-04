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

    @Test("未评级：空值口径已统一（缺缓存行 = 0 星），剩余差异是**行粒度**")
    func unratedSharesNullSemanticsButNotGranularity() throws {
        let db = try makeFixture()
        let gallery = try galleryCount(db, [
            FilterRule(field: "rating", operator: .eq, value: .number(0))])
        let culling = try cullingCount(db, CullingPageFilter(ratings: [0]))
        // #10 Step 2 之后，两页对「没有缓存行」都按 0 星算（此前图库要求有缓存行）：
        // - 图库「任一行命中即整组入选」→ a1（JPEG 变体 p2）+ p3（缺行）+ p4 = 3；
        // - 挑片只看资产**首选行**（a1 首选 RAW p1 rating=5，排除）+ p3 + p4 = 2。
        // 也就是说：空值口径已统一，剩下的差异纯粹是「任一行 vs 首选行」的粒度问题。
        // 粒度差要不要改属于产品决策（改图库为 preferred-row 会动 4 处 SQL + facet），
        // 不在本轮范围；这里把它钉住，谁改粒度这条用例会先红。
        #expect(gallery == 3)
        #expect(culling == 2)
    }

    @Test("无色标：两页已同集合（''/NULL/None 都算 None）")
    func noneLabelIsNowShared() throws {
        let db = try makeFixture()
        let gallery = try galleryCount(db, [
            FilterRule(field: "label", operator: .eq, value: .string("None"))])
        let culling = try cullingCount(db, CullingPageFilter(colorLabels: ["None"]))
        // #10 Step 2 之前：图库只认字面 "None"（1），挑片把 ""/NULL 也算（3）。
        // 现在两页都走 FilterFieldSQL.label：p1 的 ""、p3 的无缓存行、p4 的字面 None
        // 都归一到 None → 3 == 3。
        #expect(gallery == culling, "无色标口径已统一，两页必须同结果")
        #expect(gallery == 3)
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
