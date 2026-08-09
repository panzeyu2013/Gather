// desktop/native/gather-core/Sources/GatherCore/Protocol/Quality.swift
// TS 源: packages/shared/src/protocol/quality.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: QualityAnalyzeParams
public struct QualityAnalyzeParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoIds: [String]? // TS: photoIds?

    public init(sessionId: String, photoIds: [String]? = nil) {
        self.sessionId = sessionId
        self.photoIds = photoIds
    }
}

// TS: QualityGetParams
public struct QualityGetParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoIds: [String]? // TS: photoIds?

    public init(sessionId: String, photoIds: [String]? = nil) {
        self.sessionId = sessionId
        self.photoIds = photoIds
    }
}

// TS: QualityResult.status（quality.ts 内联联合 'succeeded' | 'failed'）
public enum QualityResultStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case succeeded
    case failed
}

// TS: QualityResult
public struct QualityResult: Codable, Equatable, Sendable {
    public var photoId: String
    public var assetFileId: String? // TS: assetFileId?
    public var status: QualityResultStatus
    public var errorMessage: String? // TS: errorMessage?
    public var qualityScore: Double
    public var sharpness: Double
    public var exposure: Double
    public var subjectSharpness: Double? // TS: subjectSharpness?
    public var faceQuality: Double? // TS: faceQuality?
    public var closedEyeRisk: Double? // TS: closedEyeRisk?
    public var closedEyeProbability: Double? // TS: closedEyeProbability?
    public var confidence: Double? // TS: confidence?
    public var relativeRank: Double? // TS: relativeRank?
    public var warnings: [String]
    public var modelId: String
    public var modelVersion: String
    public var inputFingerprint: String
    public var updatedAt: String

    public init(
        photoId: String,
        assetFileId: String? = nil,
        status: QualityResultStatus,
        errorMessage: String? = nil,
        qualityScore: Double,
        sharpness: Double,
        exposure: Double,
        subjectSharpness: Double? = nil,
        faceQuality: Double? = nil,
        closedEyeRisk: Double? = nil,
        closedEyeProbability: Double? = nil,
        confidence: Double? = nil,
        relativeRank: Double? = nil,
        warnings: [String],
        modelId: String,
        modelVersion: String,
        inputFingerprint: String,
        updatedAt: String
    ) {
        self.photoId = photoId
        self.assetFileId = assetFileId
        self.status = status
        self.errorMessage = errorMessage
        self.qualityScore = qualityScore
        self.sharpness = sharpness
        self.exposure = exposure
        self.subjectSharpness = subjectSharpness
        self.faceQuality = faceQuality
        self.closedEyeRisk = closedEyeRisk
        self.closedEyeProbability = closedEyeProbability
        self.confidence = confidence
        self.relativeRank = relativeRank
        self.warnings = warnings
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.inputFingerprint = inputFingerprint
        self.updatedAt = updatedAt
    }
}
