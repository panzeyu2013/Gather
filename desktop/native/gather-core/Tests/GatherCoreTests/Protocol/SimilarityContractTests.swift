// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/similarity.ts。

import Foundation
import Testing
@testable import GatherCore

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

    // MARK: - Params

    @Test func simAnalyzeParamsKeysAndOptionality() throws {
        let full = SimAnalyzeParams(sessionId: "s1", threshold: 0.82, minGroupSize: 3, groupingMode: .global)
        let fullKeys = try jsonKeys(of: JSONEncoder().encode(full))
        #expect(Set(fullKeys) == ["sessionId", "threshold", "minGroupSize", "groupingMode"])

        let minimal = SimAnalyzeParams(sessionId: "s1")
        let minimalKeys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(Set(minimalKeys) == ["sessionId"], "未设置的 TS 可选字段必须省略")
    }

    @Test func simCancelAndConfirmSyncParamsRoundTrip() throws {
        let cancel = SimCancelAnalysisParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(cancel))) == ["sessionId"])

        let confirm = SimConfirmSyncParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(confirm))) == ["sessionId"])
    }

    @Test func simResultParamsOptionality() throws {
        let withThreshold = SimResultParams(sessionId: "s1", threshold: 0.75)
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(withThreshold))) == ["sessionId", "threshold"])

        let minimal = SimResultParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(minimal))) == ["sessionId"])
    }

    @Test func simReclusterParamsRoundTrip() throws {
        let params = SimReclusterParams(sessionId: "s1", threshold: 0.8, minGroupSize: 4, groupingMode: .sequential)
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(SimReclusterParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId", "threshold", "minGroupSize", "groupingMode"])
    }

    @Test func simPreviewWritebackParamsRoundTrip() throws {
        let params = SimPreviewWritebackParams(
            sessionId: "s1",
            assignments: [
                SimilarityKeywordAssignment(groupId: 1, keywords: ["街头"]),
                SimilarityKeywordAssignment(groupId: 2, keywords: ["夜景", "长曝"]),
            ],
            threshold: 0.8
        )
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(SimPreviewWritebackParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId", "assignments", "threshold"])
    }

    @Test func simWritebackAndCleanupParamsRoundTrip() throws {
        let writeback = SimWritebackParams(sessionId: "s1", itemIds: [1, 2, 3], confirmed: true, threshold: 0.8)
        let writebackData = try JSONEncoder().encode(writeback)
        #expect(try JSONDecoder().decode(SimWritebackParams.self, from: writebackData) == writeback)
        #expect(Set(try jsonKeys(of: writebackData)) == ["sessionId", "itemIds", "confirmed", "threshold"])

        let items = SimWritebackItemsParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(items))) == ["sessionId"])

        let retry = SimRetryFailedWritebackParams(sessionId: "s1", confirmed: false)
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(retry))) == ["sessionId", "confirmed"])

        let cleanup = SimCleanupParams(sessionId: "s1", confirmed: true)
        let cleanupData = try JSONEncoder().encode(cleanup)
        #expect(try JSONDecoder().decode(SimCleanupParams.self, from: cleanupData) == cleanup)
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

    // MARK: - helpers

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
