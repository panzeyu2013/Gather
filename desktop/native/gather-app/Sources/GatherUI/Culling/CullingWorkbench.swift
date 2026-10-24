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
    @Binding var compareCount: Int
    @Binding var faceAlign: Bool
    @Binding var pendingAction: PendingCullingAction?
    @Binding var conflictChoices: [String: MetadataConflictChoice]
    @State private var filmstripExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            CullingToolbar(
                viewModel: viewModel,
                isBusy: isBusy,
                compareCount: $compareCount
            )
            // 竖向分割：查看器 + infoBar 占据上半区，全宽胶片条固定在底部。
            // （旧版把胶片条放在右侧，与右侧 .inspector 两栏夹击查看器。）
            VStack(spacing: 0) {
                // 查看器：对比/人脸对齐/翻页变化经 onChange 显式复位缩放
                // （复用旧版 resetTransform 语义）。不使用 .id() 重建——
                // 整树销毁会扰动窗口焦点/事件监听，导致快捷键与后续
                // 点击异常。
                CullingWorkbenchViewer(
                    viewModel: viewModel,
                    compareCount: compareCount,
                    faceAlign: faceAlign
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                CullingInfoBar(viewModel: viewModel, isBusy: isBusy, pendingAction: $pendingAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
