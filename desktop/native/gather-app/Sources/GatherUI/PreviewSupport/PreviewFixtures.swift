#if DEBUG
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

// 末轮收尾（final-sweep）：原 964 行 DEBUG fixture 按页面纯移动到 PreviewFixtures+*.swift；
// 本文件只保留共享常量 / 会话 / 工作区 / 任务，成员文本与顺序不变（无行为变化）。

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
}
#endif
