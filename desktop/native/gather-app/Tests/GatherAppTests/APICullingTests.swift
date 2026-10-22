// desktop/native/gather-app/Tests/GatherAppTests/APICullingTests.swift
// Cut 1 / B3a：LiveCullingAPI 的行为测试。
//
// 覆盖：
// - page 的 keyset 分页（limit/nextRowId/total）；
// - update 的修订冲突（CULLING_REVISION_CONFLICT + expected/current 参数）；
// - batchUpdate 的整批单事务结果；
// - decideGroup 的“保留即拒绝其余”语义；
// - 5 个破坏性入口的 Confirmed<T> 边界（reset / cleanup 的 confirmed 由实现
//   固定为 true：若实现丢确认，CullingService 会抛 *_CONFIRM_REQUIRED）；
// - writeback 只经 Confirmed<CullingWritebackInput> 进入写回端口。
// 全部使用内存 SQLite + 迁移 + fake 端口，不触碰 XMP/文件系统；端口替身与
// CullingServiceTests 同一口径（本包不能复用 gather-core 的测试文件）。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

// MARK: - Fake 端口

/// MetadataMutationPort 的替身：本文件的用例只用 pickState 更新，写回不改真实
/// outbox；方法返回可用的最小结果。
private final class CullingTestMutationPort: MetadataMutationPort, @unchecked Sendable {
    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending"
        )
    }

    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending"
        )
    }
}

/// CullingWritebackPort 的替身：只记录 writeback/retry 调用的模块与项，返回注入结果。
/// `items` 同时是 getItems 的读模型：retryFailedWriteback 先按 status="failed"
/// 读失败集、执行后再按 status=nil 读镜像行（与真实执行器同一两段读法）。
private final class CullingTestWritebackPort: CullingWritebackPort {
    var previewItems: [WritebackItem] = []
    var persistCalls: [[WritebackItem]] = []
    var executeCalls: [(sessionId: String, module: String, items: [WritebackItem])] = []
    var items: [WritebackItem] = []
    var retryCalls: [(sessionId: String, module: String)] = []
    var executeResult = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0,
        errors: [], failedItems: [], report: "Written: 0, Failed: 0, Skipped: 0"
    )
    var cleanupResult = CleanupResult(deletedCount: 0, errors: [])

    func preview(
        sessionId: String,
        module: String,
        options: WritebackOptions,
        photoIds: Set<String>?,
        keywordAdditions: [String: [String]]?
    ) async throws -> WritebackPreview {
        WritebackPreview(
            items: previewItems, totalCount: previewItems.count, affectedPhotos: previewItems.count
        )
    }

    func persistAttributes(items: [WritebackItem]) throws {
        persistCalls.append(items)
    }

    func execute(sessionId: String, module: String, items: [WritebackItem]) async throws -> WritebackResult {
        executeCalls.append((sessionId, module, items))
        return executeResult
    }

    func retryFailed(sessionId: String, module: String) async throws -> WritebackResult {
        retryCalls.append((sessionId, module))
        return executeResult
    }

    func getItems(sessionId: String, module: String, status: String?) throws -> [WritebackItem] {
        items.filter { status == nil || $0.xmpStatus == status }
    }

    func confirmSync(sessionId: String, module: String) async throws {}

    func cleanup(sessionId: String, module: String) async throws -> CleanupResult {
        cleanupResult
    }
}

// MARK: - 夹具

private struct CullingAPIFixture {
    let db: DBConnection
    let sessionId: String
    let photoRepo: PhotoRepo
    let decisionRepo: CullingDecisionRepo
    let similarityRepo: SimilarityResultRepo
    let writeback: CullingTestWritebackPort
    let api: LiveCullingAPI

