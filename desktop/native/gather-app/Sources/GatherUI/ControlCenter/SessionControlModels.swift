// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlModels.swift
// Cut 4 / 4c-2e：控制中心纯模型（Action Inbox / 推荐下一步 / 索引头文案），
// 从 SessionControlView.swift 319-381 行原样搬出。
// internal（非 private）：InboxItemsTests / IndexHeaderCopyTests 直测这些类型。

import GatherProtocol

// MARK: - Action Inbox 模型（对齐 workspace-view.ts InboxItem / InboxKind）
// internal（非 private）：InboxItemsTests 直测 deriveInboxItems 优先级。

enum InboxKind: Equatable {
    case scanIncomplete
    case xmpConflict
    case analysisStale
    case xmpPending
    case offlinePhotos
    case jobFailed
    case exportPending
}

enum InboxAction: Equatable {
    case none
    case showStages
    /// D10：进入挑片并只看 XMP 冲突（待办指向的是「某类问题」，不是「某个页面」）。
    case reviewXmpConflicts
    /// D10：进入图库并只看离线照片。
    case reviewOfflinePhotos
    /// D10：进入人脸页并直达分析步骤（分析已过期）。
    case reviewStaleAnalysis
    case navigateTab(SessionTab)
    case navigateSimilarity
    case navigateGallery
    case retryJob(String)
    case retryFailedJobs
}

struct InboxItem: Identifiable, Equatable {
    let id: String
    let kind: InboxKind
    let label: String
    let detail: String?
    let actionLabel: String
    let action: InboxAction
}

// MARK: - 推荐下一步模型（对齐 workspace-view.ts RecommendedNextView）

struct RecommendedNextView {
    let title: String
    let detail: String
    let actionLabel: String
    let action: InboxAction?
}

// MARK: - 头部索引文案模型（对齐 indexProgress.ts IndexHeaderCopy）

/// 索引进度头文案模式（internal：IndexProgressTests 直测纯推导）。
enum IndexHeaderMode: Equatable {
    case scanning
    case error
    case count
}

struct IndexHeaderCopy: Equatable {
    let mode: IndexHeaderMode
    let text: String
    let percent: Double?
    let done: Int
    let total: Int
}
