// desktop/native/gather-app/Tests/GatherAppTests/GatherAutomationRuntimeTests.swift
// Wave3 / task-21：Shortcuts/App Intents 运行时注册表与动作返回形状。
// Wave5 batch5（task-24）：新增的 queryPhotos / applyDecisions 两个闭包，以及
// 「查询条件归一化」「写判断补丁归一化」两套校验（URL scheme 与 App Intents 共用）。
//
// 覆盖：
// 1. 未安装时 current == nil（App Intents 走 runtimeUnavailable）；
// 2. install 后六个动作闭包按注入实现返回（intents 只依赖这些闭包，不需要真库）；
// 3. query 过滤条件映射（关键词 contains_any / 最低星级 gte）与字符串入口校验；
// 4. applyDecisions 入参（rating/label/pick）归一化与非法值拒绝；
// 5. reset 清空。
//
// 边界：不启动 AppBootstrap、不打开 SQLite；只验证注册表、闭包装配面与纯归一化逻辑。
import Foundation
import Testing
@testable import GatherHost
@testable import GatherProtocol

@Suite("Shortcuts 运行时注册表", .serialized)
struct GatherAutomationRuntimeTests {
    private func makeRuntime(
        query: @escaping @Sendable (GatherAutomationPhotoQuery) async throws -> GatherAutomationPhotoQueryResult = { _ in
            GatherAutomationPhotoQueryResult(sessionId: "session-1", photoIds: [], total: 0)
        },
        apply: @escaping @Sendable (
            String, [String], GatherAutomationDecisionPatch
        ) async throws -> GatherAutomationDecisionSummary = { sessionId, _, _ in
            GatherAutomationDecisionSummary(sessionId: sessionId, written: 0, skipped: 0)
        }
    ) -> GatherAutomationRuntime {
        GatherAutomationRuntime(
            createWorkspaceAndImport: { _, _ in "session-1" },
            exportSession: { _, _, _, _, _ in
                ExportResult(totalFiles: 2, exported: 2, failed: 0, skipped: 0, errors: [])
            },
            writebackMetadata: { sessionId, target in
                GatherAutomationWritebackSummary(
                    sessionId: sessionId, target: target,
                    written: 3, failed: 0, skipped: 1)
            },
            sessionStatus: { sessionId in
                GatherAutomationSessionStatus(
                    sessionId: sessionId, name: "WS", photoCount: 10,
                    pendingXmp: 0, writtenXmp: 10, failedXmp: 0,
                    conflictXmp: 0, reloadAckedAt: "2026-11-11T00:00:00Z")
            },
            queryPhotos: query,
            applyDecisions: apply)
    }

    @Test func registryStartsEmptyThenInstallsAndResets() async throws {
        GatherAutomationRuntimeRegistry.reset()
        #expect(GatherAutomationRuntimeRegistry.current == nil)

        let runtime = makeRuntime(
            query: { query in
                GatherAutomationPhotoQueryResult(
                    sessionId: query.sessionId,
                    photoIds: ["photo-1", "photo-2"],
                    total: 2,
                    samples: [GatherAutomationPhotoSample(photoId: "photo-1", filename: "a.jpg")])
            },
            apply: { sessionId, photoIds, _ in
                GatherAutomationDecisionSummary(
                    sessionId: sessionId, written: photoIds.count, skipped: 0)
            })
        GatherAutomationRuntimeRegistry.current = runtime
        let installed = try #require(GatherAutomationRuntimeRegistry.current)

        let created = try await installed.createWorkspaceAndImport(
            "workspace", ["/tmp/a.jpg", "/tmp/b.jpg"])
        #expect(created == "session-1")

        let export = try await installed.exportSession(
            "session-1", "/tmp/export", "jpeg", 0.9, 2000)
        #expect(export.exported == 2)

        let writeback = try await installed.writebackMetadata("session-1", "rating")
        #expect(writeback.written == 3)

        let status = try await installed.sessionStatus("session-1")
        #expect(status.photoCount == 10)

        let query = try GatherAutomationPhotoQuery(sessionId: "session-1", limit: 10)
        let found = try await installed.queryPhotos(query)
        #expect(found.photoIds == ["photo-1", "photo-2"])
        #expect(found.samples.first?.filename == "a.jpg")

        let apply = try await installed.applyDecisions(
            "session-1", ["photo-1", "photo-2"],
            GatherAutomationDecisionPatch(rating: 4))
        #expect(apply.written == 2)

        GatherAutomationRuntimeRegistry.reset()
        #expect(GatherAutomationRuntimeRegistry.current == nil)
    }

