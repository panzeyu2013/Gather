// desktop/native/gather-core/Sources/GatherProtocol/API/MetadataAPI.swift
// Cut 1 / 阶段 1A：元数据域协议（7 个方法）。
//
// 职责：冲突与孤儿列表、冲突/孤儿处置、关键词预览/应用/重试。
// 对应命令（7 条）：metadata.conflicts / orphans / resolve_conflict /
// resolve_orphan，以及 K0 的 preview / apply_keywords / retry_keyword_writeback。
// 校验归属：
// - resolveConflict/resolveOrphan/applyKeywords/retryKeywordWriteback 使用 Confirmed<T>；
// - tags 的类型在解码期失败，不再把非对象当空对象（G6）；
// - XMP 冲突/孤儿的领域判定与 XMP_* 码由 MetadataSyncCoordinator 负责。

import Foundation

public protocol MetadataAPI: Sendable {
    func conflicts(_ sessionId: String) async throws -> [MetadataConflict]
    func orphans() async throws -> [MetadataOrphan]
    func resolveConflict(_ input: Confirmed<MetadataResolveConflictInput>) async throws -> MetadataSyncSummary
    func resolveOrphan(_ input: Confirmed<MetadataResolveOrphanInput>) async throws -> [MetadataOrphan]

    // K0 关键词（P0）：只读预览 / delta 写入 / 重试。preview 不建 pending 行。
    func preview(_ input: MetadataPreviewInput) async throws -> WritebackPreview
    func applyKeywords(_ input: Confirmed<MetadataKeywordApplyInput>) async throws -> MetadataKeywordApplyResult
    func retryKeywordWriteback(_ input: Confirmed<SessionReference>) async throws -> MetadataKeywordApplyResult
}