    init() throws {
        let db = try makeGatherTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "B3a", source: "test")
        let photoRepo = PhotoRepo(connection: db)
        let decisionRepo = CullingDecisionRepo(connection: db)
        let similarityRepo = SimilarityResultRepo(connection: db)
        let writeback = CullingTestWritebackPort()
        // 生产装配只包装 旧命令面已有的 CullingService；测试里用同一构造器 +
        // fake 端口，断言 API 边界而不是服务内部。
        let service = CullingService(
            photoRepo: photoRepo,
            cullingDecisionRepo: decisionRepo,
            similarityResultRepo: similarityRepo,
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            connection: db,
            metadataMutations: CullingTestMutationPort(),
            writeback: writeback,
            cullingHistoryRepo: CullingHistoryRepo(connection: db)
        )
        self.db = db
        self.sessionId = session.id
        self.photoRepo = photoRepo
        self.decisionRepo = decisionRepo
        self.similarityRepo = similarityRepo
        self.writeback = writeback
        self.api = LiveCullingAPI(cullingService: service, sessionRepo: sessionRepo)
    }

    /// 返回与输入同序的照片 id（去重跳过项为空串，本文件不构造重复路径）。
    @discardableResult
    func addPhotos(_ names: [String]) throws -> [String] {
        try photoRepo.addPhotos(
            sessionId: sessionId,
            filepaths: names.map { PhotoAddInput(filepath: "/shoot/\($0)", width: 100, height: 100) },
            "test"
        ).ids
    }

    func decision(_ photoId: String) throws -> String? {
        try decisionRepo.getDecision(sessionId: sessionId, photoId: photoId)?.decision
    }

    /// 建一个“全部成员在同一组”的最新相似度结果，返回 culling 的 "resultId:index"。
    @discardableResult
    func addSimilarityGroup(_ photoIds: [String]) throws -> String {
        let resultId = try similarityRepo.replace(
            sessionId: sessionId,
            groupsJson: "{\"groups\":[]}",
            statsJson: "{\"totalGroups\":1}",
            threshold: 10,
            minGroupSize: 2,
            memberships: photoIds.map { (photoId: $0, groupIndex: 0) }
        )
        return "\(resultId):0"
    }

    func writebackItem(_ photoId: String) -> WritebackItem {
        WritebackItem(
            id: 1,
            photoId: photoId,
            photoPath: "/shoot/a.jpg",
            sessionId: sessionId,
            module: "culling",
            keywords: [],
            attributes: nil,
            xmpPath: "/shoot/a.xmp",
            backupPath: "",
            xmpStatus: "pending",
            errorMessage: "",
            attemptCount: 0,
            lastAttemptAt: "2026-01-01T00:00:00.000Z"
        )
    }

    // MARK: - 交付夹具（syncStatus / flush / retrySync / finalizeSync / confirmSync）

    /// 一条「已入队、未写盘」的交付（delivery=pending，culling item=pending）。
    @discardableResult
    func seedPendingDelivery(photoId: String, filepath: String) throws -> DeliveryRow {
        let repo = DeliveryRepo(connection: db)
        let xmpPath = DeliveryPath.sidecar(filepath)
        let row = try repo.createOrGet(xmpPath: xmpPath, photoPath: filepath)
        _ = try repo.upsertItem(
            xmpPath: xmpPath,
            photoId: photoId,
            module: .culling,
            keywords: ["culling:keep"],
            status: .pending
        )
        _ = try repo.linkSession(xmpPath: xmpPath, sessionId: sessionId)
        return row
    }

    /// 一条「已写盘、已确认」的交付（delivery=synced，culling item=synced）。
    /// 走真实状态机 pending → writing → written → synced，不直接改 status 列。
    @discardableResult
    func seedSyncedDelivery(photoId: String, filepath: String) throws -> DeliveryRow {
        let repo = DeliveryRepo(connection: db)
        let xmpPath = DeliveryPath.sidecar(filepath)
        let row = try repo.createOrGet(xmpPath: xmpPath, photoPath: filepath)
        _ = try repo.upsertItem(
            xmpPath: xmpPath,
            photoId: photoId,
            module: .culling,
            keywords: ["culling:keep"],
            status: .written
        )
        guard try repo.markWriting(xmpPath: xmpPath, revision: row.revision) != nil,
              try repo.markWritten(
                  xmpPath: xmpPath,
                  revision: row.revision,
                  baseFingerprint: "",
                  baseValues: .object([:]),
                  backupPath: ""
              ) != nil,
              try repo.linkSession(xmpPath: xmpPath, sessionId: sessionId).id == row.id
        else {
            throw CullingFixtureError.deliveryTransitionFailed
        }
        _ = try repo.confirm(scope: .session, sessionId: sessionId)
        guard let synced = try repo.get(xmpPath), synced.typedStatus == .synced else {
            throw CullingFixtureError.deliveryTransitionFailed
        }
        return synced
    }

    /// 按交付行快照写一条 cleanup intent（prepared 或 fileDone）。
    @discardableResult
    func seedCleanupIntent(
        delivery: DeliveryRow,
        photoPath: String,
        phase: DeliveryIntentPhase = .prepared
    ) throws -> Int64 {
        let intentRepo = DeliveryIntentRepo(connection: db)
        let payload: JSONValue = .object([
            "op": .string("cleanup"),
            "delivery_id": .int(delivery.id),
            "revision": .int(delivery.revision),
            "status": .string(delivery.status),
            "backup_path": .string(delivery.backupPath),
            "photo_path": .string(photoPath),
            "base_fingerprint": .string(delivery.baseFingerprint),
            "module": .string("culling"),
        ])
        let intentId = try intentRepo.prepare(
            kind: .cleanup, xmpPath: delivery.xmpPath, payload: payload)
        if phase != .prepared {
            _ = try intentRepo.advance(id: intentId, to: phase)
        }
        return intentId
    }

    /// 模拟 Capture One 已确认重载（confirm/finalize 的 §5.4-2 门禁）。
    func ackReload(at timestamp: String = "2026-01-01T00:00:00.000Z") throws {
        _ = try db.prepare("UPDATE sessions SET reload_acked_at = ? WHERE id = ?")
            .run([.text(timestamp), .text(sessionId)])
    }
}

