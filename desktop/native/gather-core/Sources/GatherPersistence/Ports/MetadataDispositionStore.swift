// desktop/native/gather-core/Sources/GatherPersistence/Ports/MetadataDispositionStore.swift
// 元数据处置（冲突/孤儿）的读取端口（#2：把 LiveMetadataAPI 的用例编排下沉到
// MetadataDispositionService）。
//
// 5 个方法、唯一消费者、每个都用到：冲突列表 + 孤儿列表 + 交付项 + 按 xmpPath
// 读单行 + 会话写回摘要（resolveConflict 的返回值）。写入口不在这里——状态迁移
// 统一走 GatherDelivery 的 DeliveryStateWriter（它才是 CAS/租约语义的拥有者）。
import Foundation
import GatherProtocol

public protocol MetadataDispositionReading: Sendable {
    func conflictDeliveries(sessionId: String) throws -> [DeliveryRow]
    func orphanDeliveries() throws -> [DeliveryRow]
    func items(deliveryId: Int64) throws -> [DeliveryItemRow]
    /// 按 xmpPath 读单行（孤儿 restore 的事后复核）。
    func deliveryRow(xmpPath: String) throws -> DeliveryRow?
    /// 会话写回摘要（module = nil = 全部模块）。
    func metadataSummary(sessionId: String, module: DeliveryModule?) throws -> MetadataSyncSummary
}

extension DeliveryRepo: MetadataDispositionReading {
    public func deliveryRow(xmpPath: String) throws -> DeliveryRow? {
        try get(xmpPath)
    }
}
