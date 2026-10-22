// desktop/native/gather-core/Sources/GatherDelivery/Ports/DeliveryModulePorts.swift
// WP2b：模块适配器（替代 Coordinator 上 3 组共 14 个 public 转发方法）。
//
// 迁移前：DeliveryCoordinator 直接 conform CullingDeliveryPort / FaceKwDeliveryPort /
// SimilarityDeliveryPort，14 个方法体全是「module 常量 + 一行转发」；同一组 5 个
// 操作 × 3 个模块，60% 的公开面是复制。
//
// 迁移后：
// - DeliveryEngine：交付引擎的 6 个通用操作（Confirm/Cleanup/Finalize/Mirror/
//   MetadataSummary/Replay），Coordinator 是它的唯一生产实现；
// - DeliveryModuleAdapter：模块适配器协议，只有 5 个方法 + module/capabilities/engine；
//   模块差异（culling 有 finalize/metadataSummary，face/similarity 没有）由
//   capabilities 显式表达，越权调用抛 unsupportedCapability；
// - 旧端口协议保留为**面向 feature 的窄接口**（FaceKeywordingServiceTests 的替身
//   仍可直接实现），由受限扩展把 14 个名字转发到 5 个适配器方法，行为不变。

import Foundation
import GatherPersistence
import GatherProtocol

// MARK: - 引擎

/// 交付引擎的通用操作（Coordinator 的模块无关公开面）。
public protocol DeliveryEngine: Sendable {
    func confirm(sessionId: String, module: DeliveryModule) throws -> DeliveryConfirmSummary
    func cleanup(sessionId: String, module: DeliveryModule) async throws -> DeliveryCleanupSummary
    func finalize(sessionId: String, module: DeliveryModule) async throws -> DeliveryFinalizeSummary
    func mirrorWriteback(
        sessionId: String,
        module: DeliveryModule,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary
    func metadataSummary(sessionId: String, module: DeliveryModule?) throws -> MetadataSyncSummary
    func replay() async throws -> DeliveryReplaySummary
}

extension DeliveryCoordinator: DeliveryEngine {}

// MARK: - 适配器

/// 模块能力：feature 差异的唯一声明处（不是 switch 在 Coordinator 里）。
public enum DeliveryModuleCapability: String, CaseIterable, Sendable, Equatable {
    case confirm
    case cleanup
    case finalize
    case mirrorWriteback
    case metadataSummary

    /// 各交付模块真实具备的能力（与迁移前三个 port 的方法集合一一对应）。
    ///
    /// - culling：confirm + cleanup + finalize + mirror + metadataSummary；
    /// - face-keyword / similarity：confirm + cleanup + mirror；
    /// - template / metadata：与 face/similarity 同形（交付面尚未单独接线）。
    public static func capabilities(for module: DeliveryModule) -> Set<DeliveryModuleCapability> {
        switch module {
        case .culling:
            return [.confirm, .cleanup, .finalize, .mirrorWriteback, .metadataSummary]
        case .faceKeyword, .similarity, .template, .metadata:
            return [.confirm, .cleanup, .mirrorWriteback]
        }
    }
}

/// 模块适配器错误（新码，不映射 GatherError；API 边界再转）。
public enum DeliveryModuleAdapterError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// 该模块没有这个能力（例如 face-keyword 没有 finalize）。
    case unsupportedCapability(module: DeliveryModule, capability: DeliveryModuleCapability)

    public var code: String { "DELIVERY_MODULE_UNSUPPORTED_CAPABILITY" }

    public var description: String {
        switch self {
        case .unsupportedCapability(let module, let capability):
            return "\(code): \(module.rawValue)/\(capability.rawValue)"
        }
    }

    public var errorDescription: String? { description }
}

/// 模块适配器：5 个方法 + 3 个只读属性（module/capabilities/engine）。
public protocol DeliveryModuleAdapter: Sendable {
    var module: DeliveryModule { get }
    var capabilities: Set<DeliveryModuleCapability> { get }
    /// 旧端口（replayPendingDeliveries 等引擎级操作）的转发依赖；不暴露内部行。
    var engine: any DeliveryEngine { get }

    func confirm(sessionId: String) throws -> DeliveryConfirmSummary
    func cleanup(sessionId: String) async throws -> DeliveryCleanupSummary
    func finalize(sessionId: String) async throws -> DeliveryFinalizeSummary
    func mirrorWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary
    func metadataSummary(sessionId: String) throws -> MetadataSyncSummary
}

/// 生产适配器：把模块常量固定下来，能力之外的调用显式失败。
public struct CoordinatorDeliveryAdapter: DeliveryModuleAdapter {
    public let module: DeliveryModule
    public let capabilities: Set<DeliveryModuleCapability>
    public let engine: any DeliveryEngine

    public init(
        engine: any DeliveryEngine,
        module: DeliveryModule,
        capabilities: Set<DeliveryModuleCapability>? = nil
    ) {
        self.module = module
        self.capabilities = capabilities ?? DeliveryModuleCapability.capabilities(for: module)
        self.engine = engine
    }

    public func confirm(sessionId: String) throws -> DeliveryConfirmSummary {
        try require(.confirm)
        return try engine.confirm(sessionId: sessionId, module: module)
    }

    public func cleanup(sessionId: String) async throws -> DeliveryCleanupSummary {
        try require(.cleanup)
        return try await engine.cleanup(sessionId: sessionId, module: module)
    }

    public func finalize(sessionId: String) async throws -> DeliveryFinalizeSummary {
        try require(.finalize)
        return try await engine.finalize(sessionId: sessionId, module: module)
    }

    public func mirrorWriteback(
        sessionId: String,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        try require(.mirrorWriteback)
        return try engine.mirrorWriteback(sessionId: sessionId, module: module, items: items)
    }

    public func metadataSummary(sessionId: String) throws -> MetadataSyncSummary {
        try require(.metadataSummary)
        return try engine.metadataSummary(sessionId: sessionId, module: module)
    }

    private func require(_ capability: DeliveryModuleCapability) throws {
        guard capabilities.contains(capability) else {
            throw DeliveryModuleAdapterError.unsupportedCapability(
                module: module, capability: capability)
        }
    }
}

public extension DeliveryCoordinator {
    /// 取得固定模块的适配器（组合根/Domain 服务默认接线用；不缓存，无状态）。
    func adapter(for module: DeliveryModule) -> CoordinatorDeliveryAdapter {
        CoordinatorDeliveryAdapter(engine: self, module: module)
    }
}
