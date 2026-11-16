// desktop/native/gather-core/Sources/GatherProtocol/API/MetadataAPI.swift
// Cut 1 / 阶段 1A：元数据域协议（20 个方法；P0 / B2 追加 applyDescriptive 与 diskDescriptive）。
//
// 职责：冲突与孤儿列表、冲突/孤儿处置、关键词预览/应用/重试；P1 起追加
// 只读元数据详情（metadata）、元数据模板（templates/saveTemplate/templateFields/
// deleteTemplate/previewTemplate/applyTemplate/undoTemplate/recentBatches）与
// triage 写回（applyTriageWriteback/undoTriageWriteback）。
// 对应命令（7 条历史命令面）：metadata.conflicts / orphans / resolve_conflict /
// resolve_orphan，以及 K0 的 preview / apply_keywords / retry_keyword_writeback；
// 模板与 triage 写回是 P1 新增的类型化入口，没有对应的历史命令。
// 校验归属：
// - resolveConflict/resolveOrphan/applyKeywords/retryKeywordWriteback 使用 Confirmed<T>；
// - tags 的类型在解码期失败，不再把非对象当空对象（G6）；
// - XMP 冲突/孤儿的领域判定与 XMP_* 码由 MetadataSyncCoordinator 负责。
//
// P1 下一波 §3.1（本文件追加）：metadata/template 写回的**生命周期**入口
// （syncState / confirmSync / finalizeSync）。三者返回同一份派生状态
// MetadataDeliveryState（类型定义在 Protocol/MetadataDelivery.swift），
// "同步与备份"状态条只读它，不自己数行。
// 三个方法都有协议扩展的默认实现：PreviewAPIs 与各测试替身实现 MetadataAPI
// 时不必为新增能力补桩，未接线的地方也不会在编译期炸掉。

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

    /// P0 / B2：单张（或少量）照片的直接字段编辑。批次 templateId = "inline"，
    /// undo 复用 undoTemplate 的批次机制；返回类型与模板套用一致。
    func applyDescriptive(_ input: Confirmed<MetadataInlineApplyInput>) async throws -> MetadataTemplateApplyOutcome

    /// P0 / B2：**盘上**当前描述性元数据（含 JPEG 内嵌 IPTC），编辑器初值用。
    /// 不能拿缓存当初值：缓存落后时用户会看到旧值，保存会静默覆盖外部改动。
    func diskDescriptive(_ photoId: String) async throws -> DescriptiveMetadata
    /// D3（task-31 review）：盘上描述性元数据 + sidecar 存在性；nil = 未接线/未知。
    /// 批量直改用它判断 diskKnown（避免把"仅缓存"的导入照片判成外部改动）。
    func diskDescriptiveAvailability(photoId: String) async throws -> DiskDescriptiveAvailability?
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

    // MARK: - P1 下一波 3.1：写回生命周期（确认 → 结束 → 备份回收）

    /// 只读状态：本会话 metadata/template 两个模块的交付计数、备份体积与逐文件行。
    /// 不写库、不碰文件内容（备份体积只读目录项元数据）。
    func syncState(_ sessionId: String) async throws -> MetadataDeliveryState

    /// 确认同步：对 '.metadata' 与 '.template' 各 confirm 一次（同一交付的 items
    /// 会被第一次确认全翻 synced，第二次是幂等）。门禁与 culling 同源：
    /// - 仍有 pending/writing/failed/conflict → XMP_CONFIRM_INCOMPLETE；
    /// - C1 在本机启用且本会话未 reload-ack → XMP_CONFIRM_REQUIRES_SYNC。
    func confirmSync(_ input: Confirmed<SessionReference>) async throws -> MetadataDeliveryState

    /// 结束同步：**只做 drop**（保留 XMP、删行/备份），绝不 restore。
    /// 共享文件只删本模块 synced item；仍有其它模块 item 时保留行与备份
    /// （留给最后一个模块收尾）；本模块仍有未确认 item 时按 XMP_CONFIRM_INCOMPLETE 跳过。
    func finalizeSync(_ input: Confirmed<SessionReference>) async throws -> MetadataDeliveryState

    /// 立即回收已确认交付的行与备份（XMP 保留；ignoreReloadAck 由用户显式确认）。
    func cleanupRetention(_ input: Confirmed<MetadataCleanupInput>) async throws -> MetadataCleanupSummary

    // MARK: - Wave2 / 词库（受控词表）

    /// 词库树（含每个路径的同义词）。prefix 为空 = 全量；非空 = 前缀过滤。
    func keywordLibrary(_ query: KeywordLibraryQuery) async throws -> [KeywordLibraryNode]

    /// 自动补全：词库路径前缀 + 同义词命中（同义词只影响候选，不改变规范路径）。
    func keywordSuggestions(_ query: KeywordSuggestionQuery) async throws -> [KeywordSuggestion]

    /// 改名（含子孙前缀级联；photo_keywords/keyword_synonyms 同事务）。
    func renameKeyword(_ input: Confirmed<KeywordRenameInput>) async throws -> KeywordMutationSummary

    /// 合并到一个已存在的路径（只允许叶子；成员/同义词并入 target）。
    func mergeKeywords(_ input: Confirmed<KeywordMergeInput>) async throws -> KeywordMutationSummary

    /// 删除（cascade=false 时仓储守卫：有成员/子级/同义词一律拒绝）。
    func deleteKeyword(_ input: Confirmed<KeywordDeleteInput>) async throws -> KeywordMutationSummary

    /// 覆盖式设置同义词（空数组 = 清空）。同义词参与补全与检索，不写 XMP。
    func setKeywordSynonyms(_ input: Confirmed<KeywordSynonymsInput>) async throws -> KeywordMutationSummary

    /// 新建空路径（含祖先物化；已存在时幂等）。
    func createKeyword(_ input: Confirmed<KeywordCreateInput>) async throws -> KeywordMutationSummary

    // MARK: - Wave5（batch5）：位置 / 拍摄时间

    /// 直接写入/清空 GPS 坐标与拍摄时间（**sidecar 通道**）。返回与内联 apply
    /// 一致的 outcome；batchId 为空串 = 本操作不产生可撤销批快照（不做 undo）。
    ///
    /// 三态语义见 `MetadataGeoDateInput`：nil 不动 / dateTaken 空串清空 / 有值写入。
    /// JPEG 内嵌写目标（无 sidecar、auto 模式）在写后校验阶段会显式失败：GPS/时间的
    /// 内嵌读侧尚未接线（回执已列），不谎报成功。
    func applyGeoAndDate(
        _ input: Confirmed<MetadataGeoDateInput>
    ) async throws -> MetadataTemplateApplyOutcome

    /// 盘上当前 GPS 坐标与拍摄时间（编辑器初值；与 diskDescriptive 同口径的读盘）。
    /// nil = 未接线 / 读不到（调用方退回缓存投影，不得当成"盘上为空"）。
    func diskGeoDate(photoId: String) async throws -> MetadataGeoDateSnapshot?

    // MARK: - Wave5（batch9）：双源可见性

    /// 内嵌元数据与 sidecar 的逐字段冲突（JPEG 且 sidecar 存在时才可能出现）。
    ///
    /// 这是**只读可见性**接口：写目标策略（MetadataTargetPolicy）不变——JPEG 有
    /// sidecar 时永远写 sidecar、读侧 sidecar 覆盖内嵌；本接口不清理内嵌、也不改写入位置。
    /// nil = 无双源 / 无冲突 / 读不到（无法判定）；调用方不得把它当成"一定没有冲突"的缓存依据。
    func dualSourceConflict(photoId: String) async throws -> MetadataDualSourceConflict?
}

