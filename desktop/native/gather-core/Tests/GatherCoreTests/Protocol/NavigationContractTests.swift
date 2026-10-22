// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/NavigationContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/navigation.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct NavigationContractTests {

    // MARK: - Enums

    @Test func navigationEnumsRawValuesMatchTS() {
        let types: [(NavigationGroupType, String)] = [
            (.burst, "burst"), (.scene, "scene"),
        ]
        for (type, raw) in types {
            #expect(type.rawValue == raw)
        }

        let sources: [(NavigationGroupSource, String)] = [
            (.automatic, "automatic"), (.manual, "manual"),
        ]
        for (source, raw) in sources {
            #expect(source.rawValue == raw)
        }
    }

    // MARK: - Params

    @Test func navigationAnalyzeParamsKeysAndOptionality() throws {
        let full = NavigationAnalyzeParams(sessionId: "s1", burstGapSeconds: 0.5, sceneGapSeconds: 2.5, dryRun: true)
        let fullKeys = try jsonKeys(of: JSONEncoder().encode(full))
        #expect(Set(fullKeys) == ["sessionId", "burstGapSeconds", "sceneGapSeconds", "dryRun"])

        let minimal = NavigationAnalyzeParams(sessionId: "s1")
        let minimalKeys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(Set(minimalKeys) == ["sessionId"], "未设置的 TS 可选字段必须省略")
    }

    @Test func navigationSplitParamsRoundTrip() throws {
        let params = NavigationSplitParams(sessionId: "s1", groupId: "g1", beforePhotoId: "p1")
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(NavigationSplitParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId", "groupId", "beforePhotoId"])
    }

    @Test func navigationMergeParamsRoundTrip() throws {
        let params = NavigationMergeParams(sessionId: "s1", groupIds: ["g1", "g2"])
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(NavigationMergeParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId", "groupIds"])
    }

    // MARK: - NavigationGroup

    @Test func navigationGroupRoundTripAndKeys() throws {
        let original = NavigationGroup(
            id: "g1",
            type: .burst,
            photoIds: ["p1", "p2", "p3"],
            startAt: "2025-01-01T10:00:00Z",
            endAt: "2025-01-01T10:00:02Z",
            leadPhotoId: "p2",
            explanation: "间隔 0.4s 连拍",
            source: .automatic
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NavigationGroup.self, from: data)
        #expect(decoded == original)

        let expected = [
            "id", "type", "photoIds", "startAt", "endAt", "leadPhotoId", "explanation", "source",
        ]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "NavigationGroup JSON key 必须与 TS 字段名一致")
        #expect(!Set(try jsonKeys(of: data)).contains("photo_ids"))
    }

    @Test func navigationGroupLeadPhotoIdOmittedWhenNil() throws {
        let group = NavigationGroup(
            id: "g1", type: .scene, photoIds: ["p1"],
            startAt: "t", endAt: "t", explanation: "e", source: .manual
        )
        let keys = try jsonKeys(of: JSONEncoder().encode(group))
        #expect(!keys.contains("leadPhotoId"))
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
