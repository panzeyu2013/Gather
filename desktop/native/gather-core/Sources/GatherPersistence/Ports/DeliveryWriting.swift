// desktop/native/gather-core/Sources/GatherPersistence/Ports/DeliveryWriting.swift
// P2：DeliveryStateWriter 的窄写端口。具体 DeliveryRepo 只在组合根出现；
// 编排层通过协议表达写语义，Repo 的其余 public 写方法不再被静态依赖。

import Foundation
import GatherProtocol

public protocol DeliveryWriting: Sendable {
    func createOrGet(
        xmpPath: String, photoPath: String, revision: Int64,
        baseFingerprint: String, baseValues: JSONValue
    ) throws -> DeliveryRow
    func mergeInput(
        xmpPath: String, photoPath: String, expectedRevision: Int64,
        newRevision: Int64, baseFingerprint: String, baseValues: JSONValue
    ) throws -> DeliveryRow?
    func claimWriting(
        xmpPath: String, revision: Int64, leaseOwner: String, heartbeatAt: String?,
        now: Date
    ) throws -> DeliveryRow?
    func renewWriting(
        xmpPath: String, revision: Int64, leaseOwner: String, heartbeatAt: String?
    ) throws -> Bool
    func markWritten(
        xmpPath: String, revision: Int64, leaseOwner: String,
        baseFingerprint: String, baseValues: JSONValue, backupPath: String
    ) throws -> DeliveryRow?
    func markWrittenAndClearReloadAcks(
        xmpPath: String, revision: Int64, leaseOwner: String,
        baseFingerprint: String, baseValues: JSONValue, backupPath: String,
        timestamp: String
    ) throws -> DeliveryRow?
    func markFailed(
        xmpPath: String, revision: Int64, errorMessage: String, leaseOwner: String
    ) throws -> DeliveryRow?
    func markConflict(
        xmpPath: String, revision: Int64, errorMessage: String, leaseOwner: String
    ) throws -> DeliveryRow?
    func confirm(
        scope: DeliveryConfirmScope, sessionId: String, module: DeliveryModule?,
        requireReloadAck: Bool
    ) throws -> DeliveryConfirmSummary
    func linkSession(xmpPath: String, sessionId: String) throws -> DeliveryRow
    func get(_ xmpPath: String) throws -> DeliveryRow?
    func upsertItem(
        xmpPath: String, photoId: String, module: DeliveryModule,
        attributes: [String: JSONValue], keywords: [String],
        status: DeliveryItemStatus, errorMessage: String
    ) throws -> DeliveryItemRow
    func markItem(
        itemId: Int64, status: DeliveryItemStatus, errorMessage: String,
        leaseOwner: String?
    ) throws -> DeliveryItemRow?
    func deleteItems(
        xmpPath: String, module: DeliveryModule?, statuses: Set<DeliveryItemStatus>
    ) throws -> Int
    func updateItemAttributes(
        _ updates: [(itemId: Int64, attributes: [String: JSONValue])]
    ) throws
    func updateItemKeywords(_ updates: [(itemId: Int64, keywords: [String])]) throws
    func applyMetadataMutation(
        xmpPath: String, photoPath: String, photoId: String, sessionId: String,
        attributes: [String: JSONValue], keywords: [String]?
    ) throws -> DeliveryRow
    func deleteOrphanDelivery(xmpPath: String, revision: Int64) throws -> Bool
    func resetConfirmations(xmpPath: String) throws -> Int
    func deleteSyncedDelivery(
        xmpPath: String, deliveryId: Int64, revision: Int64
    ) throws -> DeliveryRepo.DeliveryDeleteOutcome
    func deleteSyncedDeliveryInTransaction(
        xmpPath: String, deliveryId: Int64, revision: Int64
    ) throws -> DeliveryRepo.DeliveryDeleteOutcome
    func deleteItemsInTransaction(
        xmpPath: String, module: DeliveryModule?, statuses: Set<DeliveryItemStatus>
    ) throws -> Int
}

extension DeliveryRepo: DeliveryWriting {}
