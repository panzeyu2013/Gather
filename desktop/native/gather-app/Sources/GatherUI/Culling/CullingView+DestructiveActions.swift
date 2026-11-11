// desktop/native/gather-app/Sources/GatherUI/Culling/CullingView+DestructiveActions.swift
// Cut 4 / 4c-2a：破坏性动作集合 + 确认文案 + 确认分支（原 CullingView.swift 1784-1873 行）。
// 唯一改动：private -> internal（extension 跨文件访问壳的 viewModel/l10n）；
// confirmed: true 仍只从 perform 的确认分支到达，不存在硬编码 true。
import SwiftUI
import GatherProtocol

enum PendingCullingAction: Identifiable {
    case reset
    case cleanup
    case writeback(CullingWritebackTarget)
    case retryFailedWriteback
    case finalizeSync
    case resolveConflict(MetadataConflict, [MetadataField: MetadataConflictChoice])
    /// P1-8：相似组决策的真实影响面（完整组员数 + 当前可见数 + 样本文件名）。
    case groupDecision(CullingGroupDecisionPlan)
    /// P1-7：跨页全选批量（服务端重算 + hash）。
    case crossPageBatch(CullingCrossPageBatchPlan)
    /// P2-5：全部冲突采用同一策略。
    case resolveAllConflicts(MetadataConflictChoice)

    var id: String {
        switch self {
        case .reset: "reset"
        case .cleanup: "cleanup"
        case .writeback(let target): "writeback:\(target.rawValue)"
        case .retryFailedWriteback: "retry_failed_writeback"
        case .finalizeSync: "finalize_sync"
        case .resolveConflict(let conflict, let choices):
            "resolve:\(conflict.xmpPath):" + choices
                .map { "\($0.key.rawValue)=\($0.value.rawValue)" }
                .sorted()
                .joined(separator: ",")
        case .groupDecision(let plan):
            "group:\(plan.id)"
        case .crossPageBatch(let plan):
            "cross:\(plan.id)"
        case .resolveAllConflicts(let choice):
            "resolve_all:\(choice.rawValue)"
        }
    }

    /// 4b-2a：动作标题只存 key（确认弹窗按钮与取消提示共用）；渲染期再解析。
    var actionText: LocalizedText {
        switch self {
        case .reset: return LocalizedText("重置挑片状态")
        case .cleanup: return LocalizedText("清理写回备份")
        case .writeback(let target):
            switch target {
            case .rating: return LocalizedText("写回评分到 XMP")
            case .colorLabel: return LocalizedText("写回颜色标签到 XMP")
            // Wave5 / N6：关键词写回已停用（不写 XMP，避免污染 C1 词库）。
            case .keyword: return LocalizedText("挑片关键词写回（已停用）")
            }
        case .retryFailedWriteback: return LocalizedText("重试失败写回项")
        case .finalizeSync: return LocalizedText("保留 XMP 并结束同步")
        case .resolveConflict: return LocalizedText("裁决 XMP 冲突")
        case .groupDecision: return LocalizedText("保留所选并淘汰同组其余")
        case .crossPageBatch: return LocalizedText("应用到跨页选择")
        case .resolveAllConflicts(let choice):
            return LocalizedText(choice == .useRemote ? "全部采用外部值" : "全部保留 Gather")
        }
    }

    func actionLabel(with l10n: L10n) -> String {
        l10n.resolve(actionText)
    }
}

extension CullingView {

