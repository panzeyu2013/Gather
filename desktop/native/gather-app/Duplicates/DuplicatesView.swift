// Phase 3.6：重复检测与处置 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/SessionDetail/Duplicates.tsx。
// 对齐项：
// - 三档预设（严格 2 / 均衡 4 / 宽松 7，TS L309-343）；阈值滑块始终可拖（TS L332-340）；
// - 推荐保留徽章（TS L68-75：score = fileSize*1000 + mtime ms，最高分者，平手取先出现者）；
// - 成员上限 12 + 展开/收起（TS L10/77-79/135-145）；
// - 分段 Tab 计数徽标（TS L366-379）；
// - 成员文件大小（TS L42-44）；
// - 100 组分页 + 加载更多（TS L11/291-296/406-416）；
// - 空态区分：未扫描 → 先运行扫描；扫描过无该类型结果 → 对应空态（TS L383-393）；
// - 操作后局部更新（TS L201-270）：resolve/toggle 成功后就地 patch，避免整页重拉。
import SwiftUI
import GatherCore

private let defaultMemberLimit = 12
private let groupPageSize = 100

/// 待确认的重复组处置：影响范围（保留/丢弃的数量与文件）在弹窗 message 中呈现。
private struct PendingGroupResolution: Identifiable {
    let group: DuplicateGroup
    let resolution: DupResolution
    /// 推荐保留文件名：由视图层（MainActor）预计算后带入，文件级确认上下文
    /// 不直接调用 DuplicatesViewModel 的隔离静态方法。
    let recommendedFilename: String?

    var id: String { "\(group.id)-\(resolution.rawValue)" }

    var confirmLabel: String {
        resolution == .keepOne ? GatherLocalization.l("保留最佳，丢弃其余") : GatherLocalization.l("全部保留")
    }

    /// 保留最佳/全部保留都只改数据库标记（不删文件、可再改回），不使用红色破坏性语义。
    var confirmRole: ButtonRole? { nil }

    var scopeText: String {
        let total = group.memberCount
        switch resolution {
        case .keepOne:
            let kept = recommendedFilename ?? GatherLocalization.l("推荐照片")
            return String(
                format: GatherLocalization.l("组 #%lld 共 %lld 张：仅保留推荐「%@」，其余 %lld 张标记为丢弃；被丢弃的照片会在导出时被排除，不会删除文件。"),
                group.id, total, kept, max(0, total - 1)
            )
        case .keepAll:
            return String(
                format: GatherLocalization.l("组 #%lld 共 %lld 张全部标记为保留，不再从导出中排除任何成员。"),
                group.id, total
            )
        }
    }

    var cancelCopy: String {
        resolution == .keepOne
            ? String(format: GatherLocalization.l("保留最佳（组 #%lld）"), group.id)
            : String(format: GatherLocalization.l("全部保留（组 #%lld）"), group.id)
    }
}

/// 待确认的成员保留状态：目标状态由点击时的意图决定，不在命令层翻转。
private struct PendingMemberDecision: Identifiable {
    let member: DuplicateGroupMember
    let isKept: Bool

    var id: String { "\(member.id)-\(isKept)" }

    var confirmLabel: String {
        isKept ? GatherLocalization.l("保留此照片") : GatherLocalization.l("丢弃此照片")
    }

    /// 保留/丢弃都只改数据库标记（不删文件、可反向操作），不使用红色破坏性语义。
    var confirmRole: ButtonRole? { nil }

    var scopeText: String {
        isKept
            ? String(format: GatherLocalization.l("将「%@」（%@）改回保留，重新参与导出。"), member.filename, member.filepath)
            : String(format: GatherLocalization.l("将「%@」（%@）标记为丢弃；该照片会从重复组中排除并在导出时被跳过，不会删除文件。"), member.filename, member.filepath)
    }

    var cancelCopy: String {
        isKept
            ? String(format: GatherLocalization.l("保留「%@」"), member.filename)
            : String(format: GatherLocalization.l("丢弃「%@」"), member.filename)
    }
}

// 对齐 TS DUP_THRESHOLD_PRESETS：严格 2 / 均衡 4 / 宽松 7（Duplicates.tsx:160-166）。
public enum VisualPreset: String, CaseIterable {
    case strict
    case balanced
    case loose

