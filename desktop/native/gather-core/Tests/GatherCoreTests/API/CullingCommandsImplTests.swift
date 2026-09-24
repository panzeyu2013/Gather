// Tests/GatherCoreTests/API/CullingCommandsImplTests.swift
// R5：culling 域命令实现直测（17 方法）。
// 逻辑来源：宿主路由层 culling.* 的 17 个分支；真实临时库 + fake 端口建成
// CullingRuntime，再经 CullingCommandsImpl 走协议面，覆盖：
// - 读路径正常取值 + 游标/limit/history limit 门控 + Store 错误上抛；
// - 写路径正常落库 + expectedRevision / batchMax / entries 门控；
// - 破坏性命令正常委托 + confirmed 门控与无副作用断言。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/CullingCommandsImpl (R5)")
struct CullingCommandsImplTests {

    private struct Harness {
        let base: CullingRuntimeHarness
        let impl: CullingCommandsImpl
    }

    private func makeHarness(writeOutbox: Bool = true) async throws -> Harness {
        let base = try await makeCullingRuntimeHarness(writeOutbox: writeOutbox)
        return Harness(base: base, impl: CullingCommandsImpl(culling: base.runtime))
    }

    /// sync 端口全部失败的第二运行时：覆盖 sync 域命令的错误上抛。
    private final class FailingSyncPort: CullingSyncPort {
        struct Boom: Error {}

        func schedule(xmpPath: String) {}
        func getSummary(sessionId: String) async throws -> MetadataSyncSummary { throw Boom() }
        func flushSession(sessionId: String) async throws -> MetadataSyncSummary { throw Boom() }
        func retrySession(sessionId: String) async throws -> MetadataSyncSummary { throw Boom() }
        func finalizeSession(sessionId: String) async throws -> MetadataSyncSummary { throw Boom() }
        func confirmSync(sessionId: String, sourceModule: String) async throws -> MetadataSyncSummary {
            throw Boom()
        }
        func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult {
            throw Boom()
        }
    }

    private func makeFailingSyncImpl(_ base: CullingRuntimeHarness) -> CullingCommandsImpl {
        let runtime = CullingRuntime(dependencies: CullingRuntime.Dependencies(
            photoStore: base.photoStore,
            queryStore: base.queryStore,
            cullingStore: base.cullingStore,
            metadataStore: base.metadataStore,
            similarityStore: base.similarityStore,
            writebackStore: base.writebackStore,
            sessionStore: base.sessionStore,
            jobStore: base.jobStore,
            faceStore: base.faceStore,
            personStore: base.personStore,
            metadataSync: FailingSyncPort(),
            metadataMutations: base.mutations,
            writeback: base.writeback
        ))
        return CullingCommandsImpl(culling: runtime)
    }

    // MARK: - list_page / groups / summary / history

    @Test("listPage：缺省 limit 200 全量 + keyset 游标")
    func listPagePaginatesWithDefaults() async throws {
        let h = try await makeHarness()
        try await insertCullingVariantPair(h.base.db, assetId: "asset-1")
        try await insertCullingPhoto(h.base.db, id: "p2")
        try await insertCullingPhoto(h.base.db, id: "p3")

        let first = try await h.impl.listPage(CullingListPageParams(
            sessionId: h.base.sessionId, scope: .all))
        #expect(first.assets.map(\.photo.id) == ["asset-1-raw", "p2", "p3"])
        #expect(first.assets[0].photo.variantCount == 2, "变体同页")
        #expect(first.total == 3)
        #expect(first.nextRowId == 4, "游标为页内末行 rowid（覆盖全量时同样返回）")

        let done = try await h.impl.listPage(CullingListPageParams(
            sessionId: h.base.sessionId, scope: .all, afterRowId: 4))
        #expect(done.assets.isEmpty)
        #expect(done.nextRowId == nil, "末页无游标（不产生死循环）")

        let second = try await h.impl.listPage(CullingListPageParams(
            sessionId: h.base.sessionId, scope: .all, afterRowId: 1, limit: 1))
        #expect(second.assets.map(\.photo.id) == ["p2"])
        #expect(second.nextRowId == 3)
    }