    func confirmationMessage(_ action: PendingCullingAction) -> String {
        switch action {
        case .reset:
            return l10n.format("将清空本会话 %lld 张照片的挑片决策、星级与色标（只改 Gather 数据库，不写 XMP、不删除照片文件）。", viewModel.summary?.totalPhotos ?? 0)
        case .cleanup:
            return l10n.format("将删除 %lld 项已确认同步的备份；未确认的项会恢复原 XMP 并标记冲突，原因会显示在面板里。", viewModel.syncStatus?.synced ?? 0)
        case .writeback(let target):
            switch target {
            case .rating:
                return l10n.format("将把 %lld 张已决策照片的当前星级写入 XMP 附属文件（会创建备份，可在同步完成后清理）。", viewModel.decidedPhotoCount)
            case .colorLabel:
                return l10n.format("将把 %lld 张已决策照片的当前颜色标签写入 XMP 附属文件（会创建备份）。", viewModel.decidedPhotoCount)
            case .keyword:
                // Wave5 / N6：挑片关键词写回已停用 —— 不再把 culling:keep / culling:reject
                // 写进 XMP（C1 Load Metadata 后会污染它自己的词库）。入口已从
                // CullingSyncControls 移除；这里保留不可达分支的实话文案，避免"看起来还能用"。
                return l10n.format("挑片关键词写回已停用：不再把 culling:keep / culling:reject 写进 XMP（避免 C1 载入后污染它的词库）。")
            }
        case .retryFailedWriteback:
            return l10n.format("将重试 %lld 个失败写回项并覆盖对应 XMP 附属文件。", viewModel.failedSyncItems.count)
        case .finalizeSync:
            return l10n.format("将确认同步并删除 %lld 项备份，之后无法再从备份恢复原 XMP。", viewModel.syncStatus?.synced ?? 0)
        case .resolveConflict(let conflict, let choices):
            let name = URL(fileURLWithPath: conflict.xmpPath).lastPathComponent
            let usesRemote = !choices.isEmpty && choices.values.allSatisfy({ $0 == .useRemote })
            return usesRemote
                ? l10n.format("将丢弃 Gather 待写入值、采用外部值，结清 %@ 的冲突。", name)
                : l10n.format("将把 Gather 的值写回 %@（覆盖外部修改）并结清冲突。", name)
        case .groupDecision(let plan):
            let names = plan.sampleRejectedNames.joined(separator: "、")
            let sample = names.isEmpty ? "" : l10n.format("（如：%@…）", names)
            return l10n.format(
                "相似组共 %lld 张（当前视图 %lld 张）：保留 %lld 张，淘汰其余 %lld 张%@。",
                plan.totalCount,
                plan.visibleCount,
                plan.keepPhotoIds.count,
                plan.totalCount - plan.keepPhotoIds.count,
                sample
            )
        case .resolveAllConflicts(let choice):
            return l10n.format(
                choice == .useRemote
                    ? "将把当前 %lld 个冲突全部采用外部值（丢弃 Gather 待写入值）。"
                    : "将把当前 %lld 个冲突全部保留 Gather 值并结清。",
                viewModel.conflicts.count)
        case .crossPageBatch(let plan):
            let hidden = plan.totalCount - plan.visibleCount
            if plan.snapshot != nil {
                let truncation = plan.snapshot?.truncated == true
                    ? l10n.format("；选择已命中 %lld 张上限，超出的照片不会被处理",
                                  CullingSelectionQuery.maxIds)
                    : ""
                return l10n.format(
                    "将把本次决策应用到 %lld 张照片（当前视图 %lld 张，%lld 张不可见）%@。服务端会校验选择未变化；若筛选/范围/组员已变，则不会写入任何照片。",
                    plan.totalCount, plan.visibleCount, hidden, truncation)
            }
            return l10n.format(
                "将把本次决策应用到 %lld 张照片（当前视图 %lld 张，%lld 张不可见）。可只应用到当前可见的 %lld 张。",
                plan.totalCount, plan.visibleCount, hidden, plan.visibleCount)
        }
    }

    func perform(_ action: PendingCullingAction) {
        switch action {
        case .reset:
            Task { await viewModel.reset(confirmed: true) }
        case .cleanup:
            Task { await viewModel.cleanup(confirmed: true, l10n: l10n) }
        case .writeback(let target):
            Task { await viewModel.writeback(target: target, confirmed: true, l10n: l10n) }
        case .retryFailedWriteback:
            Task { await viewModel.retryFailedWriteback(confirmed: true, l10n: l10n) }
        case .finalizeSync:
            Task { await viewModel.finalizeSync(confirmed: true) }
        case .resolveConflict(let conflict, let choices):
            Task { await viewModel.resolve(conflict, choices: choices, confirmed: true) }
        case .groupDecision(let plan):
            Task { await viewModel.performGroupDecision(plan) }
        case .crossPageBatch(let plan):
            Task { await viewModel.performCrossPageBatch(plan, onlyVisible: false) }
        case .resolveAllConflicts(let choice):
            Task { await viewModel.resolveAllConflicts(choice: choice, confirmed: true) }
        }
    }
}