    public var threshold: Int {
        switch self {
        case .strict: return 2
        case .balanced: return 4
        case .loose: return 7
        }
    }

    public var label: String {
        switch self {
        case .strict: return GatherLocalization.l("严格")
        case .balanced: return GatherLocalization.l("均衡")
        case .loose: return GatherLocalization.l("宽松")
        }
    }
}

@MainActor
@Observable
public final class DuplicatesViewModel {
    private let client: NativeCommandClient
    public let sessionId: String
    private(set) public var groups: [DuplicateGroup] = []
    private(set) public var scanResult: DuplicateScanResult?
    private(set) public var isScanning = false
    private(set) public var isLoading = false
    private(set) public var errorMessage: String?
    private(set) public var notice: String?
    /// dup.scan 实时进度（JobService duplicateScan 任务事件驱动）。
    private(set) public var scanProgressCurrent = 0
    private(set) public var scanProgressTotal = 0
    private(set) public var scanProgressPhase = "duplicate.read"
    private(set) public var scanJobId: String?
    public var threshold = 4
    public var showExact = true
    /// 产出当前 scanResult 时使用的阈值（第三轮审计 C-#7）。
    /// 改阈值/预设后旧数字必须标记为过期——否则「视觉相似 N 组」是上一个档位的结论，
    /// 却摆在新档位控件旁边冒充当前设置的结果（N03 的同类）。
    private(set) public var scannedThreshold: Int?