private enum CullingFixtureError: Error {
    case deliveryTransitionFailed
}

private func cullingGatherError<T>(_ body: () async throws -> T) async -> GatherError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

// MARK: - 用例

@Suite("B3a Live Culling API")
struct APICullingTests {
    @Test("page：keyset 分页按 limit 取资产，nextRowId 可续页，total 精确")
    func pagePaginates() async throws {
        let fixture = try CullingAPIFixture()
        try fixture.addPhotos(["a.jpg", "b.jpg", "c.jpg"])

        let first = try await fixture.api.page(
            CullingPageQuery(sessionId: fixture.sessionId, scope: .all, limit: 2)
        )
        #expect(first.assets.count == 2)
        #expect(first.total == 3)
        let cursor = try #require(first.nextRowId)

        let second = try await fixture.api.page(
            CullingPageQuery(
                sessionId: fixture.sessionId, scope: .all,
                afterRowId: Int64(cursor), limit: 2
            )
        )
        #expect(second.assets.count == 1)
        #expect(second.total == 3)
        // nextRowId 是“本页最后一组的首 rowid”，不是“还有下一页”的布尔标记；
        // 最后一页也会给出游标，再翻一次才是空页 + nil 游标。
        let tail = try #require(second.nextRowId)

        let exhausted = try await fixture.api.page(
            CullingPageQuery(
                sessionId: fixture.sessionId, scope: .all,
                afterRowId: Int64(tail), limit: 2
            )
        )
        #expect(exhausted.assets.isEmpty)
        #expect(exhausted.nextRowId == nil)
    }

    @Test("update：expectedRevision 冲突返回 CULLING_REVISION_CONFLICT 与 expected/current 参数")
    func updateRevisionConflict() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg"])
        let photoId = try #require(ids.first)

