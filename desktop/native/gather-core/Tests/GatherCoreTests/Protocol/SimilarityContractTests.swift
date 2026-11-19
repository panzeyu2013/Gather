// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/similarity.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct SimilarityContractTests {

    // MARK: - Enums

    @Test func similarityGroupingModeRawValuesMatchTS() {
        let cases: [(SimilarityGroupingMode, String)] = [(.sequential, "sequential"), (.global, "global")]
        for (mode, raw) in cases {
            #expect(mode.rawValue == raw)
        }
    }

    // MARK: - DTO 往返 + key 冻结（P2：逐样本合并，含可选字段省略）

    @Test("Similarity 契约 DTO：JSON 往返稳定 + camelCase key 冻结")
    func similarityDTOsRoundTripAndKeys() throws {
        try assertRoundTrip(SimilarityGroup(
            id: 1, label: "group_1", count: 3,
            images: [SimilarityImage(path: "/u/a.jpg", representative: true), SimilarityImage(path: "/u/b.jpg")],
            thumbnailBase64: "b64"),
            keys: ["id", "label", "count", "images", "thumbnailBase64"],
            forbiddenKeys: ["thumbnail_base64"])
        try assertRoundTrip(SimilarityResultStats(
            totalGroups: 5, totalUngrouped: 12,
            threshold: 0.8, minGroupSize: 3, groupingMode: .global, precomputed: true),
            keys: ["totalGroups", "totalUngrouped", "threshold", "minGroupSize", "groupingMode", "precomputed"],
            forbiddenKeys: ["total_groups", "min_group_size"])
        // representative? / precomputed? 未设置时省略 key（原 keys 断言保留为期望值）。
        try assertJSONKeys(SimilarityImage(path: "/u/a.jpg"), keys: ["path"],
                           name: "SimilarityImage(无 representative)")
        try assertJSONKeys(SimilarityResultStats(totalGroups: 1, totalUngrouped: 0,
                                                 threshold: 0.8, minGroupSize: 3, groupingMode: .sequential),
                           name: "SimilarityResultStats(无 precomputed)",
                           forbiddenKeys: ["precomputed"])
    }
}
