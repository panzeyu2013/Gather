// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/IndexerContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/indexer.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct IndexerContractTests {

    @Test func indexScanResultRoundTripAndKeys() throws {
        try assertRoundTrip(IndexScanResult(sessionId: "s1", discovered: 120, added: 100, skipped: 15,
                                            missing: 5, failed: ["/u/bad1.ARW", "/u/bad2.ARW"]),
                            keys: ["sessionId", "discovered", "added", "skipped", "missing", "failed"])
    }
}
