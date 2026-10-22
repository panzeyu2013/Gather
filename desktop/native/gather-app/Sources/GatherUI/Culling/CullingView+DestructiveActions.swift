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
            case .keyword: return LocalizedText("写回挑片关键词到 XMP")
            }
        case .retryFailedWriteback: return LocalizedText("重试失败写回项")
        case .finalizeSync: return LocalizedText("保留 XMP 并结束同步")
        case .resolveConflict: return LocalizedText("裁决 XMP 冲突")
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
                return l10n.format("将把 %lld 张已决策照片的当前星级写入 XMP 侧车（会创建备份，可在同步完成后清理）。", viewModel.decidedPhotoCount)
            case .colorLabel:
                return l10n.format("将把 %lld 张已决策照片的当前颜色标签写入 XMP 侧车（会创建备份）。", viewModel.decidedPhotoCount)
            case .keyword:
                return l10n.format("将把 %lld 张已决策照片的 culling:keep / culling:reject 关键词合并进 XMP（不覆盖其它关键词）。", viewModel.decidedPhotoCount)
            }
        case .retryFailedWriteback:
            return l10n.format("将重试 %lld 个失败写回项并覆盖对应 XMP 侧车。", viewModel.failedSyncItems.count)
        case .finalizeSync:
            return l10n.format("将确认同步并删除 %lld 项备份，之后无法再从备份恢复原 XMP。", viewModel.syncStatus?.synced ?? 0)
        case .resolveConflict(let conflict, let choices):
            let name = URL(fileURLWithPath: conflict.xmpPath).lastPathComponent
            let usesRemote = !choices.isEmpty && choices.values.allSatisfy({ $0 == .useRemote })
            return usesRemote
                ? l10n.format("将丢弃 Gather 待写入值、采用外部值，结清 %@ 的冲突。", name)
                : l10n.format("将把 Gather 的值写回 %@（覆盖外部修改）并结清冲突。", name)
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
        }
    }
}
