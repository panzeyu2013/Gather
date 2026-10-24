// desktop/native/gather-app/Sources/GatherUI/Library/LibraryView+Support.swift
// Cut 4 / 4c-2j：从 LibraryView.swift 移出右侧检查器与四项支持能力（原 311-653 行）。
// 纯搬移：四张卡片、supportCard 容器与静态文案映射逐字未动；5 个
// gatherDestructiveConfirm 的节点与顺序保持（相册删除 -> 接受关联 ->
// 拒绝/拆分关联 -> 恢复原片 -> 重新关联）。
import SwiftUI
import GatherProtocol

extension LibraryView {

    // MARK: 支持能力（TS Library sidebar：智能相册、RAW/JPEG 关联、孤立 XMP、离线卷）

    /// 支持能力卡片：自适应网格。
    ///
    /// 旧实现是**隐藏滚动条的固定宽度横条**（280+320+320+300 = 1244pt）：
    /// 在最小窗口（内容宽 ≈900pt）下「离线存储卷」整张卡落在屏幕外，
    /// 而 showsIndicators:false 又抹掉了唯一的提示——已实现的功能不可达。
    /// 改为自适应列数：窗口变窄时自动折行，任何宽度下四张卡都在视野内。
    var libraryInspector: some View {
        // 用 ScrollView + 卡片，而不是 Form(.grouped)：
        // Form 装进 .inspector 会在 AppKit 的约束更新阶段抛异常
        // （崩溃栈：NSDisplayCycleObserverInvoke → objc_exception_rethrow），
        // 已实测复现。这里的四组内容是「管理面板」而不是表单行，
        // 用卡片分组本来也更贴切。
        ScrollView {
            VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
                Text(l10n("资料库"))
                    .font(GatherFont.sectionTitle)
                smartAlbumsCard
                assetCandidatesCard
                metadataOrphansCard
                offlineVolumesCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GatherMetrics.Space.l)
        }
    }

    private var smartAlbumsCard: some View {
        supportCard(title: l10n("智能相册"), systemImage: "rectangle.stack") {
            Picker(l10n("相册"), selection: Binding(
                get: { viewModel.selectedAlbumId ?? "" },
                set: { viewModel.selectAlbum($0.isEmpty ? nil : $0) }
            )) {
                Text(l10n("全部照片")).tag("")
                ForEach(viewModel.albums, id: \.id) { album in
                    Group {
                        if album.validationError == nil {
                            Text(album.name)
                        } else {
                            Label(album.name, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(GatherTheme.errorText)
                        }
                    }
                    .tag(album.id)
                    .help(album.validationError ?? "")
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                TextField(l10n("新相册名称"), text: $albumName)
                Button(l10n("创建")) {
                    let name = albumName
                    albumName = ""
                    Task { await viewModel.createAlbum(name: name) }
                }
                .disabled(albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSupportBusy)
            }
            if viewModel.selectedAlbumId != nil {
                HStack(spacing: 8) {
                    Button(l10n("用当前筛选更新")) {
                        Task { await viewModel.updateSelectedAlbum() }
                    }
                    .disabled(viewModel.isSupportBusy)
                    Button(l10n("删除"), role: .destructive) {
                        pendingDeleteAlbum = viewModel.albums.first {
                            $0.id == viewModel.selectedAlbumId
                        }
                    }
                    .disabled(viewModel.isSupportBusy)
                }
            }
        }
        .gatherDestructiveConfirm(
            pending: $pendingDeleteAlbum,
            title: l10n("删除当前智能相册？"),
            confirmLabel: { _ in l10n("删除相册") },
            message: { album in
                l10n.format("将删除智能相册「%@」及其筛选规则。只删除相册规则，不会删除任何照片文件。", album.name)
            },
            onConfirm: { album in
                // confirmed: true 只能从这个分支到达。
                Task { await viewModel.deleteAlbum(id: album.id, confirmed: true) }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
    }

    private var assetCandidatesCard: some View {
        supportCard(title: l10n("RAW/JPEG 资产关联"), systemImage: "link") {
            if viewModel.assetCandidates.isEmpty {
                Text(l10n("暂无待处理关联候选"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            } else {
                // TS Library/index.tsx:348 —— 候选直出（卡片内可滚动，无分页门控）。
                // C-6（性能审计）：旧实现在 ScrollView { VStack } 里**直出**全部候选
                // （无 LIMIT），每次重建实例化所有行。LazyVStack 是零行为变化的修法。
                LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.assetCandidates, id: \.id) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Self.basename(candidate.leftPath)) ↔ \(Self.basename(candidate.rightPath))")
                            .font(GatherFont.secondary)
                            .lineLimit(1)
                            .help("\(candidate.leftPath)\n\(candidate.rightPath)")
                            .textSelection(.enabled)
                        Text(l10n.format("%@ · 置信度 %lld%%", Self.candidateStatusText(candidate.status, with: l10n), Int(candidate.confidence * 100)))
                            .font(GatherFont.secondary)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            if candidate.status != .accepted {
                                Button(l10n("接受")) {
                                    pendingAcceptCandidate = candidate
                                }
                                .disabled(viewModel.isSupportBusy)
                            }
                            if candidate.status != .rejected {
                                Button(candidate.status == .accepted ? l10n("拆分") : l10n("拒绝")) {
                                    pendingRejectCandidate = candidate
                                }
                                .disabled(viewModel.isSupportBusy)
                            }
                        }
                    }
                    if candidate.id != viewModel.assetCandidates.last?.id {
                        Divider()
                    }
                }
                }
            }
        }
        .gatherDestructiveConfirm(
            pending: $pendingAcceptCandidate,
            title: l10n("接受资产关联？"),
            confirmLabel: { _ in l10n("接受并合并") },
            message: { candidate in
                l10n.format(
                    "将把「%@」与「%@」合并为同一个资产（RAW + JPEG 变体）：图库与导出中只保留一个条目，另一个作为变体保留在磁盘上。",
                    Self.basename(candidate.leftPath),
                    Self.basename(candidate.rightPath)
                )
            },
            onConfirm: { candidate in
                Task { await viewModel.updateCandidate(candidate, accept: true, confirmed: true) }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
        .gatherDestructiveConfirm(
            pending: $pendingRejectCandidate,
            title: l10n("拒绝资产关联？"),
            confirmLabel: { candidate in
                candidate.status == .accepted
                    ? l10n("拆分资产")
                    : l10n("拒绝关联")
            },
            message: { candidate in
                l10n.format(
                    candidate.status == .accepted
                        ? "将拆分「%@」与「%@」：两张文件重新作为独立照片出现在图库中。"
                        : "将拒绝「%@」与「%@」的关联：两张文件保持独立，自动关联不会再合并它们。",
                    Self.basename(candidate.leftPath),
                    Self.basename(candidate.rightPath)
                )
            },
            onConfirm: { candidate in
                Task { await viewModel.updateCandidate(candidate, accept: false, confirmed: true) }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
    }

    private var metadataOrphansCard: some View {
        supportCard(title: l10n("孤立 XMP"), systemImage: "doc.badge.ellipsis") {
            if viewModel.metadataOrphans.isEmpty {
                Text(l10n("没有孤立 XMP"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            } else {
                // TS Library/index.tsx:377 —— 孤立 XMP 直出（卡片内可滚动，无分页门控）。
                LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.metadataOrphans, id: \.xmpPath) { orphan in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.basename(orphan.xmpPath))
                            .font(GatherFont.secondary)
                            .lineLimit(1)
                            .help(orphan.xmpPath)
                            .textSelection(.enabled)
                        // TS index.tsx:380 —— translateErrorCode 语义：状态与错误码
                        // 一律经本地化漏斗，原始诊断只进日志（不直显给用户）。
                        Text(orphan.errorMessage.isEmpty
                            ? Self.orphanStatusText(orphan.status, with: l10n)
                            : l10n.format(
                                "%@ · %@",
                                Self.orphanStatusText(orphan.status, with: l10n),
                                Self.orphanErrorText(orphan.errorMessage, with: l10n)
                            ))
                            .font(GatherFont.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if orphan.status == "pending" || orphan.status == "failed" {
                                // 重试是「再试一次已授权的写回」，按钮本身即用户决定。
                                Button(l10n("重试")) {
                                    Task { await viewModel.resolveOrphan(orphan, action: .retry, confirmed: true) }
                                }
                                .disabled(viewModel.isSupportBusy)
                            }
                            // 保留 XMP 不改写任何照片文件，按钮本身即用户决定。
                            Button(l10n("保留 XMP")) {
                                Task { await viewModel.resolveOrphan(orphan, action: .keep, confirmed: true) }
                            }
                            .disabled(viewModel.isSupportBusy)
                            Button(l10n("恢复原片"), role: .destructive) {
                                pendingRestoreOrphan = orphan
                            }
                            .disabled(viewModel.isSupportBusy)
                        }
                    }
                    if orphan.xmpPath != viewModel.metadataOrphans.last?.xmpPath {
                        Divider()
                    }
                }
                }
            }
        }
        .gatherDestructiveConfirm(
            pending: $pendingRestoreOrphan,
            title: l10n("恢复原片"),
            confirmLabel: { _ in l10n("恢复原片") },
            message: { orphan in
                l10n.format("会用备份覆盖照片文件「%@」，当前内容将被替换，此操作不可撤销。", Self.basename(orphan.xmpPath))
            },
            onConfirm: { orphan in
                Task { await viewModel.resolveOrphan(orphan, action: .restore, confirmed: true) }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
    }

    private var offlineVolumesCard: some View {
        supportCard(title: l10n("离线存储卷"), systemImage: "externaldrive.badge.exclamationmark") {
            let offlineVolumes = viewModel.assetVolumes.filter { $0.offlineFiles > 0 }
            if offlineVolumes.isEmpty {
                Text(l10n("没有需要重新关联的离线卷"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(offlineVolumes, id: \.volumeId) { volume in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(volume.roots.joined(separator: "、").isEmpty ? volume.volumeId : volume.roots.joined(separator: "、"))
                            .font(GatherFont.secondary)
                            .lineLimit(2)
                            .help(volume.roots.joined(separator: "\n"))
                        Text(l10n.format("离线文件：%lld", volume.offlineFiles))
                            .font(GatherFont.secondary)
                            .foregroundStyle(.secondary)
                        ForEach(volume.roots, id: \.self) { root in
                            Button(l10n("重新关联此目录")) {
                                Task {
                                    // 先只选目录（不发命令），拿到新旧根后再弹确认。
                                    if let newRoot = await viewModel.chooseRelinkRoot(with: l10n) {
                                        pendingRelink = PendingRelink(oldRoot: root, newRoot: newRoot)
                                    }
                                }
                            }
                            .disabled(viewModel.isSupportBusy)
                        }
                    }
                }
            }
        }
        .gatherDestructiveConfirm(
            pending: $pendingRelink,
            title: l10n("重新关联离线存储卷？"),
            confirmLabel: { _ in l10n("重新关联") },
            message: { relink in
                l10n.format(
                    "会把「%@」下已登记的文件路径改写为「%@」（该卷共 %lld 个离线文件），并重新索引这些文件。原目录不会被修改或删除。",
                    relink.oldRoot,
                    relink.newRoot,
                    viewModel.assetVolumes.reduce(0) { $0 + $1.offlineFiles }
                )
            },
            onConfirm: { relink in
                Task {
                    await viewModel.relinkVolume(
                        root: relink.oldRoot,
                        newRoot: relink.newRoot,
                        confirmed: true
                    )
                }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
    }

    /// 检查器里的一组管理功能：标题 + 内容，套系统分组容器。
    private func supportCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(GatherFont.cardTitle)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gatherCard(cornerRadius: GatherTheme.Radius.card, elevated: false)
    }

    /// 对齐 TS Library/index.tsx:353-355：已关联/已拒绝/待确认·N%。
    /// 孤立 XMP 状态 → 可本地化文案；未知状态记日志并回退通用文案，
    /// 绝不把原始状态码/诊断字符串直显给用户（审查 P3）。
    private static func orphanStatusText(_ status: String, with l10n: L10n) -> String {
        switch status {
        case "pending": return l10n("待处理")
        case "failed": return l10n("上次处理失败")
        case "resolved", "kept", "restored": return l10n("已处理")
        default:
            GatherLogger.log("library orphan status unmapped: \(status)", level: .debug)
            return l10n("状态未知")
        }
    }

    /// 孤立 XMP 错误码 → 本地化文案；非错误码诊断只进日志 + 通用文案。
    private static func orphanErrorText(_ raw: String, with l10n: L10n) -> String {
        LibraryViewModel.userFacingText(for: raw, with: l10n)
    }

    private static func candidateStatusText(_ status: AssetLinkCandidateStatus, with l10n: L10n) -> String {
        switch status {
        case .accepted: return l10n("已关联")
        case .rejected: return l10n("已拒绝")
        case .pending: return l10n("待确认")
        }
    }

    private static func basename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
