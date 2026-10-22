// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/assets.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct AssetsContractTests {

    // MARK: - AssetCandidateListParams

    @Test func assetCandidateListParamsOptionality() throws {
        let withSession = AssetCandidateListParams(sessionId: "s1")
        let withKeys = try jsonKeys(of: JSONEncoder().encode(withSession))
        #expect(Set(withKeys) == ["sessionId"])

        let withoutSession = AssetCandidateListParams()
        let withoutKeys = try jsonKeys(of: JSONEncoder().encode(withoutSession))
        #expect(withoutKeys.isEmpty, "nil 可选字段不应输出 key")

        #expect(try JSONDecoder().decode(AssetCandidateListParams.self, from: JSONEncoder().encode(withSession)) == withSession)
    }

    // MARK: - AssetCandidateMutationParams

    @Test func assetCandidateMutationParamsRoundTrip() throws {
        let params = AssetCandidateMutationParams(candidateId: "c_1", confirmed: true)
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(AssetCandidateMutationParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["candidateId", "confirmed"])
    }

    // MARK: - AssetLinkCandidateData

    @Test func assetLinkCandidateDataRoundTripAndCamelCaseKeys() throws {
        let original = AssetLinkCandidateData(
            id: "c_1",
            leftFileId: "f_left",
            rightFileId: "f_right",
            leftPath: "/Volumes/A/IMG_1.ARW",
            rightPath: "/Volumes/A/IMG_1.JPG",
            confidence: 0.97,
            status: .pending,
            evidence: ["dimensions": .object(["width": .number(6000)]), "matchType": .string("exif")]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AssetLinkCandidateData.self, from: data)
        #expect(decoded == original)

        let keys = try jsonKeys(of: data)
        let expected = [
            "id", "leftFileId", "rightFileId", "leftPath", "rightPath",
            "confidence", "status", "evidence",
        ]
        #expect(Set(keys) == Set(expected), "AssetLinkCandidateData JSON key 必须与 TS 字段名一致")
        #expect(!keys.contains("left_file_id"))
        #expect(!keys.contains("right_path"))

        #expect(decoded.evidence["dimensions"] == .object(["width": .number(6000)]))
        #expect(decoded.evidence["matchType"] == .string("exif"))
    }

    @Test func assetLinkCandidateStatusRawValuesMatchTS() {
        let cases: [(AssetLinkCandidateStatus, String)] = [
            (.pending, "pending"),
            (.accepted, "accepted"),
            (.rejected, "rejected"),
        ]
        for (status, raw) in cases {
            #expect(status.rawValue == raw)
        }
    }

    @Test func assetLinkCandidateDataDecodesStatusRawValues() throws {
        let json = #"{"id":"c","leftFileId":"l","rightFileId":"r","leftPath":"/a","rightPath":"/b","confidence":0.5,"status":"accepted","evidence":{}}"#
        let decoded = try JSONDecoder().decode(AssetLinkCandidateData.self, from: Data(json.utf8))
        #expect(decoded.status == .accepted)
    }

    // MARK: - AssetVolumeData

    @Test func assetVolumeDataRoundTrip() throws {
        let original = AssetVolumeData(
            volumeId: "vol_1",
            roots: ["/Volumes/A", "/Volumes/B"],
            onlineFiles: 1200,
            offlineFiles: 34
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AssetVolumeData.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["volumeId", "roots", "onlineFiles", "offlineFiles"])
    }

    // MARK: - AssetRelinkRootParams

    @Test func assetRelinkRootParamsRoundTrip() throws {
        let params = AssetRelinkRootParams(oldRoot: "/Volumes/A", newRoot: "/Volumes/B", confirmed: false)
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(AssetRelinkRootParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["oldRoot", "newRoot", "confirmed"])
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
