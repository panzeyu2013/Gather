// desktop/native/gather-core/Sources/GatherPersistence/Ports/DeliveryRepository.swift
// WP3b-1：Delivery 读端口。
//
// Application 只读交付摘要/项；状态机写入仍归 GatherDelivery（WP2）。
import Foundation
import GatherProtocol

public protocol DeliveryRepository {
    func listItems(
        sessionId: String,
        module: DeliveryModule?,
        status: DeliveryItemStatus?
    ) throws -> [DeliveryItemRow]
}

public extension DeliveryRepository {
    func listItems(sessionId: String) throws -> [DeliveryItemRow] {
        try listItems(sessionId: sessionId, module: nil, status: nil)
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

extension DeliveryRepo: DeliveryRepository {}
extension DeliverySummaryQuery: DeliverySummaryReading {}
