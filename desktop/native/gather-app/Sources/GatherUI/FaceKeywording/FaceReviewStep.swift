// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceReviewStep.swift
// Cut 4 / 4c-2b：Step 2 审核（原 1516-1627、1698-1830 行）；簇卡片在 FaceClusterCard。
import SwiftUI
import GatherProtocol

extension FaceKeywordingView {
    // MARK: - Step 2 审核（TS StepReview）

    var stepReview: some View {
        Group {
            if viewModel.isLoading {
                ProgressView(l10n("加载中…"))
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.clusters.isEmpty {
                ContentUnavailableView {
                    Label(
                        l10n("暂无人脸簇"),
                        systemImage: "person.crop.circle.badge.questionmark"
                    )
                } description: {
                    Text(l10n("先运行人脸分析"))
                } actions: {
                    Button(l10n("前往分析")) {
                        viewModel.setStep(.analyze)
                    }
                    .gatherPrimaryActionButton()
                    .help(l10n("切换到分析步骤"))
                }
            } else {
                // 两栏可拖拽（HSplitView）：删掉 GeometryReader 与 340pt 魔法宽度；
                // 左右各一个滚动区（旧版在页面 ScrollView 里再嵌成员列表/预览的
                // 内层滚动，滚轮命中哪个区域不可预测）。
                HSplitView {
                    ScrollView {
                        clusterPane
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(GatherMetrics.Space.l)
                    }
                    // A2（第三轮审计）：HSplitView 的最小宽度 = 两栏最小宽度**相加**，
                    // 320+280+分隔线已逼近最小窗口能给内容区的 680pt，detailPane 的内容
                    //（成员行 40pt 人脸 + 文件名 + 置信度 + 两个按钮）再顶一下就会超。
                    // 收紧到 280/240：分栏仍可拖拽，最小窗口下不再与 split view 抢宽度。
                    .frame(minWidth: 280)
                    detailPane
                        .padding(GatherMetrics.Space.l)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 460)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// TS StepReview.clusterPane：标题 + 组数 + 角色过滤 + 簇网格 + 加载更多。
    private var clusterPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(l10n("人脸聚类")).font(GatherFont.sectionTitle)
                Text(l10n.format("%lld 组", visibleClusters.count))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                roleFilterPicker
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
                    Button(l10n.format("加载更多（还有 %lld 组）", visibleClusters.count - visibleClusterCount)) {
                        visibleClusterCount += FaceKeywordingViewModel.clusterPageSize
                    }
                    .buttonStyle(.bordered)
                    .help(l10n("继续加载剩余的人脸簇"))
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
        }
        .task(id: viewModel.clusters.count) {
            await viewModel.loadReviewSummaries()
        }
    }

    private var visibleClusters: [FaceClusterData] {
        guard let roleFilter = viewModel.roleFilter else { return viewModel.clusters }
        return viewModel.clusters.filter { $0.binding?.roleName == roleFilter }
    }

    /// TS roleFilterBar：手绘胶囊（角色多时会溢出并把标题挤出视野）→ 原生菜单选择器，
    /// 自动带选中态、键盘操作与「全部角色」清空入口。
    @ViewBuilder
    private var roleFilterPicker: some View {
        // C-P1-6：用 VM 缓存的角色集合（一次 body 不再重建+排序）。
        let roles = viewModel.roleNames
        if !roles.isEmpty {
            Picker(l10n("角色筛选"), selection: roleFilterSelection) {
                Text(l10n("全部角色")).tag(String?.none)
                ForEach(roles, id: \.self) { role in
                    Text(role).tag(String?.some(role))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel(l10n("按角色筛选簇"))
            .help(l10n("只看某个角色的簇"))
        }
    }

    private var roleFilterSelection: Binding<String?> {
        Binding(
            get: { viewModel.roleFilter },
            set: { viewModel.roleFilter = $0 }
        )
    }

    /// TS StepReview.detailPane：详情栏（复核成员 + 拆分 + 编辑 + 合并面板）。
    /// 宽度由 HSplitView 拖拽决定（280–460），不再用 GeometryReader 换算。
    private var detailPane: some View {
        Group {
            if let cluster = viewModel.selectedCluster {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(cluster.label)
                                .font(GatherFont.sectionTitle)
                            Spacer()
                            Text(cluster.sampleCountText(with: l10n))
                                .font(GatherFont.secondary)
                                .foregroundStyle(.secondary)
                        }
                        reviewHeader(cluster)
                        reviewMemberList(cluster)
                        if let actionError = viewModel.reviewActionError {
                            NativeBanner(
                                text: CommandErrorText.resolve(actionError, with: l10n),
                                systemImage: "exclamationmark.triangle.fill",
                                color: GatherTheme.error
                            )
                        }
                        editor(cluster)
                        // 绑定簇不能合并/拆分（服务会拒绝）；直接不渲染注定失败的面板。
                        if cluster.binding == nil {
                            mergePanel(cluster)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: cluster.id) {
                    await viewModel.loadReview(clusterId: cluster.id, reset: true)
                }
            } else {
                ContentUnavailableView {
                    Label(l10n("未选择人脸簇"), systemImage: "person.crop.square")
                } description: {
                    Text(l10n("点击左侧簇卡片查看成员与绑定编辑"))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 复核头：仅看待复核成员 + 拆分所选。
    private func reviewHeader(_ cluster: FaceClusterData) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            HStack(spacing: GatherMetrics.Space.s) {
                Toggle(
                    l10n("仅看待复核成员"),
                    isOn: Binding(
                        get: { viewModel.includeOnlyReviewMembers },
                        set: { value in
                            Task { await viewModel.setIncludeOnlyReviewMembers(value) }
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .help(l10n("只显示低质量、小脸、未解析或与簇中心差异较大的成员"))

                Spacer(minLength: 8)
                Text(l10n.format("已选 %lld 个", viewModel.selectedMemberIds.count))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)

                Button(l10n.format("拆分所选（%lld）", viewModel.selectedMemberIds.count)) {
                    let selected = viewModel.selectedReviewItems.filter {
                        viewModel.selectedMemberIds.contains($0.memberId)
                    }
                    pendingSplit = PendingFaceSplit(cluster: cluster, members: selected)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSplit)
                .help(splitHelp(cluster))
            }
            Text(l10n("拆分会把选中的成员移到一个新簇，原簇保留其余成员；拆分会在重新聚类后保持。"))
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
        }
    }

    private func splitHelp(_ cluster: FaceClusterData) -> String {
        if cluster.binding != nil {
            return l10n("先解除绑定（会撤销已写入关键词）")
        }
        if viewModel.analysisPhase == .running {
            return l10n("分析进行中，暂不能拆分")
        }
        if viewModel.selectedMemberIds.isEmpty {
            return l10n("先选择要移出的成员")
        }
        if viewModel.selectedMemberIds.count >= cluster.size {
            return l10n("至少保留 1 个成员在原簇")
        }
        return l10n("把所选成员移到一个新簇")
    }

    /// 复核成员列表：受 includeOnlyReviewMembers / 分页游标控制。
    @ViewBuilder
    private func reviewMemberList(_ cluster: FaceClusterData) -> some View {
        let items = viewModel.selectedReviewItems
        if viewModel.isLoadingReview && items.isEmpty {
            ProgressView(l10n("加载中…"))
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(EdgeInsets(top: GatherMetrics.Space.m, leading: 0, bottom: GatherMetrics.Space.m, trailing: 0))
        } else if items.isEmpty {
            VStack(spacing: GatherMetrics.Space.s) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(
                    viewModel.includeOnlyReviewMembers
                        ? l10n("未发现待复核成员")
                        : l10n("该簇没有成员")
                )
                .font(GatherFont.sectionTitle)
                Text(
                    viewModel.includeOnlyReviewMembers
                        ? l10n("这组人脸看起来一致；可显示全部成员后再判断。")
                        : l10n("重新分析或调整聚类参数后再试。")
                )
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                if viewModel.includeOnlyReviewMembers {
                    Button(l10n("显示全部成员")) {
                        Task { await viewModel.setIncludeOnlyReviewMembers(false) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: GatherMetrics.Space.l, leading: 0, bottom: GatherMetrics.Space.l, trailing: 0))
        } else {
            LazyVStack(spacing: .zero) {
                ForEach(Array(items.enumerated()), id: \.element.memberId) { index, item in
                    FaceReviewMemberRowView(
                        item: item,
                        isSelected: viewModel.selectedMemberIds.contains(item.memberId),
                        focusedMemberId: $focusedMemberId,
                        onToggle: { viewModel.toggleMemberSelection(item.memberId) },
                        onRemove: {
                            pendingReviewRemoval = PendingFaceReviewRemoval(item: item, cluster: cluster)
                        }
                    )
                    if index < items.count - 1 { Divider() }
                }
                if viewModel.reviewNextCursor != nil {
                    Button(l10n("加载更多成员")) {
                        Task { await viewModel.loadMoreReview() }
                    }
                    .buttonStyle(.borderless)
                    .padding(EdgeInsets(top: GatherMetrics.Space.s, leading: 0, bottom: GatherMetrics.Space.s, trailing: 0))
                }
            }
            .accessibilityLabel(l10n("待复核成员"))
            .onKeyPress(.escape) {
                viewModel.clearMemberSelection()
                return .handled
            }
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.contains(.command),
                      press.characters.lowercased() == "a" else { return .ignored }
                viewModel.selectAllReviewMembers()
                return .handled
            }
        }
    }

    /// TS editor：角色名/关键字输入 + 绑定/更新绑定 + 解除绑定（解除绑定撤销
    /// 已写入关键词，经确认弹窗后才执行）。表单行改用 LabeledContent。
    private func editor(_ cluster: FaceClusterData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n("绑定角色")).font(GatherFont.cardTitle)
            LabeledContent(l10n("角色名称")) {
                TextField(l10n("输入角色名称"), text: bindable.roleName)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            LabeledContent(l10n("关键字")) {
                TextField(l10n("关键字，用逗号分隔"), text: bindable.keywords)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Button(cluster.binding != nil ? l10n("更新绑定") : l10n("绑定")) {
                    Task { await viewModel.bind(cluster) }
                }
                .gatherPrimaryActionButton()
                .help(l10n("用角色名称与关键字绑定该簇"))
                if cluster.binding != nil {
                    Button(role: .destructive) {
                        pendingUnbind = PendingFaceUnbind(cluster: cluster)
                    } label: {
                        Text(l10n("解除绑定"))
                    }
                    .help(l10n("撤销该簇已写入的人脸关键词"))
                }
            }
        }
        .gatherCard(cornerRadius: GatherTheme.Radius.panel)
    }

    /// TS mergePanel：合并目标下拉（过滤当前簇，选项 label (n 张)）+ 合并按钮，
    /// 无目标时禁用。
    private func mergePanel(_ cluster: FaceClusterData) -> some View {
        // 服务端会拒绝绑定簇合并；UI 不提供注定报错的选项。
        let candidates = viewModel.clusters.filter {
            $0.id != cluster.id && $0.binding == nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(l10n("合并")).font(GatherFont.cardTitle)
            if candidates.isEmpty {
                Text(l10n("没有其他簇可合并。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent(l10n("合并到")) {
                    Picker(l10n("合并目标"), selection: bindable.mergeTargetId) {
                        Text(l10n("选择目标簇")).tag(Int?.none)
                        ForEach(candidates, id: \.id) { candidate in
                            Text(l10n.format("%@（%lld 个人脸样本）", candidate.label, candidate.size))
                                .tag(Int?.some(candidate.id))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(l10n("合并目标"))
                }
                HStack {
                    Spacer(minLength: 0)
                    Button(l10n("合并")) {
                        guard let targetId = viewModel.mergeTargetId,
                              let target = candidates.first(where: { $0.id == targetId }) else {
                            viewModel.reportInvalidMergeTarget()
                            return
                        }
                        pendingMerge = PendingFaceMerge(cluster: cluster, target: target)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.mergeTargetId == nil)
                    .help(l10n("把当前簇合并到选中的目标簇"))
                }
            }
        }
        .gatherCard(cornerRadius: GatherTheme.Radius.panel)
    }
}
