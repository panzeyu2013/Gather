// Phase 3.5：人脸分析、簇绑定、成员修订和安全写回流程。
// TS 源：desktop/src/renderer/pages/FaceKeywording/* + face-kw.ipc.ts。
// 对齐清单（2026-08-12）：
// - 三步向导外壳（index.tsx）：顶部胶囊 step indicator（分析→审核→写回，
//   34pt 高 / 999px 圆角、→ 分隔、已过步骤可回点、下一步 analysis done 门控），
//   切换步骤仅渲染当前步骤内容。
// - Step 1 分析（StepAnalyze.tsx）：模型缺失引导条（warning 边框 +「前往设置」
//   按钮，onOpenSettings 为 nil 时禁用）+ 匹配强度预设三按钮（strict 0.72/3、
//   balanced 0.6/3、loose 0.5/2）+ 高级参数（eps：SliderInputView 渐变滑块 +
//   数字输入 0.3–0.95 step 0.01；minSamples：SliderInputIntView 2–20）+
//   错误块（error 色 12% 底）+ 自定义 8pt 圆角进度条（相位 + (n/N) + 0.2s 过渡，
//   min(100, ratio) 宽度）+ 动作区（开始分析 / 仅重新聚类 / 取消红字）。
// - 实时进度：订阅 GatherEventCenter.jobProgress（job.type == face.analyze 且
//   scopeId == sessionId），相位经 GatherLocalization.progressPhaseText 翻译，
//   终态事件（succeeded/failed/cancelled/interrupted）翻转状态机，succeeded
//   即 finishAnalysis → 进入审核（StepAnalyze.tsx:130-155）。
// - 断点恢复：挂载时 jobs.list 查 queued/running/cancelling 的 face.analyze
//   任务，恢复「分析中」状态与进度（StepAnalyze.tsx:101-125）。
// - Step 2 审核（StepReview.tsx）：左簇网格（adaptive minmax(132,1fr) gap 10，
//   2x2 蒙太奇圆角 9、hover 主色描边 + 上浮、选中主色描边 + 外发光、label 13 /
//   成员数 11 / 绑定角色 success 胶囊 10）+ 右侧 340pt 详情栏（成员列表 #序号 +
//   文件名 + 置信度%、移除红字；角色/关键字编辑 + 绑定/更新绑定/解除；
//   合并目标下拉过滤当前簇，选项 label (n 张)）+ 每批 100「加载更多」。
//   角色过滤条（旧版 URL searchParam，本页用角色胶囊切换；Persons 深链
//   ?role= 经 initialRoleFilter 播种，分析已完成时直达审核步骤）。
// - Step 3 写回（StepWriteback.tsx）：三统计卡（已绑定簇 accent / 受影响照片 /
//   未绑定跳过 warning，数值 24pt tabular）+ 绑定簇预览（roleName + keywords +
//   前 5 文件名 + 剩余数）+ XMP 预览三行明细（文件名 / before→after / 新建|更新
//   XMP + 共享数 + 外部冲突 + 来源，前 50 行，max-height 240）+ 预览/执行 +
//   写回报告（已写入/失败/已跳过三色统计卡 28pt + 失败项 + 重试/确认同步/清理 +
//   reload 行；预览生成后即显示操作行）。
// - 保留合理增益：2 个 confirmationDialog（确认写回/清理；解除绑定为可逆
//   操作即时执行、移除成员对齐旧版即时执行）、GatherEmptyState 空态、
//   顶部错误/提示横幅、审核动作失败的内联错误块。
import Combine
import SwiftUI
import GatherCore

