// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/similarity.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct SimilarityContractTests {

    // MARK: - Enums

    @Test func similarityGroupingModeRawValuesMatchTS() {
        let cases: [(SimilarityGroupingMode, String)] = [
            (.sequential, "sequential"), (.global, "global"),
        ]
        for (mode, raw) in cases {
            #expect(mode.rawValue == raw)
        }
    }
    // MARK: - SimilarityGroup / SimilarityImage

    @Test func similarityGroupRoundTripAndKeys() throws {
        let original = SimilarityGroup(
            id: 1,
            label: "group_1",
            count: 3,
            images: [
                SimilarityImage(path: "/u/a.jpg", representative: true),
                SimilarityImage(path: "/u/b.jpg"),
            ],
            thumbnailBase64: "b64"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SimilarityGroup.self, from: data)
        #expect(decoded == original)

        let expected = ["id", "label", "count", "images", "thumbnailBase64"]
        #expect(Set(try jsonKeys(of: data)) == Set(expected))
        #expect(!Set(try jsonKeys(of: data)).contains("thumbnail_base64"))
    }

    @Test func similarityImageRepresentativeOmittedWhenNil() throws {
        let image = SimilarityImage(path: "/u/a.jpg")
        let keys = try jsonKeys(of: JSONEncoder().encode(image))
        #expect(Set(keys) == ["path"], "TS representative? 未设置时必须省略")
    }

    // MARK: - SimilarityResultStats

    @Test func similarityResultStatsRoundTripAndKeys() throws {
        let original = SimilarityResultStats(
            totalGroups: 5, totalUngrouped: 12,
            threshold: 0.8, minGroupSize: 3, groupingMode: .global,
            precomputed: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SimilarityResultStats.self, from: data)
        #expect(decoded == original)

        let expected = [
            "totalGroups", "totalUngrouped", "threshold", "minGroupSize", "groupingMode", "precomputed",
        ]
        #expect(Set(try jsonKeys(of: data)) == Set(expected))
        #expect(!Set(try jsonKeys(of: data)).contains("total_groups"))
        #expect(!Set(try jsonKeys(of: data)).contains("min_group_size"))
    }

    @Test func similarityResultStatsPrecomputedOmittedWhenNil() throws {
        let stats = SimilarityResultStats(
            totalGroups: 1, totalUngrouped: 0,
            threshold: 0.8, minGroupSize: 3, groupingMode: .sequential
        )
        let keys = try jsonKeys(of: JSONEncoder().encode(stats))
        #expect(!keys.contains("precomputed"))
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
