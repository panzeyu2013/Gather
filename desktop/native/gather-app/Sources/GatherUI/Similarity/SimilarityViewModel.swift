// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityViewModel.swift
// Phase 3.3 Similarity（相似度分析）：视图模型（服务可注入，同进程直连路由）。
// TS 源: desktop/src/renderer/pages/Similarity/index.tsx（AnalysisPanel 分析流程/
//       阈值档切换/预设/KeywordWritebackPanel）+ stores/similarityStore.ts（阈值/
//       组大小/分组模式/isAnalyzing 草稿语义）+ api/similarity.ts（sim.* 命令形状）
//       + utils/c1-sync-controls.ts（三按钮状态机门控，2.3.5 P1）
//
// 差异说明（有意）：
// - TS 的 jobs:progress 推送 → 分析期间轮询 jobs.list（1s，测试可注入），
//   进度相位经 progressPhaseLabel 映射中文（progress.* 键值）；
// - 挂载恢复（重启后残留 running 任务）经轮询首帧识别并续传进度；
// - 关键词写回面板复用 sim.preview_writeback/sim.writeback 的预览、确认、
//   C1 reload ack 和失败重试链，选择集合仍对齐 onResultAdopted 清空语义；
// - TS 的「重新加载并确认」拆成两步（loadMetadata → confirmSync），按钮可用性
//   经 c1-sync-controls.ts 的 deriveSyncControls 移植实现；
// - 同步状态视图（TS captureOneApi.syncState）无现成路由命令，改经
//   sim.writeback_items 统计模块 outbox 行推导；reload ack（sessions.reload_acked_at）
//   路由侧不可读，以本地标记近似（reloadMetadata 成功置位、新写回活动复位，
//   与 DB clearReloadAck 语义一致），服务端 requireReloadAck 仍兜底。
//
// Cut 1 / B4b：ViewModel 的领域依赖迁移到 any SimilarityAPI（10 个方法）+
// any JobAPI（进度轮询只消费 jobs.list）；不再由本类型直接发 sim.* 命令。
// - 破坏性入口 writeback/retry/cleanup 只构造 Confirmed<T>(source: .userDialog)；
// - 错误统一以 CommandError（码/参数/诊断）落地，文案在 View 渲染期经 L10n 解析；
// - refreshSyncState() 保留同步签名（SimilarityView 的同步事件回调调用），
//   内部调度异步 writebackItems；load()/写回动作则 await 同一实现；
// - B8.4：旧 provider 构造器与适配器已删除，生产 RootView 只注入
//   AppServices.similarity + AppServices.job。
//
// Cut 4 / 4c-2h：1021 行 -> 5 文件（行为不变）。本文件只放：
// 类型（同步视图 / 三按钮门控 / 写回提示）+ 全部存储状态 + 装配 init +
// 结果参数指纹 + 可见性 / 关闭。行为按域拆到四个 extension：
//   +Load（加载与恢复 / 两路轮询）/ +Analysis（参数 / 分析 / 重聚类 / 采纳 / 选择）/
//   +Writeback（预览 / 写回 / 重试 / 确认同步 / 清理）/ +Sync（同步状态机与门控）。
// 跨文件 extension 需要写回的属性 setter 由 private(set) 放宽为 internal(set)，
// 声明、默认值、注释与文案逐字未动——行为不变。
import Foundation
import GatherProtocol

/// 同步状态视图（TS C1SyncStateView 的模块级近似：state + written 计数）。
/// reload ack 路由侧不可读，由 SimilarityViewModel 本地标记提供。
public struct SimilaritySyncView: Equatable {
    /// TS: state（CaptureOneSyncState 枚举；nil 表示尚未加载）。
    public let state: CaptureOneSyncState?
    /// TS: xmp.written —— 已写入、C1 未确认的行数。
    public let written: Int

    public init(state: CaptureOneSyncState?, written: Int) {
        self.state = state
        self.written = written
    }
}

