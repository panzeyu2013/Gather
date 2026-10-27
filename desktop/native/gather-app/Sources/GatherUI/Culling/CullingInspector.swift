// desktop/native/gather-app/Sources/GatherUI/Culling/CullingInspector.swift
// Cut 4 / 4c-2a：右侧检查器（当前照片决策 / 星级 / 色标 / 相似组 / 选择管理 / 统计）
// + 决策按钮。原 CullingView.swift 2151-2329 + 2902-2940 + 2855-2864 + 3695-3701 行。
import SwiftUI
import GatherProtocol

// MARK: 右侧检查器（Bridge / Capture One 式：选项面板交给系统 .inspector，
// 内容区只留查看器 + 胶片；工具栏开关由系统自动提供，不自绘切换按钮）。
struct CullingInspector: View {
    let viewModel: CullingViewModel
    let isBusy: Bool
    @Binding var faceAlign: Bool
    @Binding var gridDensity: CullingGridDensity
    /// T0：复核队列需要把布局切到网格。
    @Binding var layoutMode: CullingLayoutMode
    @State private var filtersExpanded = false
    /// P1 / D：淘汰移出的确认弹窗（移动文件属于破坏性操作，必须显式确认）。
    @State private var confirmMoveRejected = false
    /// 检查器内的互斥 sheet（SwiftUI 同视图叠多个 .sheet 行为不稳定）。
    private enum InspectorSheet: String, Identifiable {
        case ingest, templates, batches
        var id: String { rawValue }
    }
    @State private var activeSheet: InspectorSheet?
    /// P1 / E：建议写回必须先确认（VM 只准备输入，Confirmed 由视图构造）。
    @State private var pendingTriageInput: TriageWritebackInput?
    @State private var showTriageWritebackConfirm = false
    @State private var showTriageUndoConfirm = false

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
                // 当前照片：决策条（对齐旧版 decisionBar：✓ 保留 P / × 淘汰 X / ○ 未处理 U）
                // + 星级 + 颜色。系统 bordered 按钮 + 裸键 .keyboardShortcut（取代手绘卡片描边）。
                GatherInspectorSection(l10n("当前照片")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.selectedPhotoIds.isEmpty ? l10n("当前照片") : l10n.format("批量 %lld 张", viewModel.selectedPhotoIds.count))
                            .controlLabelStyle()
                        VStack(spacing: 6) {
                            decisionButton(icon: "checkmark", iconColor: GatherTheme.success, title: l10n("保留"), shortcut: "P", key: "p") {
                                Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked)) }
                            }
                            decisionButton(icon: "xmark", iconColor: GatherTheme.error, title: l10n("淘汰"), shortcut: "X", key: "x") {
                                Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .rejected)) }
                            }
                            decisionButton(icon: "circle", iconColor: .secondary, title: l10n("未处理"), shortcut: "U", key: "u") {
                                Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .unreviewed), shouldAdvance: false) }
                            }
                        }
                    }

                    // 星级：0–5 的**图标**按钮 + 累计填充的标准评分外观。
                    //
                    // 旧实现是 "1★"/"2★" 文字按钮：窄列宽下六个按钮会被压缩成「…」，
                    // 整行不可读。图标按钮只占约 22pt/个，检查器任意列宽下都完整可见。
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n("星级")).controlLabelStyle()
                        HStack(spacing: 2) {
                            let current = Int(viewModel.currentAsset?.state.rating ?? 0)
                            Button {
                                Task { await viewModel.commit(patch: CullingUpdatePatch(rating: 0)) }
                            } label: {
                                Image(systemName: "star.slash")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.large)
                            .foregroundStyle(current == 0 ? GatherTheme.accent : Color.secondary)
                            .disabled(isBusy)
                            .help(l10n("清除评分"))
                            .accessibilityLabel(l10n("清除评分"))

                            ForEach(1...5, id: \.self) { rating in
                                Button {
                                    Task { await viewModel.commit(patch: CullingUpdatePatch(rating: Double(rating))) }
                                } label: {
                                    Image(systemName: rating <= current ? "star.fill" : "star")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.large)
                                .foregroundStyle(rating <= current ? GatherTheme.accent : Color.secondary)
                                .disabled(isBusy)
                                .help(l10n.format("评分 %lld", rating))
                                .accessibilityLabel(l10n.format("评分 %lld", rating))
                                .accessibilityAddTraits(rating == current ? .isSelected : [])
                            }
                        }
                    }

                    // 颜色标签：系统菜单选择器（取代手绘圆形色钮 + 选中外环）；
                    // C1 色标是数据本身（非状态色），沿用固定色值。
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n("颜色")).controlLabelStyle()
                        Picker(l10n("颜色"), selection: colorSelectionBinding) {
                            ForEach(CaptureOneColorLabel.allCases, id: \.self) { label in
                                Label {
                                    Text(CullingDisplayFormat.title(label, with: l10n))
                                } icon: {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(CullingDisplayFormat.dot(label))
                                }
                                .tag(CaptureOneColorLabel?.some(label))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(isBusy)
                        .help(l10n("设置当前照片的颜色标签"))
                        .accessibilityLabel(l10n("颜色标签"))
                    }
                }

                // P0/K0：关键词 delta 编辑（当前选择集；未多选时作用于当前照片）。
                // P1 / A3：只读元数据（拍摄参数 / IPTC / 文件）。数据来自缓存投影，
                // 由 .task(id:) 在当前照片变化时按需加载，面板本身不触发磁盘解析。
                MetadataSections(
                    detail: viewModel.metadataDetail,
                    selectionCount: max(1, viewModel.selectedPhotoIds.count)
                )
                .task(id: viewModel.currentAsset?.photo.id) {
                    viewModel.loadMetadataDetail()
                }
                .confirmationDialog(
                    l10n("把选中的淘汰照片移出到 _rejects？"),
                    isPresented: $confirmMoveRejected,
                    titleVisibility: .visible
                ) {
                    Button(l10n("移出"), role: .destructive) {
                        Task { await viewModel.moveRejectedOut() }
                    }
                    Button(l10n("取消"), role: .cancel) {}
                } message: {
                    Text(l10n("只移动、不删除；文件可在会话目录的 _rejects 中找回。"))
                }
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .ingest:
                        IngestSheet(viewModel: viewModel, sessionSourcePath: "")
                    case .templates:
                        MetadataTemplateSheet(viewModel: viewModel)
                    case .batches:
                        MetadataBatchSheet(viewModel: viewModel)
                    }
                }

                // P1 / B2：模板批量套用入口（选中集或当前照片）。
                GatherInspectorSection(l10n("元数据模板")) {
                    Button(l10n("套用模板…")) { activeSheet = .templates }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(isBusy || viewModel.currentAsset == nil)
                        .help(l10n("预览后把描述性元数据批量套用到选中的照片"))
                    Button(l10n("历史与撤销…")) { activeSheet = .batches }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .help(l10n("查看最近套用/写回批次并撤销"))
                }

                // P1 / D：摄取入口（复制/重命名/校验 → 登记进当前会话）。
                GatherInspectorSection(l10n("导入")) {
                    Button(l10n("摄取照片…")) { activeSheet = .ingest }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .help(l10n("从存储卡或文件夹复制照片到工作目录并登记"))
                }

                // P1 / E：把技术建议写成 rating（只写空值）+ 私有命名空间，可回溯。
                GatherInspectorSection(l10n("技术建议写回")) {
                    VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
                        Button(l10n("把建议写成评级")) {
                            Task {
                                pendingTriageInput = await viewModel.prepareTriageWriteback()
                                showTriageWritebackConfirm = pendingTriageInput != nil
                            }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(isBusy)
                        Text(l10n("只写空评级；已有星级与人工决策一律不动。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if viewModel.lastTriageWritebackBatchId != nil {
                            Button(l10n("撤销上次建议写回")) {
                                showTriageUndoConfirm = true
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .disabled(isBusy)
                        }
                    }
                    .confirmationDialog(
                        l10n("把全会话的建议写成评级？"),
                        isPresented: $showTriageWritebackConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(l10n("写回")) {
                            guard let input = pendingTriageInput else { return }
                            pendingTriageInput = nil
                            Task {
                                await viewModel.applyTriageWriteback(
                                    Confirmed(input, source: .userDialog))
                            }
                        }
                        Button(l10n("取消"), role: .cancel) { pendingTriageInput = nil }
                    } message: {
                        Text(l10n("会写入全会话所有 keep/reject 建议的私有信号；rating 只写空值。"))
                    }
                    .confirmationDialog(
                        l10n("撤销上次建议写回？"),
                        isPresented: $showTriageUndoConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(l10n("撤销"), role: .destructive) {
                            guard let batchId = viewModel.lastTriageWritebackBatchId,
                                  let input = try? MetadataTemplateUndoInput(batchId: batchId)
                            else { return }
                            Task {
                                await viewModel.undoTriageWriteback(
                                    Confirmed(input, source: .userDialog))
                            }
                        }
                        Button(l10n("取消"), role: .cancel) {}
                    } message: {
                        Text(l10n("还原 rating/关键词，并清除私有命名空间信号。"))
                    }
                }

                GatherInspectorSection(l10n("关键词")) {
                    CullingKeywordPanel(viewModel: viewModel, isBusy: isBusy)
                }

                // G0：排序 / 网格密度 / 建议筛选（可见，不折叠）。
                GatherInspectorSection(l10n("排序与网格")) {
                    VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
                        labeledControl(l10n("排序")) {
                            Picker(l10n("排序"), selection: sortBinding) {
                                Text(l10n("导入顺序")).tag(CullingSort.importOrder)
                                Text(l10n("拍摄时间（新→旧）")).tag(CullingSort.captureDesc)
                                Text(l10n("拍摄时间（旧→新）")).tag(CullingSort.captureAsc)
                                Text(l10n("评分（高→低）")).tag(CullingSort.ratingDesc)
                                if viewModel.triageEnabled {
                                    Text(l10n("建议置信度（低→高）"))
                                        .tag(CullingSort.triageConfidenceAsc)
                                }
                            }
                            .labelsHidden()
                        }

                        labeledControl(l10n("网格密度")) {
                            Picker(l10n("网格密度"), selection: $gridDensity) {
                                ForEach(CullingGridDensity.allCases, id: \.self) { density in
                                    Text(l10n(density.titleKey)).tag(density)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        if viewModel.triageEnabled {
                            labeledControl(l10n("建议筛选")) {
                                Picker(l10n("建议筛选"), selection: triageBinding) {
                                    Text(l10n("全部")).tag(TriageVerdict?.none)
                                    Text(l10n("建议保留")).tag(TriageVerdict?.some(.keep))
                                    Text(l10n("建议淘汰")).tag(TriageVerdict?.some(.reject))
                                    Text(l10n("待复核")).tag(TriageVerdict?.some(.review))
                                }
                                .labelsHidden()
                            }
                        }
                    }
                }

                // P0/T0：技术质量建议（Beta）。生成/应用/复核队列都在这里。
                if viewModel.triageEnabled {
                    GatherInspectorSection(l10n("技术质量建议（Beta）")) {
                        CullingTriageCard(
                            viewModel: viewModel,
                            layoutMode: $layoutMode,
                            isBusy: isBusy
                        )
                    }
                } else {
                    GatherInspectorSection(l10n("技术质量建议（Beta）")) {
                        Text(l10n("已关闭，可在设置中开启。"))
                            .gatherText(.secondary)
                    }
                }

                // 页面级选项：折叠收纳，默认不遮挡当前照片决策。
                GatherInspectorSection(l10n("筛选")) {
                    DisclosureGroup(isExpanded: $filtersExpanded) {
                        CullingFilterControls(
                            viewModel: viewModel,
                            faceAlign: $faceAlign,
                            isBusy: isBusy
                        )
                        .padding(.top, GatherMetrics.Space.xs)
                    } label: {
                        HStack {
                            Text(activeFilterCount == 0
                                 ? l10n("全部照片")
                                 : l10n.format("%lld 项筛选", activeFilterCount))
                                .font(GatherFont.secondary)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }

                // 相似组决策（对齐旧版 groupDecision：仅当前照片所在组 >1 张时显示）。
                if currentGroupAssets.count > 1, let current = viewModel.currentAsset {
                    let groupIds = Set(currentGroupAssets.map(\.photo.id))
                    let selectedInGroup = viewModel.selectedPhotoIds.intersection(groupIds)
                    let keepValid = !selectedInGroup.isEmpty && selectedInGroup.count < currentGroupAssets.count
                    GatherInspectorSection(
                        l10n.format("相似组 · %lld 张", currentGroupAssets.count),
                        subtitle: l10n("其余照片自动淘汰")
                    ) {
                        Button(l10n("保留当前 1 张")) {
                            Task {
                                await viewModel.keepInGroupRejectRest(
                                    current.similarityGroupId ?? "",
                                    keepPhotoIds: [current.photo.id]
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(isBusy)

                        Button(selectedInGroup.isEmpty ? l10n("保留已选 K 张") : l10n.format("保留已选 %lld 张", selectedInGroup.count)) {
                            Task {
                                await viewModel.keepInGroupRejectRest(
                                    current.similarityGroupId ?? "",
                                    keepPhotoIds: selectedInGroup.sorted()
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(!keepValid || isBusy)
                        .help(keepValid ? "" : l10n("按住 ⌘ 或 Ctrl 在胶片中选择要保留的照片"))
                    }
                }

                // 选择管理：批量决策对象（在胶片条中 ⌘/Ctrl 点选）。
                GatherInspectorSection(l10n("选择管理")) {
                    if viewModel.selectedPhotoIds.isEmpty {
                        Text(l10n("未选择照片"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(l10n.format("已选 %lld 张", viewModel.selectedPhotoIds.count))
                            .controlLabelStyle()
                        Button(l10n("取消选择")) { viewModel.clearSelection() }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)

                        // P1 / D：把淘汰件移出工作目录（只移动、不删除，可在 _rejects 找回）。
                        Button(role: .destructive) {
                            confirmMoveRejected = true
                        } label: {
                            Label(l10n("淘汰移出到 _rejects"), systemImage: "arrow.up.bin")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                        .help(l10n("移到会话目录下的 _rejects 文件夹，不删除文件"))
                    }
                }

                // 附加统计（对齐 summaryCard 的增强项：已评分/已标记）。
                if let summary = viewModel.summary {
                    GatherInspectorSection(l10n("统计")) {
                        Text(l10n.format("评分 %lld", summary.rated))
                        Text(l10n.format("标记 %lld", summary.labeled))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GatherMetrics.Space.l)
        }
    }

    private var activeFilterCount: Int {
        let filter = viewModel.filterState
        return [
            filter.unreviewedOnly,
            filter.pickState != nil,
            filter.rating != nil,
            filter.colorLabel != nil,
            filter.qualityStatus != nil,
            filter.metadataConflictOnly,
            filter.triageVerdicts?.isEmpty == false,
        ].filter { $0 }.count
    }

    private func decisionButton(
        icon: String,
        iconColor: Color,
        title: String,
        shortcut: String,
        key: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        DecisionButtonView(
            icon: icon,
            iconColor: iconColor,
            title: title,
            shortcut: shortcut,
            key: key,
            isBusy: isBusy,
            action: action
        )
    }

    /// 当前照片的颜色标签（工具列菜单选择器；选中即写入当前照片）。
    private var colorSelectionBinding: Binding<CaptureOneColorLabel?> {
        Binding(
            get: { viewModel.currentAsset?.state.colorLabel },
            set: { value in
                guard let value else { return }
                Task { await viewModel.commit(patch: CullingUpdatePatch(colorLabel: value)) }
            }
        )
    }

    /// 当前照片所在相似组（已加载范围内）成员，对齐 TS currentGroupAssets。
    private var currentGroupAssets: [CullingAsset] {
        guard let current = viewModel.currentAsset, let groupId = current.similarityGroupId else { return [] }
        return viewModel.page?.assets.filter { $0.similarityGroupId == groupId } ?? []
    }

    private var sortBinding: Binding<CullingSort> {
        Binding(
            get: { viewModel.sortMode },
            set: { value in Task { await viewModel.setSort(value) } }
        )
    }

    private var triageBinding: Binding<TriageVerdict?> {
        Binding(
            get: { viewModel.filterState.triageVerdicts?.first },
            set: { value in
                Task { await viewModel.setTriageVerdicts(value.map { [$0] }) }
            }
        )
    }

    private func labeledControl<Content: View>(
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
}

/// 决策按钮：系统 bordered 按钮（图标 + 标题 + 快捷键提示），
/// 裸键快捷键在按钮自身上声明（任意焦点下窗口级生效）。
private struct DecisionButtonView: View {
    let icon: String
    let iconColor: Color
    let title: String
    let shortcut: String
    let key: KeyEquivalent
    let isBusy: Bool
    let action: () -> Void

    /// Cut 4 / 4b-2a：快捷键提示是 "标题（快捷键 X）"模板，语言源与页面同源。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: GatherMetrics.Space.s) {
                Image(systemName: icon)
                    .imageScale(.medium)
                    .foregroundStyle(iconColor)
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(shortcut)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        // 裸键由查看器的 onKeyPress 统一注册（见 CullingWorkbenchViewer），
        .disabled(isBusy)
        .help(l10n.format("%@（快捷键 %@）", title, shortcut))
        .accessibilityLabel(title)
        .accessibilityHint(l10n.format("快捷键 %@", shortcut))
    }
}

/// 检查器 Section / 胶片条控制组标签样式（原生化：.callout 承载内容语义，中文不再加字距）。
private extension View {
    func controlLabelStyle() -> some View {
        font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
