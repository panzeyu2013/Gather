// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/face.ts。
// 含 core.ts 依赖类型（WritebackOptions / WritebackItem）的跨域编解码验证。

import Foundation
import Testing
@testable import GatherProtocol

struct FaceContractTests {
    // MARK: - ClusterMember

    @Test func clusterMemberRoundTrip() throws {
        let member = ClusterMember(memberId: 1, photoId: "p1", photoPath: "/u/a.jpg", filename: "a.jpg", bbox: [0.1, 0.2, 0.3, 0.4], confidence: 0.95)
        let data = try JSONEncoder().encode(member)
        #expect(try JSONDecoder().decode(ClusterMember.self, from: data) == member)
        #expect(Set(try jsonKeys(of: data)) == ["memberId", "photoId", "photoPath", "filename", "bbox", "confidence"])
    }

    // MARK: - core.ts 跨域类型（WritebackOptions / WritebackItem）

    @Test func writebackOptionsRoundTripAndKeys() throws {
        let options = WritebackOptions(createAlbums: true, addPrefix: false)
        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(WritebackOptions.self, from: data) == options)
        #expect(Set(try jsonKeys(of: data)) == ["createAlbums", "addPrefix"])
    }

    @Test func writebackItemRoundTripAndKeys() throws {
        let original = WritebackItem(
            id: 5,
            photoId: "p1",
            photoPath: "/u/a.jpg",
            sessionId: "s1",
            module: "face-keyword",
            keywords: ["妈妈"],
            attributes: WritebackAttributes(keywords: ["妈妈"], rating: nil, label: nil),
            xmpPath: "/u/a.xmp",
            backupPath: "/u/.gather/a.xmp.bak",
            xmpStatus: "pending",
            errorMessage: "",
            attemptCount: 1,
            lastAttemptAt: "2025-01-01T00:00:00Z",
            preview: WritebackItemPreview(
                dirtyFields: [.rating, .keywords],
                before: WritebackAttributes(rating: 3),
                after: WritebackAttributes(rating: 4),
                source: "face-keyword",
                sharedPhotoCount: 3,
                externalChanged: false,
                willCreate: true
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WritebackItem.self, from: data)
        #expect(decoded == original)

        let keys = try jsonKeys(of: data)
        let expected = [
            "id", "photoId", "photoPath", "sessionId", "module", "keywords", "attributes",
            "xmpPath", "backupPath", "xmpStatus", "errorMessage", "attemptCount",
            "lastAttemptAt", "preview",
        ]
        #expect(Set(keys) == Set(expected), "WritebackItem JSON key 必须与 TS 字段名一致")
        #expect(!keys.contains("photo_path"))
        #expect(!keys.contains("last_attempt_at"))
    }

    @Test func writebackItemOptionalsOmittedWhenNil() throws {
        let item = WritebackItem(
            photoId: "p1", photoPath: "/u/a.jpg", sessionId: "s1", module: "culling",
            keywords: [], xmpPath: "/u/a.xmp", backupPath: "/u/b.xmp", xmpStatus: "clean",
            errorMessage: "", attemptCount: 0, lastAttemptAt: "t"
        )
        let keys = try jsonKeys(of: JSONEncoder().encode(item))
        #expect(!keys.contains("id"))
        #expect(!keys.contains("attributes"))
        #expect(!keys.contains("preview"))
    }

    @Test func writebackDirtyFieldRawValuesMatchTS() {
        let cases: [(WritebackDirtyField, String)] = [
            (.rating, "rating"), (.label, "label"), (.keywords, "keywords"),
        ]
        for (field, raw) in cases {
            #expect(field.rawValue == raw)
        }
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