/// 三按钮状态机门控 + 禁用提示 + 状态文案（TS utils/c1-sync-controls.ts 移植）。
///
/// Cut 4 / 4b-2c：提示与状态文案只存 key（LocalizedText），渲染期由页面的
/// l10n 解析——VM 不再读进程级语言，切语言后已渲染的页面直接换文案。
public struct SimilaritySyncControls: Equatable {
    public let canLoadMetadata: Bool
    public let canConfirmSync: Bool
    public let canCleanup: Bool
    public let loadHint: LocalizedText?
    public let confirmHint: LocalizedText?
    public let cleanupHint: LocalizedText?
    /// TS: syncStatusCopy（按钮旁状态文案）。
    public let statusText: LocalizedText

    public init(
        canLoadMetadata: Bool,
        canConfirmSync: Bool,
        canCleanup: Bool,
        loadHint: LocalizedText?,
        confirmHint: LocalizedText?,
        cleanupHint: LocalizedText?,
        statusText: LocalizedText
    ) {
        self.canLoadMetadata = canLoadMetadata
        self.canConfirmSync = canConfirmSync
        self.canCleanup = canCleanup
        self.loadHint = loadHint
        self.confirmHint = confirmHint
        self.cleanupHint = cleanupHint
        self.statusText = statusText
    }
}

/// 写回面板提示（Cut 4 / 4b-2c）：只存 key + 参数，渲染期由页面的 l10n 解析。
///
/// 为什么不是单个 LocalizedText：取消文案要把「动作名」本身也作为延迟文案
/// 嵌进模板（已取消“%@”，未执行任何更改）。若在事件点先把动作名解析成当前
/// 语言的字符串再当参数，切语言后就会留下旧语言的片段；cancelled 分支在
/// 渲染期把动作名与模板一起解析。
public struct SimilarityNotice: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case text(LocalizedText)
        case cancelled(LocalizedText)
    }

    let payload: Payload

    public init(_ key: String, params: [String] = []) {
        payload = .text(LocalizedText(key, params: params))
    }

    public init(_ text: LocalizedText) {
        payload = .text(text)
    }

    public init(cancelled action: LocalizedText) {
        payload = .cancelled(action)
    }

    /// 渲染期解析（与 L10n.resolve 同源；未知 key 原样透传）。
    public func resolve(with l10n: L10n) -> String {
        switch payload {
        case .text(let text):
            return l10n.resolve(text)
        case .cancelled(let action):
            return l10n.format("已取消“%@”，未执行任何更改", l10n.resolve(action))
        }
    }
}

/// 相似度视图模型：分析控制（阈值/组大小/分组模式/预设）+ 运行状态机
/// （idle/running/result/error）+ 阈值档切换 + 分组选择 + 关键词写回
/// （预览/写回/重试/loadMetadata→confirmSync→cleanup 状态机）。
@MainActor
@Observable
public final class SimilarityViewModel: PageVisibility {
    /// 页面级状态（TS 由 result/isLoading/error + isAnalyzing 组合表达）。
    ///
    /// Cut 4 / 4a-3b-2a：`error` 的关联值从码值字符串改为 `CommandError`。
    /// Cut 4 / 4c-3：页级错误只存这里——`errorMessage` 不再是存储属性，
    /// 而是 `phase.error`（优先）/ `actionError` 的只读代理；文案仍在渲染期
    /// 由 L10n/CommandErrorText 解析。
    public enum Phase: Equatable {
        case idle
        case running
        case result
        case error(CommandError)
    }

    /// TS: similarityStore.ts 初始值。
    public static let defaultThreshold = 10
    public static let defaultMinGroupSize = 2
    /// TS: AnalysisPanel 预设。
    public static let presets: [(name: String, threshold: Int, minGroupSize: Int)] = [
        ("strict", 6, 2),
        ("balanced", 10, 2),
        ("loose", 16, 3),
    ]
    /// TS: KeywordWritebackPanel 预览明细上限。
    public static let previewItemLimit = 50

    /// 活跃任务消失（clearCompleted/去重替换）时连续空轮上限：进度轮询
    /// 在此轮数内未再见到活跃任务即退出，防止循环永不结束（审计 5）。
    /// 查询失败同样以连续失败轮数计，单次失败不计入空闲轮数（审计 8）。
    /// 进度轮询间隔 1s、结果轮询间隔 2s → 分别约 30s / 60s 兜底。
    static let maxIdleProgressPollRounds = 30