    @Test func unavailableErrorCarriesDescription() {
        #expect(GatherAutomationError.runtimeUnavailable.errorDescription?.isEmpty == false)
        #expect(GatherAutomationError.noFiles.errorDescription?.isEmpty == false)
        // Wave5 batch5：新错误码也必须有可读描述（Shortcuts 直接把 errorDescription 给用户）。
        #expect(GatherAutomationError.invalidQuery("x").errorDescription?.isEmpty == false)
        #expect(GatherAutomationError.invalidDecision("x").errorDescription?.isEmpty == false)
        #expect(GatherAutomationError.noPhotoIds.errorDescription?.isEmpty == false)
    }

    // MARK: - Wave5 batch5：查询条件归一化

    @Test func photoQueryNormalizesInputs() throws {
        // 关键词去空白；空串归一为 nil（不生成过滤条件）。
        let query = try GatherAutomationPhotoQuery(
            sessionId: "  session-1  ", keyword: "  sunset  ", minRating: 3, limit: 5)
        #expect(query.sessionId == "session-1")
        #expect(query.keyword == "sunset")
        #expect(query.minRating == 3)
        #expect(query.limit == 5)

        let emptyKeyword = try GatherAutomationPhotoQuery(
            sessionId: "session-1", keyword: "   ")
        #expect(emptyKeyword.keyword == nil)
        #expect(emptyKeyword.minRating == nil)
        #expect(emptyKeyword.limit == GatherAutomationPhotoQuery.defaultLimit)
    }

