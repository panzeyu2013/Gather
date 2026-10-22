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
                            .padding(20)
                    }
                    // A2（第三轮审计）：HSplitView 的最小宽度 = 两栏最小宽度**相加**，
                    // 320+280+分隔线已逼近最小窗口能给内容区的 680pt，detailPane 的内容
                    //（成员行 40pt 人脸 + 文件名 + 置信度 + 两个按钮）再顶一下就会超。
                    // 收紧到 280/240：分栏仍可拖拽，最小窗口下不再与 split view 抢宽度。
                    .frame(minWidth: 280)
                    detailPane
                        .padding(20)
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
                Text(l10n("人脸聚类")).font(.title3.weight(.semibold))
                Text(l10n.format("%lld 组", visibleClusters.count))
                    .font(.callout)
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

    /// TS StepReview.detailPane：详情栏（成员列表 + 编辑 + 合并面板）。
    /// 宽度由 HSplitView 拖拽决定（280–460），不再用 GeometryReader 换算。
    private var detailPane: some View {
        Group {
            if let cluster = viewModel.selectedCluster {
                // 详情栏整体只有一个滚动区：成员行改用 LazyVStack + Divider，
                // 不再嵌套 List/ScrollView（短窗口下不会把编辑区挤出可视范围）。
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(cluster.label)
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Text(cluster.sampleCountText(with: l10n))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        memberList(cluster)
                        // TS StepReview.tsx:216-218：审核动作失败的内联错误块
                        // （绑定/移除/解除/合并），横幅错误保留。
                        if let actionError = viewModel.reviewActionError {
                            NativeBanner(
                                text: CommandErrorText.resolve(actionError, with: l10n),
                                systemImage: "exclamationmark.triangle.fill",
                                color: GatherTheme.error
                            )
                        }
                        editor(cluster)
                        mergePanel(cluster)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// TS memberList：成员行（#序号 + 文件名 + 置信度% + 悬停显现的移除按钮）。
    /// 移除不可逆：悬停显现的图标按钮 + 右键菜单两个入口，先弹确认
    /// （旧版「点击即移除」已删除）。
    private func memberList(_ cluster: FaceClusterData) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(cluster.members.enumerated()), id: \.element.memberId) { index, member in
                MemberRowView(index: index, member: member) {
                    pendingMemberRemoval = PendingFaceMemberRemoval(member: member, cluster: cluster)
                }
                if index < cluster.members.count - 1 { Divider() }
            }
        }
        .accessibilityLabel(l10n("簇成员"))
    }

    /// TS editor：角色名/关键字输入 + 绑定/更新绑定 + 解除绑定（解除绑定撤销
    /// 已写入关键词，经确认弹窗后才执行）。表单行改用 LabeledContent。
    private func editor(_ cluster: FaceClusterData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n("绑定角色")).font(.headline)
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
        let candidates = viewModel.clusters.filter { $0.id != cluster.id }
        return VStack(alignment: .leading, spacing: 8) {
            Text(l10n("合并")).font(.headline)
            if candidates.isEmpty {
                Text(l10n("没有其他簇可合并。"))
                    .font(.callout)
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
