#if DEBUG
import Foundation
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewFixtures+Culling.swift
// Cut 4 / 4c-1 Preview 固定样例的纯移动拆分（挑片 / 同步 / 历史 / 元数据冲突）。
// 成员文本与拆分前逐字一致；只在 DEBUG 编译。

extension PreviewData {
    // MARK: 挑片（Culling）

    static let cullingAssets: [CullingAsset] = (1...3).map { index in
        let path = galleryPaths[index - 1]
        let pickState: PickState = index == 1 ? .picked : (index == 2 ? .rejected : .unreviewed)
        let rating: Double = index == 1 ? 5 : (index == 2 ? 1 : 0)
        let color: CaptureOneColorLabel = index == 1 ? .green : (index == 2 ? .red : .none)
        let photo = PhotoData(
            id: "preview-culling-\(index)",
            sessionId: sessionOneId,
            filepath: path,
            filename: (path as NSString).lastPathComponent,
            checksum: String(format: "preview-culling-checksum-%02d", index),
            hasExistingXmp: index == 1,
            faceCount: index == 1 ? 1 : 0,
            width: 6000,
            height: 4000,
            metadata: [:],
            result: [:],
            status: "ready",
            createdAt: earlierTimestamp,
            updatedAt: timestamp
        )
        let state = AssetCullingState(
            photoId: photo.id,
            pickState: pickState,
            rating: rating,
            colorLabel: color,
            source: .manual,
            revision: index,
            updatedAt: timestamp
        )
        return CullingAsset(
            photo: photo,
            state: state,
            xmpPath: path.replacingOccurrences(of: ".NEF", with: ".xmp"),
            syncStatus: index == 1 ? .written : .clean,
            people: index == 1 ? ["Mika"] : [],
            keywords: index == 1 ? ["Kyoto", "Sakura"] : ["Kyoto"],
            similarityGroupId: nil,
            linkedVariantCount: index == 2 ? 2 : 1,
            faceBboxes: index == 1 ? [[0.24, 0.18, 0.28, 0.36]] : [],
            quality: index == 1
                ? CullingQuality(
                    status: .succeeded,
                    score: 0.86,
                    sharpness: 0.91,
                    exposure: 0.78,
                    warnings: []
                )
                : nil,
            metadataSource: .manual
        )
    }

    static let cullingPage = CullingPage(assets: cullingAssets, total: cullingAssets.count)

    static let cullingSummary = CullingSummary(
        totalGroups: 1,
        totalPhotos: 3,
        kept: 1,
        rejected: 1,
        pending: 1,
        rated: 2,
        labeled: 1
    )

    static let cullingGroups: [CullingGroup] = [
        CullingGroup(
            groupId: "preview-group-1",
            groupIndex: 0,
            images: cullingAssets.enumerated().map { offset, asset in
                CullingImage(
                    photoId: asset.photo.id,
                    filepath: asset.photo.filepath,
                    filename: asset.photo.filename,
                    decision: offset == 0 ? .keep : (offset == 1 ? .reject : .pending)
                )
            },
            keepCount: 1,
            rejectCount: 1,
            pendingCount: 1
        ),
    ]

    static let navigationGroups: [NavigationGroup] = [
        NavigationGroup(
            id: "preview-nav-burst",
            type: .burst,
            photoIds: cullingAssets.map(\.photo.id),
            startAt: earlierTimestamp,
            endAt: timestamp,
            leadPhotoId: cullingAssets[0].photo.id,
            explanation: "连拍 3 张（预览样例）",
            source: .automatic
        ),
        NavigationGroup(
            id: "preview-nav-scene",
            type: .scene,
            photoIds: [cullingAssets[0].photo.id, cullingAssets[2].photo.id],
            startAt: earlierTimestamp,
            endAt: timestamp,
            leadPhotoId: cullingAssets[0].photo.id,
            explanation: "场景 1（预览样例）",
            source: .manual
        ),
    ]

    static let syncSummary = MetadataSyncSummary(
        sessionId: sessionOneId,
        pending: 2,
        writing: 1,
        written: 3,
        failed: 1,
        conflict: 1,
        synced: 5,
        items: [
            MetadataSyncItem(
                xmpPath: sourceRoot + "/DSC_0001.xmp",
                revision: 3,
                persistedRevision: 2,
                status: .written,
                attemptCount: 1,
                errorMessage: "",
                updatedAt: timestamp
            ),
            MetadataSyncItem(
                xmpPath: sourceRoot + "/DSC_0002.xmp",
                revision: 2,
                persistedRevision: 2,
                status: .conflict,
                attemptCount: 0,
                errorMessage: "XMP_CONFLICT_RESOLUTION_REQUIRED",
                updatedAt: timestamp
            ),
            MetadataSyncItem(
                xmpPath: sourceRoot + "/DSC_0003.xmp",
                revision: 1,
                persistedRevision: 0,
                status: .pending,
                attemptCount: 0,
                errorMessage: "",
                updatedAt: timestamp
            ),
        ]
    )

    static let cullingSyncStatus = CullingSyncStatus(summary: syncSummary, reloadAckedAt: timestamp)

    static let cullingHistory: [CullingHistoryOperation] = [
        CullingHistoryOperation(
            id: 1,
            sessionId: sessionOneId,
            entries: [
                CullingHistoryEntry(
                    photoId: cullingAssets[0].photo.id,
                    before: CullingStateSnapshot(pickState: .unreviewed, rating: 0, colorLabel: .none),
                    after: CullingStateSnapshot(pickState: .picked, rating: 5, colorLabel: .green),
                    expectedRevision: 1,
                    fields: [.pickState, .rating, .colorLabel]
                ),
            ],
            undone: false,
            createdAt: timestamp
        ),
    ]

    static let conflicts: [MetadataConflict] = [
        MetadataConflict(
            xmpPath: sourceRoot + "/DSC_0002.xmp",
            photoPath: sourceRoot + "/DSC_0002.NEF",
            revision: 2,
            fields: [
                MetadataConflictField(
                    field: .rating,
                    baseline: .number(0),
                    local: .number(5),
                    remote: .number(3)
                ),
                MetadataConflictField(
                    field: .label,
                    baseline: .string("None"),
                    local: .string("Green"),
                    remote: .string("Red")
                ),
            ]
        ),
        MetadataConflict(
            xmpPath: sourceRoot + "/DSC_0004.xmp",
            photoPath: sourceRoot + "/DSC_0004.NEF",
            revision: 1,
            fields: [
                MetadataConflictField(
                    field: .keywords,
                    baseline: .array([]),
                    local: .array([.string("Kyoto")]),
                    remote: .array([.string("Osaka")])
                ),
            ]
        ),
    ]
}
#endif
