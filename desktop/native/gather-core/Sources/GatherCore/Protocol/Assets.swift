// desktop/native/gather-core/Sources/GatherCore/Protocol/Assets.swift
// TS 源: packages/shared/src/protocol/assets.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: AssetCandidateListParams
public struct AssetCandidateListParams: Codable, Equatable, Sendable {
    public var sessionId: String? // TS: sessionId?

    public init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }
}

// TS: AssetCandidateMutationParams
public struct AssetCandidateMutationParams: Codable, Equatable, Sendable {
    public var candidateId: String
    public var confirmed: Bool

    public init(candidateId: String, confirmed: Bool) {
        self.candidateId = candidateId
        self.confirmed = confirmed
    }
}

// TS: status（assets.ts 内联联合 'pending' | 'accepted' | 'rejected'）
public enum AssetLinkCandidateStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case pending
    case accepted
    case rejected
}

// TS: AssetLinkCandidateData
public struct AssetLinkCandidateData: Codable, Equatable, Sendable {
    public var id: String
    public var leftFileId: String
    public var rightFileId: String
    public var leftPath: String
    public var rightPath: String
    public var confidence: Double
    public var status: AssetLinkCandidateStatus
    public var evidence: [String: JSONValue] // TS: evidence: Record<string, unknown>

    public init(
        id: String,
        leftFileId: String,
        rightFileId: String,
        leftPath: String,
        rightPath: String,
        confidence: Double,
        status: AssetLinkCandidateStatus,
        evidence: [String: JSONValue]
    ) {
        self.id = id
        self.leftFileId = leftFileId
        self.rightFileId = rightFileId
        self.leftPath = leftPath
        self.rightPath = rightPath
        self.confidence = confidence
        self.status = status
        self.evidence = evidence
    }
}

// TS: AssetVolumeData
public struct AssetVolumeData: Codable, Equatable, Sendable {
    public var volumeId: String
    public var roots: [String]
    public var onlineFiles: Int
    public var offlineFiles: Int

    public init(volumeId: String, roots: [String], onlineFiles: Int, offlineFiles: Int) {
        self.volumeId = volumeId
        self.roots = roots
        self.onlineFiles = onlineFiles
        self.offlineFiles = offlineFiles
    }
}

// TS: AssetRelinkRootParams
public struct AssetRelinkRootParams: Codable, Equatable, Sendable {
    public var oldRoot: String
    public var newRoot: String
    public var confirmed: Bool

    public init(oldRoot: String, newRoot: String, confirmed: Bool) {
        self.oldRoot = oldRoot
        self.newRoot = newRoot
        self.confirmed = confirmed
    }
}