        let updated = try await fixture.api.update(
            CullingUpdateInput(
                sessionId: fixture.sessionId, photoId: photoId,
                expectedRevision: 0, patch: CullingUpdatePatch(pickState: .picked)
            )
        )
        #expect(updated.states.first?.pickState == .picked)
        #expect(try fixture.decision(photoId) == "keep")

        let error = await cullingGatherError {
            try await fixture.api.update(
                CullingUpdateInput(
                    sessionId: fixture.sessionId, photoId: photoId,
                    expectedRevision: 0, patch: CullingUpdatePatch(pickState: .rejected)
                )
            )
        }
        let conflict = try #require(error)
        #expect(conflict.code == .CULLING_REVISION_CONFLICT)
        #expect(conflict.params["expectedRevision"] == "0")
        #expect(conflict.params["currentRevision"] == "1")
        // 冲突不应落库：决策仍是第一次的 keep。
        #expect(try fixture.decision(photoId) == "keep")
    }

    @Test("batchUpdate：整批返回每个照片的状态，且同属一个历史操作")
    func batchUpdateAppliesAll() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg", "b.jpg"])
        #expect(ids.count == 2)

        let results = try await fixture.api.batchUpdate(
            CullingBatchUpdateInput(
                sessionId: fixture.sessionId, photoIds: ids,
                patch: CullingUpdatePatch(pickState: .rejected)
            )
        )
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.states.first?.pickState == .rejected })
        #expect(results[0].historyOperationId != nil)
        #expect(results[0].historyOperationId == results[1].historyOperationId)
    }

    @Test("decideGroup：keep 集合之外的同组成员全部 rejected")
    func decideGroupKeepsOnlySelection() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg", "b.jpg", "c.jpg"])
        let groupId = try fixture.addSimilarityGroup(ids)

        let results = try await fixture.api.decideGroup(
            CullingDecideGroupInput(
                sessionId: fixture.sessionId, groupId: groupId,
                keepPhotoIds: [ids[0]]
            )
        )
        #expect(results.count == 3)
        #expect(try fixture.decision(ids[0]) == "keep")
        #expect(try fixture.decision(ids[1]) == "reject")
        #expect(try fixture.decision(ids[2]) == "reject")
    }

    @Test("破坏性入口只接受 Confirmed<T>：reset/cleanup 的 confirmed 由实现固定为 true")
    func destructiveEntriesRequireConfirmed() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg"])
        let photoId = try #require(ids.first)
        _ = try await fixture.api.update(
            CullingUpdateInput(
                sessionId: fixture.sessionId, photoId: photoId,
                expectedRevision: 0, patch: CullingUpdatePatch(pickState: .picked)
            )
        )

        // 类型层面：CullingAPI.reset/cleanup/... 的形参只能是 Confirmed<T>，
        // 裸 confirmed: Bool 的调用点写不出来（D-011）；运行时：若实现把确认
        // 丢掉（传 false），CullingService 会抛 *_CONFIRM_REQUIRED，本断言失败。
        let reset = try await fixture.api.reset(
            Confirmed(CullingResetInput(sessionId: fixture.sessionId), source: .test)
        )
        #expect(reset)
        #expect(try fixture.decision(photoId) == nil)

        // S5c-2a：culling cleanup 已切 DeliveryCoordinator（module=.culling），
        // 不再合并旧 writeback.cleanup 的结果。本库没有 deliveries → 0；
        // 若实现仍合并旧端口（或忽略 confirmed=false），断言会失败。
        fixture.writeback.cleanupResult = CleanupResult(deletedCount: 2, errors: [])
        let cleanup = try await fixture.api.cleanup(
            Confirmed(SessionReference(sessionId: fixture.sessionId), source: .test)
        )
        #expect(cleanup.deletedCount == 0)
        #expect(cleanup.errors.isEmpty)
    }

    @Test("writeback：经 Confirmed<CullingWritebackInput> 进入写回端口并返回执行结果")
    func writebackThroughConfirmed() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg"])
        let photoId = try #require(ids.first)
        _ = try await fixture.api.update(
            CullingUpdateInput(
                sessionId: fixture.sessionId, photoId: photoId,
                expectedRevision: 0, patch: CullingUpdatePatch(pickState: .picked)
            )
        )

        fixture.writeback.previewItems = [fixture.writebackItem(photoId)]
        fixture.writeback.executeResult = WritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: "Written: 1, Failed: 0, Skipped: 0"
        )

        let result = try await fixture.api.writeback(
            Confirmed(
                CullingWritebackInput(sessionId: fixture.sessionId, target: .keyword),
                source: .test
            )
        )
        #expect(result.written == 1)
        #expect(fixture.writeback.persistCalls.count == 1)
        #expect(fixture.writeback.executeCalls.count == 1)
        #expect(fixture.writeback.executeCalls.first?.module == "culling")
        #expect(fixture.writeback.executeCalls.first?.sessionId == fixture.sessionId)
    }

    // MARK: - R1 P1-2：此前没有 Live 行为测试的 10 个方法

    @Test("history：更新历史按 id 倒序返回字段与撤销标记，limit 收窄最新一条")
    func historyListsOperations() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg", "b.jpg"])

        _ = try await fixture.api.update(
            CullingUpdateInput(
                sessionId: fixture.sessionId, photoId: ids[0],
                expectedRevision: 0, patch: CullingUpdatePatch(pickState: .picked)
            )
        )
        _ = try await fixture.api.update(
            CullingUpdateInput(
                sessionId: fixture.sessionId, photoId: ids[1],
                expectedRevision: 0, patch: CullingUpdatePatch(rating: 4)
            )
        )

        let operations = try await fixture.api.history(
            CullingHistoryQuery(sessionId: fixture.sessionId)
        )
        #expect(operations.count == 2)
        #expect(operations[0].id > operations[1].id)
        #expect(operations[0].undone == false)
        #expect(operations[0].entries.map(\.photoId) == [ids[1]])
        #expect(operations[0].entries.first?.fields == [CullingUpdatePatchField.rating])
        #expect(operations[1].entries.map(\.photoId) == [ids[0]])
        #expect(operations[1].entries.first?.fields == [CullingUpdatePatchField.pickState])

        let limited = try await fixture.api.history(
            CullingHistoryQuery(sessionId: fixture.sessionId, limit: 1)
        )
        #expect(limited.map(\.id) == [operations[0].id])
    }

    @Test("applyHistory：undo 回退到 before、重复 undo 报 CULLING_HISTORY_ALREADY_UNDONE、redo 恢复")
    func applyHistoryUndoRedo() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg"])
        let photoId = try #require(ids.first)

        let updated = try await fixture.api.update(
            CullingUpdateInput(
                sessionId: fixture.sessionId, photoId: photoId,
                expectedRevision: 0, patch: CullingUpdatePatch(pickState: .picked)
            )
        )
        let operationId = try #require(updated.historyOperationId)
        #expect(try fixture.decision(photoId) == "keep")

        // 服务按 historyOperationId + direction 重建 entries；显式 entries 只需
        // 通过输入校验（占位 patch 不会被应用）。
        let input = try CullingApplyHistoryInput(
            sessionId: fixture.sessionId,
            entries: [
                CullingHistoryApplyEntry(
                    photoId: photoId,
                    expectedRevision: 1,
                    patch: CullingUpdatePatch(pickState: .rejected)
                )
            ],
            historyOperationId: operationId,
            direction: .undo
        )
        let undone = try await fixture.api.applyHistory(input)
        #expect(undone.first?.states.first?.pickState == .unreviewed)
        #expect(try fixture.decision(photoId) == "pending")

        let undoAgain = await cullingGatherError {
            try await fixture.api.applyHistory(input)
        }
        #expect(undoAgain?.code == .CULLING_HISTORY_ALREADY_UNDONE)

        let redo = try await fixture.api.applyHistory(
            CullingApplyHistoryInput(
                sessionId: fixture.sessionId,
                entries: input.entries,
                historyOperationId: operationId,
                direction: .redo
            )
        )
        #expect(redo.first?.states.first?.pickState == .picked)
        #expect(try fixture.decision(photoId) == "keep")
    }

    @Test("groups：最新相似度组的成员、组 id 与 keep/reject/pending 计数")
    func groupsReflectDecisions() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg", "b.jpg", "c.jpg"])
        let groupId = try fixture.addSimilarityGroup(ids)

        _ = try await fixture.api.update(
            CullingUpdateInput(
                sessionId: fixture.sessionId, photoId: ids[0],
                expectedRevision: 0, patch: CullingUpdatePatch(pickState: .picked)
            )
        )
        _ = try await fixture.api.update(
            CullingUpdateInput(
                sessionId: fixture.sessionId, photoId: ids[1],
                expectedRevision: 0, patch: CullingUpdatePatch(pickState: .rejected)
            )
        )

        let groups = try await fixture.api.groups(fixture.sessionId)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.groupId == groupId)
        #expect(group.groupIndex == 0)
        #expect(group.images.map(\.photoId).sorted() == ids.sorted())
        #expect(group.images.first?.filename == "a.jpg")
        #expect(group.keepCount == 1)
        #expect(group.rejectCount == 1)
        #expect(group.pendingCount == 1)
        #expect(Set(group.images.map(\.decision.rawValue)) == ["keep", "reject", "pending"])
    }

    @Test("summary：keep/reject/rating/label 计数与相似度组数（唯一真相源）")
    func summaryCounts() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg", "b.jpg", "c.jpg"])
        _ = try fixture.addSimilarityGroup(ids)

        _ = try await fixture.api.update(
            CullingUpdateInput(
                sessionId: fixture.sessionId, photoId: ids[0], expectedRevision: 0,
                patch: CullingUpdatePatch(
                    rating: 5, pickState: .picked, colorLabel: .red
                )
            )
        )
        _ = try await fixture.api.update(
            CullingUpdateInput(
                sessionId: fixture.sessionId, photoId: ids[1],
                expectedRevision: 0, patch: CullingUpdatePatch(pickState: .rejected)
            )
        )

        let summary = try await fixture.api.summary(fixture.sessionId)
        #expect(summary.totalPhotos == 3)
        #expect(summary.kept == 1)
        #expect(summary.rejected == 1)
        #expect(summary.pending == 1)
        #expect(summary.rated == 1)
        #expect(summary.labeled == 1)
        #expect(summary.totalGroups == 1)
    }

    @Test("syncStatus：交付摘要计数 + SessionRepo 注入的 reloadAckedAt 投影")
    func syncStatusProjectsDeliverySummaryAndReloadAck() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg"])
        let photoId = try #require(ids.first)
        let delivery = try fixture.seedPendingDelivery(
            photoId: photoId, filepath: "/shoot/a.jpg")

        let before = try await fixture.api.syncStatus(fixture.sessionId)
        #expect(before.summary.sessionId == fixture.sessionId)
        #expect(before.summary.pending == 1)
        #expect(before.summary.written == 0)
        #expect(before.summary.items.map(\.xmpPath) == [delivery.xmpPath])
        #expect(before.reloadAckedAt == nil)

        let ack = "2026-02-03T04:05:06.000Z"
        try fixture.ackReload(at: ack)
        let after = try await fixture.api.syncStatus(fixture.sessionId)
        #expect(after.reloadAckedAt == ack)
        #expect(after.summary.pending == 1)
    }

    @Test("flush：prepared cleanup intent 回放后交付被删除、摘要归零、intent 成功闭环删除")
    func flushReplaysPreparedCleanupIntent() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg"])
        let photoId = try #require(ids.first)
        let delivery = try fixture.seedSyncedDelivery(
            photoId: photoId, filepath: "/shoot/a.jpg")
        let intentId = try fixture.seedCleanupIntent(
            delivery: delivery, photoPath: "/shoot/a.jpg", phase: .prepared)

        let summary = try await fixture.api.flush(fixture.sessionId)
        #expect(summary.sessionId == fixture.sessionId)
        #expect(summary.synced == 0)
        #expect(summary.items.isEmpty)
        #expect(try DeliveryRepo(connection: fixture.db).get(delivery.xmpPath) == nil)
        // 成功闭环走 finish(error: nil)：intent 行被删除（失败才保留 applied 记录）。
        #expect(
            try DeliveryIntentRepo(connection: fixture.db).get(intentId) == nil,
            "成功回放必须删除 intent 行"
        )
    }

    @Test("retrySync：fileDone intent 只补 DB 段（不重做文件）并清掉交付")
    func retrySyncCompletesFileDoneIntent() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg"])
        let photoId = try #require(ids.first)
        let delivery = try fixture.seedSyncedDelivery(
            photoId: photoId, filepath: "/shoot/a.jpg")
        let intentId = try fixture.seedCleanupIntent(
            delivery: delivery, photoPath: "/shoot/a.jpg", phase: .fileDone)

        let summary = try await fixture.api.retrySync(fixture.sessionId)
        #expect(summary.sessionId == fixture.sessionId)
        #expect(summary.synced == 0)
        #expect(try DeliveryRepo(connection: fixture.db).get(delivery.xmpPath) == nil)
        #expect(
            try DeliveryIntentRepo(connection: fixture.db).get(intentId) == nil,
            "fileDone 回放完成后 intent 行删除"
        )
    }

    @Test("retryFailedWriteback：经 Confirmed 进入写回端口（module=culling）、只收敛失败集并镜像交付")
    func retryFailedWritebackUsesCullingModule() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg"])
        let photoId = try #require(ids.first)
        var failed = fixture.writebackItem(photoId)
        failed.xmpStatus = "failed"
        failed.errorMessage = "WRITEBACK_FAILED"
        fixture.writeback.items = [failed]
        fixture.writeback.executeResult = WritebackResult(
            totalAffected: 1, written: 0, failed: 1, skipped: 0,
            errors: ["WRITEBACK_FAILED"],
            failedItems: [failed], report: "Written: 0, Failed: 1, Skipped: 0"
        )

        let result = try await fixture.api.retryFailedWriteback(
            Confirmed(SessionReference(sessionId: fixture.sessionId), source: .test)
        )
        #expect(result.failed == 1)
        #expect(result.failedItems.map(\.id) == [failed.id])
        #expect(fixture.writeback.retryCalls.count == 1)
        #expect(fixture.writeback.retryCalls.first?.sessionId == fixture.sessionId)
        #expect(fixture.writeback.retryCalls.first?.module == "culling")
        // 执行结果按失败项 id 镜像进交付模型（module=culling）。
        let delivery = try #require(
            try DeliveryRepo(connection: fixture.db).get(failed.xmpPath)
        )
        #expect(delivery.typedStatus == .failed)
        #expect(
            try DeliveryRepo(connection: fixture.db)
                .listItems(sessionId: fixture.sessionId, module: .culling)
                .map(\.typedStatus) == [.failed]
        )
    }

    @Test("finalizeSync：未 ack reload 报 XMP_CONFIRM_REQUIRES_SYNC；ack 后保留 XMP、删交付")
    func finalizeSyncRequiresReloadAckThenDropsDelivery() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg"])
        let photoId = try #require(ids.first)
        let delivery = try fixture.seedSyncedDelivery(
            photoId: photoId, filepath: "/shoot/a.jpg")

        let unacked: Error?
        do {
            _ = try await fixture.api.finalizeSync(
                Confirmed(SessionReference(sessionId: fixture.sessionId), source: .test)
            )
            unacked = nil
        } catch {
            unacked = error
        }
        #expect((unacked as? DeliveryError) == .confirmRequiresSync)
        #expect(try DeliveryRepo(connection: fixture.db).get(delivery.xmpPath) != nil)

        try fixture.ackReload()
        let summary = try await fixture.api.finalizeSync(
            Confirmed(SessionReference(sessionId: fixture.sessionId), source: .test)
        )
        #expect(summary.synced == 0)
        #expect(summary.items.isEmpty)
        // finalize = dropWithoutRestore：DB 行删除，XMP 文件本身不被触碰
        //（夹具路径不在磁盘上，这里断言的是交付行而不是文件内容）。
        #expect(try DeliveryRepo(connection: fixture.db).get(delivery.xmpPath) == nil)
    }

    @Test("confirmSync：未 ack 报 XMP_CONFIRM_REQUIRES_SYNC 且不落确认；ack 后 written→synced")
    func confirmSyncGatesOnReloadAck() async throws {
        let fixture = try CullingAPIFixture()
        let ids = try fixture.addPhotos(["a.jpg"])
        let photoId = try #require(ids.first)
        let delivery = try fixture.seedSyncedDelivery(
            photoId: photoId, filepath: "/shoot/a.jpg")
        let repo = DeliveryRepo(connection: fixture.db)
        // 重新打开为 written：新输入把已确认交付推回“待确认”，供 confirm 观察。
        _ = try repo.mergeInput(
            xmpPath: delivery.xmpPath,
            photoPath: "/shoot/a.jpg",
            expectedRevision: delivery.revision,
            newRevision: delivery.revision + 1,
            baseFingerprint: "",
            baseValues: .object([:])
        )
        _ = try repo.markWriting(xmpPath: delivery.xmpPath, revision: delivery.revision + 1)
        _ = try repo.markWritten(
            xmpPath: delivery.xmpPath, revision: delivery.revision + 1,
            baseFingerprint: "", baseValues: .object([:]), backupPath: ""
        )
        // item 随新输入重新打开：synced → pending → written，confirm 才能观察到迁移。
        _ = try repo.upsertItem(
            xmpPath: delivery.xmpPath, photoId: photoId, module: .culling, status: .pending)
        _ = try repo.upsertItem(
            xmpPath: delivery.xmpPath, photoId: photoId, module: .culling, status: .written)
        _ = try repo.linkSession(xmpPath: delivery.xmpPath, sessionId: fixture.sessionId)

        do {
            _ = try await fixture.api.confirmSync(fixture.sessionId)
            Issue.record("未 ack reload 时 confirmSync 必须失败")
        } catch let error as DeliveryError {
            #expect(error == .confirmRequiresSync)
        }
        let blocked = try #require(try repo.get(delivery.xmpPath))
        #expect(blocked.typedStatus == .written)
        #expect(
            try fixture.db.prepare(
                "SELECT confirmed_at FROM delivery_sessions ds JOIN deliveries d ON d.id = ds.delivery_id WHERE d.xmp_path = ?"
            ).get([.text(delivery.xmpPath)])?[0].textValue == ""
        )

        try fixture.ackReload()
        let confirmed = try await fixture.api.confirmSync(fixture.sessionId)
        #expect(confirmed)
        let synced = try #require(try repo.get(delivery.xmpPath))
        #expect(synced.typedStatus == .synced)
        #expect(
            try repo.listItems(sessionId: fixture.sessionId, module: .culling)
                .allSatisfy { $0.typedStatus == .synced }
        )
        #expect(
            try fixture.db.prepare(
                "SELECT confirmed_at FROM delivery_sessions ds JOIN deliveries d ON d.id = ds.delivery_id WHERE d.xmp_path = ?"
            ).get([.text(delivery.xmpPath)])?[0].textValue?.isEmpty == false
        )
    }
}
