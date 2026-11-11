// 挑片页筛选与导航分组控件。
//
// 这些是“页面级选项”，不是当前照片的决策按钮。把它们从两行工具栏移到
// 右侧检查器，让查看器拿回高度，也符合 Bridge / Capture One 的 options-in-panel 范式。
import SwiftUI
import GatherProtocol

struct CullingFilterControls: View {
    let viewModel: CullingViewModel
    @Binding var faceAlign: Bool
    let isBusy: Bool

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    /// Wave5 batch4：人物候选（服务端 person facet；未接线时退回已加载页并集）。
    @State private var personNames: [String] = []

    /// 已选人物即使不在候选里也必须能显示（facet 加载失败/候选截断时）。
    private var personOptions: [String] {
        var options = personNames
        if let selected = viewModel.personFilter,
           !options.contains(selected) {
            options.insert(selected, at: 0)
        }
        return options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Toggle(l10n("仅未处理"), isOn: unreviewedOnlyBinding)
                .toggleStyle(.checkbox)
                .font(GatherFont.secondary)

            filterPicker(l10n("状态")) {
                Picker(l10n("状态"), selection: pickStateBinding) {
                    Text(l10n("全部状态")).tag(PickState?.none)
                    ForEach(PickState.allCases, id: \.self) { state in
                        Text(pickStateTitle(state, with: l10n)).tag(PickState?.some(state))
                    }
                }
            }

            filterPicker(l10n("星级")) {
                Picker(l10n("星级"), selection: ratingBinding) {
                    Text(l10n("全部星级")).tag(Int?.none)
                    ForEach(0...5, id: \.self) { rating in
                        Text(rating == 0 ? l10n("未评级") : l10n.format("%lld 星", rating))
                            .tag(Int?.some(rating))
                    }
                }
            }

            filterPicker(l10n("颜色")) {
                Picker(l10n("颜色"), selection: colorFilterBinding) {
                    Text(l10n("全部颜色")).tag(CaptureOneColorLabel?.none)
                    ForEach(CaptureOneColorLabel.allCases, id: \.self) { label in
                        Text(CullingDisplayFormat.title(label, with: l10n))
                            .tag(CaptureOneColorLabel?.some(label))
                    }
                }
            }

            filterPicker(l10n("质量")) {
                Picker(l10n("质量"), selection: qualityStatusBinding) {
                    Text(l10n("全部分析状态")).tag(CullingFilterQualityStatus?.none)
                    Text(l10n("已分析")).tag(CullingFilterQualityStatus?.some(.analysed))
                    Text(l10n("未分析")).tag(CullingFilterQualityStatus?.some(.unanalysed))
                    Text(l10n("分析失败")).tag(CullingFilterQualityStatus?.some(.failed))
                }
            }

            // Wave5 batch4（50-ai-similarity §2 P1-6）：人物精确筛选取代「回 Library 再回挑片」。
            filterPicker(l10n("人物")) {
                Picker(l10n("人物"), selection: personBinding) {
                    Text(l10n("全部人物")).tag(String?.none)
                    ForEach(personOptions, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }
            if viewModel.personFilter != nil {
                Text(l10n.format(
                    "人物筛选只作用于已加载窗口（当前匹配 %lld 张，服务端分页暂不支持人物条件）；清除后恢复全部",
                    Int64(viewModel.page?.assets.count ?? 0)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(l10n("仅 XMP 冲突"), isOn: conflictOnlyBinding)
                .toggleStyle(.checkbox)
                .font(GatherFont.secondary)

            Button(l10n("重置筛选")) {
                Task { await viewModel.resetFiltersIncludingClientProjection() }
            }
            .gatherButton(.tertiary, size: .small)

            Divider()

            Toggle(l10n("人脸对齐"), isOn: $faceAlign)
                .toggleStyle(.checkbox)
                .font(GatherFont.secondary)

            Button {
                Task { await viewModel.analyzeNavigation(dryRun: false) }
            } label: {
                Label(l10n("保存 Burst/Scene 分组"), systemImage: "square.and.arrow.down")
                    .font(GatherFont.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .gatherButton(.secondary, size: .small)
            .disabled(viewModel.isNavigationBusy)

            Button {
                Task { await viewModel.analyzeNavigation(dryRun: true) }
            } label: {
                Label(l10n("预览分组"), systemImage: "eye")
                    .font(GatherFont.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .gatherButton(.secondary, size: .small)
            .disabled(viewModel.isNavigationBusy)

            if !viewModel.navigationGroups.isEmpty {
                Divider()
                filterPicker(l10n.format("导航组 (%lld)", viewModel.navigationGroups.count)) {
                    Picker(l10n("导航组"), selection: navigationGroupBinding) {
                        ForEach(viewModel.navigationGroups, id: \.id) { group in
                            let leadLabel = group.leadPhotoId
                                .flatMap { lead in group.photoIds.firstIndex(of: lead) }
                                .map { l10n.format(" · 推荐 %lld", $0 + 1) } ?? ""
                            Text(l10n.format(
                                "%@ · %lld 张%@",
                                group.type == .burst ? l10n("连拍组") : l10n("场景组"),
                                group.photoIds.count,
                                leadLabel
                            ))
                            .tag(group.id)
                        }
                    }
                }
                Button(l10n("从当前照片拆分")) {
                    Task { await viewModel.splitCurrentFromNavigationGroup() }
                }
                .gatherButton(.secondary, size: .small)
                .disabled(viewModel.isNavigationBusy || viewModel.selectedNavigationGroupId.isEmpty)

                Button(l10n("与前组合并")) {
                    Task { await viewModel.mergeCurrentWithPreviousSameType() }
                }
                .gatherButton(.secondary, size: .small)
                .disabled(viewModel.isNavigationBusy || viewModel.selectedNavigationGroupId.isEmpty)

                // Wave5 batch4：场景/连拍最佳帧视图（入口 + 状态）。
                Button(viewModel.isNavigationGroupViewActive
                       ? l10n("退出组视图")
                       : l10n("查看组视图")) {
                    Task { await viewModel.toggleNavigationGroupView() }
                }
                .gatherButton(.secondary, size: .small)
                .disabled(viewModel.isNavigationBusy
                    || (!viewModel.isNavigationGroupViewActive
                        && viewModel.selectedNavigationGroupId.isEmpty))
                .help(l10n("把当前页收窄到该场景/连拍组，组内按最佳帧优先排序"))

                if let group = viewModel.navigationGroupViewGroup {
                    Text(l10n.format(
                        "组视图：%@ · %lld 张（最佳置顶）",
                        group.type == .burst ? l10n("连拍组") : l10n("场景组"),
                        Int64(group.photoIds.count)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            // 挑片页进入时预取人物候选（失败不影响其它筛选）。
            personNames = await viewModel.personFilterNames()
        }
        .onChange(of: viewModel.pageVersion) { _, _ in
            // 首次进页时 PhotoAPI 可能还没接好/首屏未到：有页后再补一次候选。
            guard personNames.isEmpty else { return }
            Task { personNames = await viewModel.personFilterNames() }
        }
        .disabled(isBusy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterPicker<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var unreviewedOnlyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.filterState.unreviewedOnly },
            set: { value in Task { await viewModel.setFilterStateKeepingClientProjection { $0.unreviewedOnly = value } } }
        )
    }

    private var pickStateBinding: Binding<PickState?> {
        Binding(
            get: { viewModel.filterState.pickState },
            set: { value in Task { await viewModel.setFilterStateKeepingClientProjection { $0.pickState = value } } }
        )
    }

    private var ratingBinding: Binding<Int?> {
        Binding(
            get: { viewModel.filterState.rating },
            set: { value in Task { await viewModel.setFilterStateKeepingClientProjection { $0.rating = value } } }
        )
    }

    private var colorFilterBinding: Binding<CaptureOneColorLabel?> {
        Binding(
            get: { viewModel.filterState.colorLabel },
            set: { value in Task { await viewModel.setFilterStateKeepingClientProjection { $0.colorLabel = value } } }
        )
    }

    private var qualityStatusBinding: Binding<CullingFilterQualityStatus?> {
        Binding(
            get: { viewModel.filterState.qualityStatus },
            set: { value in Task { await viewModel.setFilterStateKeepingClientProjection { $0.qualityStatus = value } } }
        )
    }

    private var conflictOnlyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.filterState.metadataConflictOnly },
            set: { value in Task { await viewModel.setFilterStateKeepingClientProjection { $0.metadataConflictOnly = value } } }
        )
    }

    /// 人物筛选（nil = 全部）：客户端投影，不改服务端 scope。
    private var personBinding: Binding<String?> {
        Binding(
            get: { viewModel.personFilter },
            set: { value in Task { await viewModel.setPersonFilter(value) } }
        )
    }

    private var navigationGroupBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedNavigationGroupId },
            set: { viewModel.selectNavigationGroupAndJump($0) }
        )
    }
}
