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

    public init(id: String?, name: String, fields: DescriptiveMetadata) throws {
        self.id = id
        self.name = try APIValidation.nonBlank(name, field: "name", maxLength: 120)
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            fields: try container.decode(DescriptiveMetadata.self, forKey: .fields)
        )
    }

    private enum CodingKeys: String, CodingKey { case id, name, fields }
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
    public init(templateId: String, photoIds: [String], policy: MetadataConflictPolicy = .keepExternal) throws {
        self.templateId = try APIValidation.nonBlank(templateId, field: "templateId", maxLength: 128)
        guard !photoIds.isEmpty else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "must not be empty")
        }
        self.photoIds = photoIds
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
    public init(templateId: String, photoIds: [String], policy: MetadataConflictPolicy = .keepExternal) throws {
        self.templateId = try APIValidation.nonBlank(templateId, field: "templateId", maxLength: 128)
        guard !photoIds.isEmpty else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "must not be empty")
        }
        self.photoIds = photoIds
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
    public init(id: String, name: String, fieldCount: Int, createdAt: String, updatedAt: String) {
        self.id = id
        self.name = name
        self.fieldCount = fieldCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
    public init(photoId: String, writes: [String], clears: [String], conflicts: [String]) {
        self.photoId = photoId
        self.writes = writes
        self.clears = clears
        self.conflicts = conflicts
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
    public init(templateId: String, templateName: String, totalPhotos: Int, changedPhotos: Int,
                changedFields: Int, conflictFields: Int, photos: [MetadataPhotoPreview]) {
        self.templateId = templateId
        self.templateName = templateName
        self.totalPhotos = totalPhotos
        self.changedPhotos = changedPhotos
        self.changedFields = changedFields
        self.conflictFields = conflictFields
        self.photos = photos
    }
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
    public init(photoId: String, message: String) {
        self.photoId = photoId
        self.message = message
    }
}

public struct MetadataTemplateApplyOutcome: Codable, Equatable, Sendable {
    public var batchId: String
    public var written: [String]
    public var skipped: [String]
    public var conflicts: [String]
    public var failed: [MetadataApplyFailureDTO]
    public init(batchId: String, written: [String], skipped: [String], conflicts: [String], failed: [MetadataApplyFailureDTO]) {
        self.batchId = batchId
        self.written = written
        self.skipped = skipped
        self.conflicts = conflicts
        self.failed = failed
    }
}