@MainActor
@Observable
public final class FaceKeywordingViewModel {
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
        public let title: String
        public let eps: Double
        public let minSamples: Int
        public var id: String { name }
    }

    /// TS StepAnalyze applyPreset：strict 0.72/3、balanced 0.6/3、loose 0.5/2。
    public static let presets: [Preset] = [
        Preset(name: "strict", title: GatherLocalization.l("严格"), eps: 0.72, minSamples: 3),
        Preset(name: "balanced", title: GatherLocalization.l("均衡"), eps: 0.6, minSamples: 3),
        Preset(name: "loose", title: GatherLocalization.l("宽松"), eps: 0.5, minSamples: 2),
    ]
    /// TS StepReview CLUSTER_PAGE_SIZE。
    public static let clusterPageSize = 100

    private let commands: CommandSurface
    private let captureOne: CaptureOneBridge
    public let sessionId: String
    private(set) public var clusters: [FaceClusterData] = []
    private(set) public var analysisResult: FaceAnalysisResult?
    private(set) public var preview: WritebackPreview?
    private(set) public var writebackResult: WritebackResult?
    /// 初始为 true：首帧即渲染加载态，避免 load() 完成前误显空态。
    private(set) public var isLoading = true
    private(set) public var isWritingBack = false
    private(set) public var errorMessage: String?
    private(set) public var notice: String?
    private(set) public var analysisPhase: AnalysisPhase = .idle
    private(set) public var progressCurrent = 0
    private(set) public var progressTotal = 0
    private(set) public var progressPhase = "face.detecting"
    private(set) public var modelsMissing = false
    private(set) public var isSyncConfirmed = false
    /// 分析 succeeded 快照：0 簇时也保持已完成，仅首屏无分析历史才回退 idle。
    private var analysisSucceeded = false
    /// TS faceKwStore step：向导当前步骤。
    public var step: Step = .analyze
    public var roleName = ""
    public var keywords = ""
    public var eps = 0.6
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
    /// TS StepReview actionError：审核步骤动作（绑定/移除/解除/合并）的内联
    /// 错误文案（旧版详情栏内联错误块，StepReview.tsx:216-218）。
    private(set) public var reviewActionError: String?

    public init(
        sessionId: String,
        commands: CommandSurface,
        initialRoleFilter: String? = nil
    ) {
        self.sessionId = sessionId
        self.commands = commands
        self.captureOne = CaptureOneBridge.shared ?? CaptureOneBridge()
        self.initialRoleFilter = initialRoleFilter
    }

    public var analysisDone: Bool { analysisPhase == .done }

    public var canWriteback: Bool {
        // TS StepWriteback.tsx:195-203：仅分析未完成或正在写回时禁用；
        // 无预览时执行会自动补一次预览（handleExecute 语义）。
        analysisDone && !isWritingBack
    }

    public var boundClusters: [FaceClusterData] { clusters.filter { $0.binding != nil } }
    public var unboundClusters: [FaceClusterData] { clusters.filter { $0.binding == nil } }
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
        if eps == 0.6 && minSamples == 3 { return "balanced" }
        if eps == 0.5 && minSamples == 2 { return "loose" }
        return nil
    }

    /// TS faceKwStore setStep：已过步骤可回点；下一步门控由 View 的
    /// analysisDone 判定（StepAnalyze/index.tsx isClickable）。
    public func setStep(_ step: Step) {
        self.step = step
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            clusters = try await commands.face.clusters(FkwClustersParams(sessionId: sessionId))
            if let selectedClusterId,
               let cluster = clusters.first(where: { $0.id == selectedClusterId }) {
                select(cluster)
            }
            errorMessage = nil
        } catch {
            errorMessage = GatherErrorText.message(for: error)
        }
        await refreshModelsStatus()
        await recoverAnalysis()
        seedInitialRoleFilter()
    }

    public func select(_ cluster: FaceClusterData) {
        selectedClusterId = cluster.id
        roleName = cluster.binding?.roleName ?? ""
        keywords = cluster.binding?.keywords.joined(separator: ", ") ?? ""
        mergeTargetId = nil
        reviewActionError = nil
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
    private func finishAnalysis() {
        analysisPhase = .done
        analysisSucceeded = true
        step = .review
    }

    public func analyze() async {
        guard analysisPhase != .running else { return }
        analysisPhase = .running
        progressCurrent = 0
        progressTotal = 0
        progressPhase = "face.detecting"
        errorMessage = nil
        do {
            let result = try await commands.face.analyze(FkwAnalyzeParams(
                sessionId: sessionId,
                eps: eps,
                minSamples: minSamples
            ))
            analysisResult = FaceAnalysisResult(
                status: result.status,
                detectionFailures: result.detectionFailures,
                encodingFailures: result.encodingFailures
            )
            if let result = analysisResult, result.status == "cancelled" {
                analysisPhase = .cancelled
                notice = GatherLocalization.l("人脸分析已取消")
                return
            }
            if let result = analysisResult, result.status == "failed" {
                analysisPhase = .failed
                // 无内嵌前缀：横幅统一加「操作失败：」，避免双前缀。
                errorMessage = String(format: GatherLocalization.l("检测失败 %lld 张，编码失败 %lld 个人脸"), result.detectionFailures, result.encodingFailures) + guidanceSuffix
                return
            }
            finishAnalysis()
            notice = GatherLocalization.l("人脸分析完成")
            await load()
        } catch {
            if Self.rawMessage(for: error).localizedCaseInsensitiveContains("cancelled") {
                analysisPhase = .cancelled
                notice = GatherLocalization.l("人脸分析已取消")
            } else {
                analysisPhase = .failed
                errorMessage = GatherErrorText.message(for: error) + guidanceSuffix
            }
        }
    }

    public func cancel() async {
        do {
            try await commands.face.cancelAnalysis(FkwCancelAnalysisParams(sessionId: sessionId))
            notice = GatherLocalization.l("已请求取消人脸分析")
        } catch {
            errorMessage = GatherErrorText.message(for: error)
        }
    }

    public func recluster() async {
        guard analysisPhase != .running else { return }
        analysisPhase = .running
        errorMessage = nil
        do {
            try await commands.face.recluster(sessionId: sessionId, eps: eps, minSamples: minSamples)
            finishAnalysis()
            notice = GatherLocalization.l("已重新聚类")
            await load()
        } catch {
            if Self.rawMessage(for: error).localizedCaseInsensitiveContains("cancelled") {
                analysisPhase = .cancelled
            } else {
                analysisPhase = .failed
                errorMessage = GatherErrorText.message(for: error) + guidanceSuffix
            }
        }
    }

    public func bind(_ cluster: FaceClusterData) async {
        let role = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = parseKeywords()
        guard !role.isEmpty else {
            // TS handleBind：空角色名 → 详情栏内联错误（StepReview.tsx:95-97）。
            let text = GatherLocalization.errorText("FKW_ROLE_NAME_EMPTY")
            errorMessage = text
            reviewActionError = text
            return
        }
        do {
            try await commands.face.bind(FkwBindParams(
                sessionId: sessionId,
                clusterId: cluster.id,
                roleName: role,
                keywords: words
            ))
            notice = String(format: GatherLocalization.l("已绑定簇 #%lld"), cluster.id)
            reviewActionError = nil
            await load()
        } catch {
            errorMessage = GatherErrorText.message(for: error)
            reviewActionError = errorMessage
        }
    }

    public func unbind(_ cluster: FaceClusterData) async {
        do {
            _ = try await commands.face.unbind(FkwUnbindParams(
                sessionId: sessionId,
                clusterId: cluster.id,
                confirmed: true
            ))
            notice = String(format: GatherLocalization.l("已解除簇 #%lld 的绑定"), cluster.id)
            reviewActionError = nil
            await load()
        } catch {
            errorMessage = GatherErrorText.message(for: error)
            reviewActionError = errorMessage
        }
    }

    public func removeMember(_ member: ClusterMember, from cluster: FaceClusterData) async {
        do {
            try await commands.face.removeMember(FkwRemoveMemberParams(
                sessionId: sessionId,
                clusterId: cluster.id,
                memberId: member.memberId
            ))
            notice = String(format: GatherLocalization.l("已从簇 #%lld 移除成员"), cluster.id)
            reviewActionError = nil
            await load()
        } catch {
            errorMessage = GatherErrorText.message(for: error)
            reviewActionError = errorMessage
        }
    }

    /// TS handleMerge：合并到下拉目标（过滤当前簇），成功后选中目标簇。
    public func merge(_ cluster: FaceClusterData) async {
        guard let target = mergeTargetId,
              target != cluster.id,
              clusters.contains(where: { $0.id == target }) else {
            let text = GatherLocalization.l("请选择有效的目标簇")
            errorMessage = text
            reviewActionError = text
            return
        }
        do {
            try await commands.face.merge(FkwMergeParams(
                sessionId: sessionId,
                source: cluster.id,
                target: target
            ))
            notice = String(format: GatherLocalization.l("已将簇 #%lld 合并到簇 #%lld"), cluster.id, target)
            mergeTargetId = nil
            reviewActionError = nil
            await load()
            if let targetCluster = clusters.first(where: { $0.id == target }) {
                select(targetCluster)
            }
        } catch {
            errorMessage = GatherErrorText.message(for: error)
            reviewActionError = errorMessage
        }
    }

    public func previewWriteback() async {
        guard analysisDone else {
            errorMessage = GatherLocalization.l("请先完成人脸分析")
            return
        }
        do {
            let options = WritebackOptions(
                createAlbums: false,
                addPrefix: false,
                markUngrouped: false,
                writeIPTC: false
            )
            preview = try await commands.face.preview(FkwPreviewParams(
                sessionId: sessionId,
                options: options
            ))
            writebackResult = nil
            notice = GatherLocalization.l("写回预览已生成")
        } catch {
            errorMessage = GatherErrorText.message(for: error)
        }
    }

    /// TS handleExecute（StepWriteback.tsx:53-69）：确认写回时若尚无预览，
    /// 先自动生成一次预览，再按预览项执行写回（一键直写语义）。
    public func writeback() async {
        guard analysisDone else {
            errorMessage = GatherLocalization.l("请先完成人脸分析")
            return
        }
        isWritingBack = true
        defer { isWritingBack = false }
        do {
            let preview: WritebackPreview
            if let existing = self.preview {
                preview = existing
            } else {
                let options = WritebackOptions(
                    createAlbums: false,
                    addPrefix: false,
                    markUngrouped: false,
                    writeIPTC: false
                )
                preview = try await commands.face.preview(FkwPreviewParams(
                    sessionId: sessionId,
                    options: options
                ))
                self.preview = preview
            }
            guard !preview.items.isEmpty else {
                errorMessage = GatherLocalization.l("预览没有可写回项")
                return
            }
            writebackResult = try await commands.face.writeback(FkwWritebackParams(
                sessionId: sessionId,
                confirmed: true,
                items: preview.items
            ))
            isSyncConfirmed = false
            notice = String(format: GatherLocalization.l("已写回 %lld 项；请先让 Capture One 重新加载元数据"), writebackResult?.written ?? 0)
        } catch {
            errorMessage = GatherErrorText.message(for: error)
        }
    }

    public func retryFailed() async {
        guard let items = writebackResult?.failedItems, !items.isEmpty else {
            errorMessage = GatherLocalization.l("没有可重试的失败项")
            return
        }
        do {
            writebackResult = try await commands.face.writeback(FkwWritebackParams(
                sessionId: sessionId,
                confirmed: true,
                items: items
            ))
            isSyncConfirmed = false
            notice = GatherLocalization.l("已重试失败写回项")
        } catch {
            errorMessage = GatherErrorText.message(for: error)
        }
    }

    public func reloadCaptureOne() async {
        do {
            try await captureOne.reloadMetadata(sessionId: sessionId)
            notice = GatherLocalization.l("Capture One 已重新加载元数据，现在可以确认同步")
        } catch {
            errorMessage = GatherErrorText.message(for: error)
        }
    }

    public func confirmSync() async {
        do {
            try await commands.face.confirmSync(FkwConfirmSyncParams(sessionId: sessionId))
            isSyncConfirmed = true
            notice = GatherLocalization.l("已确认人脸关键字同步")
        } catch {
            errorMessage = GatherErrorText.message(for: error)
        }
    }

    public func cleanup() async {
        do {
            try await commands.face.cleanup(FkwCleanupParams(sessionId: sessionId, confirmed: true))
            notice = GatherLocalization.l("已清理人脸写回备份")
        } catch {
            errorMessage = GatherErrorText.message(for: error)
        }
    }

    /// TS jobs:progress 订阅入口（JobService 进度/终态帧）。
    public func applyJobEvent(_ event: GatherJobEvent) {
        guard event.job.type == .faceAnalyze,
              event.job.scopeType == "session",
              event.job.scopeId == sessionId else { return }
        if event.isTerminal {
            switch event.job.status {
            case .succeeded:
                // TS finishAnalysis：succeeded 终态直接进入审核步骤。
                finishAnalysis()
                progressCurrent = event.job.progressCurrent
                progressTotal = event.job.progressTotal
                Task { await load() }
            case .cancelled:
                analysisPhase = .cancelled
                notice = GatherLocalization.l("人脸分析已取消")
            case .interrupted, .failed:
                analysisPhase = .failed
                errorMessage = GatherLocalization.jobErrorMessage(
                    event.job.errorMessage.isEmpty ? nil : event.job.errorMessage)
            case .queued, .running, .cancelling:
                break
            }
            return
        }
        progressCurrent = event.update.current ?? event.job.progressCurrent
        progressTotal = event.update.total ?? event.job.progressTotal
        progressPhase = event.update.phase ?? event.update.message ?? "face.detecting"
        analysisPhase = .running
    }

    private var guidanceSuffix: String {
        modelsMissing ? "\n" + GatherLocalization.l("人脸推理当前使用系统内置引擎") : ""
    }

    private func refreshModelsStatus() async {
        do {
            let data = try await commands.face.modelsStatus()
            // 2.2 决议：Vision provider 恒可用（无 ONNX 模型资产）→
            // modelsPresent 恒 true → modelsMissing 恒 false。横幅/引导分支
            // 为防御性保留（若未来引入 cpu provider 回退则自然生效）。
            modelsMissing = !(data.detectorPresent && data.encoderPresent)
        } catch {
            modelsMissing = false
        }
    }

    private func recoverAnalysis() async {
        let jobs = (try? await commands.jobs.list(JobListParams())) ?? []
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

    private static func rawMessage(for error: Error) -> String {
        if let described = error as? CustomStringConvertible { return described.description }
        return (error as NSError).localizedDescription
    }

    private func parseKeywords() -> [String] {
        keywords.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}

public struct FaceKeywordingView: View {
    @State private var viewModel: FaceKeywordingViewModel
    private let commands: CommandSurface
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    /// 前往设置回调：可选（RootView 由外部接线）；nil 时页面内按钮禁用。
    private let onOpenSettings: (() -> Void)?
    @State private var confirmWriteback = false
    @State private var confirmCleanup = false
    @State private var visibleClusterCount = FaceKeywordingViewModel.clusterPageSize
    @State private var hoveredClusterId: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct StepItem {
        let key: FaceKeywordingViewModel.Step
        let label: String
    }

    private let stepItems: [StepItem] = [
        StepItem(key: .analyze, label: GatherLocalization.l("分析")),
        StepItem(key: .review, label: GatherLocalization.l("审核")),
        StepItem(key: .writeback, label: GatherLocalization.l("写回")),
    ]

    init(
        sessionId: String,
        commands: CommandSurface,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: (() -> Void)? = nil,
        initialRoleFilter: String? = nil
    ) {
        _viewModel = State(initialValue: FaceKeywordingViewModel(
            sessionId: sessionId,
            commands: commands,
            initialRoleFilter: initialRoleFilter
        ))
        self.commands = commands
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            stepIndicator
            // 审核动作错误经内联错误块就近展示（reviewActionError 与 errorMessage
            // 同源），避免横幅双提示；其余操作错误仍走横幅。
            if let error = viewModel.errorMessage, viewModel.reviewActionError == nil {
                NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error), color: GatherTheme.error)
            }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: GatherTheme.success) }
            ScrollView {
                Group {
                    switch viewModel.step {
                    case .analyze:
                        stepAnalyze.frame(maxWidth: 860, alignment: .leading)
                    case .review:
                        stepReview
                    case .writeback:
                        stepWriteback.frame(maxWidth: 800, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(24)
            }
        }
        .background(Color.gatherBackground)
        .task {
            await viewModel.load()
            visibleClusterCount = FaceKeywordingViewModel.clusterPageSize
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.applyJobEvent(event)
        }
        .onChange(of: viewModel.roleFilter) { _, _ in
            visibleClusterCount = FaceKeywordingViewModel.clusterPageSize
        }
        .confirmationDialog(GatherLocalization.l("确认写回人脸关键字？"), isPresented: $confirmWriteback, titleVisibility: .visible) {
            Button(GatherLocalization.l("确认写回")) { Task { await viewModel.writeback() } }
            Button(GatherLocalization.l("取消"), role: .cancel) {}
        } message: {
            Text(GatherLocalization.l("写回前请检查预览；写入后必须重新加载 Capture One，再确认同步。"))
        }
        .confirmationDialog(GatherLocalization.l("确认清理人脸写回备份？"), isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button(GatherLocalization.l("清理"), role: .destructive) { Task { await viewModel.cleanup() } }
            Button(GatherLocalization.l("取消"), role: .cancel) {}
        } message: {
            Text(GatherLocalization.l("只应在 Capture One 已重载并确认同步后执行。"))
        }
    }

    // MARK: - 外壳

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(GatherLocalization.l("返回"), systemImage: "chevron.left", action: onBack).buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(GatherLocalization.l("人脸检测与聚类")).font(.largeTitle.weight(.bold))
                    Text(String(format: GatherLocalization.l("工作区 %@"), String(viewModel.sessionId.prefix(8)))).foregroundStyle(.secondary)
                }
                Spacer()
                C1StatusCapsuleHost(
                    sessionId: viewModel.sessionId,
                    culling: commands.culling,
                    onOpenSettings: onOpenSettings ?? {}
                )
                Button(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise") { Task { await viewModel.load() } }
            }
            SessionTabBar(
                selection: .tab(.faceKw),
                onBrowse: { onOpenGallery(viewModel.sessionId) },
                onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
                onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
            )
        }
        .padding(24)
    }

    /// TS index.tsx steps：胶囊 34pt 高 / 999px 圆角 / → 分隔；已过步骤可回点，
    /// 下一步仅 analysisStatus === 'done' 时可点（其余 opacity 0.55 禁用）。
    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Array(stepItems.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("→").foregroundStyle(Color.gatherBorder)
                }
                stepChip(item, index: index)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.gatherSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.gatherBorder).frame(height: 1)
        }
    }

    private var currentStepIndex: Int {
        switch viewModel.step {
        case .analyze: return 0
        case .review: return 1
        case .writeback: return 2
        }
    }

    private func stepChip(_ item: StepItem, index: Int) -> some View {
        let isActive = index == currentStepIndex
        let isPast = index < currentStepIndex
        let isNext = index == currentStepIndex + 1
        let isClickable = isPast || (isNext && viewModel.analysisDone)
        let enabled = isClickable || isActive
        return Button {
            viewModel.setStep(item.key)
        } label: {
            Text(item.label)
                .font(.body)
                .foregroundStyle(isActive ? Color.accentColor : (isPast ? GatherTheme.success : Color.secondary))
                .fontWeight(isActive ? .bold : (isPast ? .semibold : .regular))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(minHeight: 34)
                .background(Capsule().fill(isActive ? GatherTheme.primarySoft : Color.gatherSurface))
                .overlay(
                    Capsule().strokeBorder(
                        isActive ? GatherTheme.primary : (isPast ? Color.gatherBorder : Color.gatherBorder.opacity(0.6)),
                        lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(isActive ? "" : (isClickable ? String(format: GatherLocalization.l("前往「%@」步骤"), item.label) : (isNext ? GatherLocalization.l("请先完成人脸分析") : GatherLocalization.l("请先完成上一步"))))
    }

    private var bindable: Bindable<FaceKeywordingViewModel> { Bindable(viewModel) }

    // MARK: - Step 1 分析（TS StepAnalyze）

    private var stepAnalyze: some View {
        VStack(alignment: .leading, spacing: 14) {
            modelsGuidanceStrip
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(GatherLocalization.l("匹配强度")).font(.headline)
                    Spacer()
                    phaseCapsule
                }
                presetSelector
                Text(GatherLocalization.l("建议从「均衡」开始，之后可在审核阶段拆分或合并人物。"))
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup(GatherLocalization.l("高级参数")) {
                    VStack(alignment: .leading, spacing: 14) {
                        // TS range slider（渐变轨道）+ 数字输入（SliderInput）。
                        SliderInputView(title: GatherLocalization.l("人脸相似度"), value: bindable.eps, range: 0.3...0.95, step: 0.01)
                            .disabled(viewModel.analysisPhase == .running)
                        Text(GatherLocalization.l("eps 范围 0.30–0.95，数值越小分组越严格。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        SliderInputIntView(title: GatherLocalization.l("最少出现次数"), value: bindable.minSamples, range: 2...20)
                            .disabled(viewModel.analysisPhase == .running)
                        Text(GatherLocalization.l("每个簇最少包含的人脸数量（2–20）。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                // TS error 块：error 色 12% 底，嵌在表单附近便于定位。
                if let error = viewModel.errorMessage,
                   (viewModel.analysisPhase == .failed || viewModel.analysisPhase == .cancelled) {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(GatherTheme.error)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(GatherTheme.error.opacity(0.12)))
                }
                if viewModel.analysisPhase == .running { analysisProgress }
                HStack(spacing: 12) {
                    if viewModel.analysisPhase == .running {
                        Button(GatherLocalization.l("取消"), systemImage: "stop.fill") { Task { await viewModel.cancel() } }
                            .foregroundStyle(GatherTheme.error)
                    } else if viewModel.analysisPhase == .done {
                        Button(GatherLocalization.l("仅重新聚类"), systemImage: "arrow.triangle.2.circlepath") {
                            Task { await viewModel.recluster() }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(GatherLocalization.l("开始分析"), systemImage: "play.fill") {
                            Task { await viewModel.analyze() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if let result = viewModel.analysisResult {
                    Text(String(format: GatherLocalization.l("分析结果：%@，检测失败 %lld 张，编码失败 %lld 个人脸"), result.status, result.detectionFailures, result.encodingFailures))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .gatherCard()
        }
    }

    /// TS StepAnalyze.guidance：warning 色边框横幅 +「前往设置」按钮
    /// （旧版导航 /settings；回调为 nil 时按钮禁用）。
    @ViewBuilder
    private var modelsGuidanceStrip: some View {
        if viewModel.modelsMissing {
            HStack(spacing: 12) {
                Text(GatherLocalization.l("人脸推理当前使用系统内置引擎，建议前往设置确认模型状态。"))
                    .font(.callout)
                Spacer()
                Button(GatherLocalization.l("前往设置")) { onOpenSettings?() }
                    .disabled(onOpenSettings == nil)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(GatherTheme.warning.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(GatherTheme.warning.opacity(0.6), lineWidth: 1))
        }
    }

    private var phaseCapsule: some View {
        Text(viewModel.analysisPhase.label)
            .font(.footnote.weight(.medium))
            .foregroundStyle(phaseColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(phaseColor.opacity(0.12)))
    }

    private var phaseColor: Color {
        switch viewModel.analysisPhase {
        case .idle: return .secondary
        case .running: return .accentColor
        case .done: return GatherTheme.success
        case .failed: return GatherTheme.error
        case .cancelled: return GatherTheme.warning
        }
    }

    private var presetSelector: some View {
        HStack(spacing: 8) {
            ForEach(FaceKeywordingViewModel.presets) { preset in
                presetButton(preset)
            }
        }
    }

    private func presetButton(_ preset: FaceKeywordingViewModel.Preset) -> some View {
        let isActive = viewModel.activePreset == preset.name
        let isRunning = viewModel.analysisPhase == .running
        return Button {
            viewModel.applyPreset(preset.name)
        } label: {
            Text(preset.title)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? GatherTheme.primarySoft : Color.gatherBackgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive ? GatherTheme.primary : Color.gatherBorder, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .opacity(isRunning ? 0.55 : 1)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// TS AnalyzeProgress：相位文本 + (n/N) + 8px 圆角 track 主色填充（0.2s 过渡）。
    private var analysisProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(GatherLocalization.progressPhaseText(viewModel.progressPhase))
                    .font(.callout)
                Spacer()
                if viewModel.progressTotal > 0 {
                    Text("\(viewModel.progressCurrent)/\(viewModel.progressTotal)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if viewModel.progressTotal > 0 {
                GatherProgressBar(
                    fraction: progressRatio,
                    fill: Color.accentColor,
                    track: Color.gatherBorder.opacity(0.35),
                    accessibilityText: GatherLocalization.l("分析进度")
                )
            } else {
                // TS AnalyzeProgress：total == 0（indeterminate）时相位文本
                // 恒显示，轨道省略；补处理中文案对齐旧版（StepAnalyze.tsx:26-29）。
                HStack(spacing: 8) {
                    ProgressView()
                    Text(GatherLocalization.l("处理中…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var progressRatio: Double {
        guard viewModel.progressTotal > 0 else { return 0 }
        return Double(viewModel.progressCurrent) / Double(viewModel.progressTotal)
    }

    // MARK: - Step 2 审核（TS StepReview）

    private var stepReview: some View {
        Group {
            if viewModel.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(GatherLocalization.l("加载中…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .gatherCard()
            } else if viewModel.clusters.isEmpty {
                GatherEmptyState(
                    icon: "person.crop.circle.badge.questionmark",
                    title: GatherLocalization.l("暂无人脸簇"),
                    message: GatherLocalization.l("先运行人脸分析")
                ) {
                    Button(GatherLocalization.l("前往分析")) {
                        viewModel.setStep(.analyze)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // 详情栏宽度自适应（布局验收 P2）：窄窗口收缩、宽窗口
                // 上限 340，簇网格始终保有可用空间。
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 18) {
                        clusterPane
                        detailPane
                            .frame(width: min(340, max(280, geometry.size.width * 0.32)))
                    }
                }
            }
        }
    }

    /// TS StepReview.clusterPane：标题 + 组数 + 角色过滤条 + 簇网格 + 加载更多。
    private var clusterPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(GatherLocalization.l("人脸聚类")).font(.title3.weight(.semibold))
                Text(String(format: GatherLocalization.l("%lld 组"), visibleClusters.count)).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                roleFilterBar
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                spacing: 10
            ) {
                ForEach(visibleClusters.prefix(visibleClusterCount), id: \.id) { cluster in
                    clusterCard(cluster)
                }
            }
            if visibleClusters.count > visibleClusterCount {
                HStack {
                    Spacer(minLength: 0)
                    Button(String(format: GatherLocalization.l("加载更多（还有 %lld 组）"), visibleClusters.count - visibleClusterCount)) {
                        visibleClusterCount += FaceKeywordingViewModel.clusterPageSize
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
        }
    }

    private var visibleClusters: [FaceClusterData] {
        guard let roleFilter = viewModel.roleFilter else { return viewModel.clusters }
        return viewModel.clusters.filter { $0.binding?.roleName == roleFilter }
    }

    /// TS roleFilterBar（旧版 URL searchParam + 清除按钮）：本页用角色胶囊切换，
    /// 再点当前角色胶囊即清除筛选。
    private var roleFilterBar: some View {
        let roles = Set(viewModel.clusters.compactMap { $0.binding?.roleName }).sorted()
        return Group {
            if roles.isEmpty {
                EmptyView()
            } else {
                HStack(spacing: 6) {
                    ForEach(roles, id: \.self) { role in
                        Button {
                            viewModel.roleFilter = (viewModel.roleFilter == role) ? nil : role
                        } label: {
                            Text(role)
                                .font(.footnote)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(viewModel.roleFilter == role ? GatherTheme.primarySoft : Color.clear)
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        viewModel.roleFilter == role ? GatherTheme.primary : Color.gatherBorder,
                                        lineWidth: 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(viewModel.roleFilter == role ? .isSelected : [])
                        .help(viewModel.roleFilter == role ? String(format: GatherLocalization.l("清除「%@」筛选"), role) : String(format: GatherLocalization.l("仅显示角色「%@」的簇"), role))
                    }
                }
            }
        }
    }

    /// TS ClusterCard：10px padding、radius-md、hover 主色描边 + 底色微变、
    /// 选中主色边框 + 外发光 + 上浮；2x2 蒙太奇（前 4 成员，圆角 8）+ label +
    /// 成员数 + 绑定角色 success 胶囊。
    private func clusterCard(_ cluster: FaceClusterData) -> some View {
        let isSelected = viewModel.selectedClusterId == cluster.id
        let isHovered = hoveredClusterId == cluster.id
        return Button {
            viewModel.select(cluster)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                clusterMontage(cluster)
                Text(cluster.label)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(String(format: GatherLocalization.l("%lld 张"), cluster.size))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let binding = cluster.binding {
                    Text(binding.roleName)
                        .font(.footnote)
                        .foregroundStyle(GatherTheme.success)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(GatherTheme.success.opacity(0.14)))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(isHovered ? GatherTheme.primarySoft.opacity(0.3) : Color.gatherSurface))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(cardBorder(isSelected: isSelected, isHovered: isHovered), lineWidth: isSelected ? 1.5 : 1)
            )
            .shadow(color: isSelected ? Color.accentColor.opacity(0.25) : .clear, radius: 3)
            .offset(y: isSelected ? -1 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredClusterId = cluster.id
            } else if hoveredClusterId == cluster.id {
                hoveredClusterId = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
    }

    private func cardBorder(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Color.accentColor }
        if isHovered { return Color.accentColor.opacity(0.45) }
        return Color.gatherBorder
    }

    /// TS ClusterThumb：2x2 蒙太奇网格（前 4 成员，gap 2，圆角 8），
    /// 空成员时显示簇大小。
    private func clusterMontage(_ cluster: FaceClusterData) -> some View {
        Group {
            if cluster.members.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.gatherBackgroundSecondary)
                    Text("\(cluster.size)")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)],
                    spacing: 2
                ) {
                    ForEach(cluster.members.prefix(4), id: \.memberId) { member in
                        PhotoThumbnailView(path: member.photoPath, size: 128)
                            .aspectRatio(1, contentMode: .fit)
                            .clipped()
                    }
                }
                .background(Color.gatherBackgroundSecondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// TS StepReview.detailPane：详情栏（成员列表 + 编辑 + 合并面板）。
    /// 宽度由调用方按可用宽自适应钳制（280–340），不再固定 340。
    private var detailPane: some View {
        Group {
            if let cluster = viewModel.selectedCluster {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(cluster.label)
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text(String(format: GatherLocalization.l("%lld 名成员"), cluster.size))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    memberList(cluster)
                    // TS StepReview.tsx:216-218：审核动作失败的内联错误块
                    // （绑定/移除/解除/合并），横幅错误保留。
                    if let actionError = viewModel.reviewActionError {
                        Text(actionError)
                            .font(.callout)
                            .foregroundStyle(GatherTheme.error)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(GatherTheme.error.opacity(0.12)))
                    }
                    editor(cluster)
                    mergePanel(cluster)
                }
            } else {
                Text(GatherLocalization.l("点击左侧簇卡片查看成员与绑定编辑"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gatherSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.gatherBorder.opacity(0.6), lineWidth: 1))
    }

    /// TS memberList：max-height 210px 滚动，每行 #idx + 文件名 + 置信度% +
    /// 红色「移除」（TS StepReview.tsx:108-117：点击即移除，无确认）。
    private func memberList(_ cluster: FaceClusterData) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(cluster.members.enumerated()), id: \.element.memberId) { index, member in
                    MemberRowView(index: index, member: member) {
                        Task { await viewModel.removeMember(member, from: cluster) }
                    }
                    Divider().opacity(0.5)
                }
            }
        }
        .frame(maxHeight: 210)
    }

    /// TS editor：角色名/关键字输入 + 绑定/更新绑定 + 解除绑定（可逆操作，
    /// 即时执行，成功经 notice 反馈）。
    private func editor(_ cluster: FaceClusterData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GatherLocalization.l("角色名称")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            TextField(GatherLocalization.l("输入角色名称"), text: bindable.roleName)
                .textFieldStyle(.roundedBorder)
            Text(GatherLocalization.l("关键字")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            TextField(GatherLocalization.l("关键字，用逗号分隔"), text: bindable.keywords)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button(cluster.binding != nil ? GatherLocalization.l("更新绑定") : GatherLocalization.l("绑定")) {
                    Task { await viewModel.bind(cluster) }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                if cluster.binding != nil {
                    Button(GatherLocalization.l("解除绑定")) {
                        Task { await viewModel.unbind(cluster) }
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(GatherTheme.error)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gatherBackground))
    }

    /// TS mergePanel：select 下拉（过滤当前簇，选项 label (n 张)）+ 合并按钮，
    /// 无目标时禁用。
    private func mergePanel(_ cluster: FaceClusterData) -> some View {
        let candidates = viewModel.clusters.filter { $0.id != cluster.id }
        return VStack(alignment: .leading, spacing: 8) {
            Text(GatherLocalization.l("合并到")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker(GatherLocalization.l("合并目标"), selection: bindable.mergeTargetId) {
                    Text(GatherLocalization.l("选择目标簇")).tag(Int?.none)
                    ForEach(candidates, id: \.id) { candidate in
                        Text(String(format: GatherLocalization.l("%@（%lld 张）"), candidate.label, candidate.size))
                            .tag(Int?.some(candidate.id))
                    }
                }
                .labelsHidden()
                .accessibilityLabel(GatherLocalization.l("合并目标"))
                .frame(maxWidth: .infinity)
                Button(GatherLocalization.l("合并")) {
                    Task { await viewModel.merge(cluster) }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.mergeTargetId == nil)
                .help(GatherLocalization.l("选择目标簇后合并当前簇到目标簇"))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gatherBackground))
    }

    // MARK: - Step 3 写回（TS StepWriteback）

    private var stepWriteback: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(GatherLocalization.l("关键字写回"))
                .font(.title3.weight(.semibold))
            writebackStats
            boundPreview
            if viewModel.preview != nil { xmpPreview }
            HStack(spacing: 9) {
                Button(GatherLocalization.l("生成预览"), systemImage: "eye") { Task { await viewModel.previewWriteback() } }
                    .disabled(!viewModel.analysisDone)
                    .help(viewModel.analysisDone ? "" : GatherLocalization.l("请先完成人脸分析"))
                // 确认写回：分析完成后恒可用；无预览时自动补一次预览再写回
                // （TS handleExecute，StepWriteback.tsx:53-69, 195-203）。
                Button(GatherLocalization.l("确认写回"), systemImage: "square.and.arrow.down") { confirmWriteback = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canWriteback)
                    .help(viewModel.analysisDone ? "" : GatherLocalization.l("请先完成人脸分析"))
            }
            if !viewModel.analysisDone {
                Text(GatherLocalization.l("请先完成人脸分析，才能生成预览并写回。"))
                    .font(.footnote).foregroundStyle(GatherTheme.error)
            }
            if let result = viewModel.writebackResult {
                resultSection(result)
            } else if viewModel.preview != nil {
                // TS StepWriteback.tsx:205-226：预览生成后即显示操作行
                // （重试失败项 / C1 重新加载 / 确认同步 / 清理），
                // 写回报告统计卡仅在有写回结果后出现。
                reportActionsRow
                    .padding(18)
                    .gatherCard()
            }
        }
    }

    /// TS stats：三统计卡（已绑定簇 accent / 受影响照片 / 未绑定跳过 warning），
    /// 数值 24pt tabular-nums。
    private var writebackStats: some View {
        HStack(spacing: 10) {
            GatherStatCard(value: viewModel.boundClusters.count, label: GatherLocalization.l("已绑定簇"), color: Color.accentColor)
            GatherStatCard(value: viewModel.totalAffected, label: GatherLocalization.l("受影响照片"))
            GatherStatCard(value: viewModel.unboundClusters.count, label: GatherLocalization.l("未绑定并跳过"), color: GatherTheme.warning)
        }
    }

    /// TS preview 面板：绑定簇预览（roleName + keywords + 前 5 文件名），
    /// 无绑定簇时显示空提示。
    private var boundPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.boundClusters.isEmpty {
                    Text(GatherLocalization.l("暂无已绑定簇，请先在审核步骤绑定角色。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(28)
                } else {
                    ForEach(viewModel.boundClusters, id: \.id) { cluster in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(cluster.binding?.roleName ?? "")
                                    .font(.body.weight(.semibold))
                                Text(String(format: GatherLocalization.l("（%lld 张）"), cluster.size))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if let keywords = cluster.binding?.keywords, !keywords.isEmpty {
                                    Text(keywords.joined(separator: ", "))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            ForEach(cluster.members.prefix(5), id: \.memberId) { member in
                                Text(member.filename)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 10)
                            }
                            if cluster.members.count > 5 {
                                Text(String(format: GatherLocalization.l("还有 %lld 名成员"), cluster.members.count - 5))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .opacity(0.7)
                                    .padding(.leading, 10)
                            }
                        }
                        .padding(.vertical, 9)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .frame(maxHeight: 270)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gatherBackgroundSecondary))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.gatherBorder.opacity(0.6), lineWidth: 0.5))
    }

    /// TS xmpPreview：前 50 行三行明细（文件名 / before→after / 标记行），
    /// max-height 240 滚动。
    @ViewBuilder
    private var xmpPreview: some View {
        if let preview = viewModel.preview {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: GatherLocalization.l("XMP 写回预览 · 共 %lld 项 · %lld 张照片受影响"), preview.totalCount, preview.affectedPhotos))
                    .font(.callout)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(preview.items.prefix(50), id: \.xmpPath) { item in
                            xmpPreviewRow(item)
                            Divider().opacity(0.5)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gatherBackgroundSecondary))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gatherBorder.opacity(0.6), lineWidth: 0.5))
                if preview.items.count > 50 {
                    Text(String(format: GatherLocalization.l("还有 %lld 项…"), preview.items.count - 50)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func xmpPreviewRow(_ item: WritebackItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(URL(fileURLWithPath: item.xmpPath).lastPathComponent)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("\(xmpKeywordsText(item.preview?.before.keywords)) → \(xmpKeywordsText(item.preview?.after.keywords ?? item.keywords))")
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Text(xmpMarkerText(item))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func xmpMarkerText(_ item: WritebackItem) -> String {
        var parts: [String] = []
        if let preview = item.preview {
            parts.append(preview.willCreate ? GatherLocalization.l("新建 XMP") : GatherLocalization.l("更新 XMP"))
            if preview.sharedPhotoCount > 1 { parts.append(String(format: GatherLocalization.l("%lld 张共享"), preview.sharedPhotoCount)) }
            if preview.externalChanged { parts.append(GatherLocalization.l("检测到外部冲突")) }
        }
        parts.append(GatherLocalization.l("来源：人脸关键词"))
        return parts.joined(separator: " · ")
    }

    private func xmpKeywordsText(_ keywords: [String]?) -> String {
        let joined = (keywords ?? []).joined(separator: "、")
        return joined.isEmpty ? GatherLocalization.l("无关键词") : joined
    }

    /// TS WritebackReport：已写入/失败/已跳过三色统计卡 + 失败项明细 +
    /// 重试/确认同步/清理 + reload 行。
    private func resultSection(_ result: WritebackResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GatherLocalization.l("写回报告")).font(.headline)
            WritebackReportCard(
                written: result.written,
                failed: result.failed,
                skipped: result.skipped,
                failedItems: result.failedItems.map { item in
                    WritebackFailureItem(
                        id: item.xmpPath,
                        path: item.photoPath.isEmpty ? item.xmpPath : item.photoPath,
                        message: item.errorMessage
                    )
                }
            )
            reportActionsRow
        }
        .padding(18)
        .gatherCard()
    }

    /// TS WritebackReport actions（StepWriteback.tsx:205-226）：预览生成后即
    /// 可见，无需等待写回结果。重试失败项仅在存在失败项时显示；清理备份
    /// 仅在确认同步后显示（旧版 onCleanup = syncConfirmed ? handleCleanup
    /// : undefined，WritebackReport.tsx:86-95）。
    private var reportActionsRow: some View {
        HStack(spacing: 8) {
            if let result = viewModel.writebackResult, !result.failedItems.isEmpty {
                Button(GatherLocalization.l("重试失败项")) { Task { await viewModel.retryFailed() } }
                    .disabled(viewModel.isWritingBack)
                    .help(GatherLocalization.l("没有失败项"))
            }
            Button(GatherLocalization.l("Capture One 重新加载")) { Task { await viewModel.reloadCaptureOne() } }
                .disabled(viewModel.isWritingBack)
            Button(GatherLocalization.l("确认同步")) { Task { await viewModel.confirmSync() } }
                .disabled(viewModel.isWritingBack)
            if viewModel.isSyncConfirmed {
                Button(GatherLocalization.l("清理备份"), role: .destructive) { confirmCleanup = true }
                    .disabled(viewModel.isWritingBack)
                    .help(GatherLocalization.l("请先在 Capture One 中加载元数据并确认同步"))
            }
        }
    }
}

private struct MemberRowView: View {
    let index: Int
    let member: ClusterMember
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Text("#\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, alignment: .leading)
            Text(member.filename)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.0f%%", member.confidence * 100))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                onRemove()
            } label: {
                Text(GatherLocalization.l("移除"))
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(GatherTheme.error)
            .help(String(format: GatherLocalization.l("从簇中移除成员 %@"), member.filename))
        }
        .padding(.vertical, 6)
        .background(isHovered ? GatherTheme.primarySoft.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private extension FaceKeywordingViewModel.AnalysisPhase {
    var label: String {
        switch self {
        case .idle: return GatherLocalization.l("未开始")
        case .running: return GatherLocalization.l("分析中")
        case .done: return GatherLocalization.l("已完成")
        case .failed: return GatherLocalization.l("失败")
        case .cancelled: return GatherLocalization.l("已取消")
        }
    }
}
