// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryStackActions.swift
// Wave1 · 堆栈管理 UI：多选菜单 / 网格右键 / 重命名 sheet / 取消堆叠确认。
//
// 与 CollectionView、CollectionSidebar 同一套交互语言：
// - 非破坏性动作（新建/加入/移出/重命名）按下即执行，结果直接体现在网格徽标与
//   「加入堆栈」菜单的张数上；
// - 破坏性动作（取消堆叠）走 gatherDestructiveConfirm，Confirmed 只从确认分支
//   构造，取消分支不发任何命令；
// - 错误统一进 viewModel.actionError（页面顶部 NativeBanner），不另开提示通道。
import SwiftUI
import GatherProtocol

/// 待确认的「取消堆叠」目标（gatherDestructiveConfirm 需要 Identifiable）。
struct PendingStackDissolve: Identifiable, Equatable {
    let stackId: String
    let name: String
    let memberCount: Int
    var id: String { stackId }
}

/// 待重命名的堆栈目标（sheet(item:) 需要 Identifiable）。
struct PendingStackRename: Identifiable, Equatable {
    let stackId: String
    var id: String { stackId }
}

extension GalleryView {

    // MARK: - 菜单内容（选择栏与网格右键共用同一份条目）

    /// 堆栈动作条目。targetIds 是动作作用对象（多选时是选中集，右键时按
    /// 「指针下的照片在不在选中集内」决定，与既有「加入集合」同口径）。
    @ViewBuilder
    func stackMenuItems(for targetIds: [String]) -> some View {
        let ids = targetIds.sorted()
        let folds = viewModel.folds(for: ids)
        Button(l10n("新建堆栈")) {
            Task { await viewModel.createStack(photoIds: ids) }
        }
        .disabled(ids.count < 2 || viewModel.isStackBusy)

        if !viewModel.stacks.isEmpty {
            Menu(l10n("加入堆栈")) {
                ForEach(viewModel.stacks) { stack in
                    Button(stackMenuTitle(stack)) {
                        Task { await viewModel.addToStack(stackId: stack.id, photoIds: ids) }
                    }
                    .disabled(viewModel.isStackBusy)
                }
            }
        }
        if !folds.isEmpty {
            Menu(l10n("移出堆栈")) {
                ForEach(folds) { fold in
                    Button(removeFromStackTitle(fold, ids: ids)) {
                        Task { await viewModel.removeFromStack(stackId: fold.stackId, photoIds: ids) }
                    }
                    .disabled(viewModel.isStackBusy)
                }
            }
        }
        // 仅当目标全部落在同一个堆栈里时，重命名/取消堆叠才有唯一对象。
        if folds.count == 1, let fold = folds.first,
           ids.allSatisfy({ fold.photoIds.contains($0) }) {
            Button(l10n("重命名堆栈")) { requestStackRename(fold) }
                .disabled(viewModel.isStackBusy)
            Button(l10n("取消堆叠"), role: .destructive) { requestStackDissolve(fold) }
                .disabled(viewModel.isStackBusy)
        }
    }

    /// 选择栏里的「堆栈」菜单（与「批量操作」并列；至少选 1 张时可用）。
    var stackMenu: some View {
        Menu(l10n("堆栈")) {
            stackMenuItems(for: Array(viewModel.selectedIds))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.selectedIds.isEmpty)
    }

    // MARK: - 延迟动作（重命名 sheet / 取消堆叠确认）

    func requestStackRename(_ fold: StackFold) {
        stackRenameText = fold.name
        pendingStackRename = PendingStackRename(stackId: fold.stackId)
    }

    func commitStackRename() {
        guard let pending = pendingStackRename else { return }
        let name = stackRenameText
        pendingStackRename = nil
        Task { await viewModel.renameStack(stackId: pending.stackId, name: name) }
    }

    func requestStackDissolve(_ fold: StackFold) {
        pendingStackDissolve = PendingStackDissolve(
            stackId: fold.stackId,
            name: stackDisplayName(fold.name),
            memberCount: fold.photoIds.count)
    }

    // MARK: - 文案

    /// 堆栈显示名：空名统一显示「未命名堆栈」（服务端允许空名）。
    func stackDisplayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? l10n("未命名堆栈") : trimmed
    }

    /// 「加入堆栈」条目：名称 + 张数（同名堆栈靠张数区分）。
    private func stackMenuTitle(_ stack: StackSummary) -> String {
        l10n.format("%@（%lld 张）", stackDisplayName(stack.name), stack.memberCount)
    }

    /// 「移出堆栈」条目：只算本次选中、且确实在该堆里的张数。
    private func removeFromStackTitle(_ fold: StackFold, ids: [String]) -> String {
        let matched = fold.photoIds.filter { ids.contains($0) }.count
        return l10n.format("从「%@」移出 %lld 张", stackDisplayName(fold.name), matched)
    }

    // MARK: - 重命名 sheet

    var stackRenameSheet: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("重命名堆栈"))
                .font(GatherFont.sectionTitle)
            TextField(l10n("堆栈名称"), text: $stackRenameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitStackRename() }
            HStack {
                Spacer(minLength: 0)
                Button(l10n("取消")) { pendingStackRename = nil }
                    .gatherButton(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                Button(l10n("保存")) { commitStackRename() }
                    .gatherButton(.primary)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(stackRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 320)
    }
}
