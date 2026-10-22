// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Indexer.swift
// TS 源: packages/shared/src/protocol/indexer.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: IndexScanResult
public struct IndexScanResult: Codable, Equatable, Sendable {
    public var sessionId: String
    public var discovered: Int
    public var added: Int
    public var skipped: Int
    public var missing: Int
    public var failed: [String]

    public init(sessionId: String, discovered: Int, added: Int, skipped: Int, missing: Int, failed: [String]) {
        self.sessionId = sessionId
        self.discovered = discovered
        self.added = added
        self.skipped = skipped
        self.missing = missing
        self.failed = failed
    }
}
