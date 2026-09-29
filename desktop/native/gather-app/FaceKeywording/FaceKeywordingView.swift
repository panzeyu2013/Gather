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
// - 破坏性命令（fkw.unbind / fkw.writeback / fkw.cleanup）一律经确认弹窗后
//   才带 confirmed: true（取消只写可见文案、不发命令）；移除成员/合并仍对齐
//   旧版即时执行（命令面无 confirmed 门控）；GatherEmptyState 空态、顶部
//   错误/提示横幅、审核动作失败的内联错误块。
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

    private let client: NativeCommandClient
    private let captureOne: CaptureOneBridge
    public let sessionId: String
    private(set) public var clusters: [FaceClusterData] = []
    private(set) public var analysisResult: FaceAnalysisResult?
    private(set) public var preview: FaceKwWritebackPreview?
    private(set) public var writebackResult: FaceKwWritebackResult?
    /// 初始为 true：首帧即渲染加载态，避免 load() 完成前误显空态。
    private(set) public var isLoading = true
    private(set) public var isWritingBack = false
    private(set) public var errorMessage: String?
    /// 分析错误原文（tooltip）：仅当 errorMessage 回落通用文案（英文散文等不可读
    /// 诊断）时非空；中文可读原因/错误码已直接上屏，不再重复。
    private(set) public var errorDetail: String?
    private(set) public var notice: String?
    private(set) public var analysisPhase: AnalysisPhase = .idle
    private(set) public var progressCurrent = 0
    private(set) public var progressTotal = 0
    private(set) public var progressPhase = "face.detecting"
    private(set) public var modelsMissing = false
    /// 部分失败可见警示：status == "done" 但 encodingFailures > 0（有脸没编码成功，
    /// 下次分析自动重试）——不得显示成"一切正常"（对抗审查新增高风险）。
    private(set) public var encodingFailureWarning: String?
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
        router: CommandRouter,
        initialRoleFilter: String? = nil
    ) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
        self.captureOne = CaptureOneBridge(router: router)
        self.initialRoleFilter = initialRoleFilter
    }

    public var analysisDone: Bool { analysisPhase == .done }

    /// 错误 tooltip 原文：仅分析失败态携带。动作类错误（绑定/写回/清理等）会覆盖
    /// errorMessage，此时不得复用上一次分析的诊断原文。
    public var errorTooltip: String? {
        analysisPhase == .failed ? errorDetail : nil
    }

    public var canWriteback: Bool {
        // TS StepWriteback.tsx:195-203：仅分析未完成或正在写回时禁用；
        // 无预览时由 requestWritebackConfirmation 先补一次预览再弹出确认
        // （handleExecute 语义，但确认前不写盘）。
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

    public func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            clusters = try client.execute("fkw.clusters", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: [FaceClusterData].self)
            if let selectedClusterId,
               let cluster = clusters.first(where: { $0.id == selectedClusterId }) {
                select(cluster)
            }
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
        refreshModelsStatus()
        recoverAnalysis()
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

    /// analyze 成功后的可见结果：encodingFailures > 0 时不显示「分析完成」，
    /// 改为 warning 警示（这些脸没被编码，下次分析会自动重试——core 语义），
    /// 避免"部分失败"在 UI 上被伪装成一切正常。
    private func applyEncodingFailures(_ result: FaceAnalysisResult?) {
        let failures = result?.encodingFailures ?? 0
        guard failures > 0 else {
            encodingFailureWarning = nil
            notice = GatherLocalization.l("人脸分析完成")
            return
        }
        encodingFailureWarning = String(
            format: GatherLocalization.l("有 %lld 张人脸编码失败，相关照片可能未被完整处理；下次分析会自动重试。"),
            failures
        )
        notice = nil
    }

    public func analyze() async {
        guard analysisPhase != .running else { return }
        analysisPhase = .running
        progressCurrent = 0
        progressTotal = 0
        progressPhase = "face.detecting"
        errorMessage = nil
        errorDetail = nil
        encodingFailureWarning = nil
        do {
            let data = try await client.executeAsync("fkw.analyze", params: [
                "sessionId": .string(sessionId),
                "eps": .number(eps),
                "minSamples": .number(Double(minSamples)),
            ])
            analysisResult = try data.decoded(as: FaceAnalysisResult.self)
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
            applyEncodingFailures(analysisResult)
            load()
        } catch {
            if Self.rawMessage(for: error).localizedCaseInsensitiveContains("cancelled") {
                analysisPhase = .cancelled
                notice = GatherLocalization.l("人脸分析已取消")
            } else {
                analysisPhase = .failed
                let failure = Self.analysisFailure(for: error)
                errorMessage = failure.text + guidanceSuffix
                errorDetail = failure.detail
            }
        }
    }

    public func cancel() {
        do {
            _ = try client.execute("fkw.cancel_analysis", params: ["sessionId": .string(sessionId)])
            notice = GatherLocalization.l("已请求取消人脸分析")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 「仅重新聚类」的影响面（破坏性确认文案用）：簇总数与其中已绑定人物/角色的簇数。
    /// 纯查询、无副作用，供 UI 在弹确认框前取真实计数。
    public func reclusterImpact() -> (clusterCount: Int, boundClusterCount: Int) {
        (
            clusters.count,
            clusters.filter { $0.binding != nil || $0.matchedPersonId != nil }.count
        )
    }

    public func recluster() async {
        guard analysisPhase != .running else { return }
        analysisPhase = .running
        errorMessage = nil
        errorDetail = nil
        do {
            _ = try await client.executeAsync("fkw.recluster", params: [
                "sessionId": .string(sessionId),
                "eps": .number(eps),
                "minSamples": .number(Double(minSamples)),
            ])
            finishAnalysis()
            notice = GatherLocalization.l("已重新聚类")
            load()
        } catch {
            if Self.rawMessage(for: error).localizedCaseInsensitiveContains("cancelled") {
                analysisPhase = .cancelled
            } else {
                analysisPhase = .failed
                let failure = Self.analysisFailure(for: error)
                errorMessage = failure.text + guidanceSuffix
                errorDetail = failure.detail
            }
        }
    }

    public func bind(_ cluster: FaceClusterData) {
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
            _ = try client.execute("fkw.bind", params: [
                "sessionId": .string(sessionId),
                "clusterId": .number(Double(cluster.id)),
                "roleName": .string(role),
                "keywords": .array(words.map(JSONValue.string)),
            ])
            publishChange(.faceKeywording, .persons)
            notice = String(format: GatherLocalization.l("已绑定簇 #%lld"), cluster.id)
            reviewActionError = nil
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            reviewActionError = errorMessage
        }
    }

    /// 解除绑定：命令层 FKW_UNBIND_CONFIRM_REQUIRED 门控，`confirmed` 只能由
    /// 确认弹窗传入 true（旧实现恒 true 已删除）。
    public func unbind(_ cluster: FaceClusterData, confirmed: Bool) async {
        guard confirmed else {
            notice = GatherLocalization.l("未确认，已取消解除绑定")
            return
        }
        do {
            _ = try await client.executeAsync("fkw.unbind", params: [
                "sessionId": .string(sessionId),
                "clusterId": .number(Double(cluster.id)),
                "confirmed": .bool(confirmed),
            ])
            publishChange(.faceKeywording, .persons)
            notice = String(format: GatherLocalization.l("已解除簇 #%lld 的绑定"), cluster.id)
            reviewActionError = nil
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            reviewActionError = errorMessage
        }
    }

    public func removeMember(_ member: ClusterMember, from cluster: FaceClusterData) {
        do {
            _ = try client.execute("fkw.remove_member", params: [
                "sessionId": .string(sessionId),
                "clusterId": .number(Double(cluster.id)),
                "memberId": .number(Double(member.memberId)),
            ])
            publishChange(.faceKeywording)
            notice = String(format: GatherLocalization.l("已从簇 #%lld 移除成员"), cluster.id)
            reviewActionError = nil
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            reviewActionError = errorMessage
        }
    }

    /// TS handleMerge：合并到下拉目标（过滤当前簇），成功后选中目标簇。
    public func merge(_ cluster: FaceClusterData) {
        guard let target = mergeTargetId,
              target != cluster.id,
              clusters.contains(where: { $0.id == target }) else {
            let text = GatherLocalization.l("请选择有效的目标簇")
            errorMessage = text
            reviewActionError = text
            return
        }
        do {
            _ = try client.execute("fkw.merge", params: [
                "sessionId": .string(sessionId),
                "source": .number(Double(cluster.id)),
                "target": .number(Double(target)),
            ])
            publishChange(.faceKeywording)
            notice = String(format: GatherLocalization.l("已将簇 #%lld 合并到簇 #%lld"), cluster.id, target)
            mergeTargetId = nil
            reviewActionError = nil
            load()
            if let targetCluster = clusters.first(where: { $0.id == target }) {
                select(targetCluster)
            }
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
            reviewActionError = errorMessage
        }
    }

    public func previewWriteback() async {
        guard analysisDone else {
            errorMessage = GatherLocalization.l("请先完成人脸分析")
            return
        }
        do {
            let options = FaceKwWritebackOptions(
                createAlbums: false,
                addPrefix: false,
                markUngrouped: false,
                writeIPTC: false
            )
            let data = try await client.executeAsync("fkw.preview", params: [
                "sessionId": .string(sessionId),
                "options": try JSONValue(from: options),
            ])
            preview = try data.decoded(as: FaceKwWritebackPreview.self)
            writebackResult = nil
            notice = GatherLocalization.l("写回预览已生成")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 写回确认准备：无预览时先生成一次预览，让确认弹窗展示真实影响范围
    /// （绑定簇 / 受影响照片 / XMP 项与示例路径）。返回是否存在可确认的写回项。
    public func prepareWritebackConfirmation() async -> Bool {
        guard analysisDone else {
            errorMessage = GatherLocalization.l("请先完成人脸分析")
            return false
        }
        if preview == nil { await previewWriteback() }
        guard let preview = preview, !preview.items.isEmpty else {
            if self.preview != nil {
                errorMessage = GatherLocalization.l("预览没有可写回项")
            }
            return false
        }
        return true
    }

    /// TS handleExecute（StepWriteback.tsx:53-69）：用户确认后按预览项执行写回。
    /// `confirmed` 只能由确认弹窗传入 true；旧实现「无预览自动补预览 + 恒 true」
    /// 已删除（预览改由 prepareWritebackConfirmation 负责）。
    public func writeback(confirmed: Bool) async {
        guard confirmed else {
            notice = GatherLocalization.l("未确认，已取消写回")
            return
        }
        guard let preview = preview, !preview.items.isEmpty else {
            errorMessage = GatherLocalization.l("请先生成写回预览并确认影响范围")
            return
        }
        isWritingBack = true
        defer { isWritingBack = false }
        do {
            let data = try await client.executeAsync("fkw.writeback", params: [
                "sessionId": .string(sessionId),
                "items": .array(try preview.items.map { try JSONValue(from: $0) }),
                "confirmed": .bool(confirmed),
            ])
            writebackResult = try data.decoded(as: FaceKwWritebackResult.self)
            isSyncConfirmed = false
            publishChange(.metadata)
            notice = String(format: GatherLocalization.l("已写回 %lld 项；请先让 Capture One 重新加载元数据"), writebackResult?.written ?? 0)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 重试失败项：同样是 WRITEBACK_CONFIRM_REQUIRED 门控的破坏性命令。
    public func retryFailed(confirmed: Bool) async {
        guard confirmed else {
            notice = GatherLocalization.l("未确认，已取消重试")
            return
        }
        guard let items = writebackResult?.failedItems, !items.isEmpty else {
            errorMessage = GatherLocalization.l("没有可重试的失败项")
            return
        }
        do {
            let data = try await client.executeAsync("fkw.writeback", params: [
                "sessionId": .string(sessionId),
                "items": .array(try items.map { try JSONValue(from: $0) }),
                "confirmed": .bool(confirmed),
            ])
            writebackResult = try data.decoded(as: FaceKwWritebackResult.self)
            isSyncConfirmed = false
            publishChange(.metadata)
            notice = GatherLocalization.l("已重试失败写回项")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func reloadCaptureOne() async {
        do {
            try await captureOne.reloadMetadata(sessionId: sessionId)
            notice = GatherLocalization.l("Capture One 已重新加载元数据，现在可以确认同步")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func confirmSync() async {
        do {
            _ = try await client.executeAsync("fkw.confirm_sync", params: ["sessionId": .string(sessionId)])
            isSyncConfirmed = true
            publishChange(.metadata)
            notice = GatherLocalization.l("已确认人脸关键字同步")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 清理备份：FKW_CLEANUP_CONFIRM_REQUIRED 门控，`confirmed` 只能由确认弹窗
    /// 传入 true（旧实现恒 true 已删除）。
    public func cleanup(confirmed: Bool) async {
        guard confirmed else {
            notice = GatherLocalization.l("未确认，已取消清理")
            return
        }
        do {
            _ = try await client.executeAsync("fkw.cleanup", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(confirmed),
            ])
            publishChange(.metadata)
            notice = GatherLocalization.l("已清理人脸写回备份")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 取消破坏性动作：可见文案（不静默 return，也不发命令）。
    public func reportCancellation(_ action: String) {
        notice = GatherLocalization.cancellationNotice(action)
        errorMessage = nil
        reviewActionError = nil
    }

    /// 合并目标无效时的内联错误（UI 侧不再用 merge() 做校验，避免静默执行）。
    public func reportInvalidMergeTarget() {
        let text = GatherLocalization.l("请选择有效的目标簇")
        errorMessage = text
        reviewActionError = text
    }

    /// 写路径统一广播：人脸域；绑定/解绑同时命中人物域（person_photos 变化）。
    private func publishChange(_ domains: GatherDomain...) {
        for domain in domains {
            GatherEventCenter.postDomainChange(domain, sessionId: sessionId)
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
                load()
            case .cancelled:
                analysisPhase = .cancelled
                notice = GatherLocalization.l("人脸分析已取消")
            case .interrupted, .failed:
                analysisPhase = .failed
                // 与 analyze 的 catch 同一判定：中文可读原因直接上屏，
                // 英文散文回落通用文案并留在 tooltip。
                let failure = Self.analysisFailure(forMessage: event.job.errorMessage)
                errorMessage = failure.text
                errorDetail = failure.detail
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

    private func refreshModelsStatus() {
        do {
            let data = try client.execute("face.models_status").decoded(as: FaceModelsStatusData.self)
            // 2.2 决议：Vision provider 恒可用（无 ONNX 模型资产）→
            // modelsPresent 恒 true → modelsMissing 恒 false。横幅/引导分支
            // 为防御性保留（若未来引入 cpu provider 回退则自然生效）。
            modelsMissing = !data.modelsPresent
        } catch {
            modelsMissing = false
        }
    }

    private func recoverAnalysis() {
        let jobs = (try? client.execute("jobs.list").decoded(as: [AnalysisJobData].self)) ?? []
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

    /// 分析类错误 → 用户可见文案 + tooltip 原文（对抗审查高 4 的复现点：
    /// 中文可读原因此前被 errorText 一律吞成「发生未知错误，请稍后重试」）。
    ///
    /// 判定规则（优先级）：
    /// 1. 已知错误码（含 `CODE::p1::p2` / `CODE: 参数`）→ errorText 本地化模板；
    /// 2. 原文含中日韩字符（FaceEmbeddingError.description 这类已经是人话的原因）→ 原样上屏；
    /// 3. 其余（英文 NSError/系统诊断/内部不变量）→ 通用回退文案，原文只进 tooltip。
    ///
    /// 为什么不泄露英文：分支 3 的门槛是"不含 CJK 即视为不可读诊断"，
    /// 英文散文（如 "Failed to load model at /x: ..."）永远进不了上屏文案；
    /// 它只出现在 .help() 悬停提示里，供排查而非阅读。
    static func analysisFailure(for error: Error) -> (text: String, detail: String?) {
        // FaceEmbeddingError 是 core 的中文可读错误（CustomStringConvertible）；
        // 它不是 LocalizedError，NSError 桥接会丢掉 description，必须显式取。
        if let embeddingError = error as? FaceEmbeddingError {
            return analysisFailure(forMessage: embeddingError.description)
        }
        return analysisFailure(forMessage: rawMessage(for: error))
    }

    static func analysisFailure(forMessage raw: String) -> (text: String, detail: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = GatherLocalization.errorText(Self.unknownDiagnosticMarker)
        guard !trimmed.isEmpty else { return (fallback, nil) }
        // errorText 命中已知码 → 本地化模板（与既有错误漏斗一致）。
        let translated = GatherLocalization.errorText(trimmed)
        if translated != fallback { return (translated, nil) }
        if containsCJK(trimmed) { return (trimmed, nil) }
        return (fallback, trimmed)
    }

    /// 仅为触发 errorText 的未知码回退分支（该字符串不是错误表里的码）。
    private static let unknownDiagnosticMarker = "__GATHER_UNKNOWN_DIAGNOSTIC__"

    /// 中日韩字符判定：汉字/假名/谚文/全角标点任一命中即认为原文是"人话"。
    /// 纯英文 NSError 散文（ASCII + 拉丁扩展）永不命中，故不会泄露给用户。
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F,   // CJK 标点（：（）「」，。等）
                 0x3040...0x30FF,   // 平假名/片假名
                 0x3400...0x4DBF,   // 汉字扩展 A
                 0x4E00...0x9FFF,   // 汉字基本区
                 0xF900...0xFAFF,   // 兼容汉字
                 0xFE30...0xFE4F,   // CJK 兼容形式
                 0xFF00...0xFFEF,   // 全角/半角形式
                 0x1100...0x11FF,   // 韩文字母
                 0xAC00...0xD7AF,   // 韩文音节
                 0x20000...0x2FA1F: // 汉字扩展 B 及以后
                return true
            default:
                return false
            }
        }
    }

    private static func rawMessage(for error: Error) -> String {
        if let native = error as? NativeCommandError { return native.description }
        if let router = error as? RouterCommandError { return router.message }
        if let bridge = error as? BridgeError { return bridge.description }
        return (error as NSError).localizedDescription
    }

    private func parseKeywords() -> [String] {
        keywords.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}

private struct FaceModelsStatusData: Codable {
    let provider: String
    let fallbackToOnnxEnabled: Bool
    let modelsPresent: Bool
    let downloading: Bool
}

// MARK: - 破坏性动作确认上下文（fkw.unbind / fkw.writeback / fkw.cleanup）

/// 写回确认：影响范围 = 绑定簇 / 受影响照片 / XMP 项与示例路径。
private struct PendingFaceWriteback: Identifiable {
    let clusterCount: Int
    let affectedPhotos: Int
    let itemCount: Int
    let samplePath: String?

    var id: String { "writeback-\(itemCount)-\(affectedPhotos)" }

    var scopeText: String {
        var text = String(
            format: GatherLocalization.l("将 %lld 个已绑定簇、%lld 张受影响照片写入 XMP，共 %lld 个文件（新建或更新）。"),
            clusterCount, affectedPhotos, itemCount
        )
        if let samplePath, !samplePath.isEmpty {
            text += String(format: GatherLocalization.l("例如：%@。"), samplePath)
        }
        text += GatherLocalization.l("写入后必须重新加载 Capture One 再确认同步；取消不会写入任何文件。")
        return text
    }
}

/// 重试失败项确认：范围 = 失败项数量与路径。
private struct PendingFaceRetry: Identifiable {
    let paths: [String]

    var id: String { "retry-\(paths.count)-\(paths.first ?? "")" }

    var scopeText: String {
        let sample = paths.prefix(3).joined(separator: GatherLocalization.l("、"))
        let more = paths.count > 3 ? GatherLocalization.l(" 等") : ""
        return String(
            format: GatherLocalization.l("将重试写入 %lld 个失败项：%@%@。取消不会重写任何文件。"),
            paths.count, sample, more
        )
    }
}

/// 解除绑定确认：范围 = 簇、角色与成员数。
private struct PendingFaceUnbind: Identifiable {
    let cluster: FaceClusterData

    var id: Int { cluster.id }

    var scopeText: String {
        let role = cluster.binding?.roleName ?? GatherLocalization.l("未知角色")
        return String(
            format: GatherLocalization.l("将解除簇 #%lld「%@」的绑定（%lld 名成员），并撤销已写入该角色的人脸关键词；此操作不可撤销。"),
            cluster.id, role, cluster.size
        )
    }
}

/// 确认同步（fkw.confirm_sync）：与 sim.confirm_sync 对称，结清后不可回退。
private struct PendingFaceConfirmSync: Identifiable {
    var id: String { "face-confirm-sync" }

    var scopeText: String {
        GatherLocalization.l("确认后 Gather 认为 Capture One 已完成「加载元数据」，之后才会开放清理备份。若尚未在 Capture One 中加载，请取消。")
    }
}

/// 成员移除确认：范围 = 成员文件名/路径与所属簇（命令面无 confirmed 门控，
/// UI 仍需先确认不可逆影响）。
private struct PendingFaceMemberRemoval: Identifiable {
    let member: ClusterMember
    let cluster: FaceClusterData

    var id: String { "remove-member-\(member.memberId)" }

    var scopeText: String {
        String(
            format: GatherLocalization.l("将把「%@」（%@）从簇 #%lld「%@」中移除；照片本身不会删除，但该成员不再参与这个簇的写回。"),
            member.filename, member.photoPath, cluster.id, cluster.label
        )
    }
}

/// 合并确认：范围 = 源/目标簇与张数（合并后源簇消失）。
private struct PendingFaceMerge: Identifiable {
    let cluster: FaceClusterData
    let target: FaceClusterData

    var id: String { "face-merge-\(cluster.id)-\(target.id)" }

    var scopeText: String {
        String(
            format: GatherLocalization.l("将把簇 #%lld「%@」（%lld 张）合并进簇 #%lld「%@」（%lld 张）；源簇随即消失，界面暂不提供撤销入口。"),
            cluster.id, cluster.label, cluster.size, target.id, target.label, target.size
        )
    }
}

/// 清理备份确认：范围 = 已写入项数。
private struct PendingFaceCleanup: Identifiable {
    let writtenCount: Int

    var id: String { "cleanup-\(writtenCount)" }

    var scopeText: String {
        String(
            format: GatherLocalization.l("将恢复或移除本次人脸写回生成的 %lld 个备份 sidecar 文件；只应在 Capture One 已重新加载并确认同步后执行。取消不会改动任何文件。"),
            writtenCount
        )
    }
}

/// 重新聚类确认：范围 = 现有簇数与其中已绑定人物/角色的簇数。
/// 全量重聚类会重建簇行，人工绑定与合并随之还原（增量分析不会）——命令面无 confirmed
/// 门控，所以必须在 UI 侧拦住；文案要给出"只想处理新照片"的正确入口。
struct PendingFaceRecluster: Identifiable {
    let clusterCount: Int
    let boundClusterCount: Int

    var id: String { "recluster-\(clusterCount)-\(boundClusterCount)" }

    var scopeText: String {
        String(
            format: GatherLocalization.l("将重新计算全部人脸簇（当前 %lld 个，其中 %lld 个已绑定人物或角色）。现有簇行会被重建，人工绑定与合并会被还原，且界面暂不提供撤销入口。只想处理新照片，请改用「开始分析」——增量模式会保留现有绑定。"),
            clusterCount, boundClusterCount
        )
    }
}

public struct FaceKeywordingView: View {
    @State private var viewModel: FaceKeywordingViewModel
    private let router: CommandRouter
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    /// 前往设置回调：可选（RootView 由外部接线）；nil 时页面内按钮禁用。
    private let onOpenSettings: (() -> Void)?
    /// 破坏性动作的待确认上下文：非空即弹确认框；命令只在确认分支发出。
    @State private var pendingWriteback: PendingFaceWriteback?
    @State private var pendingRetry: PendingFaceRetry?
    @State private var pendingUnbind: PendingFaceUnbind?
    @State private var pendingCleanup: PendingFaceCleanup?
    @State private var pendingConfirmSync: PendingFaceConfirmSync?
    @State private var pendingMemberRemoval: PendingFaceMemberRemoval?
    @State private var pendingMerge: PendingFaceMerge?
    @State private var pendingRecluster: PendingFaceRecluster?
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
        router: CommandRouter,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: (() -> Void)? = nil,
        initialRoleFilter: String? = nil
    ) {
        _viewModel = State(initialValue: FaceKeywordingViewModel(
            sessionId: sessionId,
            router: router,
            initialRoleFilter: initialRoleFilter
        ))
        self.router = router
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
                    // 通用回退文案时，不可读的原文（英文诊断）留在悬停提示里。
                    .help(viewModel.errorTooltip ?? "")
            }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: GatherTheme.success) }
            // 部分失败（encodingFailures > 0）：页面级 warning 常驻，分析成功后
            // 自动跳到审核步骤也能看见，避免"有脸没被处理"被伪装成一切正常。
            if let warning = viewModel.encodingFailureWarning {
                NativeBanner(text: warning, color: GatherTheme.warning)
            }
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
            viewModel.load()
            visibleClusterCount = FaceKeywordingViewModel.clusterPageSize
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.applyJobEvent(event)
        }
        .onChange(of: viewModel.roleFilter) { _, _ in
            visibleClusterCount = FaceKeywordingViewModel.clusterPageSize
        }
        // 破坏性命令统一门控：确认后才带 confirmed: true，取消只写可见文案。
        .gatherDestructiveConfirm(
            pending: $pendingWriteback,
            title: GatherLocalization.l("确认写回人脸关键字？"),
            confirmLabel: { _ in GatherLocalization.l("确认写回") },
            message: { $0.scopeText },
            onConfirm: { _ in Task { await viewModel.writeback(confirmed: true) } },
            onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("写回人脸关键字")) }
        )
        .gatherDestructiveConfirm(
            pending: $pendingRetry,
            title: GatherLocalization.l("确认重试失败的写回项？"),
            confirmLabel: { _ in GatherLocalization.l("重试写入") },
            message: { $0.scopeText },
            onConfirm: { _ in Task { await viewModel.retryFailed(confirmed: true) } },
            onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("重试失败写回项")) }
        )
        .gatherDestructiveConfirm(
            pending: $pendingUnbind,
            title: GatherLocalization.l("确认解除人脸绑定？"),
            confirmLabel: { _ in GatherLocalization.l("解除绑定") },
            message: { $0.scopeText },
            onConfirm: { pending in Task { await viewModel.unbind(pending.cluster, confirmed: true) } },
            onCancel: { pending in
                viewModel.reportCancellation(String(format: GatherLocalization.l("解除簇 #%lld 的绑定"), pending.cluster.id))
            }
        )
        .gatherDestructiveConfirm(
            pending: $pendingCleanup,
            title: GatherLocalization.l("确认清理人脸写回备份？"),
            confirmLabel: { _ in GatherLocalization.l("清理") },
            message: { $0.scopeText },
            onConfirm: { _ in Task { await viewModel.cleanup(confirmed: true) } },
            onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("清理人脸写回备份")) }
        )
        // 确认同步：与 sim.confirm_sync 对称的结清不可回退动作。
        .gatherDestructiveConfirm(
            pending: $pendingConfirmSync,
            title: GatherLocalization.l("确认人脸关键字同步？"),
            confirmLabel: { _ in GatherLocalization.l("确认同步") },
            message: { $0.scopeText },
            onConfirm: { _ in Task { await viewModel.confirmSync() } },
            onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("确认人脸关键字同步")) }
        )
        // 重新聚类：全量重建会还原人工绑定/合并（命令面无 confirmed 门控）。
        .gatherDestructiveConfirm(
            pending: $pendingRecluster,
            title: GatherLocalization.l("确认重新聚类？"),
            confirmLabel: { _ in GatherLocalization.l("重建全部簇") },
            message: { $0.scopeText },
            onConfirm: { _ in Task { await viewModel.recluster() } },
            onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("重新聚类")) }
        )
        // 移除成员 / 合并：命令面无 confirmed 门控，UI 仍需确认不可逆影响。
        .gatherDestructiveConfirm(
            pending: $pendingMemberRemoval,
            title: GatherLocalization.l("确认移除该成员？"),
            confirmLabel: { _ in GatherLocalization.l("移除成员") },
            message: { $0.scopeText },
            onConfirm: { pending in viewModel.removeMember(pending.member, from: pending.cluster) },
            onCancel: { pending in
                viewModel.reportCancellation(String(format: GatherLocalization.l("移除成员「%@」"), pending.member.filename))
            }
        )
        .gatherDestructiveConfirm(
            pending: $pendingMerge,
            title: GatherLocalization.l("确认合并这两个人脸簇？"),
            confirmLabel: { _ in GatherLocalization.l("合并") },
            message: { $0.scopeText },
            onConfirm: { pending in viewModel.merge(pending.cluster) },
            onCancel: { pending in
                viewModel.reportCancellation(String(format: GatherLocalization.l("合并簇 #%lld"), pending.cluster.id))
            }
        )
    }

    /// 先准备预览（无预览自动生成），再弹出带真实影响范围的确认框。
    private func requestWritebackConfirmation() async {
        guard await viewModel.prepareWritebackConfirmation(),
              let preview = viewModel.preview else { return }
        pendingWriteback = PendingFaceWriteback(
            clusterCount: viewModel.boundClusters.count,
            affectedPhotos: preview.affectedPhotos,
            itemCount: preview.items.count,
            samplePath: preview.items.first?.xmpPath
        )
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
                C1StatusCapsuleHost(sessionId: viewModel.sessionId, router: router, onOpenSettings: onOpenSettings ?? {})
                Button(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise") { viewModel.load() }
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
                        Text(GatherLocalization.l("人脸相似度下限 0.30–0.95：只有相似度不低于该值才归为同一人，数值越大分组越严格。"))
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
                        // 回落通用文案时，原始诊断只在此 tooltip 出现。
                        .help(viewModel.errorTooltip ?? "")
                }
                if viewModel.analysisPhase == .running { analysisProgress }
                HStack(spacing: 12) {
                    if viewModel.analysisPhase == .running {
                        Button(GatherLocalization.l("取消"), systemImage: "stop.fill") { viewModel.cancel() }
                            .foregroundStyle(GatherTheme.error)
                    } else if viewModel.analysisPhase == .done {
                        Button(GatherLocalization.l("仅重新聚类"), systemImage: "arrow.triangle.2.circlepath") {
                            // 先弹确认（影响面真实计数），确认分支才发 fkw.recluster。
                            let impact = viewModel.reclusterImpact()
                            pendingRecluster = PendingFaceRecluster(
                                clusterCount: impact.clusterCount,
                                boundClusterCount: impact.boundClusterCount
                            )
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
    /// 红色「移除」。移除不可逆，先弹确认（旧版「点击即移除」已删除）。
    private func memberList(_ cluster: FaceClusterData) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(cluster.members.enumerated()), id: \.element.memberId) { index, member in
                    MemberRowView(index: index, member: member) {
                        pendingMemberRemoval = PendingFaceMemberRemoval(member: member, cluster: cluster)
                    }
                    Divider().opacity(0.5)
                }
            }
        }
        .frame(maxHeight: 210)
    }

    /// TS editor：角色名/关键字输入 + 绑定/更新绑定 + 解除绑定（解除绑定撤销
    /// 已写入关键词，经确认弹窗后才执行）。
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
                    viewModel.bind(cluster)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                if cluster.binding != nil {
                    Button(GatherLocalization.l("解除绑定")) {
                        pendingUnbind = PendingFaceUnbind(cluster: cluster)
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
                    guard let targetId = viewModel.mergeTargetId,
                          let target = candidates.first(where: { $0.id == targetId }) else {
                        viewModel.reportInvalidMergeTarget()
                        return
                    }
                    pendingMerge = PendingFaceMerge(cluster: cluster, target: target)
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
                Button(GatherLocalization.l("确认写回"), systemImage: "square.and.arrow.down") {
                    Task { await requestWritebackConfirmation() }
                }
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

    private func xmpPreviewRow(_ item: FaceKwWritebackItem) -> some View {
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

    private func xmpMarkerText(_ item: FaceKwWritebackItem) -> String {
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
    private func resultSection(_ result: FaceKwWritebackResult) -> some View {
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
                Button(GatherLocalization.l("重试失败项")) {
                    pendingRetry = PendingFaceRetry(
                        paths: result.failedItems.map { $0.xmpPath.isEmpty ? $0.photoPath : $0.xmpPath }
                    )
                }
                .disabled(viewModel.isWritingBack)
                .help(GatherLocalization.l("没有失败项"))
            }
            Button(GatherLocalization.l("Capture One 重新加载")) { Task { await viewModel.reloadCaptureOne() } }
                .disabled(viewModel.isWritingBack)
            Button(GatherLocalization.l("确认同步")) { pendingConfirmSync = PendingFaceConfirmSync() }
                .disabled(viewModel.isWritingBack)
            if viewModel.isSyncConfirmed {
                Button(GatherLocalization.l("清理备份"), role: .destructive) {
                    pendingCleanup = PendingFaceCleanup(writtenCount: viewModel.writebackResult?.written ?? 0)
                }
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
