#if DEBUG
import AppKit
import Foundation
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewFixtures.swift
// Cut 4 / 4c-1：Xcode Preview 专用固定样例数据（只在 DEBUG 编译）。
//
// 三条纪律：
// 1. **全部 #if DEBUG**：fixture/替身不得进入 release 包（审计 §6.2 / §7.3 风险 4）；
// 2. **固定 id / 日期 / 路径**：不使用 Date()/UUID()，每次渲染结果一致，便于截图比对；
// 3. **不依赖 Tests target**：GatherUI 不能 import GatherAppTests；本目录把测试替身
//    重写成只读内存实现（见 PreviewAPIs/PreviewProviders），与 Tests/Support 的同名
//    夹具保持形状一致，但零耦合。
//
// 图片策略：不读磁盘、不注册真实 ImageDecoderPort（那会触发缩略图磁盘缓存写入）。
// PreviewThumbnailSeeder 直接把纯色占位图放进进程内 PhotoThumbnailCache，键与页面
// 解码路径完全一致；未覆盖的尺寸回退页面自带的灰色占位块。

// MARK: - 固定样例

enum PreviewData {
    // 固定 id / 时间 / 路径（确定性）。
    static let timestamp = "2026-03-28T09:15:00.000Z"
    static let earlierTimestamp = "2026-03-27T18:40:00.000Z"
    static let sessionOneId = "preview-session-kyoto"
    static let sessionTwoId = "preview-session-iceland"
    static let sessionOneName = "京都 · 樱花 2026"
    static let sessionTwoName = "冰岛 · 极光"
    static let sourceRoot = "/Volumes/Studio/2026/Kyoto"
    static let secondRoot = "/Volumes/Studio/2026/Iceland"
    static let exportDestination = "/Volumes/Exports/Kyoto-Selects"

    /// 图库 12 张：文件名/路径固定；第 2 张带 RAW+JPEG 变体，第 5 张离线。
    static let galleryPaths: [String] = (1...12).map {
        String(format: "/Volumes/Studio/2026/Kyoto/DSC_%04d.NEF", $0)
    }
    /// 人脸成员照片（和人像库共用一组路径）。
    static let facePaths: [String] = (1...8).map {
        String(format: "/Volumes/Studio/2026/Kyoto/PORTRAIT_%03d.NEF", $0)
    }
    /// 相似度分组照片。
    static let similarityPaths: [String] = (1...6).map {
        String(format: "/Volumes/Studio/2026/Kyoto/BURST_%03d.NEF", $0)
    }
    /// 全局图库（Library）照片。
    static let libraryPaths: [String] = (1...8).map {
        String(format: "/Volumes/Studio/2026/Kyoto/LIB_%04d.NEF", $0)
    }
    static let personPaths: [String] = (1...6).map {
        String(format: "/Volumes/Studio/2026/Kyoto/PERSON_%03d.NEF", $0)
    }

    /// 所有需要占位缩略图的路径（去重后交给 PreviewThumbnailSeeder）。
    static let thumbnailPaths: [String] = {
        var seen = Set<String>()
        return (galleryPaths + facePaths + similarityPaths + libraryPaths + personPaths)
            .filter { seen.insert($0).inserted }
    }()

    // MARK: 会话

    static let sessions: [SessionData] = [
        SessionData(
            id: sessionOneId,
            name: sessionOneName,
            status: .review,
            photoCount: 128,
            analysisStatus: .done,
            writebackStatus: .partial,
            importSource: "local",
            sourcePath: sourceRoot,
            failedWritebackCount: 2,
            truncatedImport: false,
            createdAt: earlierTimestamp,
            updatedAt: timestamp
        ),
        SessionData(
            id: sessionTwoId,
            name: sessionTwoName,
            status: .analyzing,
            photoCount: 64,
            analysisStatus: .running,
            writebackStatus: .idle,
            importSource: "local",
            sourcePath: secondRoot,
            failedWritebackCount: 0,
            truncatedImport: false,
            createdAt: earlierTimestamp,
            updatedAt: earlierTimestamp
        ),
    ]

