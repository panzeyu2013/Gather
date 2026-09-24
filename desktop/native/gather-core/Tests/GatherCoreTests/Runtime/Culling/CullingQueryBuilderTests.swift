// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Culling/CullingQueryBuilderTests.swift
// CullingQueryBuilder 纯函数测试（无数据库）。

import Testing
@testable import GatherCore

@Suite("culling query builder")
struct CullingQueryBuilderTests {
    @Test("normalize：afterRowId 必须正数，limit 1...2000")
    func normalizeValidates() throws {
        let ok = try CullingQueryBuilder.normalize(afterRowId: 5, limit: 200)
        #expect(ok.afterRowId == 5)
        #expect(ok.limit == 200)

        #expect(throws: CullingServiceError.self) {
            _ = try CullingQueryBuilder.normalize(afterRowId: 0, limit: 200)
        }
        #expect(throws: CullingServiceError.self) {
            _ = try CullingQueryBuilder.normalize(afterRowId: nil, limit: 0)
        }
        #expect(throws: CullingServiceError.self) {
            _ = try CullingQueryBuilder.normalize(afterRowId: nil, limit: CullingQueryBuilder.pageLimitMax + 1)
        }
        #expect(try CullingQueryBuilder.normalize(afterRowId: nil, limit: CullingQueryBuilder.pageLimitMax).limit == 2_000)
    }

    @Test("filterSpecs：nil/空 filters 退化为 []，有值时经唯一映射入口产出规格")
    func filterSpecsMapping() {
        #expect(CullingQueryBuilder.filterSpecs(nil).isEmpty)
        let specs = CullingQueryBuilder.filterSpecs(CullingFilters(pickStates: [.picked]))
        #expect(specs.count == 1)
        #expect(!specs[0].pickStates.isEmpty)
    }

    @Test("parseSimilarityGroupId：末冒号两侧必须为整数")
    func parseGroupId() {
        let parsed = CullingQueryBuilder.parseSimilarityGroupId("12:3")
        #expect(parsed?.resultId == 12)
        #expect(parsed?.groupIndex == 3)
        #expect(CullingQueryBuilder.parseSimilarityGroupId("noseparator") == nil)
        #expect(CullingQueryBuilder.parseSimilarityGroupId("12:x") == nil)
        #expect(CullingQueryBuilder.parseSimilarityGroupId("12:3:4") == nil)
        #expect(CullingQueryBuilder.parseSimilarityGroupId(":3") == nil)
    }

    @Test("pageRequest：scope 编译（all/filtered/similarityGroup/latest 回退）与 count 同源")
    func pageRequestCompilation() throws {
        let all = try CullingQueryBuilder.pageRequest(sessionId: "s1", scope: .all, filters: nil, requestedGroupId: nil, limit: 10)
        if case .all = all.query.scope {} else { Issue.record("all scope 编译错误") }
        #expect(all.postFilter.metadataConflictOnly == false)

        let filters = CullingFilters(metadataConflictOnly: true)
        let filtered = try CullingQueryBuilder.pageRequest(sessionId: "s1", scope: .filtered, filters: filters, requestedGroupId: nil, limit: 10)
        if case .filtered = filtered.query.scope {} else { Issue.record("filtered scope 编译错误") }
        #expect(filtered.postFilter.metadataConflictOnly)

        let grouped = try CullingQueryBuilder.pageRequest(sessionId: "s1", scope: .similarityGroup, filters: nil, requestedGroupId: "7:1", limit: 10)
        if case .similarityGroup(let resultId, let groupIndex) = grouped.query.scope {
            #expect(resultId == 7 && groupIndex == 1)
        } else {
            Issue.record("similarityGroup scope 编译错误")
        }

        let fallback = try CullingQueryBuilder.pageRequest(sessionId: "s1", scope: .similarityGroup, filters: nil, requestedGroupId: "bad", limit: 10)
        if case .similarityLatest = fallback.query.scope {} else { Issue.record("不可解析组 id 应回退 similarityLatest") }
        #expect(fallback.postFilter.requestedGroupId == "bad")

        let count = CullingQueryBuilder.countQuery(filtered)
        #expect(count.scope == filtered.query.scope)
        #expect(count.afterRowId == nil)
    }

    @Test("validateBatch：去重保序、空选择与超限")
    func validateBatchRules() throws {
        let ids = try CullingQueryBuilder.validateBatch(["a", "b", "a", "c"])
        #expect(ids == ["a", "b", "c"])
        #expect(throws: CullingServiceError.self) { _ = try CullingQueryBuilder.validateBatch([]) }
        let tooMany = (0...CullingQueryBuilder.batchMax).map { "p\($0)" }
        #expect(throws: CullingServiceError.self) { _ = try CullingQueryBuilder.validateBatch(tooMany) }
    }

    @Test("validateKeepIds：超过 batchMax 抛 tooManyKeepPhotoIds")
    func validateKeepIdsRules() throws {
        #expect(try CullingQueryBuilder.validateKeepIds(["a"]).count == 1)
        let tooMany = (0...CullingQueryBuilder.batchMax).map { "p\($0)" }
        #expect(throws: CullingServiceError.self) { _ = try CullingQueryBuilder.validateKeepIds(tooMany) }
    }

    @Test("validatePatch：字段互斥、评分范围、枚举白名单")
    func validatePatchRules() throws {
        try CullingQueryBuilder.validatePatch(CullingUpdatePatch(rating: 3, pickState: nil, colorLabel: nil))
        #expect(throws: CullingServiceError.self) {
            try CullingQueryBuilder.validatePatch(CullingUpdatePatch(rating: nil, pickState: nil, colorLabel: nil))
        }
        #expect(throws: CullingServiceError.self) {
            try CullingQueryBuilder.validatePatch(CullingUpdatePatch(rating: 3.5, pickState: nil, colorLabel: nil))
        }
        #expect(throws: CullingServiceError.self) {
            try CullingQueryBuilder.validatePatch(CullingUpdatePatch(rating: 9, pickState: nil, colorLabel: nil))
        }
        #expect(throws: CullingServiceError.ratingOutOfRange) {
            try CullingQueryBuilder.validatePatch(CullingUpdatePatch(rating: -1, pickState: nil, colorLabel: nil))
        }
        try CullingQueryBuilder.validatePatch(CullingUpdatePatch(rating: nil, pickState: .picked, colorLabel: nil))
        try CullingQueryBuilder.validatePatch(CullingUpdatePatch(rating: nil, pickState: nil, colorLabel: .red))
    }

    @Test("补丁/分页校验错误码描述与 TS 逐字一致（IPC 契约）")
    func validationErrorDescriptions() {
        #expect(CullingServiceError.patchInvalid.description == "CULLING_PATCH_INVALID")
        #expect(CullingServiceError.ratingOutOfRange.description == "rating must be an integer from 0 to 5")
        #expect(CullingServiceError.invalidPickState.description == "Invalid pickState")
        #expect(CullingServiceError.invalidColorLabel.description == "Invalid colorLabel")
        #expect(CullingServiceError.afterRowIdInvalid.description == "afterRowId must be a positive integer")
        #expect(CullingServiceError.pageLimitInvalid.description == "limit must be an integer between 1 and 2000")
    }
}
