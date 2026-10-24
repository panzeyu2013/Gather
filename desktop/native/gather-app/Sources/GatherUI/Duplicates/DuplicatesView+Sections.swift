// desktop/native/gather-app/Sources/GatherUI/Duplicates/DuplicatesView+Sections.swift
// Cut 4 / 4c-2g：DuplicatesView 的分段视图（原 DuplicatesView.swift 610-770）。
// 纯搬移：加载指示 / 扫描控件 / 类型分段 / 空态与分组卡组合的层级、文案、
// 动作与禁用条件逐字未动；语言源仍从 environment 取（与页面同源），
// 需要写 VM 的控件用 @Bindable 保持 $viewModel.showExact 原位绑定。
import SwiftUI
import GatherProtocol

/// 加载/扫描进度指示（对齐旧版 Duplicates.module.css .loading「加载中…」灰字）。
/// 扫描中显示相位文案 + (n/N) 计数 + 取消按钮（JobService 进度事件驱动）。
struct DuplicatesLoadingIndicator: View {
    let viewModel: DuplicatesViewModel

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if viewModel.isScanning {
                Text(l10n.progressPhaseText(viewModel.scanProgressPhase))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                if viewModel.scanProgressTotal > 0 {
                    Text("\(viewModel.scanProgressCurrent)/\(viewModel.scanProgressTotal)")
                        .font(GatherFont.mono)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n("取消"), systemImage: "stop.fill") {
                    Task { await viewModel.cancelScan() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(l10n("加载中…"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct DuplicatesScanControls: View {
    @Bindable var viewModel: DuplicatesViewModel
    @Binding var showAdvancedScan: Bool

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("扫描设置"))
                .font(GatherFont.sectionTitle)
            // 三档预设 = 系统分段控件（取代手绘选中底色/描边的 Button 组）。
            LabeledContent(l10n("匹配强度")) {
                Picker(l10n("匹配强度"), selection: presetBinding) {
                    ForEach(VisualPreset.allCases, id: \.self) { preset in
                        Text(preset.label(with: l10n)).tag(VisualPreset?.some(preset))
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
                    SliderInputIntView(title: l10n("视觉相似阈值"), value: $viewModel.threshold, range: 0...10)
                    Text(l10n("0 (严格) — 10 (宽松)"))
                        .font(GatherFont.secondary).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } label: {
                Text(l10n("高级：相似阈值"))
                    .font(GatherFont.secondary)
            }
            .disabled(viewModel.isScanning)

            HStack(spacing: 12) {
                // 本页唯一的「开始扫描」主动作（空态不再重复放一个同权按钮）。
                Button(viewModel.isScanning ? l10n("扫描中…") : l10n("开始扫描"), systemImage: "magnifyingglass") {
                    Task { await viewModel.scan() }
                }
                .gatherPrimaryActionButton()
                .disabled(viewModel.isScanning)
                if !viewModel.isScanning, let preset = viewModel.activePreset {
                    Text(l10n.format("当前档位：%@", preset.label(with: l10n)))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .gatherCard()
        .frame(maxWidth: 760, alignment: .leading)
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
}

struct DuplicatesTabSelector: View {
    @Bindable var viewModel: DuplicatesViewModel

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        // 计数是内容语义：用普通文本（不再以 .footnote 10pt 承载）。
        Picker(l10n("类型"), selection: $viewModel.showExact) {
            Text("\(l10n("完全重复")) · \(viewModel.exactGroupCount)").tag(true)
            Text("\(l10n("视觉相似")) · \(viewModel.visualGroupCount)").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 300)
        .accessibilityLabel(l10n("重复类型"))
        .onChange(of: viewModel.showExact) { _, _ in
            viewModel.resetPagination()
        }
    }
}

/// 空态 / 失败态：全部走系统 ContentUnavailableView；
/// 加载失败必须给重试出口（不渲染误导性的「先运行扫描」）。
struct DuplicatesEmptyState: View {
    let viewModel: DuplicatesViewModel

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        if let error = viewModel.errorMessage, viewModel.scanResult == nil {
            ContentUnavailableView {
                Label(l10n("载入重复照片失败"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(CommandErrorText.resolve(error, with: l10n))
            } actions: {
                Button(l10n("重试")) { Task { await viewModel.load() } }
                    .disabled(viewModel.isLoading)
            }
        } else if viewModel.scanResult == nil {
            // F13：空态不再放第二个同权「开始扫描」——上面控制卡里的主动作就是它。
            ContentUnavailableView {
                Label(l10n("尚未扫描"), systemImage: "square.on.square")
            } description: {
                Text(l10n("用上方的「开始扫描」检测内容完全一致的文件与视觉近似候选。"))
            }
        } else if viewModel.showExact {
            ContentUnavailableView(
                l10n("未发现完全重复的照片"),
                systemImage: "square.on.square",
                description: Text(l10n("当前工作区没有内容完全一致的文件。"))
            )
        } else {
            ContentUnavailableView(
                l10n("未发现视觉相似的照片"),
                systemImage: "square.on.square",
                description: Text(l10n("可适当放宽匹配强度后重新扫描。"))
            )
        }
    }
}

/// 分组卡组合：推荐保留与卡片徽章同源；在视图（MainActor）上下文预计算，
/// 供确认弹窗展示影响范围（保留哪一张、丢弃几张）。
struct DuplicatesGroupCard: View {
    let group: DuplicateGroup
    let viewModel: DuplicatesViewModel
    let onResolve: (PendingGroupResolution) -> Void
    let onSetMemberKept: (PendingMemberDecision) -> Void
    var onOpenPhoto: ((String) -> Void)? = nil

    var body: some View {
        let recommendedFilename = DuplicatesViewModel.recommendation(in: group)?.filename
        return DuplicatesGroupCardView(
            group: group,
            viewModel: viewModel,
            onResolve: { group, resolution in
                onResolve(
                    PendingGroupResolution(
                        group: group,
                        resolution: resolution,
                        recommendedFilename: recommendedFilename
                    )
                )
            },
            onSetMemberKept: { member, isKept in
                onSetMemberKept(PendingMemberDecision(member: member, isKept: isKept))
            },
            onOpenPhoto: onOpenPhoto
        )
    }
}
