// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Session.swift
// TS 源: packages/shared/src/protocol/session.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: SessionUpdateParams
public struct SessionUpdateParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var name: String

    public init(sessionId: String, name: String) {
        self.sessionId = sessionId
        self.name = name
    }
}

// TS: SessionData
public struct SessionData: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var status: SessionStatus
    public var photoCount: Int
    public var analysisStatus: AnalysisStatus
    public var writebackStatus: WritebackStatus
    public var importSource: String
    public var sourcePath: String
    public var failedWritebackCount: Int
    public var truncatedImport: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        status: SessionStatus,
        photoCount: Int,
        analysisStatus: AnalysisStatus,
        writebackStatus: WritebackStatus,
        importSource: String,
        sourcePath: String,
        failedWritebackCount: Int,
        truncatedImport: Bool,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.photoCount = photoCount
        self.analysisStatus = analysisStatus
        self.writebackStatus = writebackStatus
        self.importSource = importSource
        self.sourcePath = sourcePath
        self.failedWritebackCount = failedWritebackCount
        self.truncatedImport = truncatedImport
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// TS: PhotoData.variants 的元素（匿名对象 { photoId, filepath, filename, role }）
public struct PhotoVariant: Codable, Equatable, Sendable {
    public var photoId: String
    public var filepath: String
    public var filename: String
    public var role: String

    public init(photoId: String, filepath: String, filename: String, role: String) {
        self.photoId = photoId
        self.filepath = filepath
        self.filename = filename
        self.role = role
    }
}

// TS: PhotoData
public struct PhotoData: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var filepath: String
    public var filename: String
    public var checksum: String
    public var hasExistingXmp: Bool
    public var faceCount: Int
    public var width: Int
    public var height: Int
    public var metadata: [String: JSONValue] // TS: metadata: Record<string, unknown>
    public var result: [String: JSONValue] // TS: result: Record<string, unknown>
    public var status: String
    public var assetId: String? // TS: assetId?
    public var variantCount: Int? // TS: variantCount?
    public var variants: [PhotoVariant]? // TS: variants?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        sessionId: String,
        filepath: String,
        filename: String,
        checksum: String,
        hasExistingXmp: Bool,
        faceCount: Int,
        width: Int,
        height: Int,
        metadata: [String: JSONValue],
        result: [String: JSONValue],
        status: String,
        assetId: String? = nil,
        variantCount: Int? = nil,
        variants: [PhotoVariant]? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.filepath = filepath
        self.filename = filename
        self.checksum = checksum
        self.hasExistingXmp = hasExistingXmp
        self.faceCount = faceCount
        self.width = width
        self.height = height
        self.metadata = metadata
        self.result = result
        self.status = status
        self.assetId = assetId
        self.variantCount = variantCount
        self.variants = variants
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
