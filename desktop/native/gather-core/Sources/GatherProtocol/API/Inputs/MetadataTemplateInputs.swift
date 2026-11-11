// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/MetadataTemplateInputs.swift
// P1 / B2：元数据模板 API 的输入与结果 DTO。
//
// 为什么单独一层 DTO：内部计划类型（MetadataPhotoImpact）携带 XMPFieldValue，不便作为
// 跨进程契约；API 层按"字段名 + 动作"扁平化成字符串，前端只需要渲染。
import Foundation

// MARK: - 输入

public struct MetadataTemplateSaveInput: Decodable, Sendable, Equatable {
    /// nil = 新建；非 nil = 更新（保留 createdAt）。
    public let id: String?
    public let name: String
    public let fields: DescriptiveMetadata
    /// Wave2 收尾 task-22：模板级客户名（变量 {client} 的取值）。
    /// nil/空白 = 未设置；旧模板 JSON 缺该字段时解码为 nil，行为不变。
    public let client: String?

    public init(id: String?, name: String, fields: DescriptiveMetadata, client: String? = nil) throws {
        self.id = id
        self.name = try APIValidation.nonBlank(name, field: "name", maxLength: 120)
        self.fields = fields
        self.client = try Self.normalizedClient(client)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            fields: try container.decode(DescriptiveMetadata.self, forKey: .fields),
            client: try container.decodeIfPresent(String.self, forKey: .client)
        )
    }

    /// 客户名归一化：trim；空白 = nil；长度上限 120（与模板名同界）。
    static func normalizedClient(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= 120 else {
            throw GatherError.invalidParameter(
                field: "client", reason: "must be at most 120 characters")
        }
        return trimmed
    }

    private enum CodingKeys: String, CodingKey { case id, name, fields, client }
}

public struct MetadataTemplateDeleteInput: Decodable, Sendable, Equatable {
    public let templateId: String
    public init(templateId: String) throws {
        self.templateId = try APIValidation.nonBlank(templateId, field: "templateId", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(templateId: try container.decode(String.self, forKey: .templateId))
    }

    private enum CodingKeys: String, CodingKey { case templateId }
}

public struct MetadataTemplatePreviewInput: Decodable, Sendable, Equatable {
    public let templateId: String
    public let photoIds: [String]
    public let policy: MetadataConflictPolicy
    /// P2：单批上限（与 apply 同值）。超过就显式失败，不让 UI 以为"已套用全部"。
    public static let maxPhotoIds = 2_000

    public init(templateId: String, photoIds: [String], policy: MetadataConflictPolicy = .keepExternal) throws {
        self.templateId = try APIValidation.nonBlank(templateId, field: "templateId", maxLength: 128)
        self.photoIds = try APIValidation.nonEmpty(
            photoIds, field: "photoIds", maxCount: Self.maxPhotoIds)
        self.policy = policy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            templateId: try container.decode(String.self, forKey: .templateId),
            photoIds: try container.decode([String].self, forKey: .photoIds),
            policy: try container.decodeIfPresent(MetadataConflictPolicy.self, forKey: .policy) ?? .keepExternal
        )
    }

    private enum CodingKeys: String, CodingKey { case templateId, photoIds, policy }
}

public struct MetadataTemplateApplyInput: Decodable, Sendable, Equatable {
    public let templateId: String
    public let photoIds: [String]
    public let policy: MetadataConflictPolicy
    /// 预览令牌；有照片的 apply 必须携带，服务端按当前模板/照片集复算。
    public let expectedPreviewToken: String?
    /// P2：单批上限。批次快照要整体写进 settings（保留最近 20 批），
    /// 无上限时一次 2 万张会把单键写成几十 MB。
    public static let maxPhotoIds = 2_000

    public init(
        templateId: String,
        photoIds: [String],
        policy: MetadataConflictPolicy = .keepExternal,
        expectedPreviewToken: String? = nil
    ) throws {
        self.templateId = try APIValidation.nonBlank(templateId, field: "templateId", maxLength: 128)
        self.photoIds = try APIValidation.nonEmpty(
            photoIds, field: "photoIds", maxCount: Self.maxPhotoIds)
        self.policy = policy
        self.expectedPreviewToken = expectedPreviewToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            templateId: try container.decode(String.self, forKey: .templateId),
            photoIds: try container.decode([String].self, forKey: .photoIds),
            policy: try container.decodeIfPresent(MetadataConflictPolicy.self, forKey: .policy) ?? .keepExternal,
            expectedPreviewToken: try container.decodeIfPresent(
                String.self, forKey: .expectedPreviewToken)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case templateId, photoIds, policy, expectedPreviewToken
    }
}

