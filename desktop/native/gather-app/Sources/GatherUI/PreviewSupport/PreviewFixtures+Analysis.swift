#if DEBUG
import Foundation
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewFixtures+Analysis.swift
// Cut 4 / 4c-1 Preview 固定样例的纯移动拆分（人脸 / 相似度 / 重复检测）。
// 成员文本与拆分前逐字一致；只在 DEBUG 编译。

extension PreviewData {
    // MARK: 人脸（Face）

    // 每个实参先落到显式类型的局部常量：Xcode 26 的 type-checker 对整段字面量
    // 初始化式会超时（CI 实测 unable to type-check this expression in reasonable time）。
    static let faceClusters: [FaceClusterData] = (1...6).map { clusterIndex in
        let members: [ClusterMember] = (1...4).map { memberIndex in
            let pathIndex: Int = (clusterIndex + memberIndex) % facePaths.count
            let photoPath: String = facePaths[pathIndex]
            return ClusterMember(
                memberId: clusterIndex * 10 + memberIndex,
                photoId: "preview-face-\(clusterIndex)-\(memberIndex)",
                photoPath: photoPath,
                filename: (photoPath as NSString).lastPathComponent,
                bbox: [0.2, 0.16, 0.34, 0.44],
                confidence: 0.92)
        }
        let role: String? = clusterIndex == 1 ? "Mika" : (clusterIndex == 2 ? "Ren" : nil)
        let label: String = role ?? "簇 \(clusterIndex)"
        let size: Int = clusterIndex == 1 ? 12 : (clusterIndex == 2 ? 9 : 4)
        let status: String = role == nil ? "new" : "bound"
        let binding: FaceClusterBinding? = role.map { name in
            FaceClusterBinding(roleName: name, keywords: [name, "人像"])
        }
        let matchConfidence: Double? = role == nil ? nil : 0.88
        return FaceClusterData(
            id: clusterIndex,
            sessionId: sessionOneId,
            label: label,
            size: size,
            status: status,
            thumbnailBase64: "",
            binding: binding,
            thumbnailPhotoId: members[0].photoId,
            members: members,
            matchedPersonId: RolePerson.matchingId(role),
            matchedPersonName: role,
            matchConfidence: matchConfidence)
    }

    enum RolePerson {
        static func matchingId(_ role: String?) -> String? {
            switch role {
            case "Mika": return "preview-person-1"
            case "Ren": return "preview-person-2"
            default: return nil
            }
        }
    }

    static let faceModelsStatus = FaceModelsStatus(
        provider: "vision",
        fallbackToOnnxEnabled: false,
        modelsPresent: true,
        downloading: false
    )

    static let faceWritebackPreview: WritebackPreview = {
        let items: [WritebackItem] = (1...3).map { index in
            let path: String = facePaths[index - 1]
            let xmpPath: String = path.replacingOccurrences(of: ".NEF", with: ".xmp")
            let preview: WritebackItemPreview = WritebackItemPreview(
                dirtyFields: [.keywords],
                before: WritebackAttributes(keywords: []),
                after: WritebackAttributes(keywords: ["Mika", "人像"]),
                source: "face-keyword",
                sharedPhotoCount: 1,
                externalChanged: false,
                willCreate: true)
            return WritebackItem(
                id: index,
                photoId: "preview-face-1-\(index)",
                photoPath: path,
                sessionId: sessionOneId,
                module: "face-keyword",
                keywords: ["Mika", "人像"],
                attributes: WritebackAttributes(keywords: ["Mika", "人像"]),
                xmpPath: xmpPath,
                backupPath: "",
                xmpStatus: "pending",
                errorMessage: "",
                attemptCount: 0,
                lastAttemptAt: "",
                preview: preview)
        }
        return WritebackPreview(items: items, totalCount: 3, affectedPhotos: 3)
    }()

    static let faceWritebackResult = WritebackResult(
        totalAffected: 3,
        written: 2,
        failed: 1,
        skipped: 0,
        errors: ["XMP_WRITE_FAILED"],
        failedItems: [faceWritebackPreview.items[2]],
        report: "预览样例：2 成功 / 1 失败"
    )

