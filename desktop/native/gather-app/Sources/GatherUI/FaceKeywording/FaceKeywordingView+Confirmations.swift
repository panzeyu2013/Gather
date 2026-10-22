// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceKeywordingView+Confirmations.swift
// Cut 4 / 4c-2b：8 个 PendingFace* 确认上下文（原 855-984 行，private -> internal）
// 与 body 末尾的 8 个 .gatherDestructiveConfirm（原 1100-1177 行）。
// 纯搬移：确认弹窗的应用顺序不变
//（写回 → 重试 → 解绑 → 清理 → 确认同步 → 重新聚类 → 移除成员 → 合并）。
import SwiftUI
import GatherProtocol

// MARK: - 破坏性动作确认上下文（fkw.unbind / fkw.writeback / fkw.cleanup）

/// 写回确认：影响范围 = 绑定簇 / 受影响照片 / XMP 项与示例路径。
struct PendingFaceWriteback: Identifiable {
    let clusterCount: Int
    let affectedPhotos: Int
    let itemCount: Int
    let samplePath: String?

    var id: String { "writeback-\(itemCount)-\(affectedPhotos)" }

    /// Cut 4 / 4b-2b：三段在渲染期组合（单句模板 + 可选示例 + 固定指引），
    /// 不再用 `+=` 拼接已本地化的字符串。
    func scopeText(with l10n: L10n) -> String {
        var parts = [
            l10n.format(
                "将 %lld 个已绑定簇、%lld 张受影响照片写入 XMP，共 %lld 个文件（新建或更新）。",
                clusterCount, affectedPhotos, itemCount
            )
        ]
        if let samplePath, !samplePath.isEmpty {
            parts.append(l10n.format("例如：%@。", samplePath))
        }
        parts.append(l10n("写入后必须重新加载 Capture One 再确认同步；取消不会写入任何文件。"))
        return parts.joined()
    }
}

/// 重试失败项确认：范围 = 失败项数量与路径。
struct PendingFaceRetry: Identifiable {
    let paths: [String]

    var id: String { "retry-\(paths.count)-\(paths.first ?? "")" }

    /// Cut 4 / 4b-2b：示例路径与「等」在渲染期组合，整句走单一模板。
    func scopeText(with l10n: L10n) -> String {
        let sample = paths.prefix(3).joined(separator: l10n("、"))
        let more = paths.count > 3 ? l10n(" 等") : ""
        return l10n.format(
            "将重试写入 %lld 个失败项：%@%@。取消不会重写任何文件。",
            paths.count, sample, more
        )
    }
}

/// 解除绑定确认：范围 = 簇、角色与成员数。
struct PendingFaceUnbind: Identifiable {
    let cluster: FaceClusterData

    var id: Int { cluster.id }

    func scopeText(with l10n: L10n) -> String {
        let role = cluster.binding?.roleName ?? l10n("未知角色")
        return l10n.format(
            "将解除簇 #%lld「%@」的绑定（%lld 名成员），并撤销已写入该角色的人脸关键词；此操作不可撤销。",
            cluster.id, role, cluster.size
        )
    }
}

/// 确认同步（fkw.confirm_sync）：与 sim.confirm_sync 对称，结清后不可回退。
struct PendingFaceConfirmSync: Identifiable {
    var id: String { "face-confirm-sync" }

    func scopeText(with l10n: L10n) -> String {
        l10n("确认后 Gather 认为 Capture One 已完成「加载元数据」，之后才会开放清理备份。若尚未在 Capture One 中加载，请取消。")
    }
}

/// 成员移除确认：范围 = 成员文件名/路径与所属簇（命令面无 confirmed 门控，
/// UI 仍需先确认不可逆影响）。
struct PendingFaceMemberRemoval: Identifiable {
    let member: ClusterMember
    let cluster: FaceClusterData

    var id: String { "remove-member-\(member.memberId)" }

    func scopeText(with l10n: L10n) -> String {
        l10n.format(
            "将把「%@」（%@）从簇 #%lld「%@」中移除；照片本身不会删除，但该成员不再参与这个簇的写回。",
            member.filename, member.photoPath, cluster.id, cluster.label
        )
    }
}

/// 合并确认：范围 = 源/目标簇与张数（合并后源簇消失）。
struct PendingFaceMerge: Identifiable {
    let cluster: FaceClusterData
    let target: FaceClusterData

    var id: String { "face-merge-\(cluster.id)-\(target.id)" }

    func scopeText(with l10n: L10n) -> String {
        l10n.format(
            "将把簇 #%lld「%@」（%lld 张）合并进簇 #%lld「%@」（%lld 张）；源簇随即消失，界面暂不提供撤销入口。",
            cluster.id, cluster.label, cluster.size, target.id, target.label, target.size
        )
    }
}

/// 清理备份确认：范围 = 已写入项数。
struct PendingFaceCleanup: Identifiable {
    let writtenCount: Int

