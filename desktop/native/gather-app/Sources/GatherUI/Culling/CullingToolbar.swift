// desktop/native/gather-app/Sources/GatherUI/Culling/CullingToolbar.swift
// Cut 4 / 4c-2a：顶部工具栏（范围 / 筛选 / 历史撤销重做 / 对比 / 质量分析 / 导航组），
// 原 CullingView.swift 1922-2149 + 2474-2477 + 2827-2899 行，逐字搬移。
// 键盘快捷键：可见控件上的 .keyboardShortcut（任意焦点下窗口级生效）；空格键由
// 查看器的 .onKeyPress 处理——不再使用 NSEvent 局部监听，也不屏蔽控件焦点。
import SwiftUI
import GatherProtocol

// MARK: 顶部工具栏（对齐旧版 Culling.tsx:1177-1309 的 toolbar：范围分段 +
// 筛选控件 + 视图操作区）。
// 布局验收 P0 修复：拆为两行——第一行固定可见（撤销/重做 + 范围 + 自动前进 +
// 对比 + 质量分析，高频操作不再被横向滚动隐藏）；第二行可横向滚动（筛选控件 +
// 导航分组操作，低频）。
struct CullingToolbar: View {
    let viewModel: CullingViewModel
    let isBusy: Bool
    @Binding var compareCount: Int
    @Binding var faceAlign: Bool

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        VStack(spacing: 0) {
            // 约束循环修复（N01）：本行原先是不带滚动的 HStack，它的最小宽度 =
            // 所有控件最小宽度之和（实测 ≈ 876pt）。这个最小宽度会经
            // SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)
            // 传给 NavigationSplitView；默认窗口减掉侧栏与检查器只剩 ≈720pt，
            // AppKit 于是反复重算约束 → NSGenericException → SIGABRT。
            // 放进横向滚动容器后，本行对外的**最小宽度**不再等于内容总宽
            //（与下面第二行筛选栏同一处理），页面最小宽度回到预算内。
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    undoRedoButtons

                    Divider().frame(height: 18)

                    labeledPicker(l10n("范围")) {
                        Picker(l10n("范围"), selection: scopeBinding) {
                            ForEach(CullingViewModel.ScopeMode.allCases, id: \.self) { scope in
                                Text(l10n.resolve(scope.title)).tag(scope)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                        .fixedSize()

                    }

                    Toggle(l10n("自动前进"), isOn: autoAdvanceBinding)
                        .toggleStyle(.checkbox)
                        .fixedSize()


                    labeledPicker(l10n("对比")) {
                        Picker(l10n("对比"), selection: $compareCount) {
                            Text(l10n("单图")).tag(1)
                            Text(l10n("2 图")).tag(2)
                            Text(l10n("4 图")).tag(4)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                        .fixedSize()

                    }

                    Divider().frame(height: 18)

                    qualityAnalysisBlock
                        .fixedSize()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            }

            // 筛选行在窄窗口下会超出，保留横向滚动但**不再隐藏滚动条**：
            // showsIndicators:false 会抹掉「右边还有控件」的唯一线索。
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    Toggle(l10n("仅未处理"), isOn: unreviewedOnlyBinding)
                        .toggleStyle(.checkbox)

                    labeledPicker(l10n("状态")) {
                        Picker(l10n("状态"), selection: pickStateBinding) {
                            Text(l10n("全部状态")).tag(PickState?.none)
                            ForEach(PickState.allCases, id: \.self) { state in
                                Text(pickStateTitle(state, with: l10n)).tag(PickState?.some(state))
                            }
                        }
                        .fixedSize()

                    }
                    labeledPicker(l10n("星级")) {
                        Picker(l10n("星级"), selection: ratingBinding) {
                            Text(l10n("全部星级")).tag(Int?.none)
                            ForEach(0...5, id: \.self) { rating in
                                Text(rating == 0 ? l10n("未评级") : l10n.format("%lld 星", rating)).tag(Int?.some(rating))
                            }
                        }
                        .fixedSize()

                    }
                    labeledPicker(l10n("颜色")) {
                        Picker(l10n("颜色"), selection: colorFilterBinding) {
                            Text(l10n("全部颜色")).tag(CaptureOneColorLabel?.none)
                            ForEach(CaptureOneColorLabel.allCases, id: \.self) { label in
                                Text(CullingDisplayFormat.title(label, with: l10n)).tag(CaptureOneColorLabel?.some(label))
                            }
                        }
                        .fixedSize()

                    }
                    labeledPicker(l10n("质量")) {
                        Picker(l10n("质量"), selection: qualityStatusBinding) {
                            Text(l10n("全部分析状态")).tag(CullingFilterQualityStatus?.none)
                            Text(l10n("已分析")).tag(CullingFilterQualityStatus?.some(.analysed))
                            Text(l10n("未分析")).tag(CullingFilterQualityStatus?.some(.unanalysed))
                            Text(l10n("分析失败")).tag(CullingFilterQualityStatus?.some(.failed))
                        }
                        .fixedSize()

                    }
                    Toggle(l10n("仅 XMP 冲突"), isOn: conflictOnlyBinding)
                        .toggleStyle(.checkbox)

                    Button(l10n("重置")) { Task { await viewModel.resetFilters() } }

                    Divider().frame(height: 18)

                    Toggle(l10n("人脸对齐"), isOn: $faceAlign)
                        .toggleStyle(.checkbox)


                    Button(l10n("保存 Burst/Scene 分组")) {
                        Task { await viewModel.analyzeNavigation(dryRun: false) }
                    }
                    .disabled(viewModel.isNavigationBusy)

                    Button(l10n("预览分组")) {
                        Task { await viewModel.analyzeNavigation(dryRun: true) }
                    }
                    .disabled(viewModel.isNavigationBusy)


                    if !viewModel.navigationGroups.isEmpty {
                        labeledPicker(l10n.format("导航组 (%lld)", viewModel.navigationGroups.count)) {
                            Picker(l10n.format("导航组 (%lld)", viewModel.navigationGroups.count), selection: navigationGroupBinding) {
                                ForEach(viewModel.navigationGroups, id: \.id) { group in
                                    let leadLabel = group.leadPhotoId
                                        .flatMap { lead in group.photoIds.firstIndex(of: lead) }
                                        .map { l10n.format(" · 推荐 %lld", $0 + 1) } ?? ""
                                    Text(l10n.format("%@ · %lld 张%@", group.type == .burst ? "Burst" : "Scene", group.photoIds.count, leadLabel)).tag(group.id)
                                }
                            }
                            .fixedSize()

                        }
                        Button(l10n("从当前照片拆分")) {
                            Task { await viewModel.splitCurrentFromNavigationGroup() }
                        }
                        .disabled(viewModel.isNavigationBusy || viewModel.selectedNavigationGroupId.isEmpty)

                        Button(l10n("与前组合并")) {
                            Task { await viewModel.mergeCurrentWithPreviousSameType() }
                        }
                        .disabled(viewModel.isNavigationBusy || viewModel.selectedNavigationGroupId.isEmpty)

                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            }
        }
        .background(GatherTheme.contentBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var undoRedoButtons: some View {
        HStack(spacing: 4) {
            // ⌘Z / ⇧⌘Z 由宿主菜单（gatherMenuUndo/Redo 通知）承载，这里只做可见入口。
            Button { Task { await viewModel.undo() } } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            // V2 审计：宿主菜单的 undo:/redo: 走 NSUndoManager，而挑片撤销是自建栈，
            // 只认 gatherMenuUndo/Redo 通知——那两个通知全仓没有发布者，tooltip 承诺
            // 的 ⌘Z/⇧⌘Z 从未生效。直接挂在可见按钮上（挑片页无文本输入框，不冲突）。
            .keyboardShortcut("z", modifiers: .command)
            .disabled(viewModel.undoOperation == nil || isBusy)
            .help(l10n("撤销（⌘Z）"))
            .accessibilityLabel(l10n("撤销"))

            Button { Task { await viewModel.redo() } } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(viewModel.redoOperation == nil || isBusy)
            .help(l10n("重做（⇧⌘Z）"))
            .accessibilityLabel(l10n("重做"))
        }
    }

    private var qualityAnalysisBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(viewModel.isQualityBusy ? l10n("质量分析中…") : l10n("分析技术质量")) {
                Task { await viewModel.analyzeQuality() }
            }
            .disabled(viewModel.isQualityBusy)

            if let job = viewModel.qualityJob, job.progressTotal > 0,
               job.status == .queued || job.status == .running || job.status == .cancelling {
                ProgressView(
                    value: Double(min(job.progressCurrent, job.progressTotal)),
                    total: Double(job.progressTotal)
                )
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .frame(width: 150)
                HStack(spacing: 6) {
                    Text("\(qualityProgressPercent(job))% \(l10n.progressPhaseText(job.progressMessage))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(l10n("取消")) {
                        viewModel.cancelQualityAnalysis()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func labeledPicker<PickerView: View>(
        _ title: String,
        @ViewBuilder picker: () -> PickerView
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            picker().labelsHidden()
        }
    }

    private func qualityProgressPercent(_ job: AnalysisJobData) -> Int {
        guard job.progressTotal > 0 else { return 0 }
        return min(100, max(0, Int((Double(job.progressCurrent) / Double(job.progressTotal) * 100).rounded())))
    }

    private var unreviewedOnlyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.filterState.unreviewedOnly },
            set: { value in Task { await viewModel.setFilterState { $0.unreviewedOnly = value } } }
        )
    }

    private var pickStateBinding: Binding<PickState?> {
        Binding(
            get: { viewModel.filterState.pickState },
            set: { value in Task { await viewModel.setFilterState { $0.pickState = value } } }
        )
    }

    private var ratingBinding: Binding<Int?> {
        Binding(
            get: { viewModel.filterState.rating },
            set: { value in Task { await viewModel.setFilterState { $0.rating = value } } }
        )
    }

    private var colorFilterBinding: Binding<CaptureOneColorLabel?> {
        Binding(
            get: { viewModel.filterState.colorLabel },
            set: { value in Task { await viewModel.setFilterState { $0.colorLabel = value } } }
        )
    }

    private var qualityStatusBinding: Binding<CullingFilterQualityStatus?> {
        Binding(
            get: { viewModel.filterState.qualityStatus },
            set: { value in Task { await viewModel.setFilterState { $0.qualityStatus = value } } }
        )
    }

    private var conflictOnlyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.filterState.metadataConflictOnly },
            set: { value in Task { await viewModel.setFilterState { $0.metadataConflictOnly = value } } }
        )
    }

    private var autoAdvanceBinding: Binding<Bool> {
        Binding(
            get: { viewModel.autoAdvance },
            set: { viewModel.autoAdvance = $0 }
        )
    }

    private var scopeBinding: Binding<CullingViewModel.ScopeMode> {
        Binding(
            get: { viewModel.scopeMode },
            set: { value in Task { await viewModel.setScope(value) } }
        )
    }

    private var navigationGroupBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedNavigationGroupId },
            set: { viewModel.selectNavigationGroupAndJump($0) }
        )
    }
}
