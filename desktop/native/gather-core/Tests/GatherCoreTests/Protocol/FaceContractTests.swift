// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/face.ts。
// 含 core.ts 依赖类型（WritebackOptions / WritebackItem）的跨域编解码验证。

import Foundation
import Testing
@testable import GatherProtocol

struct FaceContractTests {
    // MARK: - DTO 往返 + key 冻结（P2：逐样本合并，含可选字段省略）

    @Test("Face 契约 DTO：JSON 往返稳定 + camelCase key 冻结")
    func faceDTOsRoundTripAndKeys() throws {
        try assertRoundTrip(ClusterMember(memberId: 1, photoId: "p1", photoPath: "/u/a.jpg",
                                          filename: "a.jpg", bbox: [0.1, 0.2, 0.3, 0.4], confidence: 0.95),
                            keys: ["memberId", "photoId", "photoPath", "filename", "bbox", "confidence"])
        try assertRoundTrip(WritebackOptions(createAlbums: true, addPrefix: false),
                            keys: ["createAlbums", "addPrefix"])
        try assertRoundTrip(WritebackItem(
            id: 5, photoId: "p1", photoPath: "/u/a.jpg", sessionId: "s1", module: "face-keyword",
            keywords: ["妈妈"], attributes: WritebackAttributes(keywords: ["妈妈"], rating: nil, label: nil),
            xmpPath: "/u/a.xmp", backupPath: "/u/.gather/a.xmp.bak", xmpStatus: "pending",
            errorMessage: "", attemptCount: 1, lastAttemptAt: "2025-01-01T00:00:00Z",
            preview: WritebackItemPreview(
                dirtyFields: [.rating, .keywords],
                before: WritebackAttributes(rating: 3), after: WritebackAttributes(rating: 4),
                source: "face-keyword", sharedPhotoCount: 3, externalChanged: false, willCreate: true)),
            keys: [
                "id", "photoId", "photoPath", "sessionId", "module", "keywords", "attributes",
                "xmpPath", "backupPath", "xmpStatus", "errorMessage", "attemptCount",
                "lastAttemptAt", "preview",
            ],
            forbiddenKeys: ["photo_path", "last_attempt_at"])
        // id? / attributes? / preview? 未设置时省略 key。
        try assertJSONKeys(WritebackItem(
            photoId: "p1", photoPath: "/u/a.jpg", sessionId: "s1", module: "culling",
            keywords: [], xmpPath: "/u/a.xmp", backupPath: "/u/b.xmp", xmpStatus: "clean",
            errorMessage: "", attemptCount: 0, lastAttemptAt: "t"),
            name: "WritebackItem(nil 可选字段)", forbiddenKeys: ["id", "attributes", "preview"])
    }

    @Test func writebackDirtyFieldRawValuesMatchTS() {
        let cases: [(WritebackDirtyField, String)] = [
            (.rating, "rating"), (.label, "label"), (.keywords, "keywords"),
        ]
        for (field, raw) in cases {
            #expect(field.rawValue == raw)
        }
    }
}
