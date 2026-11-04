// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+Delivery.swift
// 交付/写回编排的转发层（#6 S4：方法体已搬进 CullingSyncService）。
// 公开面一字未改，调用方（Live API / 适配器 / 测试）零改动。
import Foundation
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension CullingService {
    /// 同步态读模型（#6 S2 起在 CullingSharedCore）。
    func currentSyncStatus(
        xmpPath: String,
        fallback: MetadataSyncStatus
    ) throws -> MetadataSyncStatus {
        try core.currentSyncStatus(xmpPath: xmpPath, fallback: fallback)
    }

    public func syncStatus(sessionId: String) throws -> MetadataSyncSummary {
        try sync.syncStatus(sessionId: sessionId)
    }

    public func flush(sessionId: String) async throws -> MetadataSyncSummary {
        try await sync.flush(sessionId: sessionId)
    }

    public func retrySync(sessionId: String) async throws -> MetadataSyncSummary {
        try await sync.retrySync(sessionId: sessionId)
    }

    public func finalizeSync(sessionId: String, confirmed: Bool) async throws -> MetadataSyncSummary {
        try await sync.finalizeSync(sessionId: sessionId, confirmed: confirmed)
    }

    public func writeback(
        sessionId: String,
        target: CullingWritebackTarget,
        confirmed: Bool
    ) async throws -> WritebackResult {
        try await sync.writeback(sessionId: sessionId, target: target, confirmed: confirmed)
    }

    public func retryFailedWriteback(sessionId: String, confirmed: Bool) async throws -> WritebackResult {
        try await sync.retryFailedWriteback(sessionId: sessionId, confirmed: confirmed)
    }

    public func confirmSync(sessionId: String) async throws {
        try await sync.confirmSync(sessionId: sessionId)
    }

    public func cleanup(sessionId: String, confirmed: Bool) async throws -> CleanupResult {
        try await sync.cleanup(sessionId: sessionId, confirmed: confirmed)
    }
}

/// #6 S4：决策侧实现这个单方法读端口，交付侧只经它取决策（单向边）。
extension CullingService: CullingDecisionLiteReading {}
