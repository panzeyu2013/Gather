// UI 对齐（§十一 11.9-1）：同进程事件总线。
// 对齐 TS 三条推送通道中的 jobs:progress：
// - 宿主启动时把 JobService.setProgressSink 接到本中心（Task 已切 MainActor）；
// - 每次 flushProgress 与终态帧（emitTerminal）都广播 NotificationCenter 通知；
// - 页面用 .onReceive 订阅，替代「打开时快照 + 手动刷新」。
// 终态判定：只看 job.status —— 终态帧的 update.message 是真实
// progressMessage/errorMessage（不再等于 status.rawValue），状态机判定
// succeeded/failed/cancelled/interrupted，不依赖 message 启发式。
import Foundation
import os
import GatherProtocol

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
public enum GatherChangeDomain: String, Sendable, CaseIterable {
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

/// 任务进度帧的来源端口（实现：GatherHost 的 JobService）。
///
/// GatherUI 只声明「接一条进度 sink」这一能力，不持有领域层的 JobService；
/// UI 事件总线与领域实现之间因此只剩一个单向注入点。
public protocol JobProgressSource: AnyObject {
    /// 注册进度/终态帧回调（实现内部替换旧 sink 的语义与 JobService 一致）。
    func connectProgressSink(
        _ sink: @escaping (AnalysisJobData, JobProgressUpdate) -> Void
    )
}

/// 领域变更事件载荷（sessionId 为 nil 表示跨会话的全局变更）。
public struct GatherApplicationChange: Sendable {
    public let domain: GatherChangeDomain
    public let sessionId: String?
    /// 发布者标识：监听方跳过自己发出的变更，避免自触发重查（如人物页
    /// 写路径广播又被自己的监听器收到）。
    public let origin: String?
    /// 进程内单调序号（按域递增，R4）：监听方据此丢弃过期/重复事件。
    /// 0 表示“未编号”（仅测试或兼容构造）。
    public let revision: UInt64

    public init(
        domain: GatherChangeDomain,
        sessionId: String? = nil,
        origin: String? = nil,
        revision: UInt64 = 0
    ) {
        self.domain = domain
        self.sessionId = sessionId
        self.origin = origin
        self.revision = revision
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
    /// 写路径领域变更（GatherApplicationChange 载荷）：常驻页按域刷新。
    public static let domainChanged = Notification.Name("gather.events.domain-changed")

    public private(set) var wired = false

    private init() {}

    /// 测试接缝（@testable 专用）：直接注入一帧进度/终态帧，走与
    /// JobService progressSink 相同的 emit 路径（含终态转移判定）。
    internal func post(job: AnalysisJobData, update: JobProgressUpdate) {
        emit(job: job, update: update)
    }

    /// 最近一次接线的 JobService 身份（第三轮审计 F：wire 曾是一次性的）。
    ///
    /// 旧实现 `guard !wired else { return }`：bootstrap 失败后重试会拿到**新的**
    /// JobService，但 sink 已经挂在旧实例上 → 进度/终态事件从此静默消失
    /// （界面看起来「任务卡住不动」）。改为「同一实例重复调用是 no-op，
    /// 换了实例则重新接线」。
    private var wiredJobService: ObjectIdentifier?

    /// 宿主启动装配调用：接任务进度/终态帧。可重复调用（幂等，按实例）。
    ///
    /// Cut 3 / 3b-3（E-19 #1）：参数从 GatherDomain 的 JobService 改为本文件
    /// 的端口协议 —— GatherUI 不 import 领域层；GatherHost 让 JobService
    /// 以 extension 实现该端口，进度帧的接线点仍然只有宿主启动这一处。
    public func wire(jobEvents source: any JobProgressSource) {
        let identity = ObjectIdentifier(source)
        guard wiredJobService != identity else { return }
        wiredJobService = identity
        wired = true
        source.connectProgressSink { [weak self] job, update in
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
    ///
    /// R4：每次广播按域分配单调 revision；监听方（DomainChangeGate）丢弃
    /// revision 不新于已应用值的事件，避免重复投递/乱序投递造成二次重查。
    public static func postDomainChange(
        _ domain: GatherChangeDomain,
        sessionId: String? = nil,
        origin: String? = nil
    ) {
        let revision = Self.revisions.withLock { state -> UInt64 in
            let value = (state[domain] ?? 0) + 1
            state[domain] = value
            return value
        }
        NotificationCenter.default.post(
            name: domainChanged,
            object: GatherApplicationChange(
                domain: domain, sessionId: sessionId, origin: origin, revision: revision
            )
        )
    }

    /// 某域最近一次广播的 revision（0 = 尚未广播）。VM/页面可用于“落后”判定。
    public nonisolated static func currentRevision(_ domain: GatherChangeDomain) -> UInt64 {
        revisions.withLock { $0[domain] ?? 0 }
    }

    /// 测试接缝：清空进程内序号（@testable 专用；生产不调用）。
    nonisolated static func resetRevisionsForTesting() {
        revisions.withLock { $0.removeAll() }
    }

    /// 进程内按域序号（OSAllocatedUnfairLock 是 Sendable，无需 @unchecked）。
    nonisolated private static let revisions =
        OSAllocatedUnfairLock<[GatherChangeDomain: UInt64]>(initialState: [:])

    private func emit(job: AnalysisJobData, update: JobProgressUpdate) {
        let event = GatherJobEvent(job: job, update: update)
        NotificationCenter.default.post(name: Self.jobProgress, object: event)
        if event.isTerminal {
            NotificationCenter.default.post(name: Self.jobTerminal, object: event)
        }
    }
}