    public let sessionId: String
    // Cut 1 / B4b：相似度域与任务列表依赖（后者只用于进度轮询/挂载恢复）。
    let similarity: any SimilarityAPI
    let jobs: any JobAPI
    let pollInterval: Duration
    /// 结果轮询间隔（TS useQuery refetchInterval = 2s；可注入以便生命周期单测）。
    let resultPollInterval: Duration
    /// TS: 阈值档切换防抖（300ms）。
    let tierDebounceDelay: Duration
    var pollTask: Task<Void, Never>?
    var resultPollTask: Task<Void, Never>?
    var analysisTask: Task<Void, Never>?
    var tierTask: Task<Void, Never>?
    /// refreshSyncState() 调度的异步查询（shutdown 时取消）。
    var syncStateTask: Task<Void, Never>?
    /// 可见性真相（WP4d：默认不可见；首次 onAppear 经 setPageVisible 置 true，
    /// 不再兼容 RootView 直接 start/stop 的旧"默认可见"路径）。
    private(set) var isVisible = false
    /// 关闭终态：shutdown() 之后 setVisible(true) 明确 no-op。
    /// 4a-2c：对外只读，供 SessionWorkspace.close 的扇出测试断言。
    public private(set) var isShutdown = false
    var tierRequestID = 0
    /// 结果代：每次 adoptResult 自增；recluster/analyze 完成时若检测到
    /// await 期间已有更新代（事件驱动刷新）被采纳，则放弃旧代（对齐
    /// tierRequestID 防过期模式，审计 3）。
    var resultRequestID = 0
    /// 同步状态视图的 latest-wins 代数：refreshSyncState() 现在调度异步查询，
    /// 通知风暴下旧响应不得覆盖新状态。
    var syncStateRequestID = 0
    /// Cut 3 / 3b-3（E-17）：只持 Protocol 能力面（CaptureOneBridging）。
    let captureOne: any CaptureOneBridging

    public internal(set) var phase: Phase = .idle
    public internal(set) var result: SimilarityResult?
    public internal(set) var isAnalyzing = false
    public internal(set) var isReclustering = false
    public internal(set) var isCanceling = false
    public internal(set) var isLoading = false
    /// 操作级错误（分析/写回/同步查询等，不改变页面状态）。
    ///
    /// Cut 4 / 4c-3：原先 `errorMessage` 与 `phase.error` 各存一份同一
    /// `CommandError`，load/轮询失败要双写。现在页级错误只写 `phase`，
    /// 操作级错误只写这里；`errorMessage` 退化为只读代理，不再有第二份存储。
    var actionError: CommandError?
    /// 错误渲染入口（只读）：页级 `phase.error` 优先，其次操作级 `actionError`。
    /// 保留原属性名/类型，View 与既有测试无需改调用形态。
    public var errorMessage: CommandError? {
        if case .error(let error) = phase { return error }
        return actionError
    }
    public internal(set) var progressCurrent = 0
    public internal(set) var progressTotal = 0
    public internal(set) var progressMessage = ""
    public internal(set) var selectedGroupIds: Set<Int> = []
    public internal(set) var writebackPreview: WritebackPreview?
    public internal(set) var writebackResult: WritebackResult?
    public internal(set) var isSyncBusy = false
    /// TS: KeywordWritebackPanel 的 message（面板状态文案）。
    ///
    /// Cut 4 / 4b-2c：LocalizedText? -> SimilarityNotice?（取消文案要把动作名
    /// 本身也作为延迟文案嵌入）；渲染期由页面解析，VM 不存格式化串。
    public internal(set) var notice: SimilarityNotice?
    /// TS: syncView（C1SyncStateView；nil = 尚未加载 → 保守全禁用）。
    public internal(set) var syncView: SimilaritySyncView?
    /// reload ack 本地近似：reloadMetadata 成功后置位，新写回活动复位
    /// （对齐 DB clearReloadAck：新写入使会话 reload-ack 失效）。
    public internal(set) var reloadAcked = false
    public var writebackKeywords = ""
    /// 草稿参数（TS similarityStore：阈值/组大小/分组模式）。
    public var threshold = SimilarityViewModel.defaultThreshold
    public var minGroupSize = SimilarityViewModel.defaultMinGroupSize
    public var groupingMode: SimilarityGroupingMode = .global

