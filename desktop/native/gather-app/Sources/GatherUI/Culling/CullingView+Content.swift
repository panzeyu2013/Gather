// desktop/native/gather-app/Sources/GatherUI/Culling/CullingView+Content.swift
// Cut 4 / 4c-2a：壳层数据驱动内容（横幅 / 空态 / 载入失败 / 工作台）与页面生命周期。
// 纯搬移（原 CullingView.body 的 VStack 与 .task/.onAppear/.onDisappear/.onReceive）；
// 这些 modifier 仍作用在同一个 VStack 上、顺序不变，body 后再接确认/窗口 chrome。
import SwiftUI
import GatherProtocol

extension CullingView {
    var shellContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.errorMessage {
                NativeBanner(
                    text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                    color: GatherTheme.error
                )
            }
            if let notice = viewModel.notice {
                NativeBanner(text: notice.resolve(with: l10n), color: GatherTheme.success)
            }
            if viewModel.sessionId.isEmpty {
                emptyGuide(
                    title: l10n("未打开工作区"),
                    systemImage: "rectangle.stack",
                    message: l10n("请先打开一个工作区，再进入挑片页。")
                )
            } else if let page = viewModel.page {
                if page.assets.isEmpty {
                    // TS Culling.tsx:1157-1173：空列表时保留工具/筛选栏 + 空态文案。
                    VStack(spacing: 0) {
                        CullingToolbar(
                            viewModel: viewModel,
                            isBusy: isBusy,
                            compareCount: $compareCount,
                            faceAlign: $faceAlign
                        )
                        emptyGuide(
                            title: l10n("当前范围没有照片"),
                            systemImage: "photo.on.rectangle.angled",
                            message: l10n("切换到「全部照片」或清除筛选条件。")
                        )
                    }
                } else {
                    CullingWorkbench(
                        viewModel: viewModel,
                        isBusy: isBusy,
                        compareCount: $compareCount,
                        faceAlign: $faceAlign,
                        pendingAction: $pendingAction,
                        conflictChoices: $conflictChoices
                    )
                }
            } else if let error = viewModel.errorMessage {
                // 加载失败不留空面板/黑屏：系统空态 + 重试出口。
                ContentUnavailableView {
                    Label(l10n("载入挑片工作台失败"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(CommandErrorText.resolve(error, with: l10n))
                } actions: {
                    Button(l10n("重试")) { Task { await viewModel.load() } }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView(l10n("正在载入挑片工作台…"))
                        .controlSize(.large)
                        .padding(.vertical, 60)
                    Spacer()
                }
            }
        }
        .background(GatherTheme.windowBackground)
        .task {
            // D10：控制中心「N 个 XMP 冲突待裁决 → 逐条裁决」的入口意图。
            // 旧实现只切到挑片页，用户还得自己找冲突；有缓存状态时甚至回到上一次
            // 无关的筛选。这里在页面就位后把筛选一次性收敛到冲突，并消费意图
            //（事件语义：每次入口点击生效一次，不重复套用）。
            if case .cullingConflicts? = workspace.take(.cullingConflicts) {
                // A2（审计 4）：入口语义是「收敛到冲突」，不是「与上次的筛选求交」。
                // 挑片 VM 跨页签缓存了上一次的未审/星级/色标等维度，只置位
                // metadataConflictOnly 会变成 AND（很可能 0 行，与同屏「N 个冲突」矛盾）。
                // 因此整份筛选重置为「只看冲突」再加载。
                // A3（审计 4）：setFilterState 内部已经触发一次 loadPage(reset:)，
                // 这里不再调用 load()，避免同一次进入跑两轮完整加载 + 两个 conflicts 请求。
                await viewModel.setFilterState { state in
                    state = CullingViewModel.FilterState()
                    state.metadataConflictOnly = true
                }
            } else {
                await viewModel.load()
            }
        }
        // 可见性门控（审计 P1-并发 / Cut 4 4a-2b / R4 P1-2）：条件渲染页离开即销毁，
        // 页面级启停只由本页 onAppear/onDisappear 经 workspace 路由到 culling VM
        //（进入会话不再由 workspace 全量置真）；onAppear 补刷隐藏期领域变更并
        // 恢复画质轮询，onDisappear 停掉 500ms 轮询（隐藏页不发命令）。
        .onAppear {
            workspace.setPageVisible(.culling, true)
        }
        .onDisappear {
            workspace.setPageVisible(.culling, false)
        }
        // 写回协调器 emitSummary 后刷新同步状态（TS useEvent('culling:sync-status')）。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
            guard (notification.object as? String) == viewModel.sessionId else { return }
            Task { await viewModel.refreshSyncStatus() }
        }
        // 跨页领域变更（挑片/元数据/图库）：可见时按域补刷，隐藏时只登记，
        // 回可见由 onAppear 统一补一次；自身 origin 在 VM 内跳过。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
            guard let change = notification.object as? GatherApplicationChange else { return }
            viewModel.handleDomainChange(change)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gatherMenuUndo)) { _ in
            Task { await viewModel.undo() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gatherMenuRedo)) { _ in
            Task { await viewModel.redo() }
        }
    }

    private func emptyGuide(title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .padding(.vertical, 48)
    }
}
