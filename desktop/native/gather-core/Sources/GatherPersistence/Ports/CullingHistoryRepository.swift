// desktop/native/gather-core/Sources/GatherPersistence/Ports/CullingHistoryRepository.swift
// P1-1：culling_history 端口（undo/redo 历史栈，只含 Application 实际调用的方法）。
//
// 历史行与 CullingService 的决策写入在同一事务内追加（append），读取侧只
// 需要窗口 + 栈顶补齐所需的三条查询；SQL/排序规则留在 CullingHistoryRepo。
import Foundation
import GatherProtocol

public protocol CullingHistoryRepository {
    /// applyHistory：追加一条操作（返回带 id 的行供 undo/redo 指针使用）。
    func append(sessionId: String, entries: [CullingHistoryEntry]) throws -> CullingHistoryOperation
    /// 当前 undo/redo 栈顶（getHistory 的窗口外补齐规则）。
    func stackTops(sessionId: String) throws -> CullingHistoryStackTops
    /// undo/redo：翻转已撤销标记（applyHistory 追加后回写方向）。
    func setUndone(sessionId: String, operationId: Int, undone: Bool) throws
    /// 单条操作（undo/redo 目标读取）。
    func get(sessionId: String, operationId: Int) throws -> CullingHistoryOperation?
    /// 最近 limit 条操作（id DESC）。
    func list(sessionId: String, limit: Int) throws -> [CullingHistoryOperation]
    /// reset：删除触及给定照片的操作行（返回删除条数）。
    @discardableResult
    func deleteOperationsTouching(sessionId: String, photoIds: Set<String>) throws -> Int
}

extension CullingHistoryRepo: CullingHistoryRepository {}