    // MARK: 浏览状态（C-1 审计 5）

    /// 分组展开 / 「显示全部成员」状态。
    ///
    /// 审计 5 C-1：这两个集合原先在视图里是 @State，而页面按目的地**条件构建**
    /// （离开即销毁）——VM 的结果跨页签保留了，展开态却每次回到页面都被清空，
    /// 文档此前声称的「返回保留浏览位置」名不副实。搬进 VM 才真的跨页签保留。
    public var expandedGroupIds: Set<Int> = []
    public var showAllMemberGroupIds: Set<Int> = []

    /// 产出当前 result 的参数指纹（B-2 审计 5）：「最小组合 / 分组范围 / 阈值」
    /// 改动后结果不再代表当前参数，必须显式标记过期——重复页已有同型范式
    /// （scannedThreshold / isScanResultStale）。
    public internal(set) var resultParams: SimilarityResultParams?

    public struct SimilarityResultParams: Equatable, Sendable {
        public var threshold: Int
        public var minGroupSize: Int
        public var groupingMode: SimilarityGroupingMode

        public init(threshold: Int, minGroupSize: Int, groupingMode: SimilarityGroupingMode) {
            self.threshold = threshold
            self.minGroupSize = minGroupSize
            self.groupingMode = groupingMode
        }
    }

    /// 当前参数与产出结果的参数是否一致（false = 屏幕上的分组来自旧参数）。
    public var isResultStale: Bool {
        guard let resultParams else { return false }
        return resultParams != SimilarityResultParams(
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode
        )
    }

    /// 生产装配（RootView）：相似度域走 AppServices.similarity，进度轮询走
    /// AppServices.job；captureOne 必传（组合根注入，reload ack 写唯一
    /// AppRuntime）。E-17：删除默认自建 CaptureOneBridge() 的兜底。
    public init(
        sessionId: String,
        similarity: any SimilarityAPI,
        jobs: any JobAPI,
        pollInterval: Duration = .seconds(1),
        resultPollInterval: Duration = .seconds(2),
        tierDebounceDelay: Duration = .milliseconds(300),
        captureOne: any CaptureOneBridging
    ) {
        self.sessionId = sessionId
        self.similarity = similarity
        self.jobs = jobs
        self.pollInterval = pollInterval
        self.resultPollInterval = resultPollInterval
        self.tierDebounceDelay = tierDebounceDelay
        self.captureOne = captureOne
    }

    // MARK: - 可见性 / 关闭（Cut 4 / 4a-2b）

    /// 可见性唯一入口（PageVisibility）：View 的 onAppear/onDisappear 只调这里。
    /// - 幂等：与当前状态相同直接返回（不重复启动两路轮询）；
    /// - visible=false：停两路轮询（进度/结果），隐藏期不发命令；
    /// - visible=true：按当前状态恢复——分析中恢复进度轮询，无结果恢复结果轮询；
    /// - 代次守卫（resultRequestID/tierRequestID）与轮询内的空闲上限保持原样。
    public func setVisible(_ visible: Bool) {
        guard !isShutdown, transitionVisibility(&isVisible, to: visible) else { return }
        if visible {
            if isAnalyzing { startProgressPolling() }
            if result == nil { startResultPolling() }
        } else {
            stopProgressPolling()
            stopResultPolling()
        }
    }

    /// 关闭：取消本 VM 持有的全部 Task（两路轮询 / 分析 / 阈值防抖 / 同步态查询）。
    /// 关闭后 setVisible(true) 不重启，避免 workspace 淘汰后继续查任务/结果。
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        isVisible = false
        pollTask?.cancel()
        pollTask = nil
        resultPollTask?.cancel()
        resultPollTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        tierTask?.cancel()
        tierTask = nil
        syncStateTask?.cancel()
        syncStateTask = nil
    }

    // Cut 4 / 4a-3b-1：删除 VM 内的文案漏斗——错误只以 CommandError 落地，
    // 文案统一在 SimilarityView 渲染期经 L10n 解析（原始诊断只进日志）。
    // Cut 4 / 4c-3：错误落地也只有一个来源——页级失败写 phase.error，操作级
    // 失败写 actionError；errorMessage 只读代理，不再与 phase 双写。
}
