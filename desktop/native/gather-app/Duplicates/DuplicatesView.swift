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
        case .strict: return "严格"
        case .balanced: return "均衡"
        case .loose: return "宽松"
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
    public var threshold = 4
    public var showExact = true
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
        defer { isScanning = false }
        do {
            scanResult = try await client.executeAsync("dup.scan", params: [
                "sessionId": .string(sessionId),
                "visualThreshold": .number(Double(threshold)),
            ]).decoded(as: DuplicateScanResult.self)
            notice = "重复扫描完成"
            await load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    // MARK: - 组 / 成员操作（本地 patch，对齐 TS L201-270）

    public func resolveGroup(_ group: DuplicateGroup, resolution: DupResolution) {
        do {
            _ = try client.execute("dup.resolve", params: [
                "groupId": .number(Double(group.id)),
                "resolution": .string(resolution.rawValue),
                "confirmed": .bool(true),
            ])
            notice = "已处理重复组 #\(group.id)"
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

    public func toggle(_ member: DuplicateGroupMember) {
        do {
            _ = try client.execute("dup.resolve_member", params: [
                "memberId": .number(Double(member.id)),
                "isKept": .bool(!member.isKept),
                "confirmed": .bool(true),
            ])
            guard let groupIndex = groups.firstIndex(where: { $0.members.contains(where: { $0.id == member.id }) }),
                  let memberIndex = groups[groupIndex].members.firstIndex(where: { $0.id == member.id })
            else { return }
            let isKept = !groups[groupIndex].members[memberIndex].isKept
            groups[groupIndex].members[memberIndex].isKept = isKept
            groups[groupIndex].members[memberIndex].resolution = isKept
                ? DupResolution.keepAll.rawValue
                : DupResolution.keepOne.rawValue
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
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
    private let router: CommandRouter
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    private let onOpenSettings: () -> Void

    init(
        sessionId: String,
        router: CommandRouter,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
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
            header
            if let error = viewModel.errorMessage { NativeBanner(text: "操作失败：\(error)", color: GatherTheme.error) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: GatherTheme.success) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scanControls
                    if viewModel.isLoading || viewModel.isScanning {
                        loadingIndicator
                    }
                    if let result = viewModel.scanResult {
                        Text("完全重复：\(result.exactGroups.count) 组 · 视觉相似：\(result.visualGroups.count) 组 · 总计重复：\(result.totalDuplicates) 张")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    tabSelector
                    if viewModel.filteredGroups.isEmpty {
                        emptyState
                    } else {
                        // 惰性渲染：大组列表不预先布局全部卡片（ScrollView 内）。
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(viewModel.visibleFilteredGroups, id: \.id) { group in groupCard(group) }
                            if viewModel.remainingGroupCount > 0 {
                                HStack {
                                    Spacer()
                                    Button("加载更多（还有 \(viewModel.remainingGroupCount) 组）") {
                                        viewModel.loadMoreGroups()
                                    }
                                    .buttonStyle(.bordered)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .background(Color.gatherBackground)
        .task { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("返回", systemImage: "chevron.left", action: onBack).buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    Text("重复照片检测").font(.system(size: 24, weight: .bold))
                    Text("工作区 \(viewModel.sessionId.prefix(8))").foregroundStyle(.secondary)
                }
                Spacer()
                C1StatusCapsuleHost(sessionId: viewModel.sessionId, router: router, onOpenSettings: onOpenSettings)
                Button("刷新", systemImage: "arrow.clockwise") { Task { await viewModel.load() } }
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
    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(viewModel.isScanning ? "正在扫描…" : "加载中…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("匹配强度").font(.callout).foregroundStyle(.secondary)
                ForEach(VisualPreset.allCases, id: \.self) { preset in
                    Button(preset.label) { viewModel.selectPreset(preset) }
                        .buttonStyle(.bordered)
                        .tint(viewModel.activePreset == preset ? Color.accentColor : nil)
                        .disabled(viewModel.isScanning)
                }
                Text("均衡适合大多数图库；严格可减少视觉近似候选。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 12) {
                // 对齐旧版 range 滑块（0–10，18px thumb），替代 Stepper；
                // 滑块始终可拖，预设仅负责置值（TS L332-340）。
                SliderInputIntView(title: "视觉相似阈值: \(viewModel.threshold)", value: $viewModel.threshold, range: 0...10)
                Button(viewModel.isScanning ? "扫描中…" : "开始扫描", systemImage: "magnifyingglass") {
                    Task { await viewModel.scan() }
                }
                .disabled(viewModel.isScanning)
                Spacer()
            }
            // 对齐旧版 rangeHint / scanExplanation（TS L341/345）。
            Text("0 (严格) — 10 (宽松)")
                .font(.caption).foregroundStyle(.secondary)
            Text("扫描会先识别内容完全一致的文件，再查找视觉近似候选；不会删除照片。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var tabSelector: some View {
        Picker("类型", selection: $viewModel.showExact) {
            Text("完全重复（\(viewModel.exactGroupCount)）").tag(true)
            Text("视觉相似（\(viewModel.visualGroupCount)）").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 380)
        .onChange(of: viewModel.showExact) { _, _ in
            viewModel.resetPagination()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.scanResult == nil {
            ContentUnavailableView("先运行扫描", systemImage: "square.on.square", description: Text("点击「开始扫描」按钮检测重复照片"))
        } else if viewModel.showExact {
            ContentUnavailableView("未发现完全重复的照片", systemImage: "square.on.square")
        } else {
            ContentUnavailableView("未发现视觉相似的照片", systemImage: "square.on.square")
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
                    Text(resolution == DupResolution.keepOne.rawValue ? "· 保留最佳" : "· 保留全部")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Menu("处理") {
                    Button("保留最佳") { viewModel.resolveGroup(group, resolution: .keepOne) }
                    Button("保留全部") { viewModel.resolveGroup(group, resolution: .keepAll) }
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
                    Button(viewModel.isExpanded(group.id) ? "收起" : "展开全部（共 \(group.members.count) 张）") {
                        viewModel.toggleExpanded(group.id)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
        .nativeCard()
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hovering ? GatherTheme.primary.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }

    private var groupTitle: String {
        let type = group.groupType == .exact ? "完全重复" : "视觉相似"
        return "\(type) · \(group.memberCount) 张照片"
    }

    private func memberCard(_ member: DuplicateGroupMember, recommended: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // 对齐旧版 .memberThumb：1:1 方形、256 解码、10px 圆角（css:319-325）。
            PhotoThumbnailView(path: member.filepath, size: 256, placeholderSize: CGSize(width: 150, height: 150))
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if recommended {
                        Text("推荐")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(GatherTheme.primary))
                            .padding(4)
                    }
                }
            Text(member.filename).font(.caption).lineLimit(1)
            if let fileSize = member.fileSize {
                Text(String(format: "%.1f MB", Double(fileSize) / 1024 / 1024))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(member.isKept ? "保留" : "丢弃") { viewModel.toggle(member) }
                .buttonStyle(.bordered)
                .tint(member.isKept ? GatherTheme.success : GatherTheme.error)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            // 对齐旧版 .memberKept/.memberRejected：2px 边框区分保留/排除，
            // 排除态整卡 60% 透明（视觉降权）。
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(member.isKept ? GatherTheme.success : GatherTheme.error, lineWidth: 2)
        )
        .opacity(member.isKept ? 1 : 0.6)
    }
}
