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
    private let commands: CommandSurface
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
    private(set) public var visibleGroupCount = groupPageSize
    private var expandedGroupIds: Set<Int> = []

    public init(sessionId: String, commands: CommandSurface) {
        self.sessionId = sessionId
        self.commands = commands
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
            groups = try await commands.duplicate.groups(DupGroupsParams(sessionId: sessionId))
            errorMessage = nil
        } catch {
            errorMessage = GatherErrorText.message(for: error)
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
            scanResult = try await commands.duplicate.scan(
                DupScanParams(sessionId: sessionId, visualThreshold: Double(threshold)))
            notice = GatherLocalization.l("重复扫描完成")
            await load()
        } catch {
            let text = GatherErrorText.message(for: error)
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
    public func cancelScan() async {
        let jobId: String?
        if let scanJobId {
            jobId = scanJobId
        } else {
            jobId = await activeScanJobId()
        }
        guard let jobId else { return }
        do {
            _ = try await commands.jobs.cancel(JobCancelParams(jobId: jobId))
            notice = GatherLocalization.l("已请求取消重复扫描")
        } catch {
            errorMessage = GatherErrorText.message(for: error)
        }
    }

    private func activeScanJobId() async -> String? {
        let jobs = (try? await commands.jobs.list(JobListParams())) ?? []
        return jobs.first { job in
            job.type == .duplicateScan && job.scopeId == sessionId &&
                ["queued", "running", "cancelling"].contains(job.status.rawValue)
        }?.id
    }

    // MARK: - 组 / 成员操作（本地 patch，对齐 TS L201-270）

    public func resolveGroup(_ group: DuplicateGroup, resolution: DupResolution) async {
        do {
            try await commands.duplicate.resolve(
                DupResolveParams(groupId: group.id, resolution: resolution, confirmed: true))
            notice = String(format: GatherLocalization.l("已处理重复组 #%lld"), group.id)
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
            errorMessage = GatherErrorText.message(for: error)
        }
    }

    public func toggle(_ member: DuplicateGroupMember) async {
        do {
            try await commands.duplicate.resolveMember(
                DupResolveMemberParams(memberId: member.id, isKept: !member.isKept, confirmed: true))
            guard let groupIndex = groups.firstIndex(where: { $0.members.contains(where: { $0.id == member.id }) }),
                  let memberIndex = groups[groupIndex].members.firstIndex(where: { $0.id == member.id })
            else { return }
            let isKept = !groups[groupIndex].members[memberIndex].isKept
            groups[groupIndex].members[memberIndex].isKept = isKept
            groups[groupIndex].members[memberIndex].resolution = isKept
                ? DupResolution.keepAll.rawValue
                : DupResolution.keepOne.rawValue
        } catch {
            errorMessage = GatherErrorText.message(for: error)
        }
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
    private let commands: CommandSurface
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    private let onOpenSettings: () -> Void

    init(
        sessionId: String,
        commands: CommandSurface,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: DuplicatesViewModel(sessionId: sessionId, commands: commands))
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
        }
        .background(Color.gatherBackground)
        .task { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.applyJobEvent(event)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(GatherLocalization.l("返回"), systemImage: "chevron.left", action: onBack).buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text(GatherLocalization.l("重复照片检测")).font(.largeTitle.weight(.bold))
                    Text(String(format: GatherLocalization.l("工作区 %@"), String(viewModel.sessionId.prefix(8)))).foregroundStyle(.secondary)
                }
                Spacer()
                C1StatusCapsuleHost(
                    sessionId: viewModel.sessionId,
                    culling: commands.culling,
                    onOpenSettings: onOpenSettings
                )
                Button(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise") { Task { await viewModel.load() } }
            }
            SessionTabBar(
                selection: .tab(.duplicates),
                onBrowse: { onOpenGallery(viewModel.sessionId) },
                onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
                onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
            )
        }
        .padding(24)
        .background(Color.gatherSurface)
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
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(GatherLocalization.l("取消"), systemImage: "stop.fill") {
                    Task { await viewModel.cancelScan() }
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
            HStack(spacing: 10) {
                Text(GatherLocalization.l("匹配强度")).font(.callout).foregroundStyle(.secondary)
                ForEach(VisualPreset.allCases, id: \.self) { preset in
                    Button(preset.label) { viewModel.selectPreset(preset) }
                        .buttonStyle(.bordered)
                        .tint(GatherTheme.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(viewModel.activePreset == preset ? GatherTheme.primarySoft : Color.clear)
                        )
                        .foregroundStyle(viewModel.activePreset == preset ? GatherTheme.primary : Color.primary)
                        .disabled(viewModel.isScanning)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                // 对齐旧版 range 滑块（0–10，18px thumb），替代 Stepper；
                // 滑块始终可拖，预设仅负责置值（TS L332-340）。
                HStack(spacing: 8) {
                    SliderInputIntView(title: GatherLocalization.l("视觉相似阈值"), value: $viewModel.threshold, range: 0...10)
                    Text(GatherLocalization.l("0 (严格) — 10 (宽松)"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(viewModel.isScanning ? GatherLocalization.l("扫描中…") : GatherLocalization.l("开始扫描"), systemImage: "magnifyingglass") {
                    Task { await viewModel.scan() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isScanning)
                Spacer()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gatherSurface))
    }

    private var tabSelector: some View {
        Picker(GatherLocalization.l("类型"), selection: $viewModel.showExact) {
            (Text(GatherLocalization.l("完全重复")) + Text(" · \(viewModel.exactGroupCount)").font(.footnote)).tag(true)
            (Text(GatherLocalization.l("视觉相似")) + Text(" · \(viewModel.visualGroupCount)").font(.footnote)).tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 300)
        .onChange(of: viewModel.showExact) { _, _ in
            viewModel.resetPagination()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.scanResult == nil {
            GatherEmptyState(
                icon: "square.on.square",
                title: GatherLocalization.l("先运行扫描"),
                message: GatherLocalization.l("点击「开始扫描」按钮检测重复照片")
            )
        } else if viewModel.showExact {
            GatherEmptyState(icon: "square.on.square", title: GatherLocalization.l("未发现完全重复的照片"))
        } else {
            GatherEmptyState(icon: "square.on.square", title: GatherLocalization.l("未发现视觉相似的照片"))
        }
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        GroupCardView(group: group, viewModel: viewModel)
    }
}

/// 分组卡（对齐旧版 .groupCard：surface + 1px 边框 + radius-md + hover 反馈）。
private struct GroupCardView: View {
    let group: DuplicateGroup
    let viewModel: DuplicatesViewModel

    @State private var hovering = false

    var body: some View {
        let recommendedId = DuplicatesViewModel.recommendation(in: group)?.id
        let members = viewModel.isExpanded(group.id) ? group.members : Array(group.members.prefix(defaultMemberLimit))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(groupTitle)
                    .font(.headline)
                if let resolution = group.resolution {
                    Text(resolution == DupResolution.keepOne.rawValue ? GatherLocalization.l("· 保留最佳") : GatherLocalization.l("· 保留全部"))
                        .font(.footnote).foregroundStyle(GatherTheme.success)
                }
                Spacer()
                Menu(GatherLocalization.l("处理")) {
                    Button(GatherLocalization.l("保留最佳")) {
                        Task { await viewModel.resolveGroup(group, resolution: .keepOne) }
                    }
                    Button(GatherLocalization.l("保留全部")) {
                        Task { await viewModel.resolveGroup(group, resolution: .keepAll) }
                    }
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
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hovering ? GatherTheme.primary.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering = $0 }
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
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if recommended {
                        Text(GatherLocalization.l("推荐"))
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(GatherTheme.primary))
                            .padding(4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // 保留/丢弃文字徽标：红绿描边之外的冗余指示，
                    // 色弱/色盲用户可辨（复用成员按钮「保留/丢弃」词）。
                    Text(member.isKept ? GatherLocalization.l("保留") : GatherLocalization.l("丢弃"))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(member.isKept ? GatherTheme.success : GatherTheme.error))
                        .padding(4)
                }
            Text(member.filename).font(.footnote).lineLimit(1)
            if let fileSize = member.fileSize {
                Text(String(format: GatherLocalization.l("%.1f MB"), Double(fileSize) / 1024 / 1024))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button(member.isKept ? GatherLocalization.l("保留") : GatherLocalization.l("丢弃")) {
                Task { await viewModel.toggle(member) }
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(GatherTheme.surface.opacity(0.5)))
        .overlay(
            // 对齐旧版 .memberKept/.memberRejected：1.5px 边框区分保留/排除，
            // 排除态整卡 72% 透明（视觉降权）。
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder((member.isKept ? GatherTheme.success : GatherTheme.error).opacity(0.75), lineWidth: 1.5)
        )
        .contextMenu {
            Button(GatherLocalization.l("保留")) {
                if !member.isKept { Task { await viewModel.toggle(member) } }
            }
            Button(GatherLocalization.l("丢弃")) {
                if member.isKept { Task { await viewModel.toggle(member) } }
            }
        }
        .opacity(member.isKept ? 1 : 0.72)
    }
}
