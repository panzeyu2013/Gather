// desktop/native/gather-core/Sources/GatherDelivery/Ports/FeatureDeliveryPorts.swift
// WP2b：面向 feature 的旧端口（Culling / FaceKw / Similarity）。
//
// 这些协议由 Domain 服务以 existential 持有、由测试替身直接实现，因此保留原样
// （方法与语义不变）；生产实现改为一个 CoordinatorDeliveryAdapter：
// 旧端口的 14 个名字在此文件转发到 5 个 DeliveryModuleAdapter 方法，
// Coordinator 本身不再声明任何模块方法。
//
// 下一刀（WP2c 接线完成后）可把服务改为直接持 any DeliveryModuleAdapter，
// 删除本文件的 14 个转发；当前保留是为了 feature 调用点与既有测试零改动。

import Foundation
import GatherPersistence
import GatherProtocol

/// CullingService 的交付面：module 固定为 .culling。
///
/// 为什么不直接注入 DeliveryCoordinator：
/// 1. 调用点不应重复传模块常量，也不该拿到 face/similarity 的入口（越权面）；
/// 2. 测试可注入替身，验证「调用了确认/清理」而不必复刻 coordinator 的全部依赖。
public protocol CullingDeliveryPort: Sendable {
    /// 确认本会话在本模块下的已写交付（单事务；跨会话阻塞见返回值）。
    func confirmCulling(sessionId: String) throws -> DeliveryConfirmSummary
    /// 清理本会话在本模块下已确认（synced）的交付（恢复备份后物理删行）。
    func cleanupCulling(sessionId: String) async throws -> DeliveryCleanupSummary
    /// 保留 XMP 并结束（丢备份、删交付行；绝不 restore）。
    func finalizeCulling(sessionId: String) async throws -> DeliveryFinalizeSummary
    /// 旧 WritebackService 执行结果 → 交付镜像（S5c-2b-1 过渡双写）。
    func mirrorCullingWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary
    /// syncStatus/flush/retry/finalize 的统一读模型（旧 MetadataSyncSummary 投影）。
    func cullingMetadataSummary(sessionId: String) throws -> MetadataSyncSummary
    /// flush/retry_sync 的唯一动作：按相位回放未完成的 intent。
    func replayPendingDeliveries() async throws -> DeliveryReplaySummary
}

extension CoordinatorDeliveryAdapter: CullingDeliveryPort {
    public func confirmCulling(sessionId: String) throws -> DeliveryConfirmSummary {
        try confirm(sessionId: sessionId)
    }

    public func cleanupCulling(sessionId: String) async throws -> DeliveryCleanupSummary {
        try await cleanup(sessionId: sessionId)
    }

    public func finalizeCulling(sessionId: String) async throws -> DeliveryFinalizeSummary {
        try await finalize(sessionId: sessionId)
    }

    public func mirrorCullingWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        try mirrorWriteback(sessionId: sessionId, items: items)
    }

    public func cullingMetadataSummary(sessionId: String) throws -> MetadataSyncSummary {
        try metadataSummary(sessionId: sessionId)
    }

    public func replayPendingDeliveries() async throws -> DeliveryReplaySummary {
        try await engine.replay()
    }
}

/// FaceKwService 的交付面：module 固定为 .faceKeyword（落库 "face-keyword"）。
///
/// 与 CullingDeliveryPort 同一套理由：调用点不重复传模块常量、不拿到别域入口，
/// 测试可注入替身只验证「调用了确认/清理/镜像」。
public protocol FaceKwDeliveryPort: Sendable {
    /// 确认本会话在人脸关键词模块下的已写交付（单事务；跨会话阻塞见返回值）。
    func confirmFaceKeyword(sessionId: String) throws -> DeliveryConfirmSummary
    /// 清理本会话在人脸关键词模块下已确认（synced）的交付（恢复备份后物理删行）。
    func cleanupFaceKeyword(sessionId: String) async throws -> DeliveryCleanupSummary
    /// 旧 WritebackService 执行结果 → 交付镜像（S5c-2b-2 过渡双写）。
    func mirrorFaceKeywordWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary
    /// cleanup 前的崩溃恢复：按相位回放未完成的 intent。
    func replayPendingDeliveries() async throws -> DeliveryReplaySummary
}

extension CoordinatorDeliveryAdapter: FaceKwDeliveryPort {
    public func confirmFaceKeyword(sessionId: String) throws -> DeliveryConfirmSummary {
        try confirm(sessionId: sessionId)
    }

    public func cleanupFaceKeyword(sessionId: String) async throws -> DeliveryCleanupSummary {
        try await cleanup(sessionId: sessionId)
    }

    public func mirrorFaceKeywordWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        try mirrorWriteback(sessionId: sessionId, items: items)
    }
}

/// SimilarityService 的交付面：module 固定为 .similarity。
public protocol SimilarityDeliveryPort: Sendable {
    /// 确认本会话在相似度模块下的已写交付（单事务；跨会话阻塞见返回值）。
    func confirmSimilarity(sessionId: String) throws -> DeliveryConfirmSummary
    /// 清理本会话在相似度模块下已确认（synced）的交付（恢复备份后物理删行）。
    func cleanupSimilarity(sessionId: String) async throws -> DeliveryCleanupSummary
    /// 旧 WritebackService 执行结果 → 交付镜像（S5c-2b-2 过渡双写）。
    func mirrorSimilarityWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary
    /// cleanup 前的崩溃恢复：按相位回放未完成的 intent。
    func replayPendingDeliveries() async throws -> DeliveryReplaySummary
}

extension CoordinatorDeliveryAdapter: SimilarityDeliveryPort {
    public func confirmSimilarity(sessionId: String) throws -> DeliveryConfirmSummary {
        try confirm(sessionId: sessionId)
    }

    public func cleanupSimilarity(sessionId: String) async throws -> DeliveryCleanupSummary {
        try await cleanup(sessionId: sessionId)
    }

    public func mirrorSimilarityWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        try mirrorWriteback(sessionId: sessionId, items: items)
    }
}
