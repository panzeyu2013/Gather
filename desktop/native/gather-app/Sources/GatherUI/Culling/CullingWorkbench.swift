// desktop/native/gather-app/Sources/GatherUI/Culling/CullingWorkbench.swift
// Cut 4 / 4c-2a：工作台层级组合（原 CullingView.workbench，1875-1920 行，逐字搬移）。
// 视图层级/顺序/修饰符不变：VStack[toolbar, VStack[viewer, infoBar]+overlay(conflict), filmstrip]。
import SwiftUI
import GatherProtocol

/// 工作台：Bridge / Lightroom / darktable 式查看器居中，胶片条横贯底部。
///
/// 工作台（Bridge / Lightroom / darktable 式：查看器居中，胶片条横贯底部——
/// darktable 文档即写明胶片条 "at the bottom"；原 214px 工具列已迁入系统
/// .inspector，顶部工具栏横贯内容区）。
struct CullingWorkbench: View {
    let viewModel: CullingViewModel
    let isBusy: Bool
    @Binding var layoutMode: CullingLayoutMode
    @Binding var density: CullingGridDensity
    @Binding var faceAlign: Bool
    @Binding var pendingAction: PendingCullingAction?
    @Binding var conflictChoices: [String: MetadataConflictChoice]
    /// 胶片条展开态由页面持有：专注模式要程序化折叠，退出时按进入前状态恢复。
    @Binding var filmstripExpanded: Bool
    /// 专注模式（只对查看器布局生效；网格布局不受影响）。
    var isFocusMode = false
    /// 专注模式切换（F 裸键在查看器内触发，按钮/菜单同入口）。
    var onToggleFocusMode: () -> Void = {}

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// 忙碌文案（nil = 不显示角标）。P0-4 要求"不再静默丢键"，因此这里必须有
    /// 可见反馈，而不是等照片状态莫名其妙变了才发现。
    /// 只覆盖三类：按键排队 / 决策写入 / 页面加载——质量分析等后台任务有自己的
    /// 进度控件，不能借用"正在写入挑片决策"的语义。
    private var busyText: String? {
        if viewModel.hasPendingCommit { return l10n("按键已排队") }
        if viewModel.isCommitting { return l10n("正在写入挑片决策…") }
        if viewModel.isLoading { return l10n("加载中…") }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            CullingToolbar(
                viewModel: viewModel,
                isBusy: isBusy,
                layoutMode: $layoutMode,
                pendingAction: $pendingAction
            )
            // 竖向分割：查看器 + infoBar 占据上半区，全宽胶片条固定在底部。
            // （旧版把胶片条放在右侧，与右侧 .inspector 两栏夹击查看器。）
            VStack(spacing: 0) {
                // 查看器：对比/人脸对齐/翻页变化经 onChange 显式复位缩放
                // （复用旧版 resetTransform 语义）。不使用 .id() 重建——
                // 整树销毁会扰动窗口焦点/事件监听，导致快捷键与后续
                // 点击异常。
                if layoutMode == .grid {
                    CullingGridView(
                        viewModel: viewModel,
                        density: density,
                        onOpenSingle: { layoutMode = .single }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CullingWorkbenchViewer(
                        viewModel: viewModel,
                        // Wave2（#6）：Survey 的张数由当前选择集决定（2...9）；
                        // 2/3/4 图仍按固定格数（选择集不影响它们）。
                        compareCount: layoutMode.effectiveCompareCount(
                            selectionCount: viewModel.selectedPhotoIds.count),
                        isSurvey: layoutMode == .survey,
                        faceAlign: faceAlign,
                        isFocusMode: isFocusMode,
                        onToggleFocusMode: onToggleFocusMode
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    CullingInfoBar(viewModel: viewModel, isBusy: isBusy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // P0-4 忙碌角标：加载/提交/排队期间浮在查看器/网格右上角（不占布局
            // 高度，不挤压照片）。Wave4b / P2-10：网格布局同样可能排队按键，
            // 不能只在查看器布局显示，否则 P0-4 在网格里仍是静默丢键。
            .overlay(alignment: .topTrailing) {
                if let busyText {
                    CullingWorkbenchBusyBadge(text: busyText)
                        .padding(GatherMetrics.Space.s)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // 浮动冲突面板（对齐旧版 .conflictPanel 定位：右下、infoBar 之上；
                // 宽度不超过 540，且不超过窗口可用宽 - 32）。
                // 锚在「查看器 + infoBar」区域而非整页：胶片条移到最底部后，
                // 面板仍需浮在 infoBar 之上，不能压住胶片条。
                GeometryReader { geometry in
                    // 约束循环修复（F01）：geometry.size.width 在首帧/未定宽时为 0，
                    // min(540, 0 - 32) = -32 会安装**负宽度约束**，AppKit 必须再跑
                    // 一轮约束更新；叠加 .inspector 的列宽协商就耗尽 pass 预算。
                    // 这里钳到非负，并且只在真的有冲突面板时下固定宽度
                    //（conflicts 为空时 conflictPanel 是空视图，不该占宽度）。
                    if !viewModel.conflicts.isEmpty {
                        CullingConflictPanel(
                            viewModel: viewModel,
                            pendingAction: $pendingAction,
                            conflictChoices: $conflictChoices
                        )
                            .frame(width: max(0, min(540, geometry.size.width - 32)))
                            .padding(.trailing, 14)
                            .padding(.bottom, 52)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
            }
            CullingFilmstrip(viewModel: viewModel, isExpanded: $filmstripExpanded)
        }
    }
}

/// 工作台忙碌角标（P0-4）：加载 / 决策提交 / 按键排队时的可见反馈。
/// 浮在照片之上属功能层：用查看器深色胶囊保证在任何照片上都可读。
private struct CullingWorkbenchBusyBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: GatherMetrics.Space.xs) {
            ProgressView()
                .controlSize(.mini)
                .tint(GatherTheme.viewerTextPrimary)
            Text(text)
                .font(GatherFont.label)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, GatherMetrics.Space.s)
        .padding(.vertical, GatherMetrics.Space.xs)
        .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.85)))
        .accessibilityElement(children: .combine)
    }
}
