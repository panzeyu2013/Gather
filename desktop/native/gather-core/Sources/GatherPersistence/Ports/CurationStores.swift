// desktop/native/gather-core/Sources/GatherPersistence/Ports/CurationStores.swift
// 策展（集合 / 堆栈 / 跨工作区重复）的三个窄端口（#8：把 CurationService 从
// DBConnection 上摘下来）。
//
// 为什么三条端口而不是一条：三个仓储互不相关（集合用 collections/collection_items，
// 堆栈用 stacks/photo_stack_members，跨工作区重复是只读查询），CurationService 是唯一
// 消费者。按仓储切分后，将来把「堆栈」拆成独立服务时不需要再动端口。
//
// 事务：CurationService 有三处跨仓储的事务（建栈前 detach、加成员前 detach、
// 删成员后清空栈）。端口**不带**事务语义——repo 方法各自开事务，外层由
// TransactionRunner 提供；组合根必须保证 transactions 与三个 store 来自**同一个**
// DBConnection（不同连接时嵌套事务会退化成两个独立事务，外层回滚撤不掉内层）。
import Foundation
import GatherProtocol

public protocol CollectionStore: Sendable {
    func list(sessionId: String) throws -> [CollectionRow]
    func get(id: String) throws -> CollectionRow?
    func nameExists(sessionId: String, name: String, excluding: String?) throws -> Bool
    func create(sessionId: String, name: String, sortOrder: Int?) throws -> CollectionRow
    func rename(id: String, name: String) throws -> Bool
    func delete(id: String) throws -> Bool
    func items(collectionId: String) throws -> [CollectionItemRow]
    func appendItems(collectionId: String, photoIds: [String]) throws -> Int
    func removeItems(collectionId: String, photoIds: [String]) throws -> Int
    func reorderItems(collectionId: String, orderedPhotoIds: [String]) throws -> Int
    func moveItem(
        collectionId: String, photoId: String,
        afterPhotoId: String?, beforePhotoId: String?) throws -> Bool
    func sessionExists(_ id: String) throws -> Bool
    func existingPhotoIds(sessionId: String, photoIds: [String]) throws -> Set<String>
    /// Wave2（task-15）：并/交/差 的成员 id 解析（同会话、排除已移出工作区）。
    /// 顺序契约：union = 各集合按入参顺序拼接后稳定去重；
    /// intersection / difference = 以第一个集合的顺序为准。
    func setOperationPhotoIds(
        sessionId: String,
        collectionIds: [String],
        operation: CollectionSetOperation
    ) throws -> [String]
}

public protocol StackStore: Sendable {
    func list(sessionId: String) throws -> [StackRow]
    func get(id: String) throws -> StackRow?
    func members(stackId: String) throws -> [StackMemberRow]
    func folds(sessionId: String) throws -> [StackFold]
    func create(
        sessionId: String, name: String,
        coverPhotoId: String?, photoIds: [String]) throws -> StackRow
    func update(
        id: String, name: String?,
        coverPhotoId: String?, clearCover: Bool) throws -> Bool
    func delete(id: String) throws -> Bool
    func isMember(stackId: String, photoId: String) throws -> Bool
    func hasAnyMember(stackId: String) throws -> Bool
    func addMembers(stackId: String, photoIds: [String]) throws -> Int
    func removeMembers(stackId: String, photoIds: [String]) throws -> Int
    func detachPhotos(photoIds: [String]) throws -> Int
}

public protocol GlobalDuplicateReading: Sendable {
    func totalPhotoCount() throws -> Int
    func missingChecksumCount() throws -> Int
    func exactGroups(minSessionCount: Int, limit: Int) throws -> [GlobalDuplicateExactRow]
    func photos(checksums: [String]) throws -> [GlobalDuplicatePhotoRow]
    func visualHashRows(limit: Int) throws -> [GlobalDuplicatePhotoRow]
}

extension CollectionRepo: CollectionStore {}
extension StackRepo: StackStore {}
extension GlobalDuplicateQuery: GlobalDuplicateReading {}
