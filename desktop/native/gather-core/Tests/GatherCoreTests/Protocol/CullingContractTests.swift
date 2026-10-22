// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/culling.ts。
// 注意：CullingPage.nextRowId 为 TS `number | null`，nil 编码为 JSON null（key 恒存在）；
// CullingAsset 跨域引用 PhotoData（session.ts）与 MetadataMutationSource（metadata.ts）。

import Foundation
import Testing
@testable import GatherProtocol

struct CullingContractTests {

    // MARK: - Enums

    @Test func cullingEnumRawValuesMatchTS() {
        let pickStates: [(PickState, String)] = [
            (.unreviewed, "unreviewed"), (.picked, "picked"), (.rejected, "rejected"),
        ]
        for (value, raw) in pickStates {
            #expect(value.rawValue == raw)
        }

        let decisions: [(CullingDecisionValue, String)] = [
            (.keep, "keep"), (.reject, "reject"), (.pending, "pending"),
        ]
        for (value, raw) in decisions {
            #expect(value.rawValue == raw)
        }

        let sources: [(CullingDecisionSource, String)] = [
            (.manual, "manual"), (.ai, "ai"), (.template, "template"), (.imported, "imported"),
        ]
        for (value, raw) in sources {
            #expect(value.rawValue == raw)
        }

        let colorLabels: [(CaptureOneColorLabel, String)] = [
            (.none, "None"), (.red, "Red"), (.orange, "Orange"), (.yellow, "Yellow"),
            (.green, "Green"), (.blue, "Blue"), (.pink, "Pink"), (.purple, "Purple"),
        ]
        for (value, raw) in colorLabels {
            #expect(value.rawValue == raw, "CaptureOneColorLabel 必须与 TS 字符串（含大小写）一致")
        }

        let scopes: [(CullingScope, String)] = [
            (.all, "all"), (.filtered, "filtered"), (.similarityGroup, "similarity_group"),
        ]
        for (value, raw) in scopes {
            #expect(value.rawValue == raw)
        }

        let syncStatuses: [(MetadataSyncStatus, String)] = [
            (.clean, "clean"), (.pending, "pending"), (.writing, "writing"), (.written, "written"),
            (.failed, "failed"), (.conflict, "conflict"), (.synced, "synced"), (.cleaned, "cleaned"),
        ]
        for (value, raw) in syncStatuses {
            #expect(value.rawValue == raw)
        }

        let qualityStatuses: [(CullingQualityStatus, String)] = [
            (.succeeded, "succeeded"), (.failed, "failed"),
        ]
        for (value, raw) in qualityStatuses {
            #expect(value.rawValue == raw)
        }

        let filterQualityStatuses: [(CullingFilterQualityStatus, String)] = [
            (.analysed, "analysed"), (.unanalysed, "unanalysed"), (.failed, "failed"),
        ]
        for (value, raw) in filterQualityStatuses {
            #expect(value.rawValue == raw)
        }

        let directions: [(CullingHistoryDirection, String)] = [
            (.undo, "undo"), (.redo, "redo"),
        ]
        for (value, raw) in directions {
            #expect(value.rawValue == raw)
        }

        let targets: [(CullingWritebackTarget, String)] = [
            (.rating, "rating"), (.colorLabel, "color_label"), (.keyword, "keyword"),
        ]
        for (value, raw) in targets {
            #expect(value.rawValue == raw)
        }

        let fields: [(CullingUpdatePatchField, String)] = [
            (.rating, "rating"), (.pickState, "pickState"), (.colorLabel, "colorLabel"),
        ]
        for (value, raw) in fields {
            #expect(value.rawValue == raw)
        }
    }

    // MARK: - CullingFilters

    @Test func cullingFiltersRoundTripAndKeys() throws {
        let original = CullingFilters(
            ratings: [4, 5],
            pickStates: [.picked, .unreviewed],
            colorLabels: [.red, .green],
            unreviewedOnly: true,
            qualityStatus: .analysed,
            metadataConflictOnly: false
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CullingFilters.self, from: data) == original)

