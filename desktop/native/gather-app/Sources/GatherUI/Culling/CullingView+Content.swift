// desktop/native/gather-app/Sources/GatherUI/Culling/CullingView+Content.swift
// Cut 4 / 4c-2a：壳层数据驱动内容（横幅 / 空态 / 载入失败 / 工作台）与页面生命周期。
// 纯搬移（原 CullingView.body 的 VStack 与 .task/.onReceive）；这些 modifier 仍作用在
// 同一个 VStack 上、顺序不变，body 里再接确认弹窗、外层由 GatherSessionPage 提供骨架。
// appearance：页面级 setPageVisible 已收归 GatherSessionPage，本文件不再自建
// onAppear/onDisappear；页面底色也交给骨架的 canvas 表面。
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
                            layoutMode: layoutBinding
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
                        layoutMode: layoutBinding,
                        density: densityBinding,
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
        .task {
            // G0：布局决定首页大小（网格 200，其余 500）；在首次加载前静默设置。
            viewModel.applyPageLimit(layoutMode == .grid ? 200 : 500)
            // 排序优先 SceneStorage（用户上次选择），否则用设置默认值。
            if let stored = CullingSort(rawValue: sortRaw), viewModel.sortMode != stored {
                viewModel.applySort(stored)
            }
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
            } else if viewModel.page == nil {
                // 页签重建不应重置已翻页的网格；隐藏期变更由 setVisible 补刷。
                await viewModel.load()
            }
        }
        // 可见性门控（审计 P1-并发 / Cut 4 4a-2b / R4 P1-2）：条件渲染页离开即销毁，
        // 页面级启停由 GatherSessionPage 的 onAppear/onDisappear 经
        // workspace.setPageVisible(.culling, …) 路由到 culling VM（进入会话不再由
        // workspace 全量置真）。补刷隐藏期领域变更、恢复/停止画质 500ms 轮询都在
        // CullingViewModel.setVisible 内部——本页不再重复调用，避免两处启停互相覆盖。
        // 写回协调器 emitSummary 后刷新同步状态（TS useEvent('culling:sync-status')）。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
            guard (notification.object as? String) == viewModel.sessionId else { return }
            Task { await viewModel.refreshSyncStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.settingsChanged)) { _ in
            Task { await viewModel.refreshTriageSettings() }
        }
        // 跨页领域变更（挑片/元数据/图库）：可见时按域补刷，隐藏时只登记，
        // 回可见由 onAppear 统一补一次；自身 origin 在 VM 内跳过。
        .handleDomainEvents(Set(GatherChangeDomain.allCases)) { change in
            viewModel.handleDomainChange(change)
        }
    }

    private func emptyGuide(title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .padding(.vertical, 48)
        // 空态自己撑满剩余区域并居中；GatherSessionPage 的 topLeading 只负责
        // 让页签行贴顶，不应把空态一起顶到上方。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