    static func session(_ id: String) -> SessionData {
        sessions.first { $0.id == id } ?? sessions[0]
    }

    // MARK: 工作区状态

    static let workspaceOne = WorkspaceStatus(
        sessionId: sessionOneId,
        stage: .indexed,
        softFlags: WorkspaceSoftFlags(culled: true, exported: false),
        indexing: WorkspaceIndexingProgress(total: 128, done: 128, percent: 100, status: .idle),
        staleAnalyses: [WorkspaceStaleAnalysis(kind: .face, lastRunAt: earlierTimestamp)],
        xmp: WorkspaceXmpCounts(pending: 12, conflict: 2),
        offlinePhotos: 3,
        failedJobs: [
            WorkspaceFailedJob(
                id: "preview-job-export",
                type: AnalysisJobType.exportExecute.rawValue,
                code: "EXPORT_SOURCE_MISSING",
                message: "预览样例：有 1 个源文件缺失"
            ),
        ],
        recommendedNext: WorkspaceRecommendedNext(action: "review-culling", target: sessionOneId),
        generatedAt: timestamp
    )

    static let workspaceTwo = WorkspaceStatus(
        sessionId: sessionTwoId,
        stage: .created,
        softFlags: WorkspaceSoftFlags(culled: false, exported: false),
        indexing: WorkspaceIndexingProgress(total: 64, done: 30, percent: 46.9, status: .active),
        staleAnalyses: [],
        xmp: WorkspaceXmpCounts(pending: 0, conflict: 0),
        offlinePhotos: 0,
        failedJobs: [],
        recommendedNext: nil,
        generatedAt: timestamp
    )

    static func workspaceStatus(_ id: String) -> WorkspaceStatus {
        id == sessionTwoId ? workspaceTwo : workspaceOne
    }

    // MARK: 任务

    static let jobs: [AnalysisJobData] = [
        AnalysisJobData(
            id: "preview-job-scan",
            type: .metadataScan,
            scopeType: "session",
            scopeId: sessionOneId,
            dedupeKey: "metadata.scan:\(sessionOneId)",
            status: .running,
            priority: 0,
            progressCurrent: 72,
            progressTotal: 128,
            progressMessage: "metadata.scan",
            inputFingerprint: "preview",
            modelId: "",
            modelVersion: "",
            checkpoint: [:],
            attemptCount: 0,
            leaseOwner: "preview",
            heartbeatAt: timestamp,
            errorCode: "",
            errorMessage: "",
            createdAt: earlierTimestamp,
            startedAt: timestamp,
            finishedAt: "",
            updatedAt: timestamp
        ),
        AnalysisJobData(
            id: "preview-job-export",
            type: .exportExecute,
            scopeType: "session",
            scopeId: sessionOneId,
            dedupeKey: "export.execute:\(sessionOneId)",
            status: .failed,
            priority: 0,
            progressCurrent: 0,
            progressTotal: 8,
            progressMessage: "export.copy",
            inputFingerprint: "preview",
            modelId: "",
            modelVersion: "",
            checkpoint: [:],
            attemptCount: 1,
            leaseOwner: "",
            heartbeatAt: timestamp,
            errorCode: "EXPORT_SOURCE_MISSING",
            errorMessage: "源文件缺失",
            createdAt: earlierTimestamp,
            startedAt: earlierTimestamp,
            finishedAt: timestamp,
            updatedAt: timestamp
        ),
        AnalysisJobData(
            id: "preview-job-face",
            type: .faceAnalyze,
            scopeType: "session",
            scopeId: sessionOneId,
            dedupeKey: "face.analyze:\(sessionOneId)",
            status: .succeeded,
            priority: 0,
            progressCurrent: 128,
            progressTotal: 128,
            progressMessage: "face.encode",
            inputFingerprint: "preview",
            modelId: "sface-1.0",
            modelVersion: "1.0",
            checkpoint: [:],
            attemptCount: 1,
            leaseOwner: "",
            heartbeatAt: timestamp,
            errorCode: "",
            errorMessage: "",
            createdAt: earlierTimestamp,
            startedAt: earlierTimestamp,
            finishedAt: timestamp,
            updatedAt: timestamp
        ),
        AnalysisJobData(
            id: "preview-job-dup",
            type: .duplicateScan,
            scopeType: "session",
            scopeId: sessionTwoId,
            dedupeKey: "duplicate.scan:\(sessionTwoId)",
            status: .queued,
            priority: 0,
            progressCurrent: 0,
            progressTotal: 64,
            progressMessage: "duplicate.hash",
            inputFingerprint: "preview",
            modelId: "",
            modelVersion: "",
            checkpoint: [:],
            attemptCount: 0,
            leaseOwner: "",
            heartbeatAt: earlierTimestamp,
            errorCode: "",
            errorMessage: "",
            createdAt: earlierTimestamp,
            startedAt: "",
            finishedAt: "",
            updatedAt: earlierTimestamp
        ),
    ]

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

