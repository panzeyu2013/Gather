// desktop/native/gather-core/Sources/GatherPersistence/Ports/DeliveryRepository.swift
// WP3b-1：Delivery 读端口。
//
// Application 只读交付摘要/项；状态机写入仍归 GatherDelivery（WP2）。
import Foundation
import GatherProtocol

/// 写回基线（xmpPath → deliveries 行上的备份/指纹/基线）。
///
/// 与 GatherDelivery 的 DeliveryWritebackBaseline 同义，但定义在 Persistence：
/// GatherDelivery 依赖 Persistence，反向不行；Application 经端口读取后自行映射。
public struct DeliveryBaselineRow: Equatable, Sendable {
    public let backupPath: String
    public let baseFingerprint: String
    public let baseValues: JSONValue

    public init(backupPath: String, baseFingerprint: String, baseValues: JSONValue) {
        self.backupPath = backupPath
        self.baseFingerprint = baseFingerprint
        self.baseValues = baseValues
    }

    public static let empty = DeliveryBaselineRow(
        backupPath: "", baseFingerprint: "", baseValues: .object([:])
    )
}

public protocol DeliveryRepository {
    func listItems(
        sessionId: String,
        module: DeliveryModule?,
        status: DeliveryItemStatus?
    ) throws -> [DeliveryItemRow]
    /// 按 xmp_path 读交付行（镜像的基线 / photo_path 回读）。
    func getItem(xmpPath: String) throws -> DeliveryRow?
    /// 按 xmp_path 批量读交付行（一次 IN 查询代替逐行 get）。
    func getMany(xmpPaths: [String]) throws -> [String: DeliveryRow]
}

public extension DeliveryRepository {
    func listItems(sessionId: String) throws -> [DeliveryItemRow] {
        try listItems(sessionId: sessionId, module: nil, status: nil)
    }

    func listItems(sessionId: String, module: DeliveryModule?) throws -> [DeliveryItemRow] {
        try listItems(sessionId: sessionId, module: module, status: nil)
    }

    /// 按 xmpPath 读交付行上的基线；行不存在或读失败 → 空基线（不阻塞镜像）。
    /// 口径与 GatherDelivery.deliveryWritebackBaseline 逐字一致：不抛错，
    /// 「读不到基线」绝不伪造成写盘失败。
    func itemBaseline(xmpPath: String) -> DeliveryBaselineRow {
        do {
            guard let row = try getItem(xmpPath: xmpPath) else {
                return .empty
            }
            return DeliveryBaselineRow(
                backupPath: row.backupPath,
                baseFingerprint: row.baseFingerprint,
                baseValues: row.baseValues
            )
        } catch {
            GatherLogger.log(
                "delivery writeback baseline unavailable (\(xmpPath)): \(error)",
                level: .debug
            )
            return .empty
        }
    }
}

/// Application 侧只读交付摘要能力（DeliverySummaryQuery 的窄端口）。
public protocol DeliverySummaryReading {
    func summary(sessionId: String, module: DeliveryModule?) throws -> DeliverySessionSummary
    func metadataSummary(sessionId: String, module: DeliveryModule?) throws -> MetadataSyncSummary
    /// 本会话某模块是否存在已落盘的 item（written/synced）。
    func hasWrittenBackItem(sessionId: String, module: DeliveryModule) throws -> Bool
}

public extension DeliverySummaryReading {
    func summary(sessionId: String) throws -> DeliverySessionSummary {
        try summary(sessionId: sessionId, module: nil)
    }

    func metadataSummary(sessionId: String) throws -> MetadataSyncSummary {
        try metadataSummary(sessionId: sessionId, module: nil)
    }
}

extension DeliveryRepo: DeliveryRepository {
    /// DeliveryRepo.get 是无标签历史的入口；端口用显式标签，避免 Application 依赖旧拼写。
    public func getItem(xmpPath: String) throws -> DeliveryRow? {
        try get(xmpPath)
    }
}
extension DeliverySummaryQuery: DeliverySummaryReading {}
