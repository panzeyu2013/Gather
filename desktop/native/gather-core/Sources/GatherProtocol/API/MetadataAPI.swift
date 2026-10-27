// desktop/native/gather-core/Sources/GatherProtocol/API/MetadataAPI.swift
// Cut 1 / 阶段 1A：元数据域协议（18 个方法）。
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

    /// P1 / IPTC：单张照片的只读元数据详情（EXIF 快照 + 描述性元数据 + 文件/同步态）。
    /// 只读缓存投影，不触发磁盘解析；照片不存在抛 PHOTO_NOT_FOUND 语义错误。
    func metadata(_ photoId: String) async throws -> PhotoMetadataDetail

    // MARK: - P1 / B2：元数据模板（preview → confirm → undo）

    /// 模板列表（不含字段明细，避免一次拉全量模板体）。
    func templates() async throws -> [MetadataTemplateSummary]
    /// 新建或更新模板（id 为 nil 即新建）。
    func saveTemplate(_ input: MetadataTemplateSaveInput) async throws -> MetadataTemplateSummary
    /// 读取模板字段（编辑/清空 UI 用；列表接口不带字段明细）。
    func templateFields(id: String) async throws -> DescriptiveMetadata
    /// 删除模板（破坏性：用 Confirmed 收口）。
    func deleteTemplate(_ input: Confirmed<MetadataTemplateDeleteInput>) async throws
    /// 预览：逐照片逐字段的 write/clear/conflict 明细，不写任何文件。
    func previewTemplate(_ input: MetadataTemplatePreviewInput) async throws -> MetadataTemplatePreviewResult
    /// 应用：逐张独立提交，冲突按策略跳过；返回 batchId 供撤销。
    func applyTemplate(_ input: Confirmed<MetadataTemplateApplyInput>) async throws -> MetadataTemplateApplyOutcome
    /// 撤销：按批次记录反向写；已撤销的批次拒绝重复回滚。
    func undoTemplate(_ input: Confirmed<MetadataTemplateUndoInput>) async throws -> MetadataTemplateApplyOutcome

    /// P1 / B3：最近的套用/写回批次（设置持久化，供关面板/重启后撤销）。
    func recentBatches(limit: Int) async throws -> [MetadataBatchSummary]

    /// P1 / E：把 triage 建议写成可移植信号（rating 仅空值 + 私有命名空间 + 可选关键词）。
    func applyTriageWriteback(_ input: Confirmed<TriageWritebackInput>) async throws -> TriageWritebackResult

    /// P1 / E：撤销一次 triage 写回（按批次记录还原 rating/关键词）。
    func undoTriageWriteback(_ input: Confirmed<MetadataTemplateUndoInput>) async throws -> TriageWritebackResult

    // K0 关键词（P0）：只读预览 / delta 写入 / 重试。preview 不建 pending 行。
    func preview(_ input: MetadataPreviewInput) async throws -> WritebackPreview
    func applyKeywords(_ input: Confirmed<MetadataKeywordApplyInput>) async throws -> MetadataKeywordApplyResult
    func retryKeywordWriteback(_ input: Confirmed<SessionReference>) async throws -> MetadataKeywordApplyResult
}