// MARK: - 双源冲突（Wave5 batch9）

/// 内嵌（JPEG APP1）+ sidecar 的字段级冲突描述。
///
/// 只表达"两侧都有显式值且不同"；一侧缺失不算冲突（读侧 sidecar 覆盖但不清内嵌）。
public struct MetadataDualSourceConflict: Codable, Equatable, Sendable {
    /// 当前权威源。本轮刻意固定 sidecar：写侧有 sidecar 只写它、读侧它覆盖内嵌。
    public enum Canonical: String, Codable, Equatable, Sendable {
        case sidecar
    }

    public let photoId: String
    /// 冲突字段的稳定 id：DescriptiveField.rawValue，或 rating/label/keywords/dateTaken/latitude/longitude。已排序。
    public let fields: [String]
    public let canonical: Canonical

    public init(photoId: String, fields: [String]) throws {
        self.photoId = try APIValidation.nonBlank(photoId, field: "photoId", maxLength: 128)
        let normalized = fields.sorted()
        self.fields = try APIValidation.nonEmpty(normalized, field: "fields")
        self.canonical = .sidecar
    }
}

// MARK: - 默认实现（未接线 / 测试替身）

public extension MetadataAPI {
    /// 未接线时显式失败（INVALID_PARAM）：不返回可被误读成"已同步"的空状态。
    /// 状态类型见 Protocol/MetadataDelivery.swift（与生产实现同一形状）。
    func syncState(_ sessionId: String) async throws -> MetadataDeliveryState {
        _ = sessionId
        throw GatherError.invalidParameter(
            field: "syncState", reason: "metadata lifecycle API not wired")
    }

    /// 未接线时显式失败（INVALID_PARAM）：静默"成功但什么都没做"会让状态条骗人。
    func confirmSync(_ input: Confirmed<SessionReference>) async throws -> MetadataDeliveryState {
        _ = input
        throw GatherError.invalidParameter(
            field: "confirmSync", reason: "metadata lifecycle API not wired")
    }

