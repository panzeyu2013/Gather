// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceKeywordingViewModel.swift
// Cut 4 / 4c-2b：从 FaceKeywordingView.swift 第 48-333、720-753 行移出（VM 主体：
// 类型/状态/依赖/派生/加载/首屏落点/挂载恢复）。分析 -> +Analysis，
// 审核动作 -> +Review，写回/同步 -> +Writeback。
//
// 跨文件 extension 只能访问 internal 成员：原 private 依赖/可写状态改为 internal
// （可写状态用 `public internal(set)` 保留只读对外语义）；构造函数与公开 API 不变。
import Combine
import SwiftUI
import GatherProtocol

@MainActor
@Observable
public final class FaceKeywordingViewModel: PageVisibility {
    /// TS AnalysisStatus：idle/running/done/failed/cancelled。
    public enum AnalysisPhase: Equatable {
        case idle
        case running
        case done
        case failed
        case cancelled
    }

    /// TS faceKwStore Step：'analyze' | 'review' | 'writeback'。
    public enum Step: String, Equatable {
        case analyze
        case review
        case writeback
    }

    public struct Preset: Equatable, Identifiable {
        public let name: String
        /// Cut 4 / 4b-2b：只存 key，渲染期由 View 的 l10n 解析（静态表不再固化语言）。
        public let title: LocalizedText
        public let eps: Double
        public let minSamples: Int
        public var id: String { name }
    }

    /// TS StepAnalyze applyPreset：strict 0.72/3、balanced 0.65/3、loose 0.5/2。
    public static let presets: [Preset] = [
        Preset(name: "strict", title: LocalizedText("严格"), eps: 0.72, minSamples: 3),
        Preset(name: "balanced", title: LocalizedText("均衡"), eps: 0.65, minSamples: 3),
        Preset(name: "loose", title: LocalizedText("宽松"), eps: 0.5, minSamples: 2),
    ]
    /// TS StepReview CLUSTER_PAGE_SIZE。
    public static let clusterPageSize = 100

    // Cut 1 / B4b：人脸域与任务列表依赖（后者只用于恢复进行中的分析 job）。
    let face: any FaceAPI
    private let jobs: any JobAPI
    /// Cut 3 / 3b-3（E-17）：只持 Protocol 能力面（CaptureOneBridging）。
    let captureOne: any CaptureOneBridging
    /// 异步 reload 的 latest-wins 代数：旧实现 load() 是主线程同步的，
    /// 迁移到 async FaceAPI 后拖动刷新/操作回流可能重叠，旧请求不得覆盖新结果。
    private var reloadGeneration = 0
    public let sessionId: String
    private(set) public var clusters: [FaceClusterData] = []
    public internal(set) var analysisResult: FaceAnalysisResult?
    public internal(set) var preview: WritebackPreview?
    public internal(set) var writebackResult: WritebackResult?
    /// 初始为 true：首帧即渲染加载态，避免 load() 完成前误显空态。
    private(set) public var isLoading = true
    public internal(set) var isWritingBack = false
    public internal(set) var errorMessage: CommandError?
    /// 分析错误原文（tooltip）：仅当 errorMessage 回落通用文案（英文散文等不可读
    /// 诊断）时非空；中文可读原因/错误码已直接上屏，不再重复。
    public internal(set) var errorDetail: LocalizedText?
    public internal(set) var notice: FaceNotice?
    public internal(set) var analysisPhase: AnalysisPhase = .idle
    public internal(set) var progressCurrent = 0
    public internal(set) var progressTotal = 0
    public internal(set) var progressPhase = "face.detecting"
    private(set) public var modelsMissing = false
    /// 部分失败可见警示：status == "done" 但 encodingFailures > 0（有脸没编码成功，
    /// 下次分析自动重试）——不得显示成"一切正常"（对抗审查新增高风险）。
    public internal(set) var encodingFailureWarning: LocalizedText?
    public internal(set) var isSyncConfirmed = false
    /// 分析 succeeded 快照：0 簇时也保持已完成，仅首屏无分析历史才回退 idle。
    private var analysisSucceeded = false
    /// 可见性门控（Cut 4 / 4a-2c）：人脸页没有自持轮询，钩子只落状态，
    /// 供 SessionWorkspace.setVisible 统一扇出。
    /// WP4d：默认不可见（PageVisibility 契约），只读给生命周期矩阵断言。
    private(set) var isVisible = false
    /// 关闭终态（SessionWorkspace.close 扇出）。
    public private(set) var isShutdown = false
    /// TS faceKwStore step：向导当前步骤。
    public var step: Step = .analyze
    public var roleName = ""
    public var keywords = ""
    public var eps = 0.65
    public var minSamples = 3
    /// TS StepReview mergeTargetId：合并目标簇下拉（自由文本输入改为下拉选择）。
    public var mergeTargetId: Int?
    public private(set) var selectedClusterId: Int?
    /// TS StepReview roleFilter（URL searchParam `role`）：审核步骤角色过滤；
    /// 由 initialRoleFilter 深链播种（Persons 页「前往人脸审核」），
    /// 也可在页面内通过角色胶囊切换/清除。
    public var roleFilter: String?
    /// TS 深链（?role=）：Persons 页传入时播种 roleFilter 并在分析已完成时
    /// 直接进入审核步骤；默认 nil 不影响现有调用方。
    public let initialRoleFilter: String?
    /// 深链播种只执行一次：后续 load()（分析完成/操作刷新）不再强制跳步骤，
    /// 避免用户在写回步骤时被拉回审核。
    private var initialRoleSeeded = false
    /// F10 首屏落点只播种一次（后续 load 不打断用户当前步骤）。
    private var initialStepSeeded = false
    /// TS StepReview actionError：审核步骤动作（绑定/移除/解除/合并）的内联
    /// 错误文案（旧版详情栏内联错误块，StepReview.tsx:216-218）。
    public internal(set) var reviewActionError: CommandError?

