// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/duplicate.ts。
// 特别注意 TS `X | null` 字段：key 恒存在，nil 编码为 JSON null。

import Foundation
import Testing
@testable import GatherCore

struct DuplicateContractTests {

    // MARK: - Params

    @Test func dupScanParamsKeysAndOptionality() throws {
        let full = DupScanParams(sessionId: "s1", visualThreshold: 0.8)
        let fullKeys = try jsonKeys(of: JSONEncoder().encode(full))
        #expect(Set(fullKeys) == ["sessionId", "visualThreshold"])

        let minimal = DupScanParams(sessionId: "s1")
        let minimalKeys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(Set(minimalKeys) == ["sessionId"], "未设置的 TS 可选字段必须省略")
    }

    @Test func dupGroupsParamsRoundTrip() throws {
        let params = DupGroupsParams(sessionId: "s1")
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(DupGroupsParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId"])
    }

    @Test func dupResolveParamsRoundTrip() throws {
        let params = DupResolveParams(groupId: 3, resolution: .keepOne, confirmed: true)
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(DupResolveParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["groupId", "resolution", "confirmed"])
    }

    @Test func dupResolveMemberParamsRoundTrip() throws {
        let params = DupResolveMemberParams(memberId: 9, isKept: false, confirmed: true)
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(DupResolveMemberParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["memberId", "isKept", "confirmed"])
    }

    // MARK: - Enums

    @Test func dupResolutionRawValuesMatchTS() {
        let cases: [(DupResolution, String)] = [
            (.keepOne, "keep_one"),
            (.keepAll, "keep_all"),
        ]
        for (resolution, raw) in cases {
            #expect(resolution.rawValue == raw)
        }
    }

    @Test func duplicateGroupTypeRawValuesMatchTS() {
        let cases: [(DuplicateGroupType, String)] = [
            (.exact, "exact"),
            (.visual, "visual"),
        ]
        for (groupType, raw) in cases {
            #expect(groupType.rawValue == raw)
        }
    }

    // MARK: - DuplicateScanResult

    @Test func duplicateScanResultRoundTrip() throws {
        let original = DuplicateScanResult(
            exactGroups: [
                DuplicateGroup(
                    id: 1, groupType: .exact, checksum: "abc", hashHex: "0x01",
                    memberCount: 2,
                    members: [
                        DuplicateGroupMember(
                            id: 11, photoId: "p1", isKept: true, fileSize: 12345,
                            fileMtime: "2025-01-01T00:00:00Z", resolution: "keep_one",
                            filepath: "/u/a.jpg", filename: "a.jpg"
                        ),
                        DuplicateGroupMember(
                            id: 12, photoId: "p2", isKept: false, fileSize: nil,
                            fileMtime: nil, resolution: nil,
                            filepath: "/u/b.jpg", filename: "b.jpg"
                        ),
                    ],
                    resolution: "keep_one", createdAt: "t"
                ),
            ],
            visualGroups: [],
            totalDuplicates: 1
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DuplicateScanResult.self, from: data)
        #expect(decoded == original)

        let keys = try jsonKeys(of: data)
        #expect(Set(keys) == ["exactGroups", "visualGroups", "totalDuplicates"])
    }

    // MARK: - null 字段编码为 JSON null（非省略 key）

    @Test func duplicateGroupResolutionNullAlwaysEncoded() throws {
        let group = DuplicateGroup(
            id: 1, groupType: .visual, memberCount: 0, members: [], resolution: nil, createdAt: "t"
        )
        let object = try jsonObject(of: JSONEncoder().encode(group))
        #expect(object["resolution"] is NSNull, "TS resolution: string | null —— nil 必须编码为 null 且 key 恒存在")
        #expect(!Set(object.keys).contains("checksum"), "TS checksum? 为可选字段，nil 时省略 key")
        #expect(!Set(object.keys).contains("hashHex"))
    }

    @Test func duplicateGroupMemberNullsAlwaysEncoded() throws {
        let member = DuplicateGroupMember(
            id: 5, photoId: "p1", isKept: true, fileSize: nil, fileMtime: nil, resolution: nil,
            filepath: "/u/a.jpg", filename: "a.jpg"
        )
        let object = try jsonObject(of: JSONEncoder().encode(member))
        #expect(object["fileSize"] is NSNull)
        #expect(object["fileMtime"] is NSNull)
        #expect(object["resolution"] is NSNull)
    }

    @Test func duplicateGroupMemberNullsDecodeBack() throws {
        let json = #"{"id":5,"photoId":"p1","isKept":true,"fileSize":null,"fileMtime":null,"resolution":null,"filepath":"/u/a.jpg","filename":"a.jpg"}"#
        let decoded = try JSONDecoder().decode(DuplicateGroupMember.self, from: Data(json.utf8))
        #expect(decoded.fileSize == nil)
        #expect(decoded.fileMtime == nil)
        #expect(decoded.resolution == nil)
    }

    // MARK: - DupScanOptions

    @Test func dupScanOptionsRoundTrip() throws {
        let options = DupScanOptions(visualThreshold: 0.85)
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(DupScanOptions.self, from: data) == options)
        #expect(Set(try jsonKeys(of: data)) == ["visualThreshold"])
    }

    // MARK: - helpers

    private func jsonKeys(of data: Data) throws -> [String] {
        Array(try jsonObject(of: data).keys)
    }

    private func jsonObject(of data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContractTestError.invalidJSON
        }
        return object
    }

    private enum ContractTestError: Error {
        case invalidJSON
    }
}