    @Test("listPage：afterRowId / limit 门控与错误码")
    func listPageRejectsInvalidCursorAndLimit() async throws {
        let h = try await makeHarness()
        await #expect(throws: CullingServiceError.afterRowIdInvalid) {
            _ = try await h.impl.listPage(CullingListPageParams(
                sessionId: h.base.sessionId, scope: .all, afterRowId: 0))
        }
        await #expect(throws: CullingServiceError.pageLimitInvalid) {
            _ = try await h.impl.listPage(CullingListPageParams(
                sessionId: h.base.sessionId, scope: .all, limit: 0))
        }
        await #expect(throws: CullingServiceError.pageLimitInvalid) {
            _ = try await h.impl.listPage(CullingListPageParams(
                sessionId: h.base.sessionId, scope: .all, limit: 2001))
        }
        await #expect(throws: CullingCommandsError.invalidRatingsFilter) {
            _ = try await h.impl.listPage(CullingListPageParams(
                sessionId: h.base.sessionId, scope: .filtered,
                filters: CullingFilters(ratings: [7])))
        }
        // groupId 透传到 requestedGroupId：不可解析组走相似度最新页且不报错。
        let page = try await h.impl.listPage(CullingListPageParams(
            sessionId: h.base.sessionId, scope: .similarityGroup, groupId: "9999:0"))
        #expect(page.assets.isEmpty)
    }

    @Test("groups：组内决策计数与成员投影")
    func groupsReturnsDecisionCounts() async throws {
        let h = try await makeHarness()
        for id in ["p1", "p2", "p3"] { try await insertCullingPhoto(h.base.db, id: id) }
        let resultId = try await insertCullingSimilarityResult(h.base, memberships: [
            SimilarityMembership(photoId: "p1", groupIndex: 0),
            SimilarityMembership(photoId: "p2", groupIndex: 0),
            SimilarityMembership(photoId: "p3", groupIndex: 1),
        ])
        try await insertCullingDecision(h.base.db, photoId: "p1", decision: "keep", revision: 1)
        try await insertCullingDecision(h.base.db, photoId: "p3", decision: "reject", revision: 1)

        let groups = try await h.impl.groups(CullingGroupsParams(sessionId: h.base.sessionId))
        #expect(groups.count == 2)
        #expect(groups[0].groupId == "\(resultId):0")
        #expect(groups[0].keepCount == 1)
        #expect(groups[0].pendingCount == 1)
        #expect(groups[0].images.map(\.decision) == [.keep, .pending])
        #expect(groups[1].groupId == "\(resultId):1")
        #expect(groups[1].rejectCount == 1)
    }

    @Test("summary：决策 + 缓存兜底计数")
    func summaryCountsDecisionsAndCache() async throws {
        let h = try await makeHarness()
        for id in ["p1", "p2", "p3"] { try await insertCullingPhoto(h.base.db, id: id) }
        try await insertCullingDecision(
            h.base.db, photoId: "p1", decision: "keep", rating: 5, revision: 2)
        try await insertCullingDecision(
            h.base.db, photoId: "p2", decision: "reject", colorLabel: "Red", revision: 1)
        try await insertCullingMetadata(h.base, photoId: "p3", rating: 3, label: "Blue")
        _ = try await insertCullingSimilarityResult(
            h.base, memberships: [], statsJson: #"{"totalGroups":3}"#)

        let summary = try await h.impl.summary(CullingSummaryParams(sessionId: h.base.sessionId))
        #expect(summary.totalGroups == 3)
        #expect(summary.totalPhotos == 3)
        #expect(summary.kept == 1)
        #expect(summary.rejected == 1)
        #expect(summary.pending == 1)
        #expect(summary.rated == 2)
        #expect(summary.labeled == 2)
    }

    @Test("history：缺省 100 与显式 limit 透传")
    func historyListsOperations() async throws {
        let h = try await makeHarness()
        try await insertCullingPhoto(h.base.db, id: "p1")
        _ = try await h.impl.update(CullingUpdateParams(
            sessionId: h.base.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)))
        _ = try await h.impl.update(CullingUpdateParams(
            sessionId: h.base.sessionId, photoId: "p1", expectedRevision: 1,
            patch: CullingUpdatePatch(rating: 4)))

        let all = try await h.impl.history(CullingHistoryParams(sessionId: h.base.sessionId))
        #expect(all.count == 2)
        #expect(all[0].id > all[1].id, "最新操作在前")
        #expect(all[0].entries.map(\.fields) == [[.rating]])
        #expect(all[1].entries.map(\.fields) == [[.pickState]])

        let latest = try await h.impl.history(CullingHistoryParams(
            sessionId: h.base.sessionId, limit: 1))
        #expect(latest.count == 1)
        #expect(latest[0].id == all[0].id)
    }

    @Test("history：limit 上下界门控")
    func historyRejectsOutOfRangeLimit() async throws {
        let h = try await makeHarness()
        await #expect(throws: CullingCommandsError.historyLimitInvalid) {
            _ = try await h.impl.history(CullingHistoryParams(
                sessionId: h.base.sessionId, limit: 0))
        }
        await #expect(throws: CullingCommandsError.historyLimitInvalid) {
            _ = try await h.impl.history(CullingHistoryParams(
                sessionId: h.base.sessionId, limit: 501))
        }
    }

    @Test("读路径：Store 错误上抛，不静默降级为空")
    func readPathsPropagateStoreErrors() async throws {
        let h = try await makeHarness()
        try await insertCullingPhoto(h.base.db, id: "p1")
        await h.base.db.close()

        await #expect(throws: (any Error).self) {
            _ = try await h.impl.listPage(CullingListPageParams(
                sessionId: h.base.sessionId, scope: .all))
        }
        await #expect(throws: (any Error).self) {
            _ = try await h.impl.groups(CullingGroupsParams(sessionId: h.base.sessionId))
        }
        await #expect(throws: (any Error).self) {
            _ = try await h.impl.summary(CullingSummaryParams(sessionId: h.base.sessionId))
        }
        await #expect(throws: (any Error).self) {
            _ = try await h.impl.history(CullingHistoryParams(sessionId: h.base.sessionId))
        }
    }

    // MARK: - sync 域

    @Test("sync 域：四命令委托与故障上抛")
    func syncCommandsDelegateAndPropagateFailure() async throws {
        let h = try await makeHarness()
        let status = try await h.impl.syncStatus(
            CullingSyncStatusParams(sessionId: h.base.sessionId))
        #expect(status.sessionId == h.base.sessionId)
        _ = try await h.impl.flush(CullingFlushParams(sessionId: h.base.sessionId))
        _ = try await h.impl.retrySync(CullingRetrySyncParams(sessionId: h.base.sessionId))
        try await h.impl.confirmSync(CullingConfirmSyncParams(sessionId: h.base.sessionId))

        #expect(h.base.sync.getSummaryCalls == ["session"])
        #expect(h.base.sync.flushCalls == ["session"])
        #expect(h.base.sync.retryCalls == ["session"])
        #expect(h.base.sync.confirmSyncCalls.count == 1)
        #expect(h.base.sync.confirmSyncCalls[0].sourceModule == "culling")

        let failing = makeFailingSyncImpl(h.base)
        await #expect(throws: FailingSyncPort.Boom.self) {
            _ = try await failing.syncStatus(CullingSyncStatusParams(sessionId: h.base.sessionId))
        }
        await #expect(throws: FailingSyncPort.Boom.self) {
            _ = try await failing.flush(CullingFlushParams(sessionId: h.base.sessionId))
        }
        await #expect(throws: FailingSyncPort.Boom.self) {
            _ = try await failing.retrySync(CullingRetrySyncParams(sessionId: h.base.sessionId))
        }
        await #expect(throws: FailingSyncPort.Boom.self) {
            try await failing.confirmSync(CullingConfirmSyncParams(sessionId: h.base.sessionId))
        }
    }

    // MARK: - update / batch_update / decide_group / apply_history

    @Test("update：单张状态更新返回新状态与历史操作 id")
    func updateAppliesPatch() async throws {
        let h = try await makeHarness()
        try await insertCullingPhoto(h.base.db, id: "p1")

        let result = try await h.impl.update(CullingUpdateParams(
            sessionId: h.base.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(rating: 4)))

        #expect(result.states.count == 1)
        #expect(result.states[0].photoId == "p1")
        #expect(result.states[0].rating == 4)
        #expect(result.states[0].revision == 1)
        #expect(result.historyOperationId != nil)
        #expect(try await h.base.decision("p1")?.rating == 4)
        #expect(await h.base.mutations.queued.count == 1, "rating 进 outbox")
    }

    @Test("update：expectedRevision 非负门控 + 会话归属 / CAS 错误")
    func updateRejectsInvalidRevisionAndMissingPhoto() async throws {
        let h = try await makeHarness()
        try await insertCullingPhoto(h.base.db, id: "p1")

        await #expect(throws: CullingCommandsError.invalidExpectedRevision) {
            _ = try await h.impl.update(CullingUpdateParams(
                sessionId: h.base.sessionId, photoId: "p1", expectedRevision: -1,
                patch: CullingUpdatePatch(rating: 4)))
        }
        await #expect(throws: CullingServiceError.patchInvalid) {
            _ = try await h.impl.update(CullingUpdateParams(
                sessionId: h.base.sessionId, photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch()))
        }
        await #expect(throws: CullingServiceError.photoNotInSession) {
            _ = try await h.impl.update(CullingUpdateParams(
                sessionId: h.base.sessionId, photoId: "missing", expectedRevision: 0,
                patch: CullingUpdatePatch(rating: 4)))
        }
        _ = try await h.impl.update(CullingUpdateParams(
            sessionId: h.base.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(rating: 4)))
        await #expect(throws: CullingServiceError.revisionConflict(expected: 0, current: 1)) {
            _ = try await h.impl.update(CullingUpdateParams(
                sessionId: h.base.sessionId, photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(rating: 5)))
        }
    }

    @Test("batchUpdate：批量落库并共享历史操作 id")
    func batchUpdateAppliesToTargets() async throws {
        let h = try await makeHarness()
        try await insertCullingPhoto(h.base.db, id: "p1")
        try await insertCullingPhoto(h.base.db, id: "p2")

        let results = try await h.impl.batchUpdate(CullingBatchUpdateParams(
            sessionId: h.base.sessionId, photoIds: ["p1", "p2"],
            patch: CullingUpdatePatch(pickState: .rejected)))

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.states.allSatisfy { $0.pickState == .rejected } })
        #expect(Set(results.compactMap(\.historyOperationId)).count == 1, "历史操作 id 共享")
        #expect(try await h.base.decision("p1")?.decision == "reject")
        #expect(try await h.base.decision("p2")?.decision == "reject")
    }

    @Test("batchUpdate：photoIds 上限与空选择错误码")
    func batchUpdateRejectsOversizeAndEmptySelection() async throws {
        let h = try await makeHarness()
        await #expect(throws: CullingServiceError.tooManyPhotoIds) {
            _ = try await h.impl.batchUpdate(CullingBatchUpdateParams(
                sessionId: h.base.sessionId,
                photoIds: (0...CullingQueryBuilder.batchMax).map { "p\($0)" },
                patch: CullingUpdatePatch(pickState: .picked)))
        }
        await #expect(throws: CullingServiceError.ratingOutOfRange) {
            _ = try await h.impl.batchUpdate(CullingBatchUpdateParams(
                sessionId: h.base.sessionId, photoIds: ["p1"],
                patch: CullingUpdatePatch(rating: 7)))
        }
        await #expect(throws: CullingServiceError.emptySelection) {
            _ = try await h.impl.batchUpdate(CullingBatchUpdateParams(
                sessionId: h.base.sessionId, photoIds: [],
                patch: CullingUpdatePatch(pickState: .picked)))
        }
    }

    @Test("decideGroup：整组 K 保留其余拒绝")
    func decideGroupKeepsKRejectsRest() async throws {
        let h = try await makeHarness()
        for id in ["p1", "p2", "p3"] { try await insertCullingPhoto(h.base.db, id: id) }
        let resultId = try await insertCullingSimilarityResult(h.base, memberships: [
            SimilarityMembership(photoId: "p1", groupIndex: 0),
            SimilarityMembership(photoId: "p2", groupIndex: 0),
            SimilarityMembership(photoId: "p3", groupIndex: 0),
        ])

        let results = try await h.impl.decideGroup(CullingDecideGroupParams(
            sessionId: h.base.sessionId, groupId: "\(resultId):0", keepPhotoIds: ["p1"]))

        #expect(results.count == 3)
        #expect(try await h.base.decision("p1")?.decision == "keep")
        #expect(try await h.base.decision("p2")?.decision == "reject")
        #expect(try await h.base.decision("p3")?.decision == "reject")
    }

    @Test("decideGroup：keepPhotoIds 上限与组归属门控")
    func decideGroupRejectsInvalidKeepSet() async throws {
        let h = try await makeHarness()
        try await insertCullingPhoto(h.base.db, id: "p1")
        try await insertCullingPhoto(h.base.db, id: "p2")

        await #expect(throws: CullingServiceError.tooManyKeepPhotoIds) {
            _ = try await h.impl.decideGroup(CullingDecideGroupParams(
                sessionId: h.base.sessionId, groupId: "1:0",
                keepPhotoIds: (0...CullingQueryBuilder.batchMax).map { "p\($0)" }))
        }
        let resultId = try await insertCullingSimilarityResult(h.base, memberships: [
            SimilarityMembership(photoId: "p1", groupIndex: 0),
            SimilarityMembership(photoId: "p2", groupIndex: 0),
        ])
        await #expect(throws: CullingServiceError.keepNotInGroup) {
            _ = try await h.impl.decideGroup(CullingDecideGroupParams(
                sessionId: h.base.sessionId, groupId: "\(resultId):0", keepPhotoIds: ["missing"]))
        }
    }

    @Test("applyHistory：按历史操作 undo 回滚状态")
    func applyHistoryUndoesOperation() async throws {
        let h = try await makeHarness()
        try await insertCullingPhoto(h.base.db, id: "p1")
        let update = try await h.impl.update(CullingUpdateParams(
            sessionId: h.base.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked)))
        let operationId = try #require(update.historyOperationId)

        let results = try await h.impl.applyHistory(CullingHistoryApplyParams(
            sessionId: h.base.sessionId,
            entries: [CullingHistoryApplyEntry(
                photoId: "p1", expectedRevision: update.states[0].revision,
                patch: CullingUpdatePatch(pickState: .rejected))],
            historyOperationId: operationId, direction: .undo))

        #expect(results.count == 1)
        #expect(try await h.base.decision("p1")?.decision == "pending", "undo 恢复 before 快照")
        let history = try await h.impl.history(CullingHistoryParams(sessionId: h.base.sessionId))
        #expect(history.first?.undone == true)
    }

    @Test("applyHistory：entries / expectedRevision / historyOperationId 门控")
    func applyHistoryRejectsInvalidGates() async throws {
        let h = try await makeHarness()
        try await insertCullingPhoto(h.base.db, id: "p1")
        let entry = CullingHistoryApplyEntry(
            photoId: "p1", expectedRevision: 0, patch: CullingUpdatePatch(rating: 3))

        await #expect(throws: CullingCommandsError.invalidEntries) {
            _ = try await h.impl.applyHistory(CullingHistoryApplyParams(
                sessionId: h.base.sessionId, entries: [],
                historyOperationId: 1, direction: .undo))
        }
        await #expect(throws: CullingCommandsError.invalidEntries) {
            _ = try await h.impl.applyHistory(CullingHistoryApplyParams(
                sessionId: h.base.sessionId,
                entries: Array(repeating: entry, count: CullingQueryBuilder.batchMax + 1),
                historyOperationId: 1, direction: .undo))
        }
        await #expect(throws: CullingServiceError.patchInvalid) {
            _ = try await h.impl.applyHistory(CullingHistoryApplyParams(
                sessionId: h.base.sessionId,
                entries: [CullingHistoryApplyEntry(
                    photoId: "p1", expectedRevision: 0, patch: CullingUpdatePatch())],
                historyOperationId: 1, direction: .undo))
        }
        await #expect(throws: CullingCommandsError.invalidEntryExpectedRevision(0)) {
            _ = try await h.impl.applyHistory(CullingHistoryApplyParams(
                sessionId: h.base.sessionId,
                entries: [CullingHistoryApplyEntry(
                    photoId: "p1", expectedRevision: -1,
                    patch: CullingUpdatePatch(rating: 3))],
                historyOperationId: 1, direction: .undo))
        }
        await #expect(throws: CullingCommandsError.invalidHistoryOperationId) {
            _ = try await h.impl.applyHistory(CullingHistoryApplyParams(
                sessionId: h.base.sessionId, entries: [entry],
                historyOperationId: 0, direction: .undo))
        }
        await #expect(throws: CullingServiceError.historyNotFound) {
            _ = try await h.impl.applyHistory(CullingHistoryApplyParams(
                sessionId: h.base.sessionId, entries: [entry],
                historyOperationId: 999, direction: .undo))
        }
    }

    // MARK: - writeback / retry_failed_writeback / finalize_sync / cleanup / reset

    @Test("writeback：confirmed 门控与决策计划执行")
    func writebackGatesAndExecutesPlan() async throws {
        let h = try await makeHarness()
        try await insertCullingPhoto(h.base.db, id: "p1")
        try await insertCullingPhoto(h.base.db, id: "p2")
        try await insertCullingDecision(h.base.db, photoId: "p1", decision: "keep", revision: 1)
        try await insertCullingDecision(h.base.db, photoId: "p2", decision: "reject", revision: 1)
        h.base.writeback.previewItems = [
            makeCullingWritebackItem(id: 1, photoId: "p1", keywords: ["old"]),
            makeCullingWritebackItem(id: 2, photoId: "p2"),
        ]

        await #expect(throws: CullingServiceError.writebackConfirmRequired) {
            _ = try await h.impl.writeback(CullingWritebackParams(
                sessionId: h.base.sessionId, confirmed: false, target: .keyword))
        }
        #expect(h.base.writeback.previewCalls.isEmpty, "未确认无副作用")

        let result = try await h.impl.writeback(CullingWritebackParams(
            sessionId: h.base.sessionId, confirmed: true, target: .keyword))
        #expect(h.base.writeback.previewCalls.count == 1)
        let persisted = try #require(h.base.writeback.persistCalls.first)
        #expect(persisted.map(\.photoId) == ["p1", "p2"])
        #expect(persisted[0].attributes?.keywords == ["old", "culling:keep"], "关键词去重合并")
        #expect(h.base.writeback.executeCalls.count == 1)
        #expect(result.totalAffected == 0)
    }

    @Test("writeback：无决策计划抛 CULLING_NO_DECISIONS")
    func writebackWithoutDecisions() async throws {
        let h = try await makeHarness()
        await #expect(throws: CullingServiceError.noDecisions) {
            _ = try await h.impl.writeback(CullingWritebackParams(
                sessionId: h.base.sessionId, confirmed: true, target: .rating))
        }
    }

    @Test("retryFailedWriteback：confirmed 门控与委托")
    func retryFailedWritebackDelegates() async throws {
        let h = try await makeHarness()
        await #expect(throws: CullingServiceError.writebackRetryConfirmRequired) {
            _ = try await h.impl.retryFailedWriteback(CullingRetryWritebackParams(
                sessionId: h.base.sessionId, confirmed: false))
        }
        #expect(h.base.writeback.retryFailedCalls.isEmpty, "未确认无副作用")

        _ = try await h.impl.retryFailedWriteback(CullingRetryWritebackParams(
            sessionId: h.base.sessionId, confirmed: true))
        #expect(h.base.writeback.retryFailedCalls.map(\.module) == ["culling"])
    }

    @Test("finalizeSync：confirmed 门控与委托")
    func finalizeSyncDelegates() async throws {
        let h = try await makeHarness()
        await #expect(throws: CullingServiceError.finalizeConfirmRequired) {
            _ = try await h.impl.finalizeSync(CullingFinalizeSyncParams(
                sessionId: h.base.sessionId, confirmed: false))
        }
        #expect(h.base.sync.finalizeCalls.isEmpty, "未确认无副作用")

        let summary = try await h.impl.finalizeSync(CullingFinalizeSyncParams(
            sessionId: h.base.sessionId, confirmed: true))
        #expect(summary.sessionId == h.base.sessionId)
        #expect(h.base.sync.finalizeCalls == ["session"])
    }

    @Test("cleanup：confirmed 门控与协调器/写回结果并集")
    func cleanupMergesResults() async throws {
        let h = try await makeHarness()
        await #expect(throws: CullingServiceError.writebackCleanupConfirmRequired) {
            _ = try await h.impl.cleanup(CullingCleanupParams(
                sessionId: h.base.sessionId, confirmed: false))
        }
        h.base.sync.cleanupResult = CleanupResult(deletedCount: 2, errors: ["bg"])
        h.base.writeback.cleanupResult = CleanupResult(deletedCount: 3, errors: ["wb"])

        let result = try await h.impl.cleanup(CullingCleanupParams(
            sessionId: h.base.sessionId, confirmed: true))
        #expect(result.deletedCount == 5)
        #expect(result.errors == ["bg", "wb"])
        #expect(h.base.sync.cleanupCalls.map(\.sourceModule) == ["culling"])
        #expect(h.base.writeback.cleanupCalls.map(\.module) == ["culling"])
    }

    @Test("reset：confirmed 门控与整会话 / 按组清空")
    func resetClearsDecisions() async throws {
        let h = try await makeHarness()
        try await insertCullingPhoto(h.base.db, id: "p1")
        try await insertCullingPhoto(h.base.db, id: "p2")
        try await insertCullingDecision(h.base.db, photoId: "p1", groupId: "1:0", revision: 1)
        try await insertCullingDecision(h.base.db, photoId: "p2", groupId: "2:0", revision: 1)

        await #expect(throws: CullingServiceError.resetConfirmRequired) {
            try await h.impl.reset(CullingResetParams(
                sessionId: h.base.sessionId, confirmed: false))
        }
        #expect(try await h.base.decision("p1") != nil, "未确认不删除")

        try await h.impl.reset(CullingResetParams(
            sessionId: h.base.sessionId, groupId: "1:0", confirmed: true))
        #expect(try await h.base.decision("p1") == nil)
        #expect(try await h.base.decision("p2") != nil, "按组只清该组")

        try await h.impl.reset(CullingResetParams(sessionId: h.base.sessionId, confirmed: true))
        #expect(try await h.base.decision("p2") == nil)
    }
}
