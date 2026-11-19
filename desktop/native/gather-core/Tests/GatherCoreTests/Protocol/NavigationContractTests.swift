// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/NavigationContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/navigation.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct NavigationContractTests {

    // MARK: - Enums

    @Test func navigationEnumsRawValuesMatchTS() {
        let types: [(NavigationGroupType, String)] = [(.burst, "burst"), (.scene, "scene")]
        for (type, raw) in types {
            #expect(type.rawValue == raw)
        }
        let sources: [(NavigationGroupSource, String)] = [(.automatic, "automatic"), (.manual, "manual")]
        for (source, raw) in sources {
            #expect(source.rawValue == raw)
        }
    }

    // MARK: - DTO 往返 + key 冻结（P2：逐样本合并，含可选字段省略）

    @Test("Navigation 契约 DTO：JSON 往返稳定 + camelCase key 冻结")
    func navigationDTOsRoundTripAndKeys() throws {
        try assertRoundTrip(NavigationSplitParams(sessionId: "s1", groupId: "g1", beforePhotoId: "p1"),
                            keys: ["sessionId", "groupId", "beforePhotoId"])
        try assertRoundTrip(NavigationMergeParams(sessionId: "s1", groupIds: ["g1", "g2"]),
                            keys: ["sessionId", "groupIds"])
        try assertRoundTrip(NavigationGroup(
            id: "g1", type: .burst, photoIds: ["p1", "p2", "p3"],
            startAt: "2025-01-01T10:00:00Z", endAt: "2025-01-01T10:00:02Z",
            leadPhotoId: "p2", explanation: "间隔 0.4s 连拍", source: .automatic),
            keys: ["id", "type", "photoIds", "startAt", "endAt", "leadPhotoId", "explanation", "source"],
            forbiddenKeys: ["photo_ids"])
        // 可选参数/字段省略：analyzeParams 的 TS 可选字段、group 的 leadPhotoId?。
        try assertJSONKeys(NavigationAnalyzeParams(sessionId: "s1", burstGapSeconds: 0.5,
                                                   sceneGapSeconds: 2.5, dryRun: true),
                           keys: ["sessionId", "burstGapSeconds", "sceneGapSeconds", "dryRun"],
                           name: "NavigationAnalyzeParams(全量)")
        try assertJSONKeys(NavigationAnalyzeParams(sessionId: "s1"), keys: ["sessionId"],
                           name: "NavigationAnalyzeParams(缺省)")
        try assertJSONKeys(NavigationGroup(id: "g1", type: .scene, photoIds: ["p1"],
                                           startAt: "t", endAt: "t", explanation: "e", source: .manual),
                           name: "NavigationGroup(nil leadPhotoId)", forbiddenKeys: ["leadPhotoId"])
    }
}