    // MARK: - P0 / F0：复核与拆分（成员级）
    /// 当前复核页的成员（按选中簇 / includeResolved 过滤）。
    public internal(set) var reviewItems: [FaceReviewItem] = []
    /// 全部簇的复核概要（卡片角标用）。
    public internal(set) var reviewSummaries: [FaceReviewClusterSummary] = []
    public internal(set) var reviewNextCursor: Int?
    public internal(set) var reviewTotal = 0
    public internal(set) var reviewSuspectTotal = 0
    public internal(set) var selectedMemberIds: Set<Int> = []
    public internal(set) var isSplitting = false
    public internal(set) var isLoadingReview = false
    /// 默认只看待复核成员；关闭后显示全部成员（includeResolved=true）。
    public var includeOnlyReviewMembers = true
    /// latest-wins：切换簇/刷新时旧复核请求不得覆盖新结果。
    var reviewGeneration = 0

    /// 生产装配（RootView）：人脸域走 AppServices.face，jobs.list 走
    /// AppServices.job；captureOne 由组合根构造（reload ack 写唯一 AppRuntime）。
    /// B8.4 起这是唯一构造器（字符串命令构造器已删除）。
    public init(
        sessionId: String,
        face: any FaceAPI,
        jobs: any JobAPI,
        captureOne: any CaptureOneBridging,
        initialRoleFilter: String? = nil
    ) {
        self.sessionId = sessionId
        self.face = face
        self.jobs = jobs
        self.captureOne = captureOne
        self.initialRoleFilter = initialRoleFilter
    }

    // MARK: - 可见性 / 关闭（Cut 4 / 4a-2c）

    /// 可见性唯一入口（PageVisibility）：默认不可见，重复调用幂等；
    /// shutdown 之后 no-op（关闭是终态）。
    public func setVisible(_ visible: Bool) {
        guard !isShutdown, transitionVisibility(&isVisible, to: visible) else { return }
    }

