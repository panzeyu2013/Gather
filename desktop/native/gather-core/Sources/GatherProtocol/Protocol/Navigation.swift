// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Navigation.swift
// TS 源: packages/shared/src/protocol/navigation.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: NavigationGroupType
public enum NavigationGroupType: String, Codable, CaseIterable, Equatable, Sendable {
    case burst
    case scene
}

// TS: NavigationAnalyzeParams
public struct NavigationAnalyzeParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var burstGapSeconds: Double? // TS: burstGapSeconds?
    public var sceneGapSeconds: Double? // TS: sceneGapSeconds?
    public var dryRun: Bool? // TS: dryRun?

    public init(sessionId: String, burstGapSeconds: Double? = nil, sceneGapSeconds: Double? = nil, dryRun: Bool? = nil) {
        self.sessionId = sessionId
        self.burstGapSeconds = burstGapSeconds
        self.sceneGapSeconds = sceneGapSeconds
        self.dryRun = dryRun
    }
}

// TS: NavigationGroup.source（navigation.ts 内联联合 'automatic' | 'manual'）
public enum NavigationGroupSource: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case manual
}

// TS: NavigationGroup
public struct NavigationGroup: Codable, Equatable, Sendable {
    public var id: String
    public var type: NavigationGroupType
    public var photoIds: [String]
    public var startAt: String
    public var endAt: String
    public var leadPhotoId: String? // TS: leadPhotoId?
    public var explanation: String
    public var source: NavigationGroupSource

    public init(
        id: String,
        type: NavigationGroupType,
        photoIds: [String],
        startAt: String,
        endAt: String,
        leadPhotoId: String? = nil,
        explanation: String,
        source: NavigationGroupSource
    ) {
        self.id = id
        self.type = type
        self.photoIds = photoIds
        self.startAt = startAt
        self.endAt = endAt
        self.leadPhotoId = leadPhotoId
        self.explanation = explanation
        self.source = source
    }
}

// TS: NavigationSplitParams
public struct NavigationSplitParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var groupId: String
    public var beforePhotoId: String

    public init(sessionId: String, groupId: String, beforePhotoId: String) {
        self.sessionId = sessionId
        self.groupId = groupId
        self.beforePhotoId = beforePhotoId
    }
}

// TS: NavigationMergeParams
public struct NavigationMergeParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var groupIds: [String]

    public init(sessionId: String, groupIds: [String]) {
        self.sessionId = sessionId
        self.groupIds = groupIds
    }
}
