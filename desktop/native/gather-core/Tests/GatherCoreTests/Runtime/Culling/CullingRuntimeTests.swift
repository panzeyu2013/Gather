// Tests/GatherCoreTests/Runtime/Culling/CullingRuntimeTests.swift
// W2b 步骤 5-6：CullingRuntime 读路径 + 写路径行为测试（真实临时库 + fake 端口）。
// 覆盖设计 §3 的关键断言：try? 已消除（缺照片才 photoNotInSession）、JS 过滤后空页
// 仍返回 nextRowId、revision CAS、batch 单事务回滚、错误码映射、schedule 仅
// metadataPatch 非空时调用。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 读路径

@Suite("CullingRuntime 读路径 (W2b)")
struct CullingRuntimeReadTests {

    /// 变体对 + 单张照片 + 决策/缓存/outbox/相似度/人脸/质量 的完整夹具。
    private func makeAssembledHarness() async throws -> (CullingRuntimeHarness, Int64) {
        let harness = try await makeCullingRuntimeHarness(writeOutbox: true)
        try await insertAssetFile(harness.db, id: "af-p2", normalizedPath: "/shoot/p2.jpg")
        try await insertCullingVariantPair(harness.db, assetId: "asset-1")
        try await insertCullingPhoto(harness.db, id: "p2", assetFileId: "af-p2")
        try await insertCullingDecision(
            harness.db, photoId: "asset-1-raw", decision: "keep", rating: 5,
            colorLabel: "Green", revision: 2)
        try await insertCullingMetadata(
            harness, photoId: "p2", rating: 3, label: "Blue", keywords: ["k1"])
        try await insertCullingOutbox(
            harness, photoId: "p2",
            patch: ["source": .string("culling")], status: "conflict")
        let resultId = try await insertCullingSimilarityResult(harness, memberships: [
            SimilarityMembership(photoId: "p2", groupIndex: 0),
        ])
        try await insertCullingFaceObservation(harness.db, photoId: "p2", x: 0.1, y: 0.2, w: 0.5, h: 0.5)
        try await insertCullingFaceObservation(harness.db, photoId: "p2", x: 0.0, y: 0.0, w: 0.2, h: 0.2)
        try await insertCullingQuality(
            harness.db, photoId: "p2", assetFileId: "af-p2",
            resultJSON: #"{"status":"succeeded","qualityScore":0.8}"#)
        return (harness, resultId)
    }

    @Test("list：变体折叠（RAW 首选）+ 状态/缓存/outbox/相似度/人脸/质量富化")
    func listAssemblesFoldedAssets() async throws {
        let (harness, resultId) = try await makeAssembledHarness()
        let assets = try await harness.runtime.list(sessionId: harness.sessionId, scope: .all)

        #expect(assets.count == 2, "变体对折叠为一个逻辑资产")
        let preferred = try #require(assets.first)
        #expect(preferred.photo.id == "asset-1-raw", "RAW 变体首选")
        #expect(preferred.photo.variantCount == 2)
        let variants: [PhotoVariant] = preferred.photo.variants ?? []
        let variantIds = variants.map(\.photoId)
        let variantRoles = variants.map(\.role)
        #expect(variantIds == ["asset-1-raw", "asset-1-jpg"])
        #expect(variantRoles == ["primary", "variant"])
        #expect(preferred.state.pickState == .picked)
        #expect(preferred.state.rating == 5)
        #expect(preferred.state.colorLabel == .green)
        #expect(preferred.state.revision == 2)
        #expect(preferred.xmpPath == TSPath.xmpSidecarPath("/shoot/asset-1.NEF"))
        #expect(preferred.linkedVariantCount == 2, "两条变体共享同一侧车")

        let single = try #require(assets.last)
        #expect(single.photo.id == "p2")
        #expect(single.state.pickState == .unreviewed)
        #expect(single.state.rating == 3, "无决策行时 rating 取缓存兜底")
        #expect(single.state.colorLabel == .blue)
        #expect(single.keywords == ["k1"])
        #expect(single.photo.faceCount == 2)
        #expect(single.faceBboxes.count == 2)
        #expect(single.faceBboxes.first == [0.1, 0.2, 0.5, 0.5], "按面积降序（大脸在前）")
        #expect(single.similarityGroupId == "\(resultId):0")
        #expect(single.quality?.score == 0.8)
        #expect(single.syncStatus == .conflict)
        #expect(single.metadataSource == .culling, "outbox patch.source 解析")
        #expect(single.linkedVariantCount == 1)
    }

    @Test("list：pick/rating/quality/metadataConflictOnly/相似度组 过滤")
    func listFilters() async throws {
        let (harness, resultId) = try await makeAssembledHarness()

        let picked = try await harness.runtime.list(
            sessionId: harness.sessionId, scope: .filtered,
            filters: CullingFilters(pickStates: [.picked]))
        #expect(picked.map(\.photo.id) == ["asset-1-raw"])

        let rated = try await harness.runtime.list(
            sessionId: harness.sessionId, scope: .filtered, filters: CullingFilters(ratings: [3]))
        #expect(rated.map(\.photo.id) == ["p2"])

        let analysed = try await harness.runtime.list(
            sessionId: harness.sessionId, scope: .filtered,
            filters: CullingFilters(qualityStatus: .analysed))
        #expect(analysed.map(\.photo.id) == ["p2"])

        let unanalysed = try await harness.runtime.list(
            sessionId: harness.sessionId, scope: .filtered,
            filters: CullingFilters(qualityStatus: .unanalysed))
        #expect(unanalysed.map(\.photo.id) == ["asset-1-raw"], "无质量行视为未分析")

        let conflicts = try await harness.runtime.list(
            sessionId: harness.sessionId, scope: .filtered,
            filters: CullingFilters(metadataConflictOnly: true))
        #expect(conflicts.map(\.photo.id) == ["p2"], "冲突过滤只在 JS 层（SQL 不下推）")

        let group = try await harness.runtime.list(
            sessionId: harness.sessionId, scope: .similarityGroup,
            requestedGroupId: "\(resultId):0")
        #expect(group.map(\.photo.id) == ["p2"])

        let stale = try await harness.runtime.list(
            sessionId: harness.sessionId, scope: .similarityGroup,
            requestedGroupId: "9999:0")
        #expect(stale.isEmpty)
    }

    @Test("listPage：keyset 分页整组、total 同源、非法入参错误码")
    func listPagePaginatesWholeGroups() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingVariantPair(harness.db, assetId: "asset-1")
        try await insertCullingPhoto(harness.db, id: "p2")
        try await insertCullingPhoto(harness.db, id: "p3")

        let first = try await harness.runtime.listPage(
            sessionId: harness.sessionId, scope: .all, limit: 1)
        #expect(first.assets.map(\.photo.id) == ["asset-1-raw"])
        #expect(first.assets[0].photo.variantCount == 2, "变体同页")
        #expect(first.nextRowId == 1)
        #expect(first.total == 3)

        let second = try await harness.runtime.listPage(
            sessionId: harness.sessionId, scope: .all, afterRowId: 1, limit: 1)
        #expect(second.assets.map(\.photo.id) == ["p2"])
        #expect(second.nextRowId == 3)

        let last = try await harness.runtime.listPage(
            sessionId: harness.sessionId, scope: .all, afterRowId: 3, limit: 1)
        #expect(last.assets.map(\.photo.id) == ["p3"])
        #expect(last.nextRowId == 4)

        let done = try await harness.runtime.listPage(
            sessionId: harness.sessionId, scope: .all, afterRowId: 4, limit: 1)
        #expect(done.assets.isEmpty)
        #expect(done.nextRowId == nil, "末页无游标（不产生死循环）")
        #expect(done.total == 3)

        await #expect(throws: CullingServiceError.afterRowIdInvalid) {
            _ = try await harness.runtime.listPage(
                sessionId: harness.sessionId, scope: .all, afterRowId: 0, limit: 1)
        }
        await #expect(throws: CullingServiceError.pageLimitInvalid) {
            _ = try await harness.runtime.listPage(sessionId: harness.sessionId, scope: .all, limit: 0)
        }
        await #expect(throws: CullingServiceError.pageLimitInvalid) {
            _ = try await harness.runtime.listPage(sessionId: harness.sessionId, scope: .all, limit: 2001)
        }
    }

    @Test("listPage：filtered 下推 + JS 过滤后空页仍返回 nextRowId（防死循环）")
    func listPageEmptyAfterJSFilterStillReturnsCursor() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingVariantPair(harness.db, assetId: "asset-1") // rowid 1/2
        try await insertCullingPhoto(harness.db, id: "p2") // rowid 3
        try await insertCullingPhoto(harness.db, id: "p3") // rowid 4
        try await insertCullingDecision(harness.db, photoId: "asset-1-raw", decision: "keep", rating: 5, revision: 1)
        try await insertCullingDecision(harness.db, photoId: "p2", decision: "keep", rating: 3, revision: 1)
        _ = try await insertCullingSimilarityResult(harness, memberships: [
            SimilarityMembership(photoId: "asset-1-raw", groupIndex: 1),
            SimilarityMembership(photoId: "p2", groupIndex: 0),
            SimilarityMembership(photoId: "p3", groupIndex: 0),
        ])

        let filtered = try await harness.runtime.listPage(
            sessionId: harness.sessionId,
            scope: .filtered,
            filters: CullingFilters(ratings: [5]),
            limit: 10
        )
        #expect(filtered.assets.map(\.photo.id) == ["asset-1-raw"])
        #expect(filtered.total == 1, "count 与 page 同一 scope 编译")

        // 不可解析的组 id：SQL 走 similarityLatest，JS 过滤全部丢弃 → 空页但有游标。
        let empty = try await harness.runtime.listPage(
            sessionId: harness.sessionId,
            scope: .similarityGroup,
            requestedGroupId: "stale-group",
            limit: 1
        )
        #expect(empty.assets.isEmpty, "JS 相似度映射过滤后空页")
        #expect(empty.nextRowId != nil, "空页仍返回 nextRowId（调用方可继续翻页，不死循环）")
        #expect(empty.total == 0, "不可解析组 id 的 total 回退 JS 映射计数")
    }

    @Test("groups：组内决策计数、成员投影、按 groupIndex 升序")
    func groupsCountsAndOrder() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        try await insertCullingPhoto(harness.db, id: "p3")
        let resultId = try await insertCullingSimilarityResult(harness, memberships: [
            SimilarityMembership(photoId: "p1", groupIndex: 0),
            SimilarityMembership(photoId: "p2", groupIndex: 0),
            SimilarityMembership(photoId: "p3", groupIndex: 1),
        ])
        try await insertCullingDecision(harness.db, photoId: "p1", decision: "keep", revision: 1)
        try await insertCullingDecision(harness.db, photoId: "p3", decision: "reject", revision: 1)

        let groups = try await harness.runtime.groups(sessionId: harness.sessionId)
        #expect(groups.count == 2)
        #expect(groups[0].groupId == "\(resultId):0")
        #expect(groups[0].groupIndex == 0)
        #expect(groups[0].keepCount == 1)
        #expect(groups[0].pendingCount == 1)
        #expect(groups[0].images.map(\.decision) == [.keep, .pending])
        #expect(groups[1].groupId == "\(resultId):1")
        #expect(groups[1].rejectCount == 1)
    }

    @Test("groups：无相似度结果返回空")
    func groupsWithoutSimilarity() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        #expect(try await harness.runtime.groups(sessionId: harness.sessionId).isEmpty)
    }

    @Test("summary：决策 + 缓存兜底计数 + totalGroups（含刚完成的写入）")
    func summaryCounts() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        try await insertCullingPhoto(harness.db, id: "p3")
        try await insertCullingDecision(
            harness.db, photoId: "p1", decision: "keep", rating: 5, revision: 2)
        try await insertCullingDecision(
            harness.db, photoId: "p2", decision: "reject", colorLabel: "Red", revision: 1)
        try await insertCullingMetadata(harness, photoId: "p3", rating: 3, label: "Blue")
        _ = try await insertCullingSimilarityResult(
            harness, memberships: [], statsJson: #"{"totalGroups":3}"#)

        let summary = try await harness.runtime.summary(sessionId: harness.sessionId)
        #expect(summary.totalGroups == 3)
        #expect(summary.totalPhotos == 3)
        #expect(summary.kept == 1)
        #expect(summary.rejected == 1)
        #expect(summary.pending == 1)
        #expect(summary.rated == 2)
        #expect(summary.labeled == 2)

        // 写入后不失效缓存也必须新鲜（summary 不走会话缓存）。
        _ = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p3", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked))
        let after = try await harness.runtime.summary(sessionId: harness.sessionId)
        #expect(after.kept == 2)
        #expect(after.pending == 0)
    }

    @Test("history：写入产生的历史操作按 id 倒序")
    func historyListsOperations() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        _ = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked))
        _ = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 1,
            patch: CullingUpdatePatch(rating: 4))

        let history = try await harness.runtime.history(sessionId: harness.sessionId)
        #expect(history.count == 2)
        #expect(history[0].id > history[1].id, "最新操作在前")
        #expect(history[0].entries.map(\.fields) == [[.rating]])
        #expect(history[0].undone == false)
    }

    @Test("invalidateSessionLookup：分析映射立即失效、下一次读取按需重载")
    func invalidateSessionLookupReloadsAnalyses() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertAssetFile(harness.db, id: "af-p1", normalizedPath: "/shoot/p1.jpg")
        try await insertCullingPhoto(harness.db, id: "p1", assetFileId: "af-p1")

        let before = try await harness.runtime.list(sessionId: harness.sessionId, scope: .all)
        #expect(before[0].quality == nil)

        try await insertCullingQuality(
            harness.db, photoId: "p1", assetFileId: "af-p1",
            resultJSON: #"{"status":"succeeded","qualityScore":0.7}"#)

        let cached = try await harness.runtime.list(sessionId: harness.sessionId, scope: .all)
        #expect(cached[0].quality == nil, "版本键未变 → 分析映射命中缓存（旧 TTL 语义由显式失效替代）")

        await harness.runtime.invalidateSessionLookup(sessionId: harness.sessionId)
        let reloaded = try await harness.runtime.list(sessionId: harness.sessionId, scope: .all)
        #expect(reloaded[0].quality?.score == 0.7, "失效后按需重载")
        let counts = await harness.cache.entryCounts
        #expect(counts.lookup >= 1)
    }

    @Test("Store 读错误上抛：会话读取失败绝不被当成空会话（try? 已消除）")
    func listThrowsOnStoreError() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        await harness.db.close()
        await #expect(throws: (any Error).self) {
            _ = try await harness.runtime.list(sessionId: harness.sessionId, scope: .all)
        }
        await #expect(throws: (any Error).self) {
            _ = try await harness.runtime.summary(sessionId: harness.sessionId)
        }
    }
}