public struct MetadataTemplateUndoInput: Decodable, Sendable, Equatable {
    public let batchId: String
    public init(batchId: String) throws {
        self.batchId = try APIValidation.nonBlank(batchId, field: "batchId", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(batchId: try container.decode(String.self, forKey: .batchId))
    }

    private enum CodingKeys: String, CodingKey { case batchId }
}

// MARK: - 结果

public struct MetadataTemplateSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var fieldCount: Int
    public var createdAt: String
    public var updatedAt: String
    /// Wave2 收尾 task-22：模板级客户名（{client} 作用域）；nil = 未设置。
    public var client: String?
    public init(
        id: String, name: String, fieldCount: Int, createdAt: String, updatedAt: String,
        client: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fieldCount = fieldCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.client = client
    }
}

/// 模板变量未解析项（预览逐字段列出；apply 会拒绝整批写入）。
public struct MetadataTemplateUnresolvedVariable: Codable, Equatable, Hashable, Sendable {
    /// DescriptiveField.rawValue（"caption"/"copyrightNotice"…）。
    public var field: String
    /// 原文占位符（如 "{client}"、"{year}"）。
    public var variable: String
    public init(field: String, variable: String) {
        self.field = field
        self.variable = variable
    }
}

public struct MetadataPhotoPreview: Codable, Equatable, Sendable {
    public var photoId: String
    /// 将被写入的字段名（DescriptiveField.rawValue）。
    public var writes: [String]
    /// 将被清空的字段名。
    public var clears: [String]
    /// 因外部改动而跳过的字段名。
    public var conflicts: [String]
    /// 模板变量未解析、因而不会写入的字段（逐字段列出，供 UI 定位）。
    public var unresolved: [MetadataTemplateUnresolvedVariable]
    public init(
        photoId: String, writes: [String], clears: [String], conflicts: [String],
        unresolved: [MetadataTemplateUnresolvedVariable] = []
    ) {
        self.photoId = photoId
        self.writes = writes
        self.clears = clears
        self.conflicts = conflicts
        self.unresolved = unresolved
    }
}

public struct MetadataTemplatePreviewResult: Codable, Equatable, Sendable {
    public var templateId: String
    public var templateName: String
    public var totalPhotos: Int
    public var changedPhotos: Int
    public var changedFields: Int
    public var conflictFields: Int
    public var photos: [MetadataPhotoPreview]
    /// 预览身份；apply 时服务端按当前模板/照片集复算。
    public var previewToken: String?
    public init(
        templateId: String, templateName: String, totalPhotos: Int, changedPhotos: Int,
        changedFields: Int, conflictFields: Int, photos: [MetadataPhotoPreview],
        previewToken: String? = nil
    ) {
        self.templateId = templateId
        self.templateName = templateName
        self.totalPhotos = totalPhotos
        self.changedPhotos = changedPhotos
        self.changedFields = changedFields
        self.conflictFields = conflictFields
        self.photos = photos
        self.previewToken = previewToken
    }

    /// 变量未解析总数（UI 禁用「应用」与逐字段提示共用）。
    public var unresolvedVariableCount: Int {
        photos.reduce(0) { $0 + $1.unresolved.count }
    }

    public var hasUnresolvedVariables: Bool { unresolvedVariableCount > 0 }
}

/// P1 / B3：批次摘要（不含快照明细，撤销只认 id）。
public struct MetadataBatchSummary: Codable, Equatable, Sendable {
    public var batchId: String
    /// "template" / "triage"
    public var kind: String
    public var name: String
    public var appliedAt: String
    public var undone: Bool
    public var photoCount: Int
    public init(batchId: String, kind: String, name: String, appliedAt: String,
                undone: Bool, photoCount: Int) {
        self.batchId = batchId
        self.kind = kind
        self.name = name
        self.appliedAt = appliedAt
        self.undone = undone
        self.photoCount = photoCount
    }
}

public struct MetadataApplyFailureDTO: Codable, Equatable, Sendable {
    public var photoId: String
    public var message: String
    /// 稳定错误码（摄取失败等场景）；nil/空 = 只有散文。
    public var code: String?
    public var retryable: Bool?
    public init(
        photoId: String, message: String,
        code: String? = nil, retryable: Bool? = nil
    ) {
        self.photoId = photoId
        self.message = message
        self.code = code
        self.retryable = retryable
    }
}

public struct MetadataTemplateApplyOutcome: Codable, Equatable, Sendable {
    public var batchId: String
    public var written: [String]
    public var skipped: [String]
    public var conflicts: [String]
    public var failed: [MetadataApplyFailureDTO]
    /// 这批是否真的有可撤销快照（written ∪ uncertain 非空）。false 时 UI 不显示
    /// 撤销入口——否则"全失败且批次已标 undone"会给出点了必然报错的假入口。
    public var undoAvailable: Bool
    public init(
        batchId: String,
        written: [String],
        skipped: [String],
        conflicts: [String],
        failed: [MetadataApplyFailureDTO],
        undoAvailable: Bool = false
    ) {
        self.batchId = batchId
        self.written = written
        self.skipped = skipped
        self.conflicts = conflicts
        self.failed = failed
        self.undoAvailable = undoAvailable
    }
}
