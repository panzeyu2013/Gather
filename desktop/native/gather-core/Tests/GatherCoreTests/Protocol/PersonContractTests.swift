// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/person.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct PersonContractTests {

    // MARK: - Params

    @Test func personCreateParamsOptionality() throws {
        let full = PersonCreateParams(name: "爸爸", keywords: ["爸爸", "家庭"])
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(full))) == ["name", "keywords"])

        let minimal = PersonCreateParams(name: "爸爸")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(minimal))) == ["name"], "TS keywords? 未设置时必须省略")
    }

    @Test func personUpdateParamsRoundTrip() throws {
        let full = PersonUpdateParams(
            personId: "person_1", name: "爸爸", keywords: ["爸爸"],
            notes: "n", matchThreshold: 0.75
        )
        let data = try JSONEncoder().encode(full)
        #expect(try JSONDecoder().decode(PersonUpdateParams.self, from: data) == full)
        #expect(Set(try jsonKeys(of: data)) == ["personId", "name", "keywords", "notes", "matchThreshold"])

        let minimal = PersonUpdateParams(personId: "person_1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(minimal))) == ["personId"])
    }

    @Test func personSearchPhotosParamsOptionality() throws {
        let full = PersonSearchPhotosParams(personId: "p1", sessionIds: ["s1"], limit: 50, offset: 0)
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(full))) == ["personId", "sessionIds", "limit", "offset"])

        let minimal = PersonSearchPhotosParams(personId: "p1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(minimal))) == ["personId"])
    }

    // MARK: - PersonData

    @Test func personDataRoundTripAndKeys() throws {
        let original = PersonData(
            id: "person_1",
            name: "爸爸",
            keywords: ["爸爸", "家庭"],
            thumbnailBase64: "base64...",
            thumbnailPath: "/u/avatar.jpg",
            notes: "n",
            matchThreshold: 0.72,
            photoCount: 12,
            sessionCount: 2,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-02T00:00:00Z"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersonData.self, from: data)
        #expect(decoded == original)

        let expected = [
            "id", "name", "keywords", "thumbnailBase64", "thumbnailPath", "notes",
            "matchThreshold", "photoCount", "sessionCount", "createdAt", "updatedAt",
        ]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "PersonData JSON key 必须与 TS 字段名一致")
        #expect(!Set(try jsonKeys(of: data)).contains("match_threshold"))
        #expect(!Set(try jsonKeys(of: data)).contains("thumbnail_base64"))
    }

    @Test func personDataThumbnailsOmittedWhenNil() throws {
        let person = PersonData(
            id: "person_1", name: "n", keywords: [], notes: "",
            matchThreshold: 0.7, photoCount: 0, sessionCount: 0,
            createdAt: "t", updatedAt: "t"
        )
        let keys = try jsonKeys(of: JSONEncoder().encode(person))
        #expect(!keys.contains("thumbnailBase64"))
        #expect(!keys.contains("thumbnailPath"))
    }

    // MARK: - PersonDetailData / PersonPhotoItem

    @Test func personDetailDataRoundTripAndKeys() throws {
        let original = PersonDetailData(
            id: "person_1", name: "爸爸", keywords: ["爸爸"], notes: "",
            matchThreshold: 0.7, photoCount: 1, sessionCount: 1,
            createdAt: "t", updatedAt: "t",
            photos: [
                PersonPhotoItem(
                    photoId: "ph1", sessionId: "s1", sessionName: "2025 街头",
                    filename: "a.jpg", filepath: "/u/a.jpg",
                    faceBbox: [0.1, 0.2, 0.3, 0.4], confidence: 0.9
                ),
            ],
            totalPhotoCount: 1
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersonDetailData.self, from: data)
        #expect(decoded == original)

        let keys = try jsonKeys(of: data)
        #expect(keys.contains("photos"))
        #expect(keys.contains("totalPhotoCount"))
        #expect(!keys.contains("thumbnailBase64"), "nil 可选字段不应输出 key")
    }

    @Test func personPhotoItemRoundTrip() throws {
        let item = PersonPhotoItem(
            photoId: "ph1", sessionId: "s1", sessionName: "n",
            filename: "a.jpg", filepath: "/u/a.jpg",
            faceBbox: [1, 2, 3, 4], confidence: 0.88, thumbnailBase64: "b64"
        )
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(PersonPhotoItem.self, from: data) == item)
        #expect(Set(try jsonKeys(of: data)) == ["photoId", "sessionId", "sessionName", "filename", "filepath", "faceBbox", "confidence", "thumbnailBase64"])
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
