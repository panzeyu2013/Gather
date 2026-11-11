// desktop/native/gather-app/Sources/GatherUI/Culling/CullingSyncControls.swift
// P1-9：同步/写回/重置的唯一动作入口。
//
// 旧实现把这些动作只放在 CullingInfoBar；切到网格布局时 infoBar 不渲染，
// 用户就无法写回 XMP / 确认同步 / 重置挑片。这里抽成布局无关的组件，
// 只由 toolbar（三种布局共用）挂载，动作只有一个实现。
import SwiftUI
import GatherProtocol

struct CullingSyncControls: View {
    let viewModel: CullingViewModel
    let isBusy: Bool
    @Binding var pendingAction: PendingCullingAction?
    /// 紧凑工具栏只画图标，避免挤掉范围/布局控件。
    var compact = false

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        Menu {
            Button(l10n("立即写入 XMP")) { Task { await viewModel.flush() } }
                .disabled(isBusy)
            Menu {
                Button(l10n("评分")) { pendingAction = .writeback(.rating) }
                Button(l10n("颜色标签")) { pendingAction = .writeback(.colorLabel) }
                // Wave5 / N6：删除「挑片关键词」入口 —— 挑片判断不再用 culling:keep /
                // culling:reject 关键词承载（C1 Load Metadata 会把它吸进自己的词库）。
                // 判断的在线通道是下面的「在 Capture One 中写回判断（变体级）」。
            } label: {
                Label(l10n("写回 XMP…"), systemImage: "square.and.arrow.up")
            }
            .disabled(!hasDecisions || isBusy)
            .help(l10n("把已决策照片的当前评分/色标写回 XMP（挑片关键词不写 XMP，避免污染 C1 词库）"))
            Divider()
            // G10：selectVariants 早已实现（API 有 / UI 无），这里给出唯一 UI 入口。
            // 放在同步菜单里：回 C1 看大图/调色是写回之后的下一步动作。
            Button(l10n("在 Capture One 中显示")) { Task { await viewModel.showInCaptureOne() } }
                .disabled(isBusy)
                .help(l10n("在 Capture One 中选中这些照片；只改变选中，不导入"))
            // Wave3 / G4：在线通道——直接写 C1 catalog 的 variant 属性（不用关键词表达 pick）。
            Button(l10n("在 Capture One 中写回判断（变体级）")) {
                Task { await viewModel.writeVariantJudgementsToCaptureOne() }
            }
            .disabled(isBusy)
            .help(l10n("写回星级/色标/保留（keep）到 C1 当前页；C1 无淘汰位（淘汰不写回），跨页请分批"))
            if (viewModel.syncStatus?.written ?? 0) > 0 {
                Button(l10n("在 Capture One 中加载元数据")) { Task { await viewModel.reloadCaptureOne() } }
                    .disabled(!viewModel.canLoadMetadata || isBusy)
                    .help(syncLoadHint)
                // G2：脚本失败/没有选中项时 confirm 会被 reload-ack 门禁永久挡住；
                // 用户在 C1 手动 Load Metadata 后由这里显式写 ack（唯一兜底出口）。
                if !viewModel.reloadAcked {
                    Button(l10n("我已在 Capture One 手动加载元数据")) {
                        Task { await viewModel.acknowledgeManualReload() }
                    }
                    .disabled(isBusy)
                    .help(l10n("在 Capture One 手动执行 Load Metadata 后点击；记录重载确认，解除确认/结束同步的门禁"))
                }
                Button(l10n("已在 Capture One 加载")) { Task { await viewModel.confirmSync() } }
                    .disabled(!viewModel.canConfirmSync || isBusy)
                    .help(syncConfirmHint)
            }
            if (viewModel.syncStatus?.failed ?? 0) > 0 {
                Button(l10n("重试失败项")) { pendingAction = .retryFailedWriteback }
                    .disabled(isBusy)
            }
            if (viewModel.syncStatus?.synced ?? 0) > 0 {
                Button(l10n("保留 XMP 并结束")) { pendingAction = .finalizeSync }
                    .disabled(isBusy)
                Button(l10n("恢复原 XMP"), role: .destructive) { pendingAction = .cleanup }
                    .disabled(!viewModel.canCleanup)
                    .help(syncCleanupHint)
            }
            Divider()
            Button(l10n("重置挑片"), role: .destructive) { pendingAction = .reset }
                .disabled(isBusy)
        } label: {
            if compact {
                Image(systemName: "arrow.triangle.2.circlepath")
            } else {
                Label(l10n("同步…"), systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help(l10n("先在 Capture One 中 Load Metadata，再返回 Gather 确认同步"))
        .accessibilityLabel(l10n("同步与写回"))
    }

    /// 写回入口可用性：没有已决策照片就没有可写回的计划（服务端会抛 CULLING_NO_DECISIONS）。
    private var hasDecisions: Bool {
        viewModel.decidedPhotoCount > 0
    }

    /// 逐按钮禁用 hint（对齐旧版 c1-sync-controls.ts 的独立 title 提示粒度）。
    private var syncLoadHint: String {
        switch viewModel.syncFlowState() {
        case .synced: return l10n("已完成同步，无需再次加载元数据")
        case .failed: return l10n("存在写入失败项，请先重试")
        case .conflict: return l10n("存在 XMP 冲突，请先裁决")
        default: return l10n("没有可加载的已写入元数据")
        }
    }

    private var syncConfirmHint: String {
        switch viewModel.syncFlowState() {
        case .synced: return l10n("已完成同步")
        default:
            return viewModel.reloadAcked
                ? l10n("请先等待写入完成或处理失败项")
                : l10n("请先在 Capture One 中加载元数据，再确认同步")
        }
    }

    private var syncCleanupHint: String {
        viewModel.syncFlowState() == .synced
            ? l10n("已完成清理")
            : l10n("请先加载元数据并确认同步，再执行清理")
    }
}