    func finalizeSync(_ input: Confirmed<SessionReference>) async throws -> MetadataDeliveryState {
        _ = input
        throw GatherError.invalidParameter(
            field: "finalizeSync", reason: "metadata lifecycle API not wired")
    }

    func cleanupRetention(
        _ input: Confirmed<MetadataCleanupInput>
    ) async throws -> MetadataCleanupSummary {
        _ = input
        throw GatherError.invalidParameter(
            field: "cleanupRetention", reason: "metadata maintenance API not wired")
    }

    /// Wave5（batch5）：未接线时显式失败（INVALID_PARAM），不返回"什么都没写"的空 outcome。
    func applyGeoAndDate(
        _ input: Confirmed<MetadataGeoDateInput>
    ) async throws -> MetadataTemplateApplyOutcome {
        _ = input
        throw GatherError.invalidParameter(
            field: "applyGeoAndDate", reason: "geo/date API not wired")
    }

    /// 未接线/读不到返回 nil（= 未知）；调用方不得把它当成"盘上为空"。
    func diskGeoDate(photoId: String) async throws -> MetadataGeoDateSnapshot? {
        _ = photoId
        return nil
    }

    /// Wave5（batch9）：未接线 = 未知 → nil（UI 不显示警示，也不缓存"无冲突"结论）。
    func dualSourceConflict(photoId: String) async throws -> MetadataDualSourceConflict? {
        _ = photoId
        return nil
    }
}

// MARK: - 手动回收（设置页维护）

public struct MetadataCleanupInput: Codable, Equatable, Sendable {
    /// 立即回收已确认交付的行与备份；XMP 永远保留。
    public var sessionId: String
    /// true = 忽略 C1 reload-ack 门禁（用户显式点“立即清理”）。
    public var ignoreReloadAck: Bool

    public init(sessionId: String, ignoreReloadAck: Bool = true) {
        self.sessionId = sessionId
        self.ignoreReloadAck = ignoreReloadAck
    }
}

public struct MetadataCleanupSummary: Codable, Equatable, Sendable {
    public var deleted: Int
    public var retained: Int
    public var skipped: Int
    public var errors: [String]

    public init(deleted: Int = 0, retained: Int = 0, skipped: Int = 0, errors: [String] = []) {
        self.deleted = deleted
        self.retained = retained
        self.skipped = skipped
        self.errors = errors
    }
}

// MARK: - Wave2 / 词库默认实现（未接线：显式失败，不返回可被误读成"空词库"的结果）

public extension MetadataAPI {
    /// D3：未接线的实现返回 nil（= 未知）；批量直改据此置 diskKnown=false，
    /// 不会把"读不到盘"误判成"盘上已知为空"。
    func diskDescriptiveAvailability(
        photoId: String
    ) async throws -> DiskDescriptiveAvailability? {
        _ = photoId
        return nil
    }

    func keywordLibrary(_ query: KeywordLibraryQuery) async throws -> [KeywordLibraryNode] {
        _ = query
        throw GatherError.invalidParameter(
            field: "keywordLibrary", reason: "keyword library API not wired")
    }

    func keywordSuggestions(_ query: KeywordSuggestionQuery) async throws -> [KeywordSuggestion] {
        _ = query
        throw GatherError.invalidParameter(
            field: "keywordSuggestions", reason: "keyword library API not wired")
    }

    func renameKeyword(_ input: Confirmed<KeywordRenameInput>) async throws -> KeywordMutationSummary {
        _ = input
        throw GatherError.invalidParameter(
            field: "renameKeyword", reason: "keyword library API not wired")
    }

    func mergeKeywords(_ input: Confirmed<KeywordMergeInput>) async throws -> KeywordMutationSummary {
        _ = input
        throw GatherError.invalidParameter(
            field: "mergeKeywords", reason: "keyword library API not wired")
    }

    func deleteKeyword(_ input: Confirmed<KeywordDeleteInput>) async throws -> KeywordMutationSummary {
        _ = input
        throw GatherError.invalidParameter(
            field: "deleteKeyword", reason: "keyword library API not wired")
    }

    func setKeywordSynonyms(
        _ input: Confirmed<KeywordSynonymsInput>
    ) async throws -> KeywordMutationSummary {
        _ = input
        throw GatherError.invalidParameter(
            field: "setKeywordSynonyms", reason: "keyword library API not wired")
    }

    func createKeyword(_ input: Confirmed<KeywordCreateInput>) async throws -> KeywordMutationSummary {
        _ = input
        throw GatherError.invalidParameter(
            field: "createKeyword", reason: "keyword library API not wired")
    }
}
