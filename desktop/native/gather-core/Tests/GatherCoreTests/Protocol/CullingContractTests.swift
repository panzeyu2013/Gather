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

    // MARK: - CullingPage（nextCursor 唯一续页凭据）

    @Test func cullingPageRoundTripAndKeys() throws {
        let original = CullingPage(
            assets: [],
            total: 3,
            nextCursor: CullingPageCursor(sort: .importOrder, rowId: 42)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CullingPage.self, from: data)
        #expect(decoded == original)
        #expect(Set(try jsonKeys(of: data)) == ["assets", "nextCursor", "total"])
    }

    @Test func cullingPageNilCursorIsOmitted() throws {
        let page = CullingPage(assets: [], total: 3)
        let object = try jsonObject(of: JSONEncoder().encode(page))
        #expect(object["nextCursor"] == nil)
    }

    @Test func cullingPageDecodesWithoutCursor() throws {
        let json = #"{"assets":[],"total":3}"#
        let decoded = try JSONDecoder().decode(CullingPage.self, from: Data(json.utf8))
        #expect(decoded.nextCursor == nil)
        #expect(decoded.total == 3)
    }

    // MARK: - Culling params

    @Test func cullingUpdatePatchRoundTrip() throws {
        let patch = CullingUpdatePatch(rating: 4, pickState: .picked, colorLabel: .yellow)
        let patchData = try JSONEncoder().encode(patch)
        #expect(try JSONDecoder().decode(CullingUpdatePatch.self, from: patchData) == patch)
        #expect(Set(try jsonKeys(of: patchData)) == ["rating", "pickState", "colorLabel"])
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

    @Test func cullingSummaryCarriesTriageSummary() throws {
        let triage = TriageSummary(
            counts: TriageCounts(keep: 3, reject: 2, review: 1, total: 6, coverage: 0.8),
            stale: false, policyVersion: "triage-v1",
            inputFingerprint: "fp", generatedAt: "t"
        )
        let original = CullingSummary(
            totalGroups: 5, totalPhotos: 30, kept: 20, rejected: 5, pending: 5,
            rated: 12, labeled: 8, triage: triage
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CullingSummary.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == [
            "totalGroups", "totalPhotos", "kept", "rejected", "pending", "rated", "labeled", "triage",
        ])
    }

    @Test func cullingAssetTriageRoundTripAndDefaultNil() throws {
        let photo = PhotoData(
            id: "p1", sessionId: "s1", filepath: "/u/DSC0001.ARW", filename: "DSC0001.ARW",
            checksum: "abc", hasExistingXmp: true, faceCount: 0, width: 6000, height: 4000,
            metadata: [:], result: [:], status: "indexed", assetId: "asset_1",
            createdAt: "t", updatedAt: "t"
        )
        let state = AssetCullingState(
            photoId: "p1", pickState: .unreviewed, rating: 0,
            colorLabel: .none, source: .manual, revision: 0, updatedAt: "t"
        )
        let suggestion = TriageSuggestion(
            photoId: "p1", verdict: .reject, score: 0.42, confidence: 0.91,
            reasons: [TriageReason(code: .motionBlur), TriageReason(code: .weakerThanGroupBest, value: 0.3)],
            groupId: "sim:1:0", policyVersion: "triage-v1",
            inputFingerprint: "fp", computedAt: "t"
        )
        let original = CullingAsset(
            photo: photo, state: state, xmpPath: "/u/DSC0001.xmp", syncStatus: .clean,
            people: [], keywords: [], linkedVariantCount: 1, faceBboxes: [], triage: suggestion
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CullingAsset.self, from: data) == original)
        #expect(try jsonKeys(of: data).contains("triage"))

        let without = CullingAsset(
            photo: photo, state: state, xmpPath: "/u/DSC0001.xmp", syncStatus: .clean,
            people: [], keywords: [], linkedVariantCount: 1, faceBboxes: []
        )
        let withoutData = try JSONEncoder().encode(without)
        let keysWithout = try jsonKeys(of: withoutData)
        #expect(!keysWithout.contains("triage"), "nil 建议不新增 JSON key（旧读方兼容）")
        #expect(try JSONDecoder().decode(CullingAsset.self, from: withoutData) == without)
    }

    @Test("G0 冻结枚举 rawValue：CullingSort / keyKind / 方向")
    func cullingSortRawValuesAreFrozen() {
        #expect(CullingSort.allCases.map(\.rawValue) == [
            "import", "capture_desc", "capture_asc", "rating_desc", "triage_confidence_asc",
        ])
        #expect(CullingSort.importOrder.keyKind == .rowId)
        #expect(CullingSort.captureDesc.keyKind == .date)
        #expect(CullingSort.captureAsc.keyKind == .date)
        #expect(CullingSort.ratingDesc.keyKind == .number)
        #expect(CullingSort.triageConfidenceAsc.keyKind == .number)
        #expect(CullingSort.captureDesc.descending)
        #expect(CullingSort.ratingDesc.descending)
        #expect(!CullingSort.captureAsc.descending)
        #expect(!CullingSort.importOrder.descending)
    }

    @Test("T0 冻结枚举 rawValue：verdict / reason / review flag")
    func triageRawValuesAreFrozen() {
        #expect(TriageVerdict.allCases.map(\.rawValue) == ["keep", "reject", "review"])
        #expect(TriageReasonCode.allCases.count == 17)
        #expect(Set(TriageReasonCode.allCases.map(\.rawValue)) == [
            "group_best", "weaker_than_group_best", "motion_blur", "exposure_low",
            "closed_eye_suspect", "close_call", "tie_with_group", "single_shot",
            "no_alternative", "low_technical", "quality_missing", "analysis_failed",
            "duplicate_exact", "duplicate_visual", "multi_face_low_confidence",
            "small_face", "manual_override",
        ])
        #expect(Set(FaceReviewFlag.allCases.map(\.rawValue)) == [
            "suspect", "low_quality", "small_face",
            "unresolved_observation", "incompatible_model",
        ])
    }

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
