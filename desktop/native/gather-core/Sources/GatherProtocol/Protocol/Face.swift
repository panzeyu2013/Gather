// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Face.swift
// TS 源: packages/shared/src/protocol/face.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。
//
// 说明: face.ts import type { WritebackOptions, WritebackItem } from './core'；
// 这两个 core.ts 类型位于 Core.swift（Writeback* 区块），此处直接引用。

import Foundation

// TS: ClusterMember
public struct ClusterMember: Codable, Equatable, Sendable {
    public var memberId: Int
    public var photoId: String
    public var photoPath: String
    public var filename: String
    public var bbox: [Double]
    public var confidence: Double

    public init(memberId: Int, photoId: String, photoPath: String, filename: String, bbox: [Double], confidence: Double) {
        self.memberId = memberId
        self.photoId = photoId
        self.photoPath = photoPath
        self.filename = filename
        self.bbox = bbox
        self.confidence = confidence
    }
}
