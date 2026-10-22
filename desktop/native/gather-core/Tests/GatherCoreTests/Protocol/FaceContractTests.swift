// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/face.ts。
// 含 core.ts 依赖类型（WritebackOptions / WritebackItem）的跨域编解码验证。

import Foundation
import Testing
@testable import GatherProtocol

struct FaceContractTests {

    // MARK: - Params

    @Test func fkwAnalyzeParamsKeysAndOptionality() throws {
        let full = FkwAnalyzeParams(sessionId: "s1", eps: 0.4, minSamples: 5, detectorPath: "/m/d.onnx", encoderPath: "/m/e.onnx")
        let fullKeys = try jsonKeys(of: JSONEncoder().encode(full))
        #expect(Set(fullKeys) == ["sessionId", "eps", "minSamples", "detectorPath", "encoderPath"])

        let minimal = FkwAnalyzeParams(sessionId: "s1")
        let minimalKeys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(Set(minimalKeys) == ["sessionId"], "未设置的 TS 可选字段必须省略")
    }

    @Test func fkwBindParamsRoundTrip() throws {
        let params = FkwBindParams(sessionId: "s1", clusterId: 7, roleName: "爸爸", keywords: ["爸爸", "家庭"])
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(FkwBindParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId", "clusterId", "roleName", "keywords"])
    }

    @Test func fkwUnbindAndMergeParamsRoundTrip() throws {
        let unbind = FkwUnbindParams(sessionId: "s1", clusterId: 7, confirmed: true)
        #expect(try JSONDecoder().decode(FkwUnbindParams.self, from: JSONEncoder().encode(unbind)) == unbind)

        let merge = FkwMergeParams(sessionId: "s1", source: 7, target: 9)
        let mergeData = try JSONEncoder().encode(merge)
        #expect(try JSONDecoder().decode(FkwMergeParams.self, from: mergeData) == merge)
        #expect(Set(try jsonKeys(of: mergeData)) == ["sessionId", "source", "target"])
    }

    @Test func fkwRemoveMemberParamsRoundTrip() throws {
        let params = FkwRemoveMemberParams(sessionId: "s1", clusterId: 7, memberId: 42)
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(FkwRemoveMemberParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId", "clusterId", "memberId"])
    }

    @Test func fkwPreviewAndWritebackParamsOptionality() throws {
        let preview = FkwPreviewParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(preview))) == ["sessionId"])

        let previewFull = FkwPreviewParams(
            sessionId: "s1",
            options: WritebackOptions(createAlbums: true, writeIPTC: true)
        )
        let previewFullKeys = try jsonKeys(of: JSONEncoder().encode(previewFull))
        #expect(Set(previewFullKeys) == ["sessionId", "options"])

        let writeback = FkwWritebackParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(writeback))) == ["sessionId"])

        let writebackFull = FkwWritebackParams(sessionId: "s1", confirmed: true, items: [])
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(writebackFull))) == ["sessionId", "confirmed", "items"])
    }

    @Test func fkwConfirmAndCleanupParamsOptionality() throws {
        let confirmSyncKeys = try jsonKeys(of: JSONEncoder().encode(FkwConfirmSyncParams(sessionId: "s1")))
        #expect(Set(confirmSyncKeys) == ["sessionId"], "confirmed? 未设置时必须省略")
        let confirmCleanupKeys = try jsonKeys(of: JSONEncoder().encode(FkwConfirmCleanupParams(sessionId: "s1")))
        #expect(Set(confirmCleanupKeys) == ["sessionId"], "confirmed? 未设置时必须省略")
        let cleanupKeys = try jsonKeys(of: JSONEncoder().encode(FkwCleanupParams(sessionId: "s1")))
        #expect(Set(cleanupKeys) == ["sessionId"], "confirmed? 未设置时必须省略")

        let confirmed = FkwCleanupParams(sessionId: "s1", confirmed: true)
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(confirmed))) == ["sessionId", "confirmed"])
    }

    // MARK: - FaceModelsStatusData

    @Test func faceModelsStatusDataRoundTrip() throws {
        let original = FaceModelsStatusData(
            detectorPresent: true, encoderPresent: false,
            detectorPath: "/m/d.onnx", encoderPath: ""
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(FaceModelsStatusData.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["detectorPresent", "encoderPresent", "detectorPath", "encoderPath"])
    }

    // MARK: - FaceObservation

    @Test func faceObservationRoundTripAndKeys() throws {
        let original = FaceObservation(
            id: 3, photoId: "p1", sessionId: "s1",
            bboxX: 0.1, bboxY: 0.2, bboxW: 0.3, bboxH: 0.4,
            embedding: [0.1, 0.2, -0.3], confidence: 0.92
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(FaceObservation.self, from: data) == original)

        let keys = try jsonKeys(of: data)
        let expected = ["id", "photoId", "sessionId", "bboxX", "bboxY", "bboxW", "bboxH", "embedding", "confidence"]
        #expect(Set(keys) == Set(expected))
        #expect(!keys.contains("bbox_x"))
    }

    @Test func faceObservationIdOmittedWhenNil() throws {
        let observation = FaceObservation(
            photoId: "p1", sessionId: "s1",
            bboxX: 0, bboxY: 0, bboxW: 1, bboxH: 1,
            embedding: [], confidence: 0.5
        )
        let keys = try jsonKeys(of: JSONEncoder().encode(observation))
        #expect(!keys.contains("id"), "TS id? 为可选字段，nil 时省略 key")
    }

    // MARK: - FaceCluster / ClusterMember / BindingData

    @Test func faceClusterRoundTripAndKeys() throws {
        let original = FaceCluster(
            id: 1,
            sessionId: "s1",
            label: "cluster_1",
            size: 2,
            members: [
                ClusterMember(memberId: 10, photoId: "p1", photoPath: "/u/a.jpg", filename: "a.jpg", bbox: [1, 2, 3, 4], confidence: 0.9),
            ],
            status: "analyzed",
            binding: BindingData(clusterId: 1, roleName: "妈妈", keywords: ["妈妈"], notes: "n"),
            thumbnailBase64: "base64...",
            syncedToLibrary: true,
            matchedPersonId: "person_1",
            matchConfidence: 0.87
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FaceCluster.self, from: data)
        #expect(decoded == original)

        let keys = try jsonKeys(of: data)
        let expected = [
            "id", "sessionId", "label", "size", "members", "status",
            "binding", "thumbnailBase64", "syncedToLibrary", "matchedPersonId", "matchConfidence",
        ]
        #expect(Set(keys) == Set(expected), "FaceCluster JSON key 必须与 TS 字段名一致")
        #expect(!keys.contains("synced_to_library"))
        #expect(!keys.contains("thumbnail_base64"))
    }

    @Test func faceClusterOptionalsOmittedWhenNil() throws {
        let cluster = FaceCluster(
            id: 1, sessionId: "s1", label: "c", size: 1,
            members: [], status: "analyzed"
        )
        let keys = try jsonKeys(of: JSONEncoder().encode(cluster))
        #expect(!keys.contains("binding"))
        #expect(!keys.contains("thumbnailBase64"))
        #expect(!keys.contains("syncedToLibrary"))
        #expect(!keys.contains("matchedPersonId"))
        #expect(!keys.contains("matchConfidence"))
    }

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