    var id: String { "cleanup-\(writtenCount)" }

    func scopeText(with l10n: L10n) -> String {
        l10n.format(
            "将恢复或移除本次人脸写回生成的 %lld 个备份 sidecar 文件；只应在 Capture One 已重新加载并确认同步后执行。取消不会改动任何文件。",
            writtenCount
        )
    }
}

/// 重新聚类确认：范围 = 现有簇数与其中已绑定人物/角色的簇数。
/// 全量重聚类会重建簇行，人工绑定与合并随之还原（增量分析不会）——命令面无 confirmed
/// 门控，所以必须在 UI 侧拦住；文案要给出"只想处理新照片"的正确入口。
struct PendingFaceRecluster: Identifiable {
    let clusterCount: Int
    let boundClusterCount: Int

    var id: String { "recluster-\(clusterCount)-\(boundClusterCount)" }

    func scopeText(with l10n: L10n) -> String {
        l10n.format(
            "将重新计算全部人脸簇（当前 %lld 个，其中 %lld 个已绑定人物或角色）。现有簇行会被重建，人工绑定与合并会被还原，且界面暂不提供撤销入口。只想处理新照片，请改用「开始分析」——增量模式会保留现有绑定。",
            clusterCount, boundClusterCount
        )
    }
}

extension FaceKeywordingView {
    func confirmationChrome<Content: View>(_ content: Content) -> some View {
        content
        // 破坏性命令统一门控：确认后才带 confirmed: true，取消只写可见文案。
        .gatherDestructiveConfirm(
            pending: $pendingWriteback,
            title: l10n("确认写回人脸关键字？"),
            confirmLabel: { _ in l10n("确认写回") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in Task { await viewModel.writeback(confirmed: true) } },
            onCancel: { _ in viewModel.reportCancellation(LocalizedText("写回人脸关键字")) }
        )
        .gatherDestructiveConfirm(
            pending: $pendingRetry,
            title: l10n("确认重试失败的写回项？"),
            confirmLabel: { _ in l10n("重试写入") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in Task { await viewModel.retryFailed(confirmed: true) } },
            onCancel: { _ in viewModel.reportCancellation(LocalizedText("重试失败写回项")) }
        )
        .gatherDestructiveConfirm(
            pending: $pendingUnbind,
            title: l10n("确认解除人脸绑定？"),
            confirmLabel: { _ in l10n("解除绑定") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { pending in Task { await viewModel.unbind(pending.cluster, confirmed: true) } },
            onCancel: { pending in
                viewModel.reportCancellation(LocalizedText("解除簇 #%lld 的绑定", params: ["\(pending.cluster.id)"]))
            }
        )
        .gatherDestructiveConfirm(
            pending: $pendingCleanup,
            title: l10n("确认清理人脸写回备份？"),
            confirmLabel: { _ in l10n("清理") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in Task { await viewModel.cleanup(confirmed: true) } },
            onCancel: { _ in viewModel.reportCancellation(LocalizedText("清理人脸写回备份")) }
        )
        // 确认同步：与 sim.confirm_sync 对称的结清不可回退动作。
        .gatherDestructiveConfirm(
            pending: $pendingConfirmSync,
            title: l10n("确认人脸关键字同步？"),
            confirmLabel: { _ in l10n("确认同步") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in Task { await viewModel.confirmSync() } },
            onCancel: { _ in viewModel.reportCancellation(LocalizedText("确认人脸关键字同步")) }
        )
        // 重新聚类：全量重建会还原人工绑定/合并（命令面无 confirmed 门控）。
        .gatherDestructiveConfirm(
            pending: $pendingRecluster,
            title: l10n("确认重新聚类？"),
            confirmLabel: { _ in l10n("重建全部簇") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in Task { await viewModel.recluster() } },
            onCancel: { _ in viewModel.reportCancellation(LocalizedText("重新聚类")) }
        )
        // 移除成员 / 合并：命令面无 confirmed 门控，UI 仍需确认不可逆影响。
        .gatherDestructiveConfirm(
            pending: $pendingMemberRemoval,
            title: l10n("确认移除该成员？"),
            confirmLabel: { _ in l10n("移除成员") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { pending in
                Task { await viewModel.removeMember(pending.member, from: pending.cluster) }
            },
            onCancel: { pending in
                viewModel.reportCancellation(LocalizedText("移除成员「%@」", params: [pending.member.filename]))
            }
        )
        .gatherDestructiveConfirm(
            pending: $pendingMerge,
            title: l10n("确认合并这两个人脸簇？"),
            confirmLabel: { _ in l10n("合并") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { pending in
                Task { await viewModel.merge(pending.cluster) }
            },
            onCancel: { pending in
                viewModel.reportCancellation(LocalizedText("合并簇 #%lld", params: ["\(pending.cluster.id)"]))
            }
        )
    }
}