        let expected = [
            "ratings", "pickStates", "colorLabels", "unreviewedOnly", "qualityStatus", "metadataConflictOnly",
        ]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "CullingFilters JSON key 必须与 TS 字段名一致")
        #expect(!Set(try jsonKeys(of: data)).contains("pick_states"))
    }

    @Test func cullingFiltersEmptyEncodesEmptyObject() throws {
        let empty = CullingFilters()
        #expect(try jsonKeys(of: JSONEncoder().encode(empty)).isEmpty, "全可选 filters 未设置时编码为 {}")
    }

    // MARK: - AssetCullingState

    @Test func assetCullingStateRoundTripAndKeys() throws {
        let original = AssetCullingState(
            photoId: "p1", pickState: .picked, rating: 4,
            colorLabel: .blue, source: .manual, revision: 2,
            updatedAt: "2025-01-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AssetCullingState.self, from: data) == original)

        let expected = ["photoId", "pickState", "rating", "colorLabel", "source", "revision", "updatedAt"]
        #expect(Set(try jsonKeys(of: data)) == Set(expected))
        #expect(!Set(try jsonKeys(of: data)).contains("pick_state"))
    }

    @Test func assetCullingStateDecodesColorLabelRawValues() throws {
        let json = #"{"photoId":"p1","pickState":"rejected","rating":0,"colorLabel":"Orange","source":"ai","revision":1,"updatedAt":"t"}"#
        let decoded = try JSONDecoder().decode(AssetCullingState.self, from: Data(json.utf8))
        #expect(decoded.pickState == .rejected)
        #expect(decoded.colorLabel == .orange)
        #expect(decoded.source == .ai)
    }

    // MARK: - CullingAsset（跨域引用 PhotoData / MetadataMutationSource）

    @Test func cullingAssetRoundTripAndKeys() throws {
        let photo = PhotoData(
            id: "p1", sessionId: "s1", filepath: "/u/DSC0001.ARW", filename: "DSC0001.ARW",
            checksum: "abc", hasExistingXmp: true, faceCount: 1, width: 6000, height: 4000,
            metadata: ["keywords": .array([.string("街头")])], result: [:], status: "indexed",
            assetId: "asset_1", variantCount: 2,
            variants: [PhotoVariant(photoId: "p1", filepath: "/u/DSC0001.JPG", filename: "DSC0001.JPG", role: "preview")],
            createdAt: "t", updatedAt: "t"
        )
        let original = CullingAsset(
            photo: photo,
            state: AssetCullingState(
                photoId: "p1", pickState: .picked, rating: 5, colorLabel: .green,
                source: .template, revision: 3, updatedAt: "t"
            ),
            xmpPath: "/u/DSC0001.xmp",
            syncStatus: .pending,
            people: ["爸爸"],
            keywords: ["街头"],
            similarityGroupId: "grp_1",
            linkedVariantCount: 2,
            faceBboxes: [[0.1, 0.2, 0.3, 0.4], [0.5, 0.6, 0.7, 0.8]],
            quality: CullingQuality(
                status: .succeeded, score: 0.85, sharpness: 0.7, exposure: 0.6,
                subjectSharpness: 0.9, warnings: []
            ),
            metadataSource: .culling
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CullingAsset.self, from: data)
        #expect(decoded == original)
        #expect(decoded.photo.id == "p1")
        #expect(decoded.photo.variants?.first?.role == "preview")
        #expect(decoded.metadataSource == .culling)

        let expected = [
            "photo", "state", "xmpPath", "syncStatus", "people", "keywords",
            "similarityGroupId", "linkedVariantCount", "faceBboxes", "quality", "metadataSource",
        ]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "CullingAsset JSON key 必须与 TS 字段名一致")
        #expect(!Set(try jsonKeys(of: data)).contains("linked_variant_count"))
        #expect(!Set(try jsonKeys(of: data)).contains("xmp_path"))
    }

    @Test func cullingAssetOptionalsOmittedWhenNil() throws {
        let asset = CullingAsset(
            photo: PhotoData(
                id: "p1", sessionId: "s1", filepath: "/u/a.jpg", filename: "a.jpg",
                checksum: "c", hasExistingXmp: false, faceCount: 0, width: 1, height: 1,
                metadata: [:], result: [:], status: "indexed", createdAt: "t", updatedAt: "t"
            ),
            state: AssetCullingState(
                photoId: "p1", pickState: .unreviewed, rating: 0, colorLabel: .none,
                source: .manual, revision: 0, updatedAt: "t"
            ),
            xmpPath: "/u/a.xmp", syncStatus: .clean, people: [], keywords: [],
            linkedVariantCount: 1, faceBboxes: []
        )
        let keys = try jsonKeys(of: JSONEncoder().encode(asset))
        #expect(!keys.contains("similarityGroupId"))
        #expect(!keys.contains("quality"))
        #expect(!keys.contains("metadataSource"))
    }

    // MARK: - CullingPage（nextRowId: number | null）

    @Test func cullingPageRoundTripAndKeys() throws {
        let original = CullingPage(
            assets: [],
            nextRowId: 42,
            total: 3
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CullingPage.self, from: data)
        #expect(decoded == original)
        #expect(Set(try jsonKeys(of: data)) == ["assets", "nextRowId", "total"])
    }

    @Test func cullingPageNextRowIdNullAlwaysEncoded() throws {
        let page = CullingPage(assets: [], nextRowId: nil, total: 3)
        let object = try jsonObject(of: JSONEncoder().encode(page))
        #expect(object["nextRowId"] is NSNull, "TS nextRowId: number | null —— nil 必须编码为 null 且 key 恒存在")
    }

    @Test func cullingPageNextRowIdDecodesFromNull() throws {
        let json = #"{"assets":[],"nextRowId":null,"total":3}"#
        let decoded = try JSONDecoder().decode(CullingPage.self, from: Data(json.utf8))
        #expect(decoded.nextRowId == nil)
        #expect(decoded.total == 3)
    }

    // MARK: - Culling params

    @Test func cullingListPageParamsKeysAndOptionality() throws {
        let full = CullingListPageParams(
            sessionId: "s1", scope: .filtered,
            filters: CullingFilters(ratings: [4]), groupId: "g1",
            afterRowId: 99, limit: 50
        )
        let fullKeys = try jsonKeys(of: JSONEncoder().encode(full))
        #expect(Set(fullKeys) == ["sessionId", "scope", "filters", "groupId", "afterRowId", "limit"])

        let minimal = CullingListPageParams(sessionId: "s1", scope: .all)
        let minimalKeys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(Set(minimalKeys) == ["sessionId", "scope"])
    }

    @Test func cullingUpdatePatchAndParamsRoundTrip() throws {
        let patch = CullingUpdatePatch(rating: 4, pickState: .picked, colorLabel: .yellow)
        let patchData = try JSONEncoder().encode(patch)
        #expect(try JSONDecoder().decode(CullingUpdatePatch.self, from: patchData) == patch)
        #expect(Set(try jsonKeys(of: patchData)) == ["rating", "pickState", "colorLabel"])

        let params = CullingUpdateParams(
            sessionId: "s1", photoId: "p1", expectedRevision: 3,
            patch: CullingUpdatePatch(rating: 5)
        )
        let paramsData = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(CullingUpdateParams.self, from: paramsData) == params)
        #expect(Set(try jsonKeys(of: paramsData)) == ["sessionId", "photoId", "expectedRevision", "patch"])
    }

    @Test func cullingUpdatePatchEmptyEncodesEmptyObject() throws {
        let empty = CullingUpdatePatch()
        #expect(try jsonKeys(of: JSONEncoder().encode(empty)).isEmpty)
    }

    @Test func cullingUpdateResultRoundTrip() throws {
        let original = CullingUpdateResult(
            states: [AssetCullingState(
                photoId: "p1", pickState: .picked, rating: 4, colorLabel: .blue,
                source: .manual, revision: 4, updatedAt: "t"
            )],
            xmpPath: "/u/a.xmp",
            syncStatus: .written,
            historyOperationId: 7
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CullingUpdateResult.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["states", "xmpPath", "syncStatus", "historyOperationId"])
    }

    @Test func cullingBatchUpdateAndDecideGroupParamsRoundTrip() throws {
        let batch = CullingBatchUpdateParams(
            sessionId: "s1", photoIds: ["p1", "p2"], patch: CullingUpdatePatch(pickState: .rejected)
        )
        let batchData = try JSONEncoder().encode(batch)
        #expect(try JSONDecoder().decode(CullingBatchUpdateParams.self, from: batchData) == batch)
        #expect(Set(try jsonKeys(of: batchData)) == ["sessionId", "photoIds", "patch"])

        let decideGroup = CullingDecideGroupParams(sessionId: "s1", groupId: "g1", keepPhotoIds: ["p1"])
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(decideGroup))) == ["sessionId", "groupId", "keepPhotoIds"])
    }

    @Test func cullingSyncControlParamsRoundTrip() throws {
        let syncStatus = CullingSyncStatusParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(syncStatus))) == ["sessionId"])

        let flush = CullingFlushParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(flush))) == ["sessionId"])

        let retry = CullingRetrySyncParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(retry))) == ["sessionId"])

        let finalize = CullingFinalizeSyncParams(sessionId: "s1", confirmed: true)
        let finalizeData = try JSONEncoder().encode(finalize)
        #expect(try JSONDecoder().decode(CullingFinalizeSyncParams.self, from: finalizeData) == finalize)
        #expect(Set(try jsonKeys(of: finalizeData)) == ["sessionId", "confirmed"])
    }

    // MARK: - Culling history

    @Test func cullingHistoryEntryRoundTripAndKeys() throws {
        let original = CullingHistoryEntry(
            photoId: "p1",
            before: CullingStateSnapshot(pickState: .unreviewed, rating: 0, colorLabel: .none),
            after: CullingStateSnapshot(pickState: .picked, rating: 4, colorLabel: .green),
            expectedRevision: 2,
            fields: [.pickState, .rating, .colorLabel]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CullingHistoryEntry.self, from: data) == original)

        let expected = ["photoId", "before", "after", "expectedRevision", "fields"]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "CullingHistoryEntry JSON key 必须与 TS 字段名一致")
        #expect(!Set(try jsonKeys(of: data)).contains("expected_revision"))
    }

    @Test func cullingHistoryOperationRoundTrip() throws {
        let original = CullingHistoryOperation(
            id: 1, sessionId: "s1",
            entries: [CullingHistoryEntry(
                photoId: "p1",
                before: CullingStateSnapshot(pickState: .unreviewed, rating: 0, colorLabel: .none),
                after: CullingStateSnapshot(pickState: .rejected, rating: 0, colorLabel: .none),
                expectedRevision: 1, fields: [.pickState]
            )],
            undone: false, createdAt: "t"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CullingHistoryOperation.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["id", "sessionId", "entries", "undone", "createdAt"])
    }

    @Test func cullingHistoryParamsAndApplyParamsRoundTrip() throws {
        let history = CullingHistoryParams(sessionId: "s1", limit: 20)
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(history))) == ["sessionId", "limit"])

        let apply = CullingHistoryApplyParams(
            sessionId: "s1",
            entries: [
                CullingHistoryApplyEntry(
                    photoId: "p1", expectedRevision: 2,
                    patch: CullingUpdatePatch(pickState: .picked)
                ),
            ],
            historyOperationId: 1,
            direction: .redo
        )
        let applyData = try JSONEncoder().encode(apply)
        #expect(try JSONDecoder().decode(CullingHistoryApplyParams.self, from: applyData) == apply)
        #expect(Set(try jsonKeys(of: applyData)) == ["sessionId", "entries", "historyOperationId", "direction"])
    }

    // MARK: - MetadataSyncItem / MetadataSyncSummary

    @Test func metadataSyncItemRoundTrip() throws {
        let original = MetadataSyncItem(
            xmpPath: "/u/a.xmp", revision: 2, persistedRevision: 1,
            status: .writing, attemptCount: 1, errorMessage: "", updatedAt: "t"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MetadataSyncItem.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["xmpPath", "revision", "persistedRevision", "status", "attemptCount", "errorMessage", "updatedAt"])
    }

    @Test func metadataSyncSummaryRoundTripAndKeys() throws {
        let original = MetadataSyncSummary(
            sessionId: "s1",
            pending: 2, writing: 1, written: 5, failed: 1, conflict: 1, synced: 0,
            items: [MetadataSyncItem(
                xmpPath: "/u/a.xmp", revision: 2, persistedRevision: 2,
                status: .conflict, attemptCount: 2, errorMessage: "XMP_CONFLICT_RESOLUTION_REQUIRED",
                updatedAt: "t"
            )]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MetadataSyncSummary.self, from: data) == original)

        let expected = ["sessionId", "pending", "writing", "written", "failed", "conflict", "synced", "items"]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "MetadataSyncSummary JSON key 必须与 TS 字段名一致")
        #expect(!Set(try jsonKeys(of: data)).contains("session_id"))
    }

    // MARK: - 旧版兼容契约

    @Test func legacyCullingParamsRoundTrip() throws {
        let decide = CullingDecideParams(sessionId: "s1", photoId: "p1", decision: .keep)
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(decide))) == ["sessionId", "photoId", "decision"])

        let batchDecide = CullingBatchDecideParams(sessionId: "s1", photoIds: ["p1"], decision: .reject)
        #expect(try JSONDecoder().decode(CullingBatchDecideParams.self, from: JSONEncoder().encode(batchDecide)) == batchDecide)

        let writeback = CullingWritebackParams(sessionId: "s1", confirmed: true, target: .colorLabel)
        let writebackData = try JSONEncoder().encode(writeback)
        #expect(try JSONDecoder().decode(CullingWritebackParams.self, from: writebackData) == writeback)
        #expect(Set(try jsonKeys(of: writebackData)) == ["sessionId", "confirmed", "target"])

        let retry = CullingRetryWritebackParams(sessionId: "s1", confirmed: true)
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(retry))) == ["sessionId", "confirmed"])

        let cleanup = CullingCleanupParams(sessionId: "s1", confirmed: false)
        #expect(try JSONDecoder().decode(CullingCleanupParams.self, from: JSONEncoder().encode(cleanup)) == cleanup)

        let confirm = CullingConfirmSyncParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(confirm))) == ["sessionId"])

        let groups = CullingGroupsParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(groups))) == ["sessionId"])

        let summaryParams = CullingSummaryParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(summaryParams))) == ["sessionId"])

        let reset = CullingResetParams(sessionId: "s1", groupId: "g1", confirmed: true)
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(reset))) == ["sessionId", "groupId", "confirmed"])

        let resetMinimal = CullingResetParams(sessionId: "s1", confirmed: true)
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(resetMinimal))) == ["sessionId", "confirmed"])
    }

    @Test func cullingGroupRoundTripAndKeys() throws {
        let original = CullingGroup(
            groupId: "g1", groupIndex: 0,
            images: [CullingImage(photoId: "p1", filepath: "/u/a.jpg", filename: "a.jpg", decision: .keep)],
            keepCount: 1, rejectCount: 0, pendingCount: 0
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CullingGroup.self, from: data) == original)

        let expected = ["groupId", "groupIndex", "images", "keepCount", "rejectCount", "pendingCount"]
        #expect(Set(try jsonKeys(of: data)) == Set(expected))
        #expect(!Set(try jsonKeys(of: data)).contains("group_id"))
    }

    @Test func cullingSummaryRoundTrip() throws {
        let original = CullingSummary(
            totalGroups: 5, totalPhotos: 30, kept: 20, rejected: 5, pending: 5, rated: 12, labeled: 8
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CullingSummary.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["totalGroups", "totalPhotos", "kept", "rejected", "pending", "rated", "labeled"])
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
