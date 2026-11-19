// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/person.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct PersonContractTests {

    // MARK: - Params（P2：逐样本合并，含 Optional 省略形状）

    @Test("Person 契约 params：JSON 往返稳定 + 可选字段省略")
    func personParamsRoundTripAndKeys() throws {
        try assertRoundTrip(PersonUpdateParams(
            personId: "person_1", name: "爸爸", keywords: ["爸爸"],
            notes: "n", matchThreshold: 0.75),
            keys: ["personId", "name", "keywords", "notes", "matchThreshold"],
            name: "PersonUpdateParams(完整)")
        try assertJSONKeys(PersonUpdateParams(personId: "person_1"), keys: ["personId"],
                           name: "PersonUpdateParams(缺省)")
        try assertJSONKeys(PersonCreateParams(name: "爸爸", keywords: ["爸爸", "家庭"]),
                           keys: ["name", "keywords"], name: "PersonCreateParams(完整)")
        try assertJSONKeys(PersonCreateParams(name: "爸爸"), keys: ["name"],
                           name: "PersonCreateParams(缺省)")
        try assertJSONKeys(PersonSearchPhotosParams(personId: "p1", sessionIds: ["s1"],
                                                    limit: 50, offset: 0),
                           keys: ["personId", "sessionIds", "limit", "offset"],
                           name: "PersonSearchPhotosParams(完整)")
        try assertJSONKeys(PersonSearchPhotosParams(personId: "p1"), keys: ["personId"],
                           name: "PersonSearchPhotosParams(缺省)")
    }

    // MARK: - PersonData / PersonDetailData / PersonPhotoItem（P2：逐样本合并）

    @Test("Person 契约 DTO：JSON 往返稳定 + camelCase key 冻结")
    func personDTOsRoundTripAndKeys() throws {
        try assertRoundTrip(PersonData(
            id: "person_1", name: "爸爸", keywords: ["爸爸", "家庭"],
            thumbnailBase64: "base64...", thumbnailPath: "/u/avatar.jpg", notes: "n",
            matchThreshold: 0.72, photoCount: 12, sessionCount: 2,
            createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-02T00:00:00Z"),
            keys: [
                "id", "name", "keywords", "thumbnailBase64", "thumbnailPath", "notes",
                "matchThreshold", "photoCount", "sessionCount", "createdAt", "updatedAt",
            ],
            forbiddenKeys: ["match_threshold", "thumbnail_base64"])

        let detailData = try assertRoundTrip(PersonDetailData(
            id: "person_1", name: "爸爸", keywords: ["爸爸"], notes: "",
            matchThreshold: 0.7, photoCount: 1, sessionCount: 1,
            createdAt: "t", updatedAt: "t",
            photos: [PersonPhotoItem(
                photoId: "ph1", sessionId: "s1", sessionName: "2025 街头",
                filename: "a.jpg", filepath: "/u/a.jpg",
                faceBbox: [0.1, 0.2, 0.3, 0.4], confidence: 0.9)],
            totalPhotoCount: 1), name: "PersonDetailData")
        // 原用例只断言这几个键（未锁完整键集合），保留原断言强度。
        let detailKeys = try jsonKeys(of: detailData)
        #expect(detailKeys.contains("photos"))
        #expect(detailKeys.contains("totalPhotoCount"))
        #expect(!detailKeys.contains("thumbnailBase64"), "nil 可选字段不应输出 key")

        try assertRoundTrip(PersonPhotoItem(
            photoId: "ph1", sessionId: "s1", sessionName: "n",
            filename: "a.jpg", filepath: "/u/a.jpg",
            faceBbox: [1, 2, 3, 4], confidence: 0.88, thumbnailBase64: "b64"),
            keys: ["photoId", "sessionId", "sessionName", "filename", "filepath",
                   "faceBbox", "confidence", "thumbnailBase64"])
    }

    @Test func personDataThumbnailsOmittedWhenNil() throws {
        let person = PersonData(
            id: "person_1", name: "n", keywords: [], notes: "",
            matchThreshold: 0.7, photoCount: 0, sessionCount: 0,
            createdAt: "t", updatedAt: "t")
        let keys = try jsonKeys(of: JSONEncoder().encode(person))
        #expect(!keys.contains("thumbnailBase64"))
        #expect(!keys.contains("thumbnailPath"))
    }
}