    // MARK: 人脸（Face）

    static let faceClusters: [FaceClusterData] = (1...6).map { clusterIndex in
        let members = (1...4).map { memberIndex in
            ClusterMember(
                memberId: clusterIndex * 10 + memberIndex,
                photoId: "preview-face-\(clusterIndex)-\(memberIndex)",
                photoPath: facePaths[(clusterIndex + memberIndex) % facePaths.count],
                filename: (facePaths[(clusterIndex + memberIndex) % facePaths.count] as NSString).lastPathComponent,
                bbox: [0.2, 0.16, 0.34, 0.44],
                confidence: 0.92
            )
        }
        let role: String? = clusterIndex == 1 ? "Mika" : (clusterIndex == 2 ? "Ren" : nil)
        return FaceClusterData(
            id: clusterIndex,
            sessionId: sessionOneId,
            label: role ?? "簇 \(clusterIndex)",
            size: clusterIndex == 1 ? 12 : (clusterIndex == 2 ? 9 : 4),
            status: role == nil ? "new" : "bound",
            thumbnailBase64: "",
            binding: role.map { FaceClusterBinding(roleName: $0, keywords: [$0, "人像"]) },
            thumbnailPhotoId: members[0].photoId,
            members: members,
            matchedPersonId: RolePerson.matchingId(role),
            matchedPersonName: role,
            matchConfidence: role == nil ? nil : 0.88
        )
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

    static let faceWritebackPreview = WritebackPreview(
        items: (1...3).map { index in
            WritebackItem(
                id: index,
                photoId: "preview-face-1-\(index)",
                photoPath: facePaths[index - 1],
                sessionId: sessionOneId,
                module: "face-keyword",
                keywords: ["Mika", "人像"],
                attributes: WritebackAttributes(keywords: ["Mika", "人像"]),
                xmpPath: facePaths[index - 1].replacingOccurrences(of: ".NEF", with: ".xmp"),
                backupPath: "",
                xmpStatus: "pending",
                errorMessage: "",
                attemptCount: 0,
                lastAttemptAt: "",
                preview: WritebackItemPreview(
                    dirtyFields: [.keywords],
                    before: WritebackAttributes(keywords: []),
                    after: WritebackAttributes(keywords: ["Mika", "人像"]),
                    source: "face-keyword",
                    sharedPhotoCount: 1,
                    externalChanged: false,
                    willCreate: true
                )
            )
        },
        totalCount: 3,
        affectedPhotos: 3
    )

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

    static let similarityResult = SimilarityResult(
        groups: (1...3).map { groupIndex in
            let images = (1...4).map { imageIndex in
                SimilarityImage(
                    path: similarityPaths[(groupIndex + imageIndex) % similarityPaths.count],
                    representative: imageIndex == 1 ? true : nil
                )
            }
            return SimilarityGroup(
                id: groupIndex,
                label: "连拍组 \(groupIndex)",
                count: 4,
                images: images
            )
        },
        ungrouped: [SimilarityImage(path: similarityPaths[5]), SimilarityImage(path: galleryPaths[10])],
        stats: SimilarityResultStats(
            totalGroups: 3,
            totalUngrouped: 2,
            threshold: 10,
            minGroupSize: 2,
            groupingMode: .global,
            precomputed: true
        )
    )

    static let similarityWritebackItems: [WritebackItem] = (1...3).map { index in
        let status = index == 1 ? "pending" : (index == 2 ? "written" : "failed")
        return WritebackItem(
            id: index,
            photoId: "preview-similarity-\(index)",
            photoPath: similarityPaths[index - 1],
            sessionId: sessionOneId,
            module: "similarity",
            keywords: ["连拍", "旅行"],
            attributes: WritebackAttributes(keywords: ["连拍", "旅行"]),
            xmpPath: similarityPaths[index - 1].replacingOccurrences(of: ".NEF", with: ".xmp"),
            backupPath: "",
            xmpStatus: status,
            errorMessage: status == "failed" ? "XMP_WRITE_FAILED" : "",
            attemptCount: status == "failed" ? 1 : 0,
            lastAttemptAt: status == "failed" ? timestamp : "",
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

    // MARK: 导出（Export）

    static let exportPreview: ExportPreview = {
        let files = (1...8).map { index in
            let path = galleryPaths[index - 1]
            return ExportPreviewFile(
                photoId: "preview-export-\(index)",
                filename: (path as NSString).lastPathComponent,
                fileSize: 24_000_000 + index * 512_000,
                outputName: String(format: "KYOTO_%04d.NEF", index),
                format: "original",
                includesXmp: index <= 2,
                issue: index == 6 ? "EXPORT_SOURCE_MISSING" : nil,
                isSizeEstimate: false,
                willSkip: false
            )
        }
        return ExportPreview(
            totalFiles: files.count,
            totalSizeBytes: 8_400_000_000,
            freeSpaceBytes: 1_200_000_000,
            files: files,
            photoCount: 8,
            sidecarCount: 2,
            physicalFileCount: 10,
            issueCount: 1
        )
    }()

    // MARK: 人物库（Persons）

    static let persons: [PersonData] = [
        person(id: "preview-person-1", name: "Mika", keywords: ["Mika", "人像"], photoCount: 42, sessions: 2),
        person(id: "preview-person-2", name: "Ren", keywords: ["Ren", "人像"], photoCount: 31, sessions: 2),
        person(id: "preview-person-3", name: "Aoi", keywords: ["Aoi"], photoCount: 18, sessions: 1),
        person(id: "preview-person-4", name: "Kai", keywords: ["Kai"], photoCount: 12, sessions: 1),
        person(id: "preview-person-5", name: "Yuki", keywords: ["Yuki"], photoCount: 7, sessions: 1),
    ]

    private static func person(
        id: String,
        name: String,
        keywords: [String],
        photoCount: Int,
        sessions: Int
    ) -> PersonData {
        PersonData(
            id: id,
            name: name,
            keywords: keywords,
            thumbnailBase64: nil,
            thumbnailPath: nil,
            notes: "",
            matchThreshold: 0.65,
            photoCount: photoCount,
            sessionCount: sessions,
            createdAt: earlierTimestamp,
            updatedAt: timestamp
        )
    }

    static func personDetail(_ id: String) -> PersonDetailData {
        let base = persons.first { $0.id == id } ?? persons[0]
        let photos = (1...6).map { index in
            PersonPhotoItem(
                photoId: "preview-person-\(base.id)-\(index)",
                sessionId: sessionOneId,
                sessionName: sessionOneName,
                filename: (personPaths[index - 1] as NSString).lastPathComponent,
                filepath: personPaths[index - 1],
                faceBbox: [0.22, 0.18, 0.3, 0.4],
                confidence: 0.9,
                thumbnailBase64: nil
            )
        }
        return PersonDetailData(
            id: base.id,
            name: base.name,
            keywords: base.keywords,
            thumbnailBase64: nil,
            thumbnailPath: nil,
            notes: "预览样例：\(base.name) 的人物档案",
            matchThreshold: base.matchThreshold,
            photoCount: base.photoCount,
            sessionCount: base.sessionCount,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt,
            photos: photos,
            totalPhotoCount: base.photoCount
        )
    }

    // MARK: 设置（Settings）

    static let settings: [String: String] = [
        "ui_language": "zh-CN",
        "face_compute_units": "auto",
        "thumbnail_size": "1024",
        "thumbnail_quality": "85",
        "thumbnail_concurrency": "4",
        "memory_cache_size": "256",
        "memory_cache_max_size_mb": "512",
        "disk_cache_dir": "/Users/preview/Library/Caches/Gather/Thumbnails",
        "disk_cache_max_size_gb": "20",
        "disk_cache_eviction_policy": "lru",
        "db_cache_size_mb": "64",
        "db_synchronous": "normal",
        "c1_timeout_ms": "15000",
        "c1_retries": "2",
        "c1_reload_delay_ms": "1200",
        "metadata_write_mode": "xmp",
        "metadata_write_debounce_ms": "300",
        "capture_one_color_compatibility": "strict",
        "detect_confidence": "0.5",
        "default_eps": "0.65",
        "default_min_samples": "2",
        "face_decode_concurrency": "4",
        "face_core_quality": "0.35",
        "face_core_retry_min_samples": "2",
        "face_match_margin": "0.01",
        "face_embedding_model_path": "",
        "face_embedding_model_version": "sface-1.0",
        "face_incremental_clustering": "1",
    ]

    static let mlStatus = MLStatusData(
        platform: "macOS",
        autoBackend: "coreml",
        autoBackendLabel: "Core ML",
        provider: "vision",
        isAuto: true,
        availableBackends: [
            MLBackendOption(value: "auto", label: "自动"),
            MLBackendOption(value: "coreml", label: "Core ML"),
            MLBackendOption(value: "onnx", label: "ONNX Runtime"),
        ],
        modelResourcesDir: "/Applications/Gather.app/Contents/Resources/Models",
        detectorModel: MLModelPresence(
            path: "face_detector.mlmodelc",
            resolvedPath: "/Applications/Gather.app/Contents/Resources/Models/face_detector.mlmodelc",
            exists: true
        ),
        encoderModel: MLModelPresence(
            path: "sface.mlmodelc",
            resolvedPath: "/Applications/Gather.app/Contents/Resources/Models/sface.mlmodelc",
            exists: true
        ),
        modelInfo: MLModelInfo(
            detectInputSize: 640,
            secondaryDetectInputSize: 320,
            previewMaxDimension: 2048,
            encoderInputSize: 112,
            embeddingDim: 128
        )
    )
}

// MARK: - 纯色缩略图（不读盘 / 不写盘）

/// 把固定纯色占位图放进进程内 PhotoThumbnailCache，命中页面真实解码路径。
///
/// 为什么不是 ImageDecoderPort：解码成功会触发 ThumbnailDiskCache.store（写盘）。
/// Preview 是只读/静态展示，占位色块已满足要求（任务书 §3 允许 SF Symbol/占位色块）。
@MainActor
enum PreviewThumbnailSeeder {
    private static var seeded = false

    static func seedOnce() {
        guard !seeded else { return }
        seeded = true
        let colors: [NSColor] = [
            .systemTeal, .systemIndigo, .systemOrange, .systemPink,
            .systemGreen, .systemBlue, .systemPurple, .systemYellow,
        ]
        for (index, path) in PreviewData.thumbnailPaths.enumerated() {
            let image = solidImage(colors[index % colors.count])
            for size in [256, 512, 1024, 2048] {
                PhotoThumbnailCache.setImage(
                    image,
                    for: PhotoThumbnailCache.key(path: path, size: size, preview: false)
                )
                PhotoThumbnailCache.setImage(
                    image,
                    for: PhotoThumbnailCache.key(path: path, size: size, preview: true)
                )
            }
            // FaceCropThumbnailView 的键不走 PhotoThumbnailCache.key（无 preview 位）。
            for size in [256, 512] {
                PhotoThumbnailCache.setImage(image, for: "facecrop:\(path)#\(size)")
            }
        }
    }

    private static func solidImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 96, height: 72), flipped: false) { rect in
            color.setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.black.withAlphaComponent(0.14).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 18, dy: 14)).fill()
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: CGRect(x: 60, y: 46, width: 10, height: 10)).fill()
            return true
        }
    }
}
#endif