    /// 关闭：人脸页的加载/分析 Task 由调用点各自持有，VM 只落终态；
    /// SessionWorkspace.close 通过这里保证关闭后不再被重新置可见。
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        isVisible = false
    }

    public var analysisDone: Bool { analysisPhase == .done }

    /// 错误 tooltip 原文：仅分析失败态携带。动作类错误（绑定/写回/清理等）会覆盖
    /// errorMessage，此时不得复用上一次分析的诊断原文。
    public var errorTooltip: LocalizedText? {
        analysisPhase == .failed ? errorDetail : nil
    }

    public var canWriteback: Bool {
        // TS StepWriteback.tsx:195-203：仅分析未完成或正在写回时禁用；
        // 无预览时由 requestWritebackConfirmation 先补一次预览再弹出确认
        // （handleExecute 语义，但确认前不写盘）。
        analysisDone && !isWritingBack
    }

    /// C-P1-6（性能审计）：派生数组改 stored。
    /// 旧实现每次访问都 filter 全表，而视图一次 body 会访问多次
    ///（boundClusters 甚至在 ForEach 行内再求值 ⇒ O(B×C)）。
    public private(set) var boundClusters: [FaceClusterData] = []
    public private(set) var unboundClusters: [FaceClusterData] = []
    /// 角色集合（旧实现在 roleFilterPicker 里每次求值都重建 + 排序）。
    public private(set) var roleNames: [String] = []

    /// clusters 一经替换就调用：重算派生数组（只算一次）。
    func recomputeDerivedClusters() {
        boundClusters = clusters.filter { $0.binding != nil }
        unboundClusters = clusters.filter { $0.binding == nil }
        roleNames = Set(clusters.compactMap { $0.binding?.roleName }).sorted()
    }
    public var totalAffected: Int { boundClusters.reduce(0) { $0 + $1.size } }

    /// TS StepReview selectedCluster：详情栏当前簇。
    public var selectedCluster: FaceClusterData? {
        guard let selectedClusterId else { return nil }
        return clusters.first { $0.id == selectedClusterId }
    }

    public func applyPreset(_ name: String) {
        guard let preset = Self.presets.first(where: { $0.name == name }) else { return }
        eps = preset.eps
        minSamples = preset.minSamples
    }

    public var activePreset: String? {
        if eps == 0.72 && minSamples == 3 { return "strict" }
        if eps == 0.65 && minSamples == 3 { return "balanced" }
        if eps == 0.5 && minSamples == 2 { return "loose" }
        return nil
    }

    /// TS faceKwStore setStep：已过步骤可回点；下一步门控由 View 的
    /// analysisDone 判定（StepAnalyze/index.tsx isClickable）。
    public func setStep(_ step: Step) {
        self.step = step
    }

    /// 首屏 / 刷新入口（同步 facade）：只调度 async reload()。
    public func load() {
        Task { await self.reload() }
    }

    /// 生产路径的完整加载：簇 + 模型状态 + 未完成 job 恢复 + 首屏落点。
    public func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        defer {
            if generation == reloadGeneration { isLoading = false }
        }
        do {
            let loaded = try await face.clusters(sessionId)
            guard generation == reloadGeneration else { return }
            applyClusters(loaded)
        } catch {
            guard generation == reloadGeneration else { return }
            errorMessage = CommandError(error)
        }
        await refreshModelsStatus()
        guard generation == reloadGeneration else { return }
        await recoverAnalysis()
        guard generation == reloadGeneration else { return }
        seedInitialRoleFilter()
        // F10：恢复完状态后再决定首屏落点（有结果 → 审核）。
        seedInitialStep()
    }

    private func applyClusters(_ loaded: [FaceClusterData]) {
        clusters = loaded
        recomputeDerivedClusters()
        if let selectedClusterId,
           let cluster = clusters.first(where: { $0.id == selectedClusterId }) {
            select(cluster)
        }
        errorMessage = nil
    }

    /// 选中簇。**只在真正换簇时**用服务端值重置编辑字段。
    ///
    /// 第三轮审计 C-#1：load() 末尾会对当前选中簇再调一次 select()，而绑定/解绑/
    /// 移除成员/合并之后都会 load() —— 无条件重置会把用户**还没提交**的角色名与
    /// 关键字草稿冲掉（看起来像「界面自己改回去了」）。
    public func select(_ cluster: FaceClusterData) {
        let isSameCluster = selectedClusterId == cluster.id
        selectedClusterId = cluster.id
        if !isSameCluster {
            roleName = cluster.binding?.roleName ?? ""
            keywords = cluster.binding?.keywords.joined(separator: ", ") ?? ""
            mergeTargetId = nil
            selectedMemberIds.removeAll()
            reviewItems = []
            reviewNextCursor = nil
            reviewTotal = 0
            reviewSuspectTotal = 0
        }
        reviewActionError = nil
    }

    /// F10：已有分析结果时默认落在「审核」而不是「分析」。
    ///
    /// 旧行为：step 初值恒为 .analyze，恢复已有结果时只恢复 analysisPhase，
    /// 于是每次进入一个已完成的工作区都停在分析页，主按钮还是「仅重新聚类」
    ///（该动作会还原人工绑定）——用户很容易把重置动作当成继续流程。
    ///
    /// 只在首次 load 生效：后续 load（分析完成、动作刷新、事件回流）不得
    /// 把用户从写回/审核步骤拉走。
    private func seedInitialStep() {
        guard !initialStepSeeded else { return }
        initialStepSeeded = true
        // 页面显式指定的步骤优先（例如深链或测试构造）。
        guard step == .analyze else { return }
        guard analysisDone || !clusters.isEmpty else { return }
        step = .review
    }

    /// 深链角色过滤的应用入口（外壳在页面 .task 里调用，避免视图更新期改状态）。
    ///
    /// 与 seedInitialRoleFilter 的区别：后者只在首次 load 播种（initialRoleFilter
    /// 构造参数）；本方法面向**已缓存 VM** 的二次深链（人物库「前往人脸审核」）。
    public func applyRoleFilterFromDeepLink(_ role: String) {
        guard roleFilter != role else { return }
        roleFilter = role
        reviewActionError = nil
        if analysisDone { step = .review }
    }

    /// TS 深链（?role=）：播种角色过滤；分析已完成（done）时直接进入审核步骤
    /// （review 步骤可点性本就被 analysisDone 门控，等价于旧版直接落在审核页）。
    private func seedInitialRoleFilter() {
        guard !initialRoleSeeded, let role = initialRoleFilter else { return }
        initialRoleSeeded = true
        roleFilter = role
        if analysisDone { step = .review }
    }

    /// TS finishAnalysis：成功 → 审核步骤 + done 状态。
    func finishAnalysis() {
        analysisPhase = .done
        analysisSucceeded = true
        step = .review
    }

    private func refreshModelsStatus() async {
        do {
            // Swift 使用 Vision 检测和随应用分发的 CoreML 身份模型。
            // 缺少打包资产或自定义路径失效时显示真实缺失状态。
            modelsMissing = !(try await face.modelsStatus().modelsPresent)
        } catch {
            modelsMissing = false
        }
    }

    private func recoverAnalysis() async {
        let jobs = (try? await jobs.list(JobListFilter(includeCheckpoint: false))) ?? []
        applyRecoveredJobs(jobs)
    }

    /// 挂载恢复：只认当前会话的活跃 face.analyze；无活跃任务时按已有结果
    /// 回填 done/idle（与旧命令面 的 jobs.list 过滤逐字一致）。
    private func applyRecoveredJobs(_ jobs: [AnalysisJobData]) {
        guard let job = jobs.first(where: { candidate in
            candidate.type == .faceAnalyze &&
                candidate.scopeType == "session" &&
                candidate.scopeId == sessionId &&
                ["queued", "running", "cancelling"].contains(candidate.status.rawValue)
        }) else {
            if analysisPhase != .running {
                analysisPhase = (analysisSucceeded || !clusters.isEmpty) ? .done : .idle
            }
            return
        }
        analysisPhase = .running
        progressCurrent = job.progressCurrent
        progressTotal = job.progressTotal
        progressPhase = job.progressMessage.isEmpty ? "face.detecting" : job.progressMessage
    }
}
