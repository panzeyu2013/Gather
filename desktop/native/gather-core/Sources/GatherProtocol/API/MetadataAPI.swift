// desktop/native/gather-core/Sources/GatherProtocol/API/MetadataAPI.swift
// Cut 1 / 阶段 1A：元数据域协议（7 个方法）。
//
// 职责：元数据读取/写入/批量写入、冲突与孤儿列表、冲突/孤儿处置。
// 对应命令（7 条）：metadata.get / set / batch_set / conflicts / orphans /
// resolve_conflict / resolve_orphan。
// 校验归属：
// - get 的 photoIds 非空/去重/上限在输入类型（G5）；
// - set/batchSet/resolveConflict/resolveOrphan 使用 Confirmed<T>；
// - tags 的类型在解码期失败，不再把非对象当空对象（G6）；
// - XMP 冲突/孤儿的领域判定与 XMP_* 码由 MetadataSyncCoordinator 负责。

import Foundation

public protocol MetadataAPI: Sendable {
    func get(_ input: MetadataGetInput) async throws -> [String: MetadataTags]
    /// 旧 metadata.set 返回写入后的完整 tags（MetadataService.setMetadata -> MetadataTags）。
    func set(_ input: Confirmed<MetadataSetInput>) async throws -> MetadataTags
    func batchSet(_ input: Confirmed<MetadataBatchSetInput>) async throws -> BatchMetadataResult
    func conflicts(_ sessionId: String) async throws -> [MetadataConflict]
    func orphans() async throws -> [MetadataOrphan]
    func resolveConflict(_ input: Confirmed<MetadataResolveConflictInput>) async throws -> MetadataSyncSummary
    func resolveOrphan(_ input: Confirmed<MetadataResolveOrphanInput>) async throws -> [MetadataOrphan]
}