    @Test func photoQueryRejectsInvalidInputs() {
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery(sessionId: "   ")
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery(sessionId: "session-1", minRating: 6)
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery(sessionId: "session-1", minRating: -1)
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery(sessionId: "session-1", limit: 0)
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery(
                sessionId: "session-1", limit: GatherAutomationPhotoQuery.maxLimit + 1)
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery(
                sessionId: "session-1",
                keyword: String(repeating: "k", count: GatherAutomationPhotoQuery.maxKeywordLength + 1))
        }
    }

    @Test func photoQueryStringEntryParsesAndRejects() throws {
        let parsed = try GatherAutomationPhotoQuery.parse(
            sessionId: "session-1", keyword: "beach", minRating: "4", limit: "20")
        #expect(parsed.keyword == "beach")
        #expect(parsed.minRating == 4)
        #expect(parsed.limit == 20)

        // 空串 = 未设置（App Intents 的可选参数走这条）。
        let defaults = try GatherAutomationPhotoQuery.parse(
            sessionId: "session-1", keyword: "", minRating: "", limit: "")
        #expect(defaults.keyword == nil)
        #expect(defaults.minRating == nil)
        #expect(defaults.limit == GatherAutomationPhotoQuery.defaultLimit)

        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery.parse(
                sessionId: "session-1", keyword: "", minRating: "abc", limit: "")
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery.parse(
                sessionId: "session-1", keyword: "", minRating: "9", limit: "")
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery.parse(
                sessionId: "session-1", keyword: "", minRating: "", limit: "many")
        }
    }

    @Test func photoQueryMapsToFilterCriteria() throws {
        // 空条件 → and 组里没有条件（等价「全工作区」，与检索页空搜索同口径）。
        let all = try GatherAutomationPhotoQuery(sessionId: "session-1")
        #expect(all.criteria == FilterGroup(logic: .and, conditions: []))

        // 关键词 → keywords contains_any [keyword]（与 Library 的关键词筛选同一字段/操作符）。
        let keyword = try GatherAutomationPhotoQuery(sessionId: "session-1", keyword: "sunset")
        #expect(keyword.criteria == FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(
                field: "keywords", operator: .containsAny, value: .array([.string("sunset")]))),
        ]))

        // 最低星级 → rating gte N（不是 eq：脚本要「4 星及以上」）。
        let rating = try GatherAutomationPhotoQuery(sessionId: "session-1", minRating: 4)
        #expect(rating.criteria == FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "rating", operator: .gte, value: .number(4))),
        ]))

        // 两个条件并存 → 同一 and 组（不是嵌套组）。
        let combined = try GatherAutomationPhotoQuery(
            sessionId: "session-1", keyword: "sunset", minRating: 2)
        #expect(combined.criteria == FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(
                field: "keywords", operator: .containsAny, value: .array([.string("sunset")]))),
            .rule(FilterRule(field: "rating", operator: .gte, value: .number(2))),
        ]))
    }

    @Test func photoQueryResultCapsSamples() {
        let samples = (0..<9).map {
            GatherAutomationPhotoSample(photoId: "p\($0)", filename: "\($0).jpg")
        }
        let result = GatherAutomationPhotoQueryResult(
            sessionId: "session-1", photoIds: ["p0"], total: 9, samples: samples)
        #expect(result.samples.count == GatherAutomationPhotoQueryResult.maxSamples)
        #expect(result.samples.first?.photoId == "p0")
    }

    // MARK: - Wave5 batch5：写判断补丁归一化

    @Test func decisionPatchParsesRatingLabelPick() throws {
        let keep = try GatherAutomationDecisionPatch.parse(
            rating: "4", label: "red", pick: "keep")
        #expect(keep.rating == 4)
        #expect(keep.colorLabel == .red)
        #expect(keep.pickState == .picked)
        #expect(!keep.isEmpty)

        let reject = try GatherAutomationDecisionPatch.parse(
            rating: "", label: "Purple", pick: "REJECT")
        #expect(reject.rating == nil)
        // 色标大小写不敏感（URL/Shortcuts 里用户常写小写；C1 rawValue 是首字母大写）。
        #expect(reject.colorLabel == .purple)
        #expect(reject.pickState == .rejected)

        // rating 单独给也算合法补丁（只改星级）。
        let ratingOnly = try GatherAutomationDecisionPatch.parse(
            rating: " 0 ", label: "", pick: "")
        #expect(ratingOnly.rating == 0)
        #expect(ratingOnly.colorLabel == nil)
        #expect(ratingOnly.pickState == nil)
    }

    @Test func decisionPatchRejectsInvalidValues() {
        // rating 越界/非数字。
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationDecisionPatch.parse(rating: "6", label: "", pick: "")
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationDecisionPatch.parse(rating: "-1", label: "", pick: "")
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationDecisionPatch.parse(rating: "3.5", label: "", pick: "")
        }
        // 未知色标 / 未知 pick。
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationDecisionPatch.parse(rating: "", label: "chartreuse", pick: "")
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationDecisionPatch.parse(rating: "", label: "", pick: "maybe")
        }
        // 三个字段全空拒绝（避免空写：CullingAPI 也会报 CULLING_PATCH_INVALID）。
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationDecisionPatch.parse(rating: "", label: "", pick: "")
        }
    }

    @Test func decisionPatchNamesMatchProtocolEnums() {
        // 字符串白名单必须是协议枚举的投影：C1 色标新增/改名时这里先红。
        #expect(Set(GatherAutomationDecisionPatch.colorLabelNames) == Set(
            CaptureOneColorLabel.allCases.map { $0.rawValue.lowercased() }))
        #expect(GatherAutomationDecisionPatch.pickNames == ["keep", "reject"])
    }

    @Test func applyDecisionsClosureCarriesPatchThrough() async throws {
        // @Sendable 闭包里记录调用参数：用 @unchecked Sendable 盒子（测试串行调用，
        // 与 GatherAppDelegateTests 的 Box 同写法）。
        final class Box: @unchecked Sendable {
            var seen: (sessionId: String, photoIds: [String], patch: GatherAutomationDecisionPatch)?
        }
        let box = Box()
        GatherAutomationRuntimeRegistry.reset()
        defer { GatherAutomationRuntimeRegistry.reset() }
        let runtime = makeRuntime(apply: { sessionId, photoIds, patch in
            box.seen = (sessionId, photoIds, patch)
            return GatherAutomationDecisionSummary(
                sessionId: sessionId, written: 1, skipped: photoIds.count - 1)
        })
        GatherAutomationRuntimeRegistry.current = runtime
        let installed = try #require(GatherAutomationRuntimeRegistry.current)

        let patch = try GatherAutomationDecisionPatch.parse(rating: "5", label: "", pick: "keep")
        let summary = try await installed.applyDecisions("session-9", ["a", "b"], patch)
        #expect(box.seen?.sessionId == "session-9")
        #expect(box.seen?.photoIds == ["a", "b"])
        #expect(box.seen?.patch == patch)
        #expect(summary.written == 1)
        #expect(summary.skipped == 1)
    }
}
