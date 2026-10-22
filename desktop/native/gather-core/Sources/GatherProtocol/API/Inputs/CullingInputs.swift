// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/CullingInputs.swift
// Cut 1 / 阶段 1A：CullingAPI 输入（culling.* 19 条命令 -> 17 个方法）。
//
// 对应命令：culling.list_page / history / apply_history / update / batch_update /
// decide_group / sync_status / groups / summary / reset / writeback / flush /
// retry_sync / retry_failed_writeback / cleanup / finalize_sync / confirm_sync。
// 校验归属：
// - scope/枚举由类型系统保证，未知 rawValue 在解码期失败（不再静默回退）；
// - 分页 limit/afterRowId、entries 数量与逐项字段、patch 范围在这里显式失败
//   （§6.2 / D-012）；patch 为空、rating 非 0...5 整数直接拒绝；
// - 破坏性入口一律 Confirmed<T>：reset / writeback / retryFailedWriteback /
//   cleanup / finalizeSync；确认来源只记日志，不再解析 confirmed Bool。

import Foundation

/// 复用 Protocol 的 patch 校验（旧 CullingService.validatePatch 的前置部分）。
func validateCullingPatch(_ patch: CullingUpdatePatch, field: String = "patch") throws {
    guard patch.rating != nil || patch.pickState != nil || patch.colorLabel != nil else {
        throw GatherError(
            code: .CULLING_PATCH_INVALID,
            params: ["field": field, "reason": "patch must contain at least one field"]
        )
    }
    if let rating = patch.rating {
        guard rating.isFinite, rating.rounded() == rating, (0.0...5.0).contains(rating) else {
            throw GatherError(
                code: .CULLING_PATCH_INVALID,
                params: ["field": "\(field).rating", "reason": "must be an integer from 0 to 5"]
            )
        }
    }
}

/// culling.list_page 的键集分页查询。
public struct CullingPageQuery: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let scope: CullingScope
    public let filters: CullingFilters?
    public let groupId: String?
    public let afterRowId: Int64?
    public let limit: Int

    public init(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        groupId: String? = nil,
        afterRowId: Int64? = nil,
        limit: Int? = nil
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.scope = scope
        if let filters {
            for (index, rating) in (filters.ratings ?? []).enumerated() {
                _ = try APIValidation.integer(rating, field: "filters.ratings[\(index)]", in: 0...5)
            }
        }
        self.filters = filters
        self.groupId = groupId
        if let afterRowId, afterRowId < 1 {
            throw GatherError.invalidParameter(field: "afterRowId", reason: "must be a positive integer")
        }
        self.afterRowId = afterRowId
        self.limit = try APIValidation.integerInRange(limit ?? 200, field: "limit", 1...2_000)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            scope: try container.decode(CullingScope.self, forKey: .scope),
            filters: try container.decodeIfPresent(CullingFilters.self, forKey: .filters),
            groupId: try container.decodeIfPresent(String.self, forKey: .groupId),
            afterRowId: try container.decodeIfPresent(Int64.self, forKey: .afterRowId),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, scope, filters, groupId, afterRowId, limit
    }
}

/// culling.history 的查询（limit 缺省 100，范围 1...500）。
public struct CullingHistoryQuery: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let limit: Int

    public init(sessionId: String, limit: Int? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.limit = try APIValidation.integerInRange(limit ?? 100, field: "limit", 1...500)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, limit
    }
}

