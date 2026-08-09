// desktop/native/gather-core/Sources/GatherCore/Protocol/Template.swift
// TS 源: packages/shared/src/protocol/template.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: TemplateCreateParams
public struct TemplateCreateParams: Codable, Equatable, Sendable {
    public var name: String
    public var description: String? // TS: description?
    public var config: WorkflowTemplateConfig

    public init(name: String, description: String? = nil, config: WorkflowTemplateConfig) {
        self.name = name
        self.description = description
        self.config = config
    }
}

// TS: TemplateListParams
public struct TemplateListParams: Codable, Equatable, Sendable {
    public init() {}
}

// TS: TemplateGetParams
public struct TemplateGetParams: Codable, Equatable, Sendable {
    public var templateId: String

    public init(templateId: String) {
        self.templateId = templateId
    }
}

// TS: TemplateUpdateParams
public struct TemplateUpdateParams: Codable, Equatable, Sendable {
    public var templateId: String
    public var name: String? // TS: name?
    public var description: String? // TS: description?
    public var config: WorkflowTemplateConfig? // TS: config?

    public init(templateId: String, name: String? = nil, description: String? = nil, config: WorkflowTemplateConfig? = nil) {
        self.templateId = templateId
        self.name = name
        self.description = description
        self.config = config
    }
}

// TS: TemplateDeleteParams
public struct TemplateDeleteParams: Codable, Equatable, Sendable {
    public var templateId: String
    public var confirmed: Bool

    public init(templateId: String, confirmed: Bool) {
        self.templateId = templateId
        self.confirmed = confirmed
    }
}

// TS: TemplateApplyParams
public struct TemplateApplyParams: Codable, Equatable, Sendable {
    public var templateId: String
    public var sessionId: String
    public var confirmed: Bool

    public init(templateId: String, sessionId: String, confirmed: Bool) {
        self.templateId = templateId
        self.sessionId = sessionId
        self.confirmed = confirmed
    }
}

// TS: WorkflowTemplateConfig.similarity（内联匿名对象）
public struct WorkflowTemplateSimilarity: Codable, Equatable, Sendable {
    public var threshold: Double
    public var minGroupSize: Int

    public init(threshold: Double, minGroupSize: Int) {
        self.threshold = threshold
        self.minGroupSize = minGroupSize
    }
}

// TS: WorkflowTemplateConfig.face（内联匿名对象）
public struct WorkflowTemplateFace: Codable, Equatable, Sendable {
    public var eps: Double
    public var minSamples: Int
    public var detectorConfidence: Double

    public init(eps: Double, minSamples: Int, detectorConfidence: Double) {
        self.eps = eps
        self.minSamples = minSamples
        self.detectorConfidence = detectorConfidence
    }
}

// TS: WorkflowTemplateConfig.faceLibrary（内联匿名对象）
public struct WorkflowTemplateFaceLibrary: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var matchThreshold: Double

    public init(enabled: Bool, matchThreshold: Double) {
        self.enabled = enabled
        self.matchThreshold = matchThreshold
    }
}

// TS: WorkflowTemplateConfig.duplicate（内联匿名对象）
public struct WorkflowTemplateDuplicate: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var visualThreshold: Double

    public init(enabled: Bool, visualThreshold: Double) {
        self.enabled = enabled
        self.visualThreshold = visualThreshold
    }
}

// TS: WorkflowTemplateConfig.writeback（内联匿名对象）
public struct WorkflowTemplateWriteback: Codable, Equatable, Sendable {
    public var createAlbums: Bool
    public var addPrefix: Bool
    public var markUngrouped: Bool
    public var writeIPTC: Bool

    public init(createAlbums: Bool, addPrefix: Bool, markUngrouped: Bool, writeIPTC: Bool) {
        self.createAlbums = createAlbums
        self.addPrefix = addPrefix
        self.markUngrouped = markUngrouped
        self.writeIPTC = writeIPTC
    }
}

// TS: WorkflowTemplateConfig
public struct WorkflowTemplateConfig: Codable, Equatable, Sendable {
    public var similarity: WorkflowTemplateSimilarity
    public var face: WorkflowTemplateFace
    public var faceLibrary: WorkflowTemplateFaceLibrary
    public var duplicate: WorkflowTemplateDuplicate
    public var writeback: WorkflowTemplateWriteback

    public init(
        similarity: WorkflowTemplateSimilarity,
        face: WorkflowTemplateFace,
        faceLibrary: WorkflowTemplateFaceLibrary,
        duplicate: WorkflowTemplateDuplicate,
        writeback: WorkflowTemplateWriteback
    ) {
        self.similarity = similarity
        self.face = face
        self.faceLibrary = faceLibrary
        self.duplicate = duplicate
        self.writeback = writeback
    }
}

// TS: TemplateData
public struct TemplateData: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var config: WorkflowTemplateConfig
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, name: String, description: String, config: WorkflowTemplateConfig, createdAt: String, updatedAt: String) {
        self.id = id
        self.name = name
        self.description = description
        self.config = config
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