    // MARK: 相似度（Similarity）

    static let similarityResult: SimilarityResult = {
        let groups: [SimilarityGroup] = (1...3).map { groupIndex in
            let images: [SimilarityImage] = (1...4).map { imageIndex in
                let path: String = similarityPaths[(groupIndex + imageIndex) % similarityPaths.count]
                let representative: Bool? = imageIndex == 1 ? true : nil
                return SimilarityImage(path: path, representative: representative)
            }
            return SimilarityGroup(id: groupIndex, label: "连拍组 \(groupIndex)", count: 4, images: images)
        }
        let ungrouped: [SimilarityImage] = [
            SimilarityImage(path: similarityPaths[5]),
            SimilarityImage(path: galleryPaths[10]),
        ]
        let stats = SimilarityResultStats(
            totalGroups: 3,
            totalUngrouped: 2,
            threshold: 10,
            minGroupSize: 2,
            groupingMode: .global,
            precomputed: true)
        return SimilarityResult(groups: groups, ungrouped: ungrouped, stats: stats)
    }()

    static let similarityWritebackItems: [WritebackItem] = (1...3).map { index in
        let status: String = index == 1 ? "pending" : (index == 2 ? "written" : "failed")
        let path: String = similarityPaths[index - 1]
        let failed: Bool = status == "failed"
        return WritebackItem(
            id: index,
            photoId: "preview-similarity-\(index)",
            photoPath: path,
            sessionId: sessionOneId,
            module: "similarity",
            keywords: ["连拍", "旅行"],
            attributes: WritebackAttributes(keywords: ["连拍", "旅行"]),
            xmpPath: path.replacingOccurrences(of: ".NEF", with: ".xmp"),
            backupPath: "",
            xmpStatus: status,
            errorMessage: failed ? "XMP_WRITE_FAILED" : "",
            attemptCount: failed ? 1 : 0,
            lastAttemptAt: failed ? timestamp : "",
            preview: nil
        )
    }

    static let similarityWritebackPreview = WritebackPreview(
        items: similarityWritebackItems,
        totalCount: similarityWritebackItems.count,
        affectedPhotos: similarityWritebackItems.count
    )

    // MARK: 重复检测（Duplicates）

    static let duplicateGroups: [DuplicateGroup] = [
        duplicateGroup(
            id: 1,
            type: .exact,
            photoPaths: [galleryPaths[0], galleryPaths[1], galleryPaths[2]]
        ),
        duplicateGroup(
            id: 2,
            type: .exact,
            photoPaths: [galleryPaths[3], galleryPaths[4]]
        ),
        duplicateGroup(
            id: 3,
            type: .visual,
            photoPaths: [galleryPaths[5], galleryPaths[6], galleryPaths[7], galleryPaths[8]]
        ),
    ]

    static let duplicateScanResult = DuplicateScanResult(
        exactGroups: Array(duplicateGroups.prefix(2)),
        visualGroups: [duplicateGroups[2]],
        totalDuplicates: 7
    )

    private static func duplicateGroup(
        id: Int,
        type: DuplicateGroupType,
        photoPaths: [String]
    ) -> DuplicateGroup {
        let members = photoPaths.enumerated().map { index, path in
            DuplicateGroupMember(
                id: id * 100 + index + 1,
                photoId: "preview-duplicate-\(id)-\(index)",
                isKept: index == 0,
                fileSize: 24_000_000 + index * 1_024,
                fileMtime: timestamp,
                resolution: "6000x4000",
                filepath: path,
                filename: (path as NSString).lastPathComponent
            )
        }
        return DuplicateGroup(
            id: id,
            groupType: type,
            checksum: type == .exact ? "preview-checksum-\(id)" : nil,
            hashHex: type == .visual ? "preview-hash-\(id)" : nil,
            memberCount: members.count,
            members: members,
            resolution: nil,
            createdAt: timestamp
        )
    }
}
#endif
