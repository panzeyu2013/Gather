// API/MetadataCommands.swift
// R5 类型化 async 域协议：metadata 域。
// 旧实现来源：gather-app 的会话命令分发器 metadata.* 分支
// （每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、参数与返回只用 Protocol/Metadata.swift 既有 DTO、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// metadata 域命令（7 条）。
///
/// 旧命令清单：`metadata.get`、`metadata.set`、`metadata.batch_set`、
/// `metadata.conflicts`、`metadata.resolve_conflict`、`metadata.resolve_orphan`、
/// `metadata.orphans`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 `metadata.get` 要求 photoIds 非空（空数组按 INVALID_PARAM:photoIds 拒绝），
///   返回 photoId → MetadataTags 的字典；非空门控由实现保留。
/// - 旧 `metadata.set` 的响应为更新后的 MetadataTags（不另返回 {done:true}）。
/// - 旧 `metadata.batch_set` 要求 updates 非空（旧消息
///   "Invalid updates: must be a non-empty array"），返回 BatchMetadataResult。
/// - 旧 `metadata.orphans` 无入参，Protocol/ 无参数 DTO，故本方法不接收参数。
public protocol MetadataCommands: Sendable {
    /// 旧命令：`metadata.get`。
    /// 读取多张照片的标签；photoIds 必须非空，否则实现抛 INVALID_PARAM:photoIds。
    func get(_ params: MetadataGetParams) async throws -> [String: MetadataTags]

    /// 旧命令：`metadata.set`（破坏性）。
    /// MetadataSetParams.confirmed 必须为 true，否则实现抛
    /// METADATA_SET_CONFIRM_REQUIRED；返回落库后的标签。
    func set(_ params: MetadataSetParams) async throws -> MetadataTags

    /// 旧命令：`metadata.batch_set`（破坏性）。
    /// MetadataBatchSetParams.confirmed 必须为 true，否则实现抛
    /// METADATA_BATCH_SET_CONFIRM_REQUIRED；updates 必须非空。
    func batchSet(_ params: MetadataBatchSetParams) async throws -> BatchMetadataResult

    /// 旧命令：`metadata.conflicts`。
    /// 该会话的元数据冲突列表，元素为 Protocol/Metadata.swift 的 MetadataConflict。
    func conflicts(_ params: MetadataConflictListParams) async throws -> [MetadataConflict]

    /// 旧命令：`metadata.resolve_conflict`（破坏性）。
    /// MetadataConflictResolveParams.confirmed 必须为 true；choices 必须覆盖冲突的
    /// 全部字段，裁决后返回同步摘要（MetadataSyncSummary）。
    func resolveConflict(_ params: MetadataConflictResolveParams) async throws -> MetadataSyncSummary

    /// 旧命令：`metadata.resolve_orphan`（破坏性）。
    /// MetadataOrphanResolveParams.confirmed 必须为 true；按 action
    /// （keep / restore / retry）处理后返回当前孤儿列表。
    func resolveOrphan(_ params: MetadataOrphanResolveParams) async throws -> [MetadataOrphan]

    /// 旧命令：`metadata.orphans`。
    /// 列出全部孤儿元数据行，元素为 Protocol/Metadata.swift 的 MetadataOrphan。
    func orphans() async throws -> [MetadataOrphan]
}
