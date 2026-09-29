// UI 对齐（§十一 11.9-1）：同进程事件总线。
// 对齐 TS 三条推送通道中的 jobs:progress：
// - 宿主启动时把 JobService.setProgressSink 接到本中心（Task 已切 MainActor）；
// - 每次 flushProgress 与终态帧（emitTerminal）都广播 NotificationCenter 通知；
// - 页面用 .onReceive 订阅，替代「打开时快照 + 手动刷新」。
// 终态判定：只看 job.status —— 终态帧的 update.message 是真实
// progressMessage/errorMessage（不再等于 status.rawValue），状态机判定
// succeeded/failed/cancelled/interrupted，不依赖 message 启发式。
import Foundation
import GatherCore

/// Swift 6 迁移：不可变事件载荷 —— 两个存储属性均为 let，且
/// AnalysisJobData / JobProgressUpdate 在 gather-core 中已声明 Sendable，
/// 故直接声明 Sendable（跨隔离域经 NotificationCenter 投递/测试观察者闭包捕获均安全）。
public struct GatherJobEvent: Sendable {
    public let job: AnalysisJobData
    public let update: JobProgressUpdate

    public var isTerminal: Bool {
        [.succeeded, .failed, .cancelled, .interrupted].contains(job.status)
    }
}

/// 写路径影响的领域：常驻页只刷新事件命中的域，不整树重建、不全量重查。
public enum GatherDomain: String, Sendable, CaseIterable {
    /// 人物增删改 / 人脸绑定变化（person.*、fkw.bind/unbind）。
    case persons
    /// 重复组处置（dup.resolve / dup.resolve_member）。
    case duplicates
    /// 人脸簇结构变化（绑定/解绑/成员修订/合并）。
    case faceKeywording
    /// 相似度写回以外的人脸/相似度窗口无需细分，统一由调用方选择语义域。
    case similarity
    /// XMP 写回与同步队列（culling/sim/fkw 写回族；设置页/C1 胶囊/控制中心消费）。
    case metadata
    /// 挑片决策/状态变更（Culling 写路径；图库/画廊的星级与色标消费）。
    case culling
    /// 图库资产/相册/离线卷等库级变更（Library 写路径；图库/画廊消费）。
    case library
    // 注：不设 .settings —— 设置写入无常驻页消费者（页面在重新可见/加载时
    // 自行读取最新设置值），没有消费者的域不进枚举。
}

/// 领域变更事件载荷（sessionId 为 nil 表示跨会话的全局变更）。
public struct GatherDomainChange: Sendable {
    public let domain: GatherDomain
    public let sessionId: String?
    /// 发布者标识：监听方跳过自己发出的变更，避免自触发重查（如人物页
    /// 写路径广播又被自己的监听器收到）。
    public let origin: String?

    public init(domain: GatherDomain, sessionId: String? = nil, origin: String? = nil) {
        self.domain = domain
        self.sessionId = sessionId
        self.origin = origin
    }

    /// 事件是否命中该会话（全局事件命中所有会话）。
    public func matches(sessionId: String) -> Bool {
        self.sessionId == nil || self.sessionId == sessionId
    }
}

@MainActor
@Observable
public final class GatherEventCenter {
    public static let shared = GatherEventCenter()

    public static let jobProgress = Notification.Name("gather.events.job-progress")
    public static let jobTerminal = Notification.Name("gather.events.job-terminal")
    public static let c1SyncStatus = Notification.Name("gather.events.c1-sync-status")
    /// 写路径领域变更（GatherDomainChange 载荷）：常驻页按域刷新。
    public static let domainChanged = Notification.Name("gather.events.domain-changed")

    public private(set) var wired = false

    private init() {}

    /// 测试接缝（@testable 专用）：直接注入一帧进度/终态帧，走与
    /// JobService progressSink 相同的 emit 路径（含终态转移判定）。
    internal func post(job: AnalysisJobData, update: JobProgressUpdate) {
        emit(job: job, update: update)
    }

    /// 宿主启动装配调用一次：接 JobService 进度/终态帧。
    public func wire(jobService: JobService) {
        guard !wired else { return }
        wired = true
        jobService.setProgressSink { [weak self] job, update in
            Task { @MainActor in
                self?.emit(job: job, update: update)
            }
        }
    }

    /// Capture One 写回协调器 emitSummary 后的状态变化提示（页面拉取视图）。
    public func postC1SyncStatusChange(sessionId: String) {
        NotificationCenter.default.post(name: Self.c1SyncStatus, object: sessionId)
    }

    /// 写路径完成后广播受影响的域（同步方法，VMs 均在 MainActor 上调用）。
    /// 页面侧只按域刷新自己的数据源，不做整树重建/全量重查。
    public static func postDomainChange(
        _ domain: GatherDomain,
        sessionId: String? = nil,
        origin: String? = nil
    ) {
        NotificationCenter.default.post(
            name: domainChanged,
            object: GatherDomainChange(domain: domain, sessionId: sessionId, origin: origin)
        )
    }

    private func emit(job: AnalysisJobData, update: JobProgressUpdate) {
        let event = GatherJobEvent(job: job, update: update)
        NotificationCenter.default.post(name: Self.jobProgress, object: event)
        if event.isTerminal {
            NotificationCenter.default.post(name: Self.jobTerminal, object: event)
        }
    }
}
