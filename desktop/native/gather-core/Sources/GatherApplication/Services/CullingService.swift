// desktop/native/gather-core/Sources/GatherApplication/Services/CullingService.swift
// 挑片域的**组合门面**（#6 拆分 S5 第二阶段）。
//
// 为什么保留它：调用方（Host 的 LiveCullingAPI、6 处构造点、60+ 测试）只认识
// `CullingService`。门面把决策服务与交付服务组在一起，公开面与拆分前**逐字一致**，
// 因此拆分对调用方是零改动。
//
// 门面自身不持有任何仓储：只有两个字段（decision / sync），也不吞异常、不改语义——
// 每个方法都是一行转发。这条约束由 `CullingSplitContractTests` 的 Mirror 断言守住
// （children == 2）。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherDelivery

public final class CullingService {
    let decision: CullingDecisionService
    let sync: CullingSyncService

    public init(decision: CullingDecisionService, sync: CullingSyncService) {
        self.decision = decision
        self.sync = sync
    }
    public func getUpdateContext(sessionId: String) throws -> CullingUpdateContext {
        try self.decision.getUpdateContext(sessionId: sessionId)
    }
    public func updateState(
        sessionId: String,
        photoId: String,
        expectedRevision: Int,
        patch: CullingUpdatePatch,
        context: CullingUpdateContext? = nil,
        preloadedDecision: CullingDecisionRow? = nil,
        preloadedSyncStatus: MetadataSyncStatus? = nil,
        preloadedDecisionRows: [String: CullingDecisionRow]? = nil,
        preloadedCacheRows: [String: MetadataCacheRow]? = nil,
        source: CullingDecisionSource = .manual
    ) throws -> CullingUpdateResult {
        try self.decision.updateState(sessionId: sessionId, photoId: photoId, expectedRevision: expectedRevision, patch: patch, context: context, preloadedDecision: preloadedDecision, preloadedSyncStatus: preloadedSyncStatus, preloadedDecisionRows: preloadedDecisionRows, preloadedCacheRows: preloadedCacheRows, source: source)
    }
    public func batchUpdate(
        sessionId: String,
        photoIds: [String],
        patch: CullingUpdatePatch
    ) throws -> [CullingUpdateResult] {
        try self.decision.batchUpdate(sessionId: sessionId, photoIds: photoIds, patch: patch)
    }
    public func applyImportedPicks(
        sessionId: String,
        photoIds: [String]
    ) throws -> (results: [CullingUpdateResult], failed: Int, appliedPhotoIds: [String]) {
        try self.decision.applyImportedPicks(sessionId: sessionId, photoIds: photoIds)
    }
    public func flushQueuedMetadata(sessionId: String) async throws {
        try await self.decision.flushQueuedMetadata(sessionId: sessionId)
    }
    public func applyHistory(
        sessionId: String,
        requestedEntries: [CullingHistoryApplyEntry],
        historyOperationId: Int? = nil,
        direction: CullingHistoryDirection? = nil,
        source: CullingDecisionSource = .manual
    ) throws -> [CullingUpdateResult] {
        try self.decision.applyHistory(sessionId: sessionId, requestedEntries: requestedEntries, historyOperationId: historyOperationId, direction: direction, source: source)
    }
    public func decideSimilarityGroup(
        sessionId: String,
        groupId: String,
        keepPhotoIds: [String]
    ) throws -> [CullingUpdateResult] {
        try self.decision.decideSimilarityGroup(sessionId: sessionId, groupId: groupId, keepPhotoIds: keepPhotoIds)
    }
    public func decide(sessionId: String, photoId: String, decision: CullingDecisionValue) throws {
        try self.decision.decide(sessionId: sessionId, photoId: photoId, decision: decision)
    }
    public func batchDecide(sessionId: String, photoIds: [String], decision: CullingDecisionValue) throws {
        try self.decision.batchDecide(sessionId: sessionId, photoIds: photoIds, decision: decision)
    }
    public func reset(sessionId: String, groupId: String? = nil) throws {
        try self.decision.reset(sessionId: sessionId, groupId: groupId)
    }
    public func resetCommand(sessionId: String, groupId: String? = nil, confirmed: Bool) throws {
        try self.decision.resetCommand(sessionId: sessionId, groupId: groupId, confirmed: confirmed)
    }
    public func syncStatus(sessionId: String) throws -> MetadataSyncSummary {
        try self.sync.syncStatus(sessionId: sessionId)
    }
    public func flush(sessionId: String) async throws -> MetadataSyncSummary {
        try await self.sync.flush(sessionId: sessionId)
    }
    public func retrySync(sessionId: String) async throws -> MetadataSyncSummary {
        try await self.sync.retrySync(sessionId: sessionId)
    }
    public func finalizeSync(sessionId: String, confirmed: Bool) async throws -> MetadataSyncSummary {
        try await self.sync.finalizeSync(sessionId: sessionId, confirmed: confirmed)
    }
    public func writeback(
        sessionId: String,
        target: CullingWritebackTarget,
        confirmed: Bool
    ) async throws -> WritebackResult {
        try await self.sync.writeback(sessionId: sessionId, target: target, confirmed: confirmed)
    }
    public func retryFailedWriteback(sessionId: String, confirmed: Bool) async throws -> WritebackResult {
        try await self.sync.retryFailedWriteback(sessionId: sessionId, confirmed: confirmed)
    }
    public func confirmSync(sessionId: String) async throws {
        try await self.sync.confirmSync(sessionId: sessionId)
    }
    public func cleanup(sessionId: String, confirmed: Bool) async throws -> CleanupResult {
        try await self.sync.cleanup(sessionId: sessionId, confirmed: confirmed)
    }
    public func listPage(_ query: CullingPageQuery) throws -> CullingPage {
        try self.decision.listPage(query)
    }
    public func selectableIds(_ query: CullingSelectionQuery) throws -> CullingSelectionIds {
        try self.decision.selectableIds(query)
    }
    public func list(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        requestedGroupId: String? = nil
    ) throws -> [CullingAsset] {
        try self.decision.list(sessionId: sessionId, scope: scope, filters: filters, requestedGroupId: requestedGroupId)
    }
    public func getGroups(sessionId: String) throws -> [CullingGroup] {
        try self.decision.getGroups(sessionId: sessionId)
    }
    public func getDecisions(sessionId: String) throws -> [CullingDecisionLiteRow] {
        try self.decision.getDecisions(sessionId: sessionId)
    }
    public func getHistory(sessionId: String, limit: Int = 100) throws -> [CullingHistoryOperation] {
        try self.decision.getHistory(sessionId: sessionId, limit: limit)
    }
    public func getSummary(sessionId: String) throws -> CullingSummary {
        try self.decision.getSummary(sessionId: sessionId)
    }
    public func updateSelection(
        _ input: CullingSelectionUpdateInput
    ) throws -> CullingSelectionUpdateResult {
        try self.decision.updateSelection(input)
    }

}