/// culling.apply_history 的输入：entries 1...10000，逐项 photoId/expectedRevision/patch。
public struct CullingApplyHistoryInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let entries: [CullingHistoryApplyEntry]
    public let historyOperationId: Int
    public let direction: CullingHistoryDirection

    public init(
        sessionId: String,
        entries: [CullingHistoryApplyEntry],
        historyOperationId: Int,
        direction: CullingHistoryDirection
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.entries = try APIValidation.nonEmpty(entries, field: "entries", maxCount: 10_000)
        for (index, entry) in self.entries.enumerated() {
            _ = try APIValidation.nonBlank(entry.photoId, field: "entries[\(index)].photoId", maxLength: 128)
            _ = try APIValidation.nonNegative(entry.expectedRevision, field: "entries[\(index)].expectedRevision")
            try validateCullingPatch(entry.patch, field: "entries[\(index)].patch")
        }
        self.historyOperationId = try APIValidation.positive(historyOperationId, field: "historyOperationId")
        self.direction = direction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            entries: try container.decode([CullingHistoryApplyEntry].self, forKey: .entries),
            historyOperationId: try container.decode(Int.self, forKey: .historyOperationId),
            direction: try container.decode(CullingHistoryDirection.self, forKey: .direction)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, entries, historyOperationId, direction
    }
}

/// culling.update 的单张更新输入（expectedRevision >= 0，patch 必须合法且非空）。
public struct CullingUpdateInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let photoId: String
    public let expectedRevision: Int
    public let patch: CullingUpdatePatch

    public init(sessionId: String, photoId: String, expectedRevision: Int, patch: CullingUpdatePatch) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.photoId = try APIValidation.nonBlank(photoId, field: "photoId", maxLength: 128)
        self.expectedRevision = try APIValidation.nonNegative(expectedRevision, field: "expectedRevision")
        try validateCullingPatch(patch)
        self.patch = patch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            photoId: try container.decode(String.self, forKey: .photoId),
            expectedRevision: try container.decode(Int.self, forKey: .expectedRevision),
            patch: try container.decode(CullingUpdatePatch.self, forKey: .patch)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, photoId, expectedRevision, patch
    }
}

/// culling.batch_update 的输入（photoIds 1...10000）。
public struct CullingBatchUpdateInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let photoIds: [String]
    public let patch: CullingUpdatePatch

    public init(sessionId: String, photoIds: [String], patch: CullingUpdatePatch) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.photoIds = try APIValidation.nonEmpty(photoIds, field: "photoIds", maxCount: 10_000)
        for (index, id) in self.photoIds.enumerated() {
            _ = try APIValidation.nonBlank(id, field: "photoIds[\(index)]", maxLength: 128)
        }
        try validateCullingPatch(patch)
        self.patch = patch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            photoIds: try container.decode([String].self, forKey: .photoIds),
            patch: try container.decode(CullingUpdatePatch.self, forKey: .patch)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, photoIds, patch
    }
}

/// culling.decide_group 的输入（keepPhotoIds <= 10000；空选择由服务报 CULLING_EMPTY_SELECTION）。
public struct CullingDecideGroupInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let groupId: String
    public let keepPhotoIds: [String]

    public init(sessionId: String, groupId: String, keepPhotoIds: [String]) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.groupId = try APIValidation.nonBlank(groupId, field: "groupId", maxLength: 128)
        guard keepPhotoIds.count <= 10_000 else {
            throw GatherError.invalidParameter(field: "keepPhotoIds", reason: "count must be at most 10000")
        }
        for (index, id) in keepPhotoIds.enumerated() {
            _ = try APIValidation.nonBlank(id, field: "keepPhotoIds[\(index)]", maxLength: 128)
        }
        self.keepPhotoIds = keepPhotoIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            groupId: try container.decode(String.self, forKey: .groupId),
            keepPhotoIds: try container.decode([String].self, forKey: .keepPhotoIds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, groupId, keepPhotoIds
    }
}

/// culling.reset 的载荷（Confirmed<CullingResetInput>）。
public struct CullingResetInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let groupId: String?

    public init(sessionId: String, groupId: String? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.groupId = groupId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            groupId: try container.decodeIfPresent(String.self, forKey: .groupId)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, groupId
    }
}

/// culling.writeback 的载荷（Confirmed<CullingWritebackInput>）。
public struct CullingWritebackInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let target: CullingWritebackTarget

    public init(sessionId: String, target: CullingWritebackTarget) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.target = target
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            target: try container.decode(CullingWritebackTarget.self, forKey: .target)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, target
    }
}
