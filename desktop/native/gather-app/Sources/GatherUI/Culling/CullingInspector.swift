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

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 当前照片：决策条（对齐旧版 decisionBar：✓ 保留 P / × 淘汰 X / ○ 未处理 U）
                // + 星级 + 颜色。系统 bordered 按钮 + 裸键 .keyboardShortcut（取代手绘卡片描边）。
                GroupBox {
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
                } label: {
                    Text(l10n("当前照片"))
                }

                // 相似组决策（对齐旧版 groupDecision：仅当前照片所在组 >1 张时显示）。
                if currentGroupAssets.count > 1, let current = viewModel.currentAsset {
                    let groupIds = Set(currentGroupAssets.map(\.photo.id))
                    let selectedInGroup = viewModel.selectedPhotoIds.intersection(groupIds)
                    let keepValid = !selectedInGroup.isEmpty && selectedInGroup.count < currentGroupAssets.count
                    GroupBox {
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
                    } label: {
                        Text(l10n.format("相似组 · %lld 张", currentGroupAssets.count))
                        Text(l10n("其余照片自动淘汰"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                // 选择管理：批量决策对象（在胶片条中 ⌘/Ctrl 点选）。
                GroupBox {
                    if viewModel.selectedPhotoIds.isEmpty {
                        Text(l10n("未选择照片"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(l10n.format("已选 %lld 张", viewModel.selectedPhotoIds.count))
                            .controlLabelStyle()
                        Button(l10n("取消选择")) { viewModel.clearSelection() }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                } label: {
                    Text(l10n("选择管理"))
                }

                // 附加统计（对齐 summaryCard 的增强项：已评分/已标记）。
                if let summary = viewModel.summary {
                    GroupBox {
                        Text(l10n.format("评分 %lld", summary.rated))
                        Text(l10n.format("标记 %lld", summary.labeled))
                    } label: {
                        Text(l10n("统计"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
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
            HStack(spacing: 8) {
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
