#if DEBUG
import Foundation
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewFixtures+Library.swift
// Cut 4 / 4c-1 Preview 固定样例的纯移动拆分（图库 / 全局图库 / 相册 / 资产关联 / 孤立 XMP）。
// 成员文本与拆分前逐字一致；只在 DEBUG 编译。

extension PreviewData {
    // MARK: 图库（Gallery）

    static let galleryPhotos: [GalleryPhotoData] = (1...12).map { index in
        let path = galleryPaths[index - 1]
        let variants: [GalleryVariantData] = index == 2
            ? [
                GalleryVariantData(
                    photoId: "preview-variant-\(index)-raw",
                    filepath: path,
                    filename: (path as NSString).lastPathComponent,
                    role: "raw"
                ),
                GalleryVariantData(
                    photoId: "preview-variant-\(index)-jpeg",
                    filepath: path.replacingOccurrences(of: ".NEF", with: ".JPG"),
                    filename: "DSC_0002.JPG",
                    role: "jpeg"
                ),
            ]
            : []
        return GalleryPhotoData(
            id: "preview-gallery-\(index)",
            sessionId: sessionOneId,
            filepath: path,
            filename: (path as NSString).lastPathComponent,
            checksum: String(format: "preview-checksum-%04d", index),
            hasExistingXmp: index.isMultiple(of: 3),
            faceCount: index <= 4 ? 2 : 0,
            width: 6000,
            height: 4000,
            status: index == 5 ? "missing" : "ready",
            variantCount: index == 2 ? 2 : 1,
            variants: variants,
            createdAt: earlierTimestamp,
            updatedAt: timestamp,
            assetId: "preview-asset-\(index)"
        )
    }

    // MARK: 全局图库（Library）

    static let globalPhotos: [GlobalPhotoResult] = (1...8).map { index in
        GlobalPhotoResult(
            photoId: "preview-library-\(index)",
            assetId: "preview-library-asset-\(index)",
            sessionId: index <= 5 ? sessionOneId : sessionTwoId,
            sessionName: index <= 5 ? sessionOneName : sessionTwoName,
            sessionIds: [index <= 5 ? sessionOneId : sessionTwoId],
            sessionNames: [index <= 5 ? sessionOneName : sessionTwoName],
            filename: (libraryPaths[index - 1] as NSString).lastPathComponent,
            filepath: libraryPaths[index - 1],
            status: "ready",
            rating: Double(index % 6),
            label: index.isMultiple(of: 2) ? "Green" : "None",
            keywords: index.isMultiple(of: 2) ? ["Kyoto", "Sakura"] : ["Kyoto"]
        )
    }

    static let albums: [SmartAlbumData] = [
        SmartAlbumData(
            id: "preview-album-1",
            schemaVersion: 1,
            name: "五星精选",
            description: "评分 5 的照片",
            filterCriteria: FilterGroup(logic: .and, conditions: []),
            sortBy: "rating",
            sortOrder: "desc",
            icon: "star.fill",
            createdAt: earlierTimestamp,
            updatedAt: timestamp
        ),
        SmartAlbumData(
            id: "preview-album-2",
            schemaVersion: 1,
            name: "京都 · 夜景",
            description: "关键词含 night 的照片",
            filterCriteria: FilterGroup(logic: .and, conditions: []),
            sortBy: "dateTaken",
            sortOrder: "asc",
            icon: "moon.stars",
            createdAt: earlierTimestamp,
            updatedAt: timestamp
        ),
    ]

    static let assetCandidates: [AssetLinkCandidateData] = [
        AssetLinkCandidateData(
            id: "preview-candidate-1",
            leftFileId: "preview-library-1",
            rightFileId: "preview-library-2",
            leftPath: libraryPaths[0],
            rightPath: libraryPaths[1],
            confidence: 0.94,
            status: .pending,
            evidence: ["checksum": .bool(true), "dimensions": .bool(true)]
        ),
    ]

    static let assetVolumes: [AssetVolumeData] = [
        AssetVolumeData(
            volumeId: "preview-volume-studio",
            roots: [sourceRoot],
            onlineFiles: 125,
            offlineFiles: 3
        ),
    ]

    static let orphanXMPs: [MetadataOrphan] = [
        MetadataOrphan(
            xmpPath: sourceRoot + "/ORPHAN_001.xmp",
            photoPath: sourceRoot + "/ORPHAN_001.NEF",
            status: "pending",
            revision: 1,
            errorMessage: "",
            updatedAt: timestamp
        ),
    ]
}
#endif
