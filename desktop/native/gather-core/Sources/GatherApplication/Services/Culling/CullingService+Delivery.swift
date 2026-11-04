// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+Delivery.swift
// 交付/写回编排的转发层（#6 S4：方法体已搬进 CullingSyncService）。
// 公开面一字未改，调用方（Live API / 适配器 / 测试）零改动。
import Foundation
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension CullingDecisionService {
    /// 同步态读模型（#6 S2 起在 CullingSharedCore）。
    func currentSyncStatus(
        xmpPath: String,
        fallback: MetadataSyncStatus
    ) throws -> MetadataSyncStatus {
        try core.currentSyncStatus(xmpPath: xmpPath, fallback: fallback)
    }








}

/// #6 S4：决策侧实现这个单方法读端口，交付侧只经它取决策（单向边）。
extension CullingDecisionService: CullingDecisionLiteReading {}
