// desktop/native/gather-app/Sources/GatherUI/Support/LiveSyncPorts.swift
// Cut 3 / 3b-3（E-18）：同步能力端口。
//
// 背景：LibraryDataProvider / DashboardDataProvider 是**同步**协议（View 与
// 既有测试共用），而 Session/Album/Asset/Job 的 async API 在同步上下文里既不能
// 阻塞等待（MainActor 死锁）也不能删。3b-0 前 UI 直接 `as? Live*API` 下转
// GatherHost 的实现类，拆 target 后不可再引用。
//
// 因此把「同步核」抽成 UI 侧端口，Host 的 Live API 以 extension 实现：
//   · 调用点只把 `as? LiveXxxAPI` 换成 `as? any XxxSyncAPI`；
//   · 方法名加 Sync 后缀/前缀，避免与 Live 实现的 internal 同名方法冲突；
//   · 未注入时的显式失败语义（*_NOT_SUPPORTED）保持不变。
//
// 端口归属（3b-4 收口）：保持 UI-owned。D-014 的硬约束是 UI 不得直接依赖
// GatherAnalysis；这些同步端口只承载页面消费的同步核，Host 以 extension 实现，
// UI 仅 import GatherProtocol + Foundation，已满足边界。上移 GatherProtocol
// 会把 app 专属的 Live 适配器语义带进 core 公共面，收益不足，故不搬。
import Foundation
import GatherProtocol

/// 会话同步核（LiveSessionAPI 实现）。
public protocol SessionSyncAPI: Sendable {
    func listSessionsSync() throws -> [SessionData]
    func createSessionSync(_ input: SessionCreateInput) throws -> SessionCreateResult
    func deleteSessionsSync(_ input: Confirmed<SessionDeleteInput>) throws
    func workspaceStatusSync(_ sessionId: String) throws -> WorkspaceStatus?
}

/// 相册同步核（LiveAlbumAPI 实现）。
public protocol AlbumSyncAPI: Sendable {
    func listAlbumsSync() throws -> [SmartAlbumData]
    func createAlbumSync(_ input: AlbumCreateParams) throws -> SmartAlbumDetailData
    func updateAlbumSync(_ input: AlbumUpdateParams) throws
    func deleteAlbumSync(_ albumId: String) throws
}

/// 资产/离线卷同步核（LiveAssetAPI 实现）。
public protocol AssetSyncAPI: Sendable {
    func assetCandidatesSync(_ sessionId: String?) throws -> [AssetLinkCandidateData]
    func assetVolumesSync() throws -> [AssetVolumeData]
    func acceptCandidateSync(_ candidateId: String) throws -> Bool
    func rejectCandidateSync(_ candidateId: String) throws -> Bool
    func assetRelinkRootSync(oldRoot: String, newRoot: String) throws -> Int
}

/// 任务同步核（LiveJobAPI 实现）。
public protocol JobSyncAPI: Sendable {
    func listJobsSync(_ filter: JobListFilter) throws -> [AnalysisJobData]
    func cancelJobSync(_ jobId: String) throws -> Bool
    func retryJobSync(_ jobId: String) throws -> Bool
    func clearCompletedJobsSync() throws -> Int
    func startJobSync(_ request: JobCreateParams) throws -> AnalysisJobData
}

/// 任务取消标记端口（E-19 相邻）：UI 需要把「任务被取消」与真实失败区分
/// （取消是正常终态，不落红色错误条）。实现：GatherHost 为 Domain 的
/// JobCancelledError 提供空 conformance。
public protocol JobCancellationMarker {}

/// 域错误原文端口（E-19 相邻修复）：UI 的 rawMessage 曾 `as?` Domain 的
/// JobServiceError / FaceKwServiceError 取原始文案；拆 target 后改由 Host
/// 以 extension 暴露同一语义（Live API 已优先收敛为 GatherError，这里只是
/// 兜底分支，不改变正常路径）。
public protocol DomainErrorMessaging {
    /// 可展示的原始错误文案；nil = 该错误没有更具体的原文。
    var rawErrorMessage: String? { get }
}
