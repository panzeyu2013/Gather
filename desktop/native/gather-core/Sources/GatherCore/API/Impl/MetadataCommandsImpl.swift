// API/Impl/MetadataCommandsImpl.swift
// R5 命令层接线：metadata 域实现（批次 B5）。
// 逻辑来源：宿主路由层 metadata.* 分支；错误码字符串/错误类型/返回形状不变：
// - get 的 photoIds 非空门控保留（空数组按 INVALID_PARAM:photoIds 拒绝），
//   读路径经 MetadataService（指纹缓存 / EXIF-XMP 提取）；
// - set / batch_set 为破坏性命令：confirmed 必须为 true，否则分别抛
//   METADATA_SET_CONFIRM_REQUIRED / METADATA_BATCH_SET_CONFIRM_REQUIRED；
//   batch_set 的 updates 非空校验保留（旧消息逐字：
//   "Invalid updates: must be a non-empty array"）；
// - conflicts / resolve_conflict / resolve_orphan / orphans 经元数据同步协调器
//   （getConflicts / resolveConflict / resolveOrphan / listOrphans），
//   resolve_conflict / resolve_orphan 的确认门控保留，choices 覆盖校验
//   （XMP_CHOICE_MISSING）与孤儿动作校验由协调器承担。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// metadata 域命令实现：注入元数据服务（缓存读写）与同步协调器（冲突/孤儿）。
public actor MetadataCommandsImpl: MetadataCommands {
    private let metadata: MetadataService
    private let sync: MetadataSyncRuntime

    public init(metadata: MetadataService, sync: MetadataSyncRuntime) {
        self.metadata = metadata
        self.sync = sync
    }

    /// 旧命令：`metadata.get`。photoIds 为空 → INVALID_PARAM:photoIds（旧门控保留）。
    public func get(_ params: MetadataGetParams) async throws -> [String: MetadataTags] {
        guard !params.photoIds.isEmpty else {
            throw MetadataCommandsError.invalidParam("photoIds")
        }
        return try await metadata.getMetadata(photoIds: params.photoIds)
    }

    /// 旧命令：`metadata.set`（破坏性）。confirmed 非 true →
    /// METADATA_SET_CONFIRM_REQUIRED；返回落库后的合并标签。
    public func set(_ params: MetadataSetParams) async throws -> MetadataTags {
        guard params.confirmed else {
            throw MetadataCommandsError.setConfirmRequired
        }
        return try await metadata.setMetadata(photoId: params.photoId, tags: params.tags)
    }

    /// 旧命令：`metadata.batch_set`（破坏性）。confirmed 门控 + updates 非空校验；
    /// 逐项失败隔离由 MetadataService 承担（BatchMetadataResult 含 success/failed/errors）。
    public func batchSet(_ params: MetadataBatchSetParams) async throws -> BatchMetadataResult {
        guard params.confirmed else {
            throw MetadataCommandsError.batchSetConfirmRequired
        }
        guard !params.updates.isEmpty else {
            throw MetadataCommandsError.invalidUpdates
        }
        return try await metadata.batchSet(
            updates: params.updates.map { (photoId: $0.photoId, tags: $0.tags) })
    }

    /// 旧命令：`metadata.conflicts`。该会话冲突列表（sidecar 外部改动现读）。
    public func conflicts(_ params: MetadataConflictListParams) async throws -> [MetadataConflict] {
        try await sync.getConflicts(sessionId: params.sessionId)
    }

    /// 旧命令：`metadata.resolve_conflict`（破坏性）。confirmed 门控后逐字段裁决；
    /// choices 未覆盖全部冲突字段时由协调器抛 XMP_CHOICE_MISSING（旧语义）。
    public func resolveConflict(_ params: MetadataConflictResolveParams) async throws -> MetadataSyncSummary {
        guard params.confirmed else {
            throw MetadataCommandsError.resolveConflictConfirmRequired
        }
        return try await sync.resolveConflict(
            sessionId: params.sessionId,
            xmpPath: params.xmpPath,
            choices: params.choices
        )
    }

    /// 旧命令：`metadata.resolve_orphan`（破坏性）。confirmed 门控后按 action
    /// （keep / restore / retry）处理，返回处理后的孤儿列表。
    public func resolveOrphan(_ params: MetadataOrphanResolveParams) async throws -> [MetadataOrphan] {
        guard params.confirmed else {
            throw MetadataCommandsError.resolveOrphanConfirmRequired
        }
        return try await sync.resolveOrphan(xmpPath: params.xmpPath, action: params.action)
    }

    /// 旧命令：`metadata.orphans`。全部孤儿元数据行（无入参）。
    public func orphans() async throws -> [MetadataOrphan] {
        try await sync.listOrphans()
    }
}

/// metadata 域命令边界错误（错误码字符串与旧宿主路由层分支逐字一致）。
public enum MetadataCommandsError: Error, Equatable {
    /// 旧参数校验拒绝：`INVALID_PARAM:<key>`。
    case invalidParam(String)
    /// 旧参数校验拒绝：`Invalid updates: must be a non-empty array`。
    case invalidUpdates
    /// 旧响应 error 串：`METADATA_SET_CONFIRM_REQUIRED`。
    case setConfirmRequired
    /// 旧响应 error 串：`METADATA_BATCH_SET_CONFIRM_REQUIRED`。
    case batchSetConfirmRequired
    /// 旧响应 error 串：`METADATA_RESOLVE_CONFLICT_CONFIRM_REQUIRED`。
    case resolveConflictConfirmRequired
    /// 旧响应 error 串：`METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED`。
    case resolveOrphanConfirmRequired
}

extension MetadataCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidParam(let key): "INVALID_PARAM:\(key)"
        case .invalidUpdates: "Invalid updates: must be a non-empty array"
        case .setConfirmRequired: "METADATA_SET_CONFIRM_REQUIRED"
        case .batchSetConfirmRequired: "METADATA_BATCH_SET_CONFIRM_REQUIRED"
        case .resolveConflictConfirmRequired: "METADATA_RESOLVE_CONFLICT_CONFIRM_REQUIRED"
        case .resolveOrphanConfirmRequired: "METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED"
        }
    }
}

extension MetadataCommandsError {
    /// 桥接层序列化用；参数化 INVALID_PARAM / 消息型 invalidUpdates 无同码 case。
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .invalidParam, .invalidUpdates: nil
        case .setConfirmRequired: .METADATA_SET_CONFIRM_REQUIRED
        case .batchSetConfirmRequired: .METADATA_BATCH_SET_CONFIRM_REQUIRED
        case .resolveConflictConfirmRequired: .METADATA_RESOLVE_CONFLICT_CONFIRM_REQUIRED
        case .resolveOrphanConfirmRequired: .METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED
        }
    }
}
