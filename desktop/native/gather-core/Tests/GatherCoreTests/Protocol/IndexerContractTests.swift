// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/IndexerContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/indexer.ts。

import Foundation
import Testing
@testable import GatherCore

struct IndexerContractTests {

    @Test func indexScanParamsOptionality() throws {
        let full = IndexScanParams(sessionId: "s1", confirmed: true)
        let fullKeys = try jsonKeys(of: JSONEncoder().encode(full))
        #expect(Set(fullKeys) == ["sessionId", "confirmed"])

        let minimal = IndexScanParams(sessionId: "s1")
        let minimalKeys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(Set(minimalKeys) == ["sessionId"], "TS confirmed? 未设置时必须省略")
    }

    @Test func indexScanResultRoundTripAndKeys() throws {
        let original = IndexScanResult(
            sessionId: "s1",
            discovered: 120,
            added: 100,
            skipped: 15,
            missing: 5,
            failed: ["/u/bad1.ARW", "/u/bad2.ARW"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IndexScanResult.self, from: data)
        #expect(decoded == original)

        let expected = ["sessionId", "discovered", "added", "skipped", "missing", "failed"]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "IndexScanResult JSON key 必须与 TS 字段名一致")
    }

    private func jsonKeys(of data: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContractTestError.invalidJSON
        }
        return Array(object.keys)
    }

    private enum ContractTestError: Error {
        case invalidJSON
    }
}