// MARK: - 写路径

@Suite("CullingRuntime 写路径 (W2b)")
struct CullingRuntimeWriteTests {

    // MARK: update

    @Test("update pick：资产变体一起更新、revision 递增、无 XMP 副作用")
    func updatePickUpdatesVariants() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingVariantPair(harness.db, assetId: "asset-1")

        let result = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "asset-1-raw", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked))

        #expect(result.states.map(\.photoId) == ["asset-1-raw", "asset-1-jpg"])
        #expect(result.states.allSatisfy { $0.pickState == .picked })
        #expect(result.states.allSatisfy { $0.revision == 1 })
        #expect(result.syncStatus == .clean)
        #expect(result.historyOperationId != nil)
        #expect(result.xmpPath == TSPath.xmpSidecarPath("/shoot/asset-1.NEF"))

        let raw = try #require(try await harness.decision("asset-1-raw"))
        let jpg = try #require(try await harness.decision("asset-1-jpg"))
        #expect(raw.decision == "keep" && raw.revision == 1)
        #expect(jpg.decision == "keep" && jpg.revision == 1)
        let queued = await harness.mutations.queued
        #expect(queued.isEmpty, "pick 不触碰 XMP")
        #expect(harness.sync.scheduled.isEmpty)
    }

    @Test("update rating：缓存列 + outbox 直写 + schedule；提交后回读 outbox 状态")
    func updateRatingWritesOutboxAndSchedules() async throws {
        let harness = try await makeCullingRuntimeHarness(writeOutbox: true)
        try await insertCullingPhoto(harness.db, id: "p1")

        let result = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(rating: 5))

        #expect(result.states[0].rating == 5)
        #expect(result.syncStatus == .pending, "回读写后 outbox 行")
        let cache = try #require(try await harness.metadataStore.metadata(photoId: "p1"))
        #expect(cache.rating == 5)

        let queued = await harness.mutations.queued
        #expect(queued.count == 1)
        #expect(queued[0].values["rating"] == .number(5))
        #expect(queued[0].source == .culling)
        #expect(queued[0].schedule == false, "schedule 由 metadataSync.schedule 单独承担")
        #expect(harness.sync.scheduled == [TSPath.xmpSidecarPath("/shoot/p1.jpg")])
        #expect(try await harness.writebackStore.outboxEntry(
            xmpPath: TSPath.xmpSidecarPath("/shoot/p1.jpg")) != nil)
    }

    @Test("update colorLabel=None → 写盘空标签；label=Red 写枚举值")
    func updateColorLabelEncoding() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")

        _ = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(colorLabel: .none))
        var queued = await harness.mutations.queued
        #expect(queued.last?.values["label"] == .string(""))

        _ = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 1,
            patch: CullingUpdatePatch(colorLabel: .red))
        queued = await harness.mutations.queued
        #expect(queued.last?.values["label"] == .string("Red"))
        let cache = try #require(try await harness.metadataStore.metadata(photoId: "p1"))
        #expect(cache.label == "Red")
    }

    @Test("update：expectedRevision 不匹配抛 CULLING_REVISION_CONFLICT（expected/current）")
    func updateRevisionConflict() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingDecision(harness.db, photoId: "p1", decision: "keep", revision: 1)

        await #expect(throws: CullingServiceError.revisionConflict(expected: 0, current: 1)) {
            _ = try await harness.runtime.update(
                sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(pickState: .picked))
        }
        let row = try #require(try await harness.decision("p1"))
        #expect(row.revision == 1, "冲突不落库")
    }

    @Test("update：同一资产变体 revision 基线不同也各自连续递增（CAS 分组）")
    func updateVariantWithDivergentRevisionBases() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingVariantPair(harness.db, assetId: "asset-1")
        try await insertCullingDecision(
            harness.db, photoId: "asset-1-raw", decision: "keep", revision: 3)
        try await insertCullingDecision(
            harness.db, photoId: "asset-1-jpg", decision: "keep", revision: 0)

        let result = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "asset-1-raw", expectedRevision: 3,
            patch: CullingUpdatePatch(rating: 4))

        #expect(result.states.map(\.revision) == [4, 1], "变体各自以自身基线上推")
        let raw = try #require(try await harness.decision("asset-1-raw"))
        let jpg = try #require(try await harness.decision("asset-1-jpg"))
        #expect(raw.revision == 4 && raw.rating == 4)
        #expect(jpg.revision == 1 && jpg.rating == 4)
    }

    @Test("update：照片不在会话 → CULLING_PHOTO_NOT_IN_SESSION；补丁非法错误码")
    func updateValidation() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")

        await #expect(throws: CullingServiceError.photoNotInSession) {
            _ = try await harness.runtime.update(
                sessionId: harness.sessionId, photoId: "missing", expectedRevision: 0,
                patch: CullingUpdatePatch(pickState: .picked))
        }
        await #expect(throws: CullingServiceError.patchInvalid) {
            _ = try await harness.runtime.update(
                sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch())
        }
        await #expect(throws: CullingServiceError.ratingOutOfRange) {
            _ = try await harness.runtime.update(
                sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
                patch: CullingUpdatePatch(rating: 3.5))
        }
    }

    // MARK: batchUpdate

    @Test("batchUpdate：同资产变体合并为一条操作，历史操作 id 共享")
    func batchUpdateCoalescesAssetPick() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingVariantPair(harness.db, assetId: "asset-1")

        let results = try await harness.runtime.batchUpdate(
            sessionId: harness.sessionId,
            photoIds: ["asset-1-raw", "asset-1-jpg", "asset-1-raw"],
            patch: CullingUpdatePatch(pickState: .picked))

        #expect(results.count == 1)
        #expect(results[0].states.map(\.photoId) == ["asset-1-raw", "asset-1-jpg"])
        #expect(results[0].states.allSatisfy { $0.pickState == .picked })
        #expect(results[0].historyOperationId != nil)
        #expect(try await harness.decision("asset-1-raw")?.revision == 1)
        #expect(try await harness.decision("asset-1-jpg")?.revision == 1)
        #expect(await harness.mutations.queued.isEmpty)
    }

    @Test("batchUpdate：共享侧车的 rating 只入队一次 outbox")
    func batchUpdateCoalescesSharedMetadata() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingVariantPair(harness.db, assetId: "asset-1")

        let results = try await harness.runtime.batchUpdate(
            sessionId: harness.sessionId,
            photoIds: ["asset-1-raw", "asset-1-jpg"],
            patch: CullingUpdatePatch(rating: 5))

        #expect(results.count == 1)
        #expect(results[0].xmpPath == TSPath.xmpSidecarPath("/shoot/asset-1.NEF"))
        #expect(try await harness.decision("asset-1-raw")?.rating == 5)
        #expect(try await harness.decision("asset-1-jpg")?.rating == 5)
        #expect(await harness.mutations.queued.count == 1, "共享侧车合并为一次 XMP 操作")
        #expect(harness.sync.scheduled.count == 1)
        let rawCache = try #require(try await harness.metadataStore.metadata(photoId: "asset-1-raw"))
        let jpgCache = try #require(try await harness.metadataStore.metadata(photoId: "asset-1-jpg"))
        #expect(rawCache.rating == 5 && jpgCache.rating == 5, "派生缓存列对受影响照片都写")
    }

    @Test("batchUpdate：混合 revision 基线不误报冲突（分组 CAS）")
    func batchUpdateMixedRevisionBases() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        try await insertCullingDecision(harness.db, photoId: "p1", decision: "keep", revision: 2)
        try await insertCullingDecision(harness.db, photoId: "p2", decision: "pending", revision: 0)

        let results = try await harness.runtime.batchUpdate(
            sessionId: harness.sessionId, photoIds: ["p1", "p2"],
            patch: CullingUpdatePatch(pickState: .picked))

        #expect(results.count == 2)
        #expect(try await harness.decision("p1")?.revision == 3)
        #expect(try await harness.decision("p2")?.revision == 1)
    }

    @Test("batchUpdate：空选择/陈旧照片/超限/补丁非法错误码")
    func batchUpdateValidation() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "known")

        await #expect(throws: CullingServiceError.emptySelection) {
            _ = try await harness.runtime.batchUpdate(
                sessionId: harness.sessionId, photoIds: [], patch: CullingUpdatePatch(rating: 5))
        }
        await #expect(throws: CullingServiceError.photosNotInSession) {
            _ = try await harness.runtime.batchUpdate(
                sessionId: harness.sessionId, photoIds: ["known", "stale"],
                patch: CullingUpdatePatch(rating: 5))
        }
        await #expect(throws: CullingServiceError.tooManyPhotoIds) {
            _ = try await harness.runtime.batchUpdate(
                sessionId: harness.sessionId,
                photoIds: (0...CullingQueryBuilder.batchMax).map { "p\($0)" },
                patch: CullingUpdatePatch(rating: 5))
        }
        await #expect(throws: CullingServiceError.invalidPickState) {
            _ = try await harness.runtime.batchUpdate(
                sessionId: harness.sessionId, photoIds: ["known"],
                patch: CullingUpdatePatch(pickState: .unreviewed))
        }
    }

    // MARK: applyHistory

    @Test("applyHistory：显式条目应用补丁并追加历史操作")
    func applyHistoryExplicitEntries() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        _ = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(rating: 5))

        let results = try await harness.runtime.applyHistory(
            sessionId: harness.sessionId,
            requestedEntries: [CullingHistoryApplyEntry(
                photoId: "p1", expectedRevision: 1,
                patch: CullingUpdatePatch(rating: 3))])

        #expect(results.count == 1)
        #expect(results[0].states[0].rating == 3)
        #expect(results[0].states[0].revision == 2)
        #expect(results[0].historyOperationId != nil)
        #expect(try await harness.decision("p1")?.rating == 3)
        #expect(await harness.mutations.queued.count == 2)
        #expect(harness.sync.scheduled.count == 2, "rating 补丁每条目一次 schedule")
    }

    @Test("applyHistory：空条目空数组、重复照片、revision 冲突、未知操作 id")
    func applyHistoryValidation() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        _ = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked))

        let empty = try await harness.runtime.applyHistory(
            sessionId: harness.sessionId, requestedEntries: [])
        #expect(empty.isEmpty)

        let entry = CullingHistoryApplyEntry(
            photoId: "p1", expectedRevision: 1, patch: CullingUpdatePatch(rating: 4))
        await #expect(throws: CullingServiceError.historyDuplicatePhotos) {
            _ = try await harness.runtime.applyHistory(
                sessionId: harness.sessionId, requestedEntries: [entry, entry])
        }
        await #expect(throws: CullingServiceError.revisionConflict(expected: 0, current: 1)) {
            _ = try await harness.runtime.applyHistory(
                sessionId: harness.sessionId,
                requestedEntries: [CullingHistoryApplyEntry(
                    photoId: "p1", expectedRevision: 0, patch: CullingUpdatePatch(rating: 4))])
        }
        await #expect(throws: CullingServiceError.historyNotFound) {
            _ = try await harness.runtime.applyHistory(
                sessionId: harness.sessionId, requestedEntries: [],
                historyOperationId: 999, direction: .undo)
        }
    }

    @Test("applyHistory undo/redo：恢复 before/after 快照并翻转 undone 标志")
    func applyHistoryUndoRedo() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        let applied = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked))
        let operationId = try #require(applied.historyOperationId)

        let undone = try await harness.runtime.applyHistory(
            sessionId: harness.sessionId, requestedEntries: [],
            historyOperationId: operationId, direction: .undo)
        #expect(undone.count == 1)
        #expect(undone[0].states[0].pickState == .unreviewed)
        #expect(undone[0].states[0].revision == 2)
        #expect(undone[0].historyOperationId == operationId)
        let undoneRow = try #require(try await harness.decision("p1"))
        #expect(undoneRow.decision == "pending" && undoneRow.revision == 2)

        let redone = try await harness.runtime.applyHistory(
            sessionId: harness.sessionId, requestedEntries: [],
            historyOperationId: operationId, direction: .redo)
        #expect(redone[0].states[0].pickState == .picked)
        #expect(redone[0].states[0].revision == 3)
        #expect(try await harness.decision("p1")?.decision == "keep")
        #expect(try await harness.decision("p1")?.revision == 3)
    }

    @Test("applyHistory：重复 undo / 未 undo 就 redo 的错误映射")
    func applyHistoryDirectionErrors() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        let applied = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked))
        let operationId = try #require(applied.historyOperationId)

        await #expect(throws: CullingServiceError.historyNotUndone) {
            _ = try await harness.runtime.applyHistory(
                sessionId: harness.sessionId, requestedEntries: [],
                historyOperationId: operationId, direction: .redo)
        }
        _ = try await harness.runtime.applyHistory(
            sessionId: harness.sessionId, requestedEntries: [],
            historyOperationId: operationId, direction: .undo)
        await #expect(throws: CullingServiceError.historyAlreadyUndone) {
            _ = try await harness.runtime.applyHistory(
                sessionId: harness.sessionId, requestedEntries: [],
                historyOperationId: operationId, direction: .undo)
        }
    }

    @Test("applyHistory：当前状态偏离快照抛 historyDiverged；损坏历史载荷映射 historyNotFound")
    func applyHistoryDivergenceAndCorruption() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        let applied = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked))
        let operationId = try #require(applied.historyOperationId)

        // 手工把决策改成 reject（快照 after 是 picked）→ undo 分歧。
        try await harness.db.run(
            "UPDATE culling_decisions SET decision = 'reject', revision = revision + 1 WHERE photo_id = 'p1'")
        await #expect(throws: CullingServiceError.historyDiverged) {
            _ = try await harness.runtime.applyHistory(
                sessionId: harness.sessionId, requestedEntries: [],
                historyOperationId: operationId, direction: .undo)
        }

        // 损坏 operation_json → CullingStoreError.historyCorrupt → historyNotFound。
        try await harness.db.run(
            "UPDATE culling_history SET operation_json = 'not json' WHERE id = ?",
            [.int(Int64(operationId))])
        await #expect(throws: CullingServiceError.historyNotFound) {
            _ = try await harness.runtime.applyHistory(
                sessionId: harness.sessionId, requestedEntries: [],
                historyOperationId: operationId, direction: .undo)
        }
    }

    @Test("applyHistory：非最新历史操作的 undo 映射 historyAlreadyUndone（Store 边界映射）")
    func applyHistoryUndoNotLatestMapping() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        let first = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 0,
            patch: CullingUpdatePatch(pickState: .picked))
        _ = try await harness.runtime.update(
            sessionId: harness.sessionId, photoId: "p1", expectedRevision: 1,
            patch: CullingUpdatePatch(rating: 5))
        let firstOperationId = try #require(first.historyOperationId)

        await #expect(throws: CullingServiceError.historyAlreadyUndone) {
            _ = try await harness.runtime.applyHistory(
                sessionId: harness.sessionId, requestedEntries: [],
                historyOperationId: firstOperationId, direction: .undo)
        }
    }

    // MARK: decideGroup / reset

    @Test("decideGroup：K 保留 + 其余拒绝，全部带组 id")
    func decideGroupKeepsKRejectsRest() async throws {
        let harness = try await makeCullingRuntimeHarness()
        for id in ["p1", "p2", "p3", "p4"] {
            try await insertCullingPhoto(harness.db, id: id)
        }
        let resultId = try await insertCullingSimilarityResult(harness, memberships: [
            SimilarityMembership(photoId: "p1", groupIndex: 0),
            SimilarityMembership(photoId: "p2", groupIndex: 0),
            SimilarityMembership(photoId: "p3", groupIndex: 0),
            SimilarityMembership(photoId: "p4", groupIndex: 0),
        ])

        let results = try await harness.runtime.decideGroup(
            sessionId: harness.sessionId, groupId: "\(resultId):0",
            keepPhotoIds: ["p1", "p3"])

        #expect(results.count == 4)
        #expect(try await harness.decision("p1")?.decision == "keep")
        #expect(try await harness.decision("p3")?.decision == "keep")
        #expect(try await harness.decision("p2")?.decision == "reject")
        #expect(try await harness.decision("p4")?.decision == "reject")
        #expect(try await harness.decision("p2")?.groupId == "\(resultId):0")
    }

    @Test("decideGroup：noSimilarity / groupTooSmall / keepNotInGroup / tooManyKeepPhotoIds")
    func decideGroupErrors() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")

        await #expect(throws: CullingServiceError.noSimilarity) {
            _ = try await harness.runtime.decideGroup(
                sessionId: harness.sessionId, groupId: "1:0", keepPhotoIds: ["p1"])
        }
        await #expect(throws: CullingServiceError.tooManyKeepPhotoIds) {
            _ = try await harness.runtime.decideGroup(
                sessionId: harness.sessionId, groupId: "1:0",
                keepPhotoIds: (0...CullingQueryBuilder.batchMax).map { "p\($0)" })
        }

        let resultId = try await insertCullingSimilarityResult(harness, memberships: [
            SimilarityMembership(photoId: "p1", groupIndex: 0),
            SimilarityMembership(photoId: "p2", groupIndex: 0),
        ])
        await #expect(throws: CullingServiceError.groupTooSmall) {
            _ = try await harness.runtime.decideGroup(
                sessionId: harness.sessionId, groupId: "\(resultId):9", keepPhotoIds: ["p1"])
        }
        await #expect(throws: CullingServiceError.keepNotInGroup) {
            _ = try await harness.runtime.decideGroup(
                sessionId: harness.sessionId, groupId: "\(resultId):0", keepPhotoIds: [])
        }
        await #expect(throws: CullingServiceError.keepNotInGroup) {
            _ = try await harness.runtime.decideGroup(
                sessionId: harness.sessionId, groupId: "\(resultId):0",
                keepPhotoIds: ["p1", "p2"])
        }
        await #expect(throws: CullingServiceError.keepNotInGroup) {
            _ = try await harness.runtime.decideGroup(
                sessionId: harness.sessionId, groupId: "\(resultId):0", keepPhotoIds: ["missing"])
        }
    }

    @Test("reset / resetCommand：整会话与按组清空；confirmed 守卫")
    func resetClearsDecisions() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        try await insertCullingDecision(harness.db, photoId: "p1", groupId: "1:0", revision: 1)
        try await insertCullingDecision(harness.db, photoId: "p2", groupId: "2:0", revision: 1)

        await #expect(throws: CullingServiceError.resetConfirmRequired) {
            try await harness.runtime.resetCommand(
                sessionId: harness.sessionId, confirmed: false)
        }
        try await harness.runtime.reset(sessionId: harness.sessionId, groupId: "1:0")
        #expect(try await harness.decision("p1") == nil)
        #expect(try await harness.decision("p2") != nil)

        try await harness.runtime.resetCommand(sessionId: harness.sessionId, confirmed: true)
        #expect(try await harness.decision("p2") == nil)
    }

    // MARK: 委托命令面

    @Test("sync 委托：syncStatus/flush/retrySync/finalizeSync 与 confirm 守卫")
    func syncDelegates() async throws {
        let harness = try await makeCullingRuntimeHarness()

        _ = try await harness.runtime.syncStatus(sessionId: harness.sessionId)
        _ = try await harness.runtime.flush(sessionId: harness.sessionId)
        _ = try await harness.runtime.retrySync(sessionId: harness.sessionId)
        _ = try await harness.runtime.finalizeSync(sessionId: harness.sessionId, confirmed: true)
        #expect(harness.sync.getSummaryCalls == ["session"])
        #expect(harness.sync.flushCalls == ["session"])
        #expect(harness.sync.retryCalls == ["session"])
        #expect(harness.sync.finalizeCalls == ["session"])

        await #expect(throws: CullingServiceError.finalizeConfirmRequired) {
            _ = try await harness.runtime.finalizeSync(sessionId: harness.sessionId, confirmed: false)
        }
        await #expect(throws: CullingServiceError.writebackRetryConfirmRequired) {
            _ = try await harness.runtime.retryFailedWriteback(
                sessionId: harness.sessionId, confirmed: false)
        }
        await #expect(throws: CullingServiceError.writebackCleanupConfirmRequired) {
            _ = try await harness.runtime.cleanup(sessionId: harness.sessionId, confirmed: false)
        }
    }

    @Test("confirmSync：无写回项只确认协调器；有写回项再确认写回")
    func confirmSyncDelegates() async throws {
        let harness = try await makeCullingRuntimeHarness()

        try await harness.runtime.confirmSync(sessionId: harness.sessionId)
        #expect(harness.sync.confirmSyncCalls.count == 1)
        #expect(harness.writeback.confirmSyncCalls.isEmpty)

        harness.writeback.getItemsResult = [makeCullingWritebackItem(id: 1, photoId: "p1")]
        try await harness.runtime.confirmSync(sessionId: harness.sessionId)
        #expect(harness.sync.confirmSyncCalls.count == 2)
        #expect(harness.writeback.confirmSyncCalls.map(\.module) == ["culling"])
    }

    @Test("cleanup：协调器 + 写回结果并集")
    func cleanupDelegates() async throws {
        let harness = try await makeCullingRuntimeHarness()
        harness.sync.cleanupResult = CleanupResult(deletedCount: 2, errors: ["bg"])
        harness.writeback.cleanupResult = CleanupResult(deletedCount: 3, errors: ["wb"])

        let result = try await harness.runtime.cleanup(
            sessionId: harness.sessionId, confirmed: true)
        #expect(result.deletedCount == 5)
        #expect(result.errors == ["bg", "wb"])
        #expect(harness.sync.cleanupCalls.map(\.sourceModule) == ["culling"])
        #expect(harness.writeback.cleanupCalls.map(\.module) == ["culling"])
    }

    @Test("writeback：决策计划 + 关键词合并 + preview/persist/execute；空计划报错")
    func writebackCommand() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        try await insertCullingPhoto(harness.db, id: "p2")
        try await insertCullingDecision(harness.db, photoId: "p1", decision: "keep", revision: 1)
        try await insertCullingDecision(harness.db, photoId: "p2", decision: "reject", revision: 1)
        harness.writeback.previewItems = [
            makeCullingWritebackItem(id: 1, photoId: "p1", keywords: ["old"]),
            makeCullingWritebackItem(id: 2, photoId: "p2"),
            makeCullingWritebackItem(id: nil, photoId: "missing"),
        ]

        let result = try await harness.runtime.writeback(
            sessionId: harness.sessionId, target: .keyword, confirmed: true)

        #expect(harness.writeback.previewCalls.count == 1)
        #expect(harness.writeback.previewCalls[0].photoIds == Set(["p1", "p2"]))
        let persisted = try #require(harness.writeback.persistCalls.first)
        #expect(persisted.count == 2, "无 id 的 preview 项不进入写回")
        #expect(persisted[0].attributes?.keywords == ["old", "culling:keep"], "关键词去重合并")
        #expect(persisted[1].attributes?.keywords == ["culling:reject"])
        #expect(harness.writeback.executeCalls.count == 1)
        #expect(result.totalAffected == 0)

        await #expect(throws: CullingServiceError.writebackConfirmRequired) {
            _ = try await harness.runtime.writeback(
                sessionId: harness.sessionId, target: .rating, confirmed: false)
        }
    }

    @Test("writeback：无决策计划抛 CULLING_NO_DECISIONS")
    func writebackWithoutDecisions() async throws {
        let harness = try await makeCullingRuntimeHarness()
        try await insertCullingPhoto(harness.db, id: "p1")
        await #expect(throws: CullingServiceError.noDecisions) {
            _ = try await harness.runtime.writeback(
                sessionId: harness.sessionId, target: .rating, confirmed: true)
        }
    }
}
