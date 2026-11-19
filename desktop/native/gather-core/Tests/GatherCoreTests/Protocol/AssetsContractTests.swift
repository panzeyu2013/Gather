// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/assets.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct AssetsContractTests {
    // MARK: - AssetLinkCandidateData / AssetVolumeData（P2：合并为逐样本断言）

    @Test("Assets 契约 DTO：JSON 往返稳定 + camelCase key 冻结")
    func assetDTOsRoundTripAndKeys() throws {
        try assertRoundTrip(AssetLinkCandidateData(
            id: "c_1", leftFileId: "f_left", rightFileId: "f_right",
            leftPath: "/Volumes/A/IMG_1.ARW", rightPath: "/Volumes/A/IMG_1.JPG",
            confidence: 0.97, status: .pending,
            evidence: ["dimensions": .object(["width": .number(6000)]), "matchType": .string("exif")]),
            keys: ["id", "leftFileId", "rightFileId", "leftPath", "rightPath", "confidence", "status", "evidence"],
            forbiddenKeys: ["left_file_id", "right_path"]
        ) { decoded in
            #expect(decoded.evidence["dimensions"] == .object(["width": .number(6000)]))
            #expect(decoded.evidence["matchType"] == .string("exif"))
        }
        try assertRoundTrip(AssetVolumeData(volumeId: "vol_1", roots: ["/Volumes/A", "/Volumes/B"],
                                            onlineFiles: 1200, offlineFiles: 34),
                            keys: ["volumeId", "roots", "onlineFiles", "offlineFiles"])
    }

    @Test func assetLinkCandidateStatusRawValuesMatchTS() {
        let cases: [(AssetLinkCandidateStatus, String)] = [
            (.pending, "pending"), (.accepted, "accepted"), (.rejected, "rejected"),
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
}