    /// 当前阈值与产出结果的阈值不一致（且确有结果）→ 数字已过期。
    public var isScanResultStale: Bool {
        guard scanResult != nil, let scannedThreshold else { return false }
        return scannedThreshold != threshold
    }
    private(set) public var visibleGroupCount = groupPageSize
    private var expandedGroupIds: Set<Int> = []

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
    }

    // MARK: - 预设 / 阈值（对齐 TS L159-166、309-343）

    public var activePreset: VisualPreset? {
        if threshold == VisualPreset.strict.threshold { return .strict }
        if threshold == VisualPreset.balanced.threshold { return .balanced }
        if threshold == VisualPreset.loose.threshold { return .loose }
        return nil
    }

    public func selectPreset(_ preset: VisualPreset) {
        threshold = preset.threshold
    }

    // MARK: - 数据加载

    /// dup.groups 拉取（对齐 TS loadGroups：async + loading 态，命令契约不变）。
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            groups = try await client.executeAsync("dup.groups", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: [DuplicateGroup].self)
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func scan() async {
        isScanning = true
        scanProgressCurrent = 0
        scanProgressTotal = 0
        scanProgressPhase = "duplicate.read"
        scanJobId = nil
        defer { isScanning = false }
        do {
            let scannedAt = threshold
            scanResult = try await client.executeAsync("dup.scan", params: [
                "sessionId": .string(sessionId),
                "visualThreshold": .number(Double(threshold)),
            ]).decoded(as: DuplicateScanResult.self)
            // 记录产生这份结果的阈值：之后改阈值时数字会被标记为过期（C-#7）。
            scannedThreshold = scannedAt
            notice = GatherLocalization.l("重复扫描完成")
            await load()
        } catch {
            let text = NativeCommandClient.message(for: error)
            if text.localizedCaseInsensitiveContains("cancelled") {
                notice = GatherLocalization.l("重复扫描已取消")
            } else {
                errorMessage = text
            }
        }
    }

    /// jobs:progress 订阅入口（对齐 FaceKeywording/Export：JobService
    /// duplicateScan 任务的进度/终态帧）。
    public func applyJobEvent(_ event: GatherJobEvent) {
        guard event.job.type == .duplicateScan,
              event.job.scopeType == "session",
              event.job.scopeId == sessionId else { return }
        scanJobId = event.job.id
        guard !event.isTerminal else { return }
        scanProgressCurrent = event.update.current ?? event.job.progressCurrent
        scanProgressTotal = event.update.total ?? event.job.progressTotal
        scanProgressPhase = event.update.phase ?? event.update.message ?? "duplicate.read"
    }

    /// 取消扫描：优先用事件记录的 jobId，事件未到达时按会话内活跃任务兜底。
    public func cancelScan() {
        guard let jobId = scanJobId ?? activeScanJobId() else { return }
        do {
            _ = try client.execute("jobs.cancel", params: ["jobId": .string(jobId)])
            notice = GatherLocalization.l("已请求取消重复扫描")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    private func activeScanJobId() -> String? {
        let jobs = (try? client.execute("jobs.list", params: ["includeCheckpoint": .bool(false)]).decoded(as: [AnalysisJobData].self)) ?? []
        return jobs.first { job in
            job.type == .duplicateScan && job.scopeId == sessionId &&
                ["queued", "running", "cancelling"].contains(job.status.rawValue)
        }?.id
    }

    // MARK: - 组 / 成员操作（本地 patch，对齐 TS L201-270）
    // dup.resolve / dup.resolve_member 是命令层 confirmed 门控的破坏性命令：
    // `confirmed` 只能由视图层确认弹窗传入 true；取消路径根本不会调用这里。

    public func resolveGroup(_ group: DuplicateGroup, resolution: DupResolution, confirmed: Bool) {
        do {
            _ = try client.execute("dup.resolve", params: [
                "groupId": .number(Double(group.id)),
                "resolution": .string(resolution.rawValue),
                "confirmed": .bool(confirmed),
            ])
            notice = String(format: GatherLocalization.l("已处理重复组 #%lld"), group.id)
            // 处置会改变导出过滤（removed/丢弃语义），广播供常驻页按域刷新。
            GatherEventCenter.postDomainChange(.duplicates, sessionId: sessionId)
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
            var updated = groups[index]
            updated.resolution = resolution.rawValue
            let keptMemberId = resolution == .keepAll ? nil : Self.recommendation(in: updated)?.id
            updated.members = updated.members.map { member in
                var patched = member
                patched.isKept = resolution == .keepAll || member.id == keptMemberId
                patched.resolution = resolution.rawValue
                return patched
            }
            groups[index] = updated
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 成员保留状态（用户确认后的目标状态；旧实现「无参翻转」在确认前就改变
    /// 语义，已删除）。`confirmed` 由确认弹窗传入。
    public func setMemberKept(_ member: DuplicateGroupMember, isKept: Bool, confirmed: Bool) {
        do {
            _ = try client.execute("dup.resolve_member", params: [
                "memberId": .number(Double(member.id)),
                "isKept": .bool(isKept),
                "confirmed": .bool(confirmed),
            ])
            GatherEventCenter.postDomainChange(.duplicates, sessionId: sessionId)
            guard let groupIndex = groups.firstIndex(where: { $0.members.contains(where: { $0.id == member.id }) }),
                  let memberIndex = groups[groupIndex].members.firstIndex(where: { $0.id == member.id })
            else { return }
            groups[groupIndex].members[memberIndex].isKept = isKept
            groups[groupIndex].members[memberIndex].resolution = isKept
                ? DupResolution.keepAll.rawValue
                : DupResolution.keepOne.rawValue
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 取消破坏性动作：给出可见文案（不静默 return，也不发命令）。
    public func reportCancellation(_ action: String) {
        notice = GatherLocalization.cancellationNotice(action)
        errorMessage = nil
    }

    // MARK: - 分页 / 展开折叠

    public func resetPagination() {
        visibleGroupCount = groupPageSize
        expandedGroupIds.removeAll()
    }

    public func loadMoreGroups() {
        visibleGroupCount += groupPageSize
    }

    public func isExpanded(_ groupId: Int) -> Bool {
        expandedGroupIds.contains(groupId)
    }

    public func toggleExpanded(_ groupId: Int) {
        if expandedGroupIds.contains(groupId) {
            expandedGroupIds.remove(groupId)
        } else {
            expandedGroupIds.insert(groupId)
        }
    }

    // MARK: - 派生数据

    public var filteredGroups: [DuplicateGroup] {
        showExact
            ? groups.filter { $0.groupType == .exact }
            : groups.filter { $0.groupType == .visual }
    }

    public var visibleFilteredGroups: [DuplicateGroup] {
        Array(filteredGroups.prefix(visibleGroupCount))
    }

    public var remainingGroupCount: Int {
        max(0, filteredGroups.count - visibleGroupCount)
    }

    public var exactGroupCount: Int {
        groups.filter { $0.groupType == .exact }.count
    }

    public var visualGroupCount: Int {
        groups.count - exactGroupCount
    }

    // MARK: - 推荐保留（对齐 TS Duplicates.tsx:68-75 与 duplicate.service.ts resolveGroup）
    // score = fileSize*1000 + mtime ms；最高分者为推荐保留，平手取先出现者。

    public static func recommendation(in group: DuplicateGroup) -> DuplicateGroupMember? {
        var best: DuplicateGroupMember?
        var bestScore: Int64 = -1
        for member in group.members {
            let score = memberScore(member)
            if score > bestScore {
                bestScore = score
                best = member
            }
        }
        return best
    }

    public static func memberScore(_ member: DuplicateGroupMember) -> Int64 {
        Int64(member.fileSize ?? 0) * 1000 + mtimeMilliseconds(member.fileMtime)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func mtimeMilliseconds(_ value: String?) -> Int64 {
        guard let value, !value.isEmpty else { return 0 }
        if let date = iso8601WithFractional.date(from: value) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        if let date = iso8601.date(from: value) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        return 0
    }
}

public struct DuplicatesView: View {
    @State private var viewModel: DuplicatesViewModel
    private let router: CommandRouter
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    private let onOpenSettings: () -> Void
    /// 打开成员照片（第三轮审计 E）：透传到分组卡的成员行。
    private let onOpenPhoto: ((String) -> Void)?
    /// 破坏性动作的待确认上下文：非空即弹确认框；命令只在确认分支发出。
    @State private var pendingResolution: PendingGroupResolution?
    @State private var pendingMemberDecision: PendingMemberDecision?
    /// 高级扫描参数（阈值）的展开状态（F13：与相似度/人脸页同一套渐进披露规则）。
    @State private var showAdvancedScan = false

    /// 外壳注入 VM（第三轮审计 D-P0）：扫描结果/阈值/分组展开/分页都挂在 VM 上，
    /// 页面切走即销毁——注入同一个 VM 才能在切回时保留这些状态。
    init(
        viewModel: DuplicatesViewModel,
        router: CommandRouter,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {},
        onOpenPhoto: ((String) -> Void)? = nil
    ) {
        self.onOpenPhoto = onOpenPhoto
        _viewModel = State(initialValue: viewModel)
        self.router = router
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    init(
        sessionId: String,
        router: CommandRouter,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {},
        onOpenPhoto: ((String) -> Void)? = nil
    ) {
        self.onOpenPhoto = onOpenPhoto
        _viewModel = State(initialValue: DuplicatesViewModel(sessionId: sessionId, router: router))
        self.router = router
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.errorMessage { NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error), color: GatherTheme.error) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: GatherTheme.success) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scanControls
                    if viewModel.isLoading || viewModel.isScanning {
                        loadingIndicator
                    }
                    if let result = viewModel.scanResult {
                        Text(String(format: GatherLocalization.l("完全重复：%lld 组 · 视觉相似：%lld 组 · 总计重复：%lld 张"), result.exactGroups.count, result.visualGroups.count, result.totalDuplicates))
                            .font(.callout).foregroundStyle(.secondary)
                        // C-#7：阈值改过之后旧数字必须显式标为过期，不能让上一个档位
                        // 的结论冒充当前设置的结果。
                        if viewModel.isScanResultStale {
                            Label(
                                String(format: GatherLocalization.l("当前匹配强度为 %lld，上面的结果来自 %lld；请重新扫描。"), viewModel.threshold, viewModel.scannedThreshold ?? viewModel.threshold),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.callout)
                            .foregroundStyle(GatherTheme.warning)
                        }
                    }
                    Text(GatherLocalization.l("扫描会先识别内容完全一致的文件，再查找视觉近似候选；不会删除照片。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    tabSelector
                    if viewModel.filteredGroups.isEmpty {
                        emptyState
                    } else {
                        // 惰性渲染：大组列表不预先布局全部卡片（ScrollView 内）。
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(viewModel.visibleFilteredGroups, id: \.id) { group in groupCard(group) }
                            if viewModel.remainingGroupCount > 0 {
                                Button(String(format: GatherLocalization.l("加载更多（还有 %lld 组）"), viewModel.remainingGroupCount)) {
                                    viewModel.loadMoreGroups()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(24)
            }
            // 成员保留状态确认挂在 ScrollView 节点：与组处置确认（外层 VStack）
            // 分属不同视图节点，避免两个 confirmationDialog 抢同一呈现宿主。
            .gatherDestructiveConfirm(
                pending: $pendingMemberDecision,
                title: GatherLocalization.l("确认更改这张照片的保留状态？"),
                confirmLabel: { $0.confirmLabel },
                message: { $0.scopeText },
                onConfirm: { pending in
                    viewModel.setMemberKept(pending.member, isKept: pending.isKept, confirmed: true)
                },
                onCancel: { pending in
                    viewModel.reportCancellation(pending.cancelCopy)
                }
            )
        }
        .background(GatherTheme.windowBackground)
        .task { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.applyJobEvent(event)
        }
        // 组处置 / 成员保留状态：确认后才发 dup.resolve / dup.resolve_member，
        // 取消只写可见文案（不发命令）。
        .gatherDestructiveConfirm(
            pending: $pendingResolution,
            title: GatherLocalization.l("确认处理这个重复组？"),
            confirmLabel: { $0.confirmLabel },
            confirmRole: { $0.confirmRole },
            message: { $0.scopeText },
            onConfirm: { pending in
                viewModel.resolveGroup(pending.group, resolution: pending.resolution, confirmed: true)
            },
            onCancel: { pending in
                viewModel.reportCancellation(pending.cancelCopy)
            }
        )
        .sessionPageChrome(
            subtitle: GatherLocalization.l("重复照片检测"),
            selection: .tab(.duplicates),
            onBrowse: { onOpenGallery(viewModel.sessionId) },
            onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
            onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onBack()
                } label: {
                    Label(GatherLocalization.l("返回"), systemImage: "chevron.backward")
                }
                .help(GatherLocalization.l("返回到上一页"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                C1StatusCapsuleHost(sessionId: viewModel.sessionId, router: router, onOpenSettings: onOpenSettings)
                Button(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise") {
                    Task { await viewModel.load() }
                }
                .disabled(viewModel.isLoading || viewModel.isScanning)
                .help(GatherLocalization.l("刷新重复照片"))
            }
        }
    }

    /// 加载/扫描进度指示（对齐旧版 Duplicates.module.css .loading「加载中…」灰字）。
    /// 扫描中显示相位文案 + (n/N) 计数 + 取消按钮（JobService 进度事件驱动）。
    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if viewModel.isScanning {
                Text(GatherLocalization.progressPhaseText(viewModel.scanProgressPhase))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if viewModel.scanProgressTotal > 0 {
                    Text("\(viewModel.scanProgressCurrent)/\(viewModel.scanProgressTotal)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(GatherLocalization.l("取消"), systemImage: "stop.fill") {
                    viewModel.cancelScan()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(GatherLocalization.l("加载中…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 三档预设 = 系统分段控件（取代手绘选中底色/描边的 Button 组）。
            LabeledContent(GatherLocalization.l("匹配强度")) {
                Picker(GatherLocalization.l("匹配强度"), selection: presetBinding) {
                    ForEach(VisualPreset.allCases, id: \.self) { preset in
                        Text(preset.label).tag(VisualPreset?.some(preset))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                .disabled(viewModel.isScanning)
            }
            // F13：阈值滑杆与范围说明属于高级参数——相似度、人脸、重复三页
            // 统一「预设优先 → 高级按需展开」；旧实现三页规则各不相同，
            // 重复页默认把滑杆、范围说明和预设一起摆在首屏。
            // （滑块始终可拖，预设仅负责置值，对齐 TS L332-340。）
            DisclosureGroup(isExpanded: $showAdvancedScan) {
                HStack(spacing: 8) {
                    SliderInputIntView(title: GatherLocalization.l("视觉相似阈值"), value: $viewModel.threshold, range: 0...10)
                    Text(GatherLocalization.l("0 (严格) — 10 (宽松)"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } label: {
                Text(GatherLocalization.l("高级：相似阈值"))
                    .font(.callout)
            }
            .disabled(viewModel.isScanning)

            HStack(spacing: 12) {
                // 本页唯一的「开始扫描」主动作（空态不再重复放一个同权按钮）。
                Button(viewModel.isScanning ? GatherLocalization.l("扫描中…") : GatherLocalization.l("开始扫描"), systemImage: "magnifyingglass") {
                    Task { await viewModel.scan() }
                }
                .gatherPrimaryActionButton()
                .disabled(viewModel.isScanning)
                if !viewModel.isScanning, let preset = viewModel.activePreset {
                    Text(String(format: GatherLocalization.l("当前档位：%@"), preset.label))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .gatherCard()
    }

    /// 预设选择绑定：阈值为非预设值时保持「无选中」（不虚报档位）。
    private var presetBinding: Binding<VisualPreset?> {
        Binding(
            get: { viewModel.activePreset },
            set: { preset in
                guard let preset else { return }
                viewModel.selectPreset(preset)
            }
        )
    }

    private var tabSelector: some View {
        // 计数是内容语义：用普通文本（不再以 .footnote 10pt 承载）。
        Picker(GatherLocalization.l("类型"), selection: $viewModel.showExact) {
            Text("\(GatherLocalization.l("完全重复")) · \(viewModel.exactGroupCount)").tag(true)
            Text("\(GatherLocalization.l("视觉相似")) · \(viewModel.visualGroupCount)").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 300)
        .accessibilityLabel(GatherLocalization.l("重复类型"))
        .onChange(of: viewModel.showExact) { _, _ in
            viewModel.resetPagination()
        }
    }

    /// 空态 / 失败态：全部走系统 ContentUnavailableView；
    /// 加载失败必须给重试出口（不渲染误导性的「先运行扫描」）。
    @ViewBuilder
    private var emptyState: some View {
        if let error = viewModel.errorMessage, viewModel.scanResult == nil {
            ContentUnavailableView {
                Label(GatherLocalization.l("载入重复照片失败"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(GatherLocalization.l("重试")) { Task { await viewModel.load() } }
                    .disabled(viewModel.isLoading)
            }
        } else if viewModel.scanResult == nil {
            // F13：空态不再放第二个同权「开始扫描」——上面控制卡里的主动作就是它。
            ContentUnavailableView {
                Label(GatherLocalization.l("尚未扫描"), systemImage: "square.on.square")
            } description: {
                Text(GatherLocalization.l("用上方的「开始扫描」检测内容完全一致的文件与视觉近似候选。"))
            }
        } else if viewModel.showExact {
            ContentUnavailableView(
                GatherLocalization.l("未发现完全重复的照片"),
                systemImage: "square.on.square",
                description: Text(GatherLocalization.l("当前工作区没有内容完全一致的文件。"))
            )
        } else {
            ContentUnavailableView(
                GatherLocalization.l("未发现视觉相似的照片"),
                systemImage: "square.on.square",
                description: Text(GatherLocalization.l("可适当放宽匹配强度后重新扫描。"))
            )
        }
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        // 推荐保留与卡片徽章同源；在视图（MainActor）上下文预计算，供确认弹窗
        // 展示影响范围（保留哪一张、丢弃几张）。
        let recommendedFilename = DuplicatesViewModel.recommendation(in: group)?.filename
        return GroupCardView(
            group: group,
            viewModel: viewModel,
            onResolve: { group, resolution in
                pendingResolution = PendingGroupResolution(
                    group: group,
                    resolution: resolution,
                    recommendedFilename: recommendedFilename
                )
            },
            onSetMemberKept: { member, isKept in
                pendingMemberDecision = PendingMemberDecision(member: member, isKept: isKept)
            },
            onOpenPhoto: onOpenPhoto
        )
    }
}

/// 分组卡（对齐旧版 .groupCard：surface + 1px 边框 + radius-md + hover 反馈）。
/// 处置动作只上抛意图，确认弹窗与命令由 DuplicatesView 统一门控。
private struct GroupCardView: View {
    let group: DuplicateGroup
    let viewModel: DuplicatesViewModel
    let onResolve: (DuplicateGroup, DupResolution) -> Void
    let onSetMemberKept: (DuplicateGroupMember, Bool) -> Void
    /// 打开成员照片（第三轮审计 E）：成员卡原先只有「保留/丢弃」，
    /// 用户看不到照片本体，无法判断该保留哪一张。
    var onOpenPhoto: ((String) -> Void)? = nil

    var body: some View {
        let recommendedId = DuplicatesViewModel.recommendation(in: group)?.id
        let members = viewModel.isExpanded(group.id) ? group.members : Array(group.members.prefix(defaultMemberLimit))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(groupTitle)
                    .font(.headline)
                if let resolution = group.resolution {
                    GatherBadge(
                        resolution == DupResolution.keepOne.rawValue
                            ? GatherLocalization.l("保留最佳")
                            : GatherLocalization.l("全部保留"),
                        tone: .success
                    )
                }
                Spacer()
                Menu(GatherLocalization.l("处理")) {
                    Button(GatherLocalization.l("保留最佳")) { onResolve(group, .keepOne) }
                    Button(GatherLocalization.l("保留全部")) { onResolve(group, .keepAll) }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(members, id: \.id) { member in
                    memberCard(member, recommended: member.id == recommendedId)
                }
            }
            if group.members.count > defaultMemberLimit {
                HStack {
                    Spacer()
                    Button(viewModel.isExpanded(group.id) ? GatherLocalization.l("收起") : String(format: GatherLocalization.l("展开全部（共 %lld 张）"), group.members.count)) {
                        viewModel.toggleExpanded(group.id)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
        .gatherCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groupTitle)
    }

    private var groupTitle: String {
        let type = group.groupType == .exact ? GatherLocalization.l("完全重复") : GatherLocalization.l("视觉相似")
        return String(format: GatherLocalization.l("%@ · %lld 张照片"), type, group.memberCount)
    }

    private func memberCard(_ member: DuplicateGroupMember, recommended: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // 对齐旧版 .memberThumb：1:1 方形、256 解码、10px 圆角（css:319-325）。
            PhotoThumbnailView(path: member.filepath, size: 256, placeholderSize: CGSize(width: 150, height: 150))
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous))
                .accessibilityLabel(Text(member.filename))
                .overlay(alignment: .topTrailing) {
                    if recommended {
                        GatherBadge(GatherLocalization.l("推荐"), tone: .accent)
                            .padding(4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // 保留/丢弃文字徽标：红绿描边之外的冗余指示，
                    // 色弱/色盲用户可辨（复用成员按钮「保留/丢弃」词）。
                    GatherBadge(
                        member.isKept ? GatherLocalization.l("保留") : GatherLocalization.l("丢弃"),
                        tone: member.isKept ? .success : .error
                    )
                    .padding(4)
                }
            Text(member.filename).font(.callout).lineLimit(1)
            if let fileSize = member.fileSize {
                Text(String(format: GatherLocalization.l("%.1f MB"), Double(fileSize) / 1024 / 1024))
                    .font(.callout).foregroundStyle(.secondary)
            }
            // 按钮文案 = 点击后执行的动作（不再显示当前状态，避免标签与动作相反）。
            HStack(spacing: 6) {
                if let onOpenPhoto {
                    Button(GatherLocalization.l("查看照片")) { onOpenPhoto(member.photoId) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(GatherLocalization.l("在图库中打开这张照片"))
                }
                Button(member.isKept ? GatherLocalization.l("丢弃") : GatherLocalization.l("保留")) {
                    onSetMemberKept(member, !member.isKept)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(member.isKept ? GatherLocalization.l("丢弃此照片") : GatherLocalization.l("保留此照片"))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .fill(member.isKept ? GatherTheme.contentBackground : GatherTheme.secondaryContentBackground)
        )
        .overlay(
            // 保留/排除用语义色描边区分；排除态不靠整卡降透明（可读性）。
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .strokeBorder((member.isKept ? GatherTheme.success : GatherTheme.error).opacity(0.5), lineWidth: 1)
        )
        .contextMenu {
            Button(GatherLocalization.l("保留")) {
                if !member.isKept { onSetMemberKept(member, true) }
            }
            Button(GatherLocalization.l("丢弃")) {
                if member.isKept { onSetMemberKept(member, false) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(member.filename)，\(member.isKept ? GatherLocalization.l("保留") : GatherLocalization.l("丢弃"))")
    }
}
