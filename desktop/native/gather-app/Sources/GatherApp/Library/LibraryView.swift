// desktop/native/gather-app/Sources/GatherApp/Library/LibraryView.swift
// Phase 3.2 Library（全局图库）：SwiftUI 页面（宿主内直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/Library/index.tsx（筛选面板/工具栏/卡片网格/分页）
// 中文文案硬编码（项目 i18n 于 3.6 收尾，本阶段对齐 TS 默认语言 zh-CN）。
import SwiftUI
import AppKit
import GatherCore

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    /// 页面是否可见（RootView 传 navigation.isLibrary）。隐藏页不发命令、
    /// 不响应领域事件刷新（防抖任务与弹窗按钮由修饰符显式启用）。
    var isActive: Bool = true
    let onOpenSession: (String) -> Void

    /// 需要刷新本页支持数据（相册/关联候选/孤立 XMP/离线卷）的域。
    private static let refreshDomains: Set<GatherDomain> = [
        .duplicates, .metadata, .culling, .library,
    ]

    @State private var showAdvancedFilters = false
    @State private var albumName = ""
    /// 破坏性动作的待确认项（非空即弹确认；取消不发命令）。
    @State private var pendingDeleteAlbum: SmartAlbumData?
    @State private var pendingAcceptCandidate: AssetLinkCandidateData?
    @State private var pendingRejectCandidate: AssetLinkCandidateData?
    @State private var pendingRelink: PendingRelink?
    /// 「恢复原片」确认的目标（不可逆覆盖操作）。
    @State private var pendingRestoreOrphan: MetadataOrphan?

    /// 待确认的重新关联：oldRoot → newRoot 由用户选目录后填充。
    struct PendingRelink: Equatable {
        let oldRoot: String
        let newRoot: String
    }
    @State private var jobProgressDebounceTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.actionError {
                Text(String(format: GatherLocalization.l("操作失败：%@"), error))
                    .font(.callout)
                    .foregroundStyle(GatherTheme.error)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
            header
            filterPanel
            supportPanel
            Divider()
            toolbar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gatherBackground)
        .disabled(!isActive)
        .task {
            if viewModel.phase == .loading {
                await viewModel.load()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
            guard let change = notification.object as? GatherDomainChange,
                  Self.refreshDomains.contains(change.domain),
                  change.origin != LibraryViewModel.changeOrigin,
                  isActive else { return }
            // 只刷新本次变更可能影响的支持子域 + 当前页（不重置筛选/页码）。
            viewModel.scheduleEventRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobTerminal)) { _ in
            // 任意终态事件都重载支持数据/照片列表（索引/分析结束即反映）。
            viewModel.scheduleEventRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent,
                  event.job.type == .metadataScan else { return }
            let viewModel = viewModel
            jobProgressDebounceTask?.cancel()
            jobProgressDebounceTask = Task { [weak viewModel] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                viewModel?.scheduleEventRefresh()
            }
        }
    }

    // MARK: 头部（TS Library header：eyebrow + title + subtitle + 工作区选择）

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(GatherLocalization.l("照片资产"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(GatherLocalization.l("全局图库"))
                    .font(.largeTitle.weight(.bold))
                Text(GatherLocalization.l("以同一逻辑照片为单位，跨工作区浏览、筛选和管理。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker(GatherLocalization.l("全部工作区"), selection: $viewModel.sessionFilter) {
                Text(GatherLocalization.l("全部工作区")).tag("")
                ForEach(viewModel.sessions, id: \.id) { session in
                    Text("\(session.name)（\(session.photoCount)）").tag(session.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 240)
            .onChange(of: viewModel.sessionFilter) { _, _ in
                viewModel.onSessionFilterChanged()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: 筛选面板（TS filterPanel：主筛选 + 更多筛选 + 操作）

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(GatherLocalization.l("搜索文件名"), text: $viewModel.filter.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onChange(of: viewModel.filter.search) { _, _ in viewModel.onFilterChanged() }
                filterSelect(
                    GatherLocalization.l("全部星级"),
                    selection: $viewModel.filter.rating,
                    options: [1, 2, 3, 4, 5].map { (String(format: GatherLocalization.l("至少 %lld 星"), $0), "\($0)") }
                )
                filterSelect(
                    GatherLocalization.l("全部颜色"),
                    selection: $viewModel.filter.label,
                    options: LibraryColorOption.all.map { ($0.label, $0.value) }
                )
                filterSelect(
                    GatherLocalization.l("全部在线状态"),
                    selection: $viewModel.filter.status,
                    options: [(GatherLocalization.l("在线"), "online"), (GatherLocalization.l("离线"), "missing")]
                )
            }
            if showAdvancedFilters {
                HStack(spacing: 8) {
                    TextField(GatherLocalization.l("关键词"), text: $viewModel.filter.keyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .onChange(of: viewModel.filter.keyword) { _, _ in viewModel.onFilterChanged() }
                    TextField(GatherLocalization.l("人物"), text: $viewModel.filter.person)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .onChange(of: viewModel.filter.person) { _, _ in viewModel.onFilterChanged() }
                    TextField(GatherLocalization.l("目录路径前缀"), text: $viewModel.filter.directory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onChange(of: viewModel.filter.directory) { _, _ in viewModel.onFilterChanged() }
                    filterSelect(
                        GatherLocalization.l("全部存储卷"),
                        selection: $viewModel.filter.volume,
                        options: viewModel.assetVolumes.map {
                            ($0.roots.first ?? $0.volumeId, $0.volumeId)
                        }
                    )
                    filterSelect(
                        GatherLocalization.l("全部重复状态"),
                        selection: $viewModel.filter.duplicates,
                        options: [(GatherLocalization.l("有重复候选"), "yes"), (GatherLocalization.l("无重复候选"), "no")]
                    )
                    filterSelect(
                        GatherLocalization.l("全部导入时间"),
                        selection: $viewModel.filter.recentDays,
                        options: [(GatherLocalization.l("最近 24 小时"), "1"), (GatherLocalization.l("最近 7 天"), "7"), (GatherLocalization.l("最近 30 天"), "30")]
                    )
                }
            }
            HStack(spacing: 12) {
                Button(showAdvancedFilters ? GatherLocalization.l("收起更多筛选") : moreFiltersLabel) {
                    showAdvancedFilters.toggle()
                }
                .buttonStyle(.link)
                Button(GatherLocalization.l("清除筛选")) {
                    viewModel.clearFilters()
                }
                .disabled(viewModel.activeFilterCount == 0)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    // MARK: 支持能力（TS Library sidebar：智能相册、RAW/JPEG 关联、孤立 XMP、离线卷）

    private var supportPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                smartAlbumsCard
                    .frame(width: 280)
                assetCandidatesCard
                    .frame(width: 320)
                metadataOrphansCard
                    .frame(width: 320)
                offlineVolumesCard
                    .frame(width: 300)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .frame(minHeight: 120, maxHeight: 220)
        .background(Color.gatherBackground)
    }

    private var smartAlbumsCard: some View {
        supportCard(title: GatherLocalization.l("智能相册"), systemImage: "rectangle.stack") {
            Picker(GatherLocalization.l("相册"), selection: Binding(
                get: { viewModel.selectedAlbumId ?? "" },
                set: { viewModel.selectAlbum($0.isEmpty ? nil : $0) }
            )) {
                Text(GatherLocalization.l("全部照片")).tag("")
                ForEach(viewModel.albums, id: \.id) { album in
                    Group {
                        if album.validationError == nil {
                            Text(album.name)
                        } else {
                            Label(album.name, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(GatherTheme.error)
                        }
                    }
                    .tag(album.id)
                    .help(album.validationError ?? "")
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                TextField(GatherLocalization.l("新相册名称"), text: $albumName)
                    .textFieldStyle(.roundedBorder)
                Button(GatherLocalization.l("创建")) {
                    let name = albumName
                    albumName = ""
                    Task { await viewModel.createAlbum(name: name) }
                }
                .disabled(albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSupportBusy)
            }
            if viewModel.selectedAlbumId != nil {
                HStack(spacing: 8) {
                    Button(GatherLocalization.l("用当前筛选更新")) {
                        Task { await viewModel.updateSelectedAlbum() }
                    }
                    .disabled(viewModel.isSupportBusy)
                    Button(GatherLocalization.l("删除"), role: .destructive) {
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
            title: GatherLocalization.l("删除当前智能相册？"),
            confirmLabel: { _ in GatherLocalization.l("删除相册") },
            message: { album in
                String(
                    format: GatherLocalization.l("将删除智能相册「%@」及其筛选规则。只删除相册规则，不会删除任何照片文件。"),
                    album.name
                )
            },
            onConfirm: { album in
                // confirmed: true 只能从这个分支到达。
                Task { await viewModel.deleteAlbum(id: album.id, confirmed: true) }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
    }

    private var assetCandidatesCard: some View {
        supportCard(title: GatherLocalization.l("RAW/JPEG 资产关联"), systemImage: "link") {
            if viewModel.assetCandidates.isEmpty {
                Text(GatherLocalization.l("暂无待处理关联候选"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // TS Library/index.tsx:348 —— 候选直出（卡片内可滚动，无分页门控）。
                ForEach(viewModel.assetCandidates, id: \.id) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Self.basename(candidate.leftPath)) ↔ \(Self.basename(candidate.rightPath))")
                            .font(.footnote)
                            .lineLimit(1)
                            .help("\(candidate.leftPath)\n\(candidate.rightPath)")
                            .textSelection(.enabled)
                        Text(String(format: GatherLocalization.l("%@ · 置信度 %lld%%"), Self.candidateStatusText(candidate.status), Int(candidate.confidence * 100)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            if candidate.status != .accepted {
                                Button(GatherLocalization.l("接受")) {
                                    pendingAcceptCandidate = candidate
                                }
                                .disabled(viewModel.isSupportBusy)
                            }
                            if candidate.status != .rejected {
                                Button(candidate.status == .accepted ? GatherLocalization.l("拆分") : GatherLocalization.l("拒绝")) {
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
        .gatherDestructiveConfirm(
            pending: $pendingAcceptCandidate,
            title: GatherLocalization.l("接受资产关联？"),
            confirmLabel: { _ in GatherLocalization.l("接受并合并") },
            message: { candidate in
                String(
                    format: GatherLocalization.l("将把「%@」与「%@」合并为同一个资产（RAW + JPEG 变体）：图库与导出中只保留一个条目，另一个作为变体保留在磁盘上。"),
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
            title: GatherLocalization.l("拒绝资产关联？"),
            confirmLabel: { candidate in
                candidate.status == .accepted
                    ? GatherLocalization.l("拆分资产")
                    : GatherLocalization.l("拒绝关联")
            },
            message: { candidate in
                String(
                    format: candidate.status == .accepted
                        ? GatherLocalization.l("将拆分「%@」与「%@」：两张文件重新作为独立照片出现在图库中。")
                        : GatherLocalization.l("将拒绝「%@」与「%@」的关联：两张文件保持独立，自动关联不会再合并它们。"),
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
        supportCard(title: GatherLocalization.l("孤立 XMP"), systemImage: "doc.badge.ellipsis") {
            if viewModel.metadataOrphans.isEmpty {
                Text(GatherLocalization.l("没有孤立 XMP"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // TS Library/index.tsx:377 —— 孤立 XMP 直出（卡片内可滚动，无分页门控）。
                ForEach(viewModel.metadataOrphans, id: \.xmpPath) { orphan in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.basename(orphan.xmpPath))
                            .font(.footnote)
                            .lineLimit(1)
                            .help(orphan.xmpPath)
                            .textSelection(.enabled)
                        // TS index.tsx:380 —— translateErrorCode 语义：状态与错误码
                        // 一律经本地化漏斗，原始诊断只进日志（不直显给用户）。
                        Text(orphan.errorMessage.isEmpty
                            ? Self.orphanStatusText(orphan.status)
                            : String(
                                format: GatherLocalization.l("%@ · %@"),
                                Self.orphanStatusText(orphan.status),
                                Self.orphanErrorText(orphan.errorMessage)
                            ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if orphan.status == "pending" || orphan.status == "failed" {
                                // 重试是「再试一次已授权的写回」，按钮本身即用户决定。
                                Button(GatherLocalization.l("重试")) {
                                    Task { await viewModel.resolveOrphan(orphan, action: .retry, confirmed: true) }
                                }
                                .disabled(viewModel.isSupportBusy)
                            }
                            // 保留 XMP 不改写任何照片文件，按钮本身即用户决定。
                            Button(GatherLocalization.l("保留 XMP")) {
                                Task { await viewModel.resolveOrphan(orphan, action: .keep, confirmed: true) }
                            }
                            .disabled(viewModel.isSupportBusy)
                            Button(GatherLocalization.l("恢复原片"), role: .destructive) {
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
        .gatherDestructiveConfirm(
            pending: $pendingRestoreOrphan,
            title: GatherLocalization.l("恢复原片"),
            confirmLabel: { _ in GatherLocalization.l("恢复原片") },
            message: { orphan in
                String(
                    format: GatherLocalization.l("会用备份覆盖照片文件「%@」，当前内容将被替换，此操作不可撤销。"),
                    Self.basename(orphan.xmpPath)
                )
            },
            onConfirm: { orphan in
                Task { await viewModel.resolveOrphan(orphan, action: .restore, confirmed: true) }
            },
            onCancel: { _ in viewModel.reportActionCancelled() }
        )
    }

    private var offlineVolumesCard: some View {
        supportCard(title: GatherLocalization.l("离线存储卷"), systemImage: "externaldrive.badge.exclamationmark") {
            let offlineVolumes = viewModel.assetVolumes.filter { $0.offlineFiles > 0 }
            if offlineVolumes.isEmpty {
                Text(GatherLocalization.l("没有需要重新关联的离线卷"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(offlineVolumes, id: \.volumeId) { volume in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(volume.roots.joined(separator: "、").isEmpty ? volume.volumeId : volume.roots.joined(separator: "、"))
                            .font(.footnote)
                            .lineLimit(2)
                            .help(volume.roots.joined(separator: "\n"))
                        Text(String(format: GatherLocalization.l("离线文件：%lld"), volume.offlineFiles))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(volume.roots, id: \.self) { root in
                            Button(GatherLocalization.l("重新关联此目录")) {
                                Task {
                                    // 先只选目录（不发命令），拿到新旧根后再弹确认。
                                    if let newRoot = await viewModel.chooseRelinkRoot() {
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
            title: GatherLocalization.l("重新关联离线存储卷？"),
            confirmLabel: { _ in GatherLocalization.l("重新关联") },
            message: { relink in
                String(
                    format: GatherLocalization.l("会把「%@」下已登记的文件路径改写为「%@」（该卷共 %lld 个离线文件），并重新索引这些文件。原目录不会被修改或删除。"),
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

    private func supportCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            // 面板高度自适应（minHeight 120 / maxHeight 220）：内容超限时
            // 卡片内纵向滚动，避免大列表被裁切不可达；空内容时卡片收缩。
            ScrollView(.vertical, showsIndicators: false) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gatherSurface)
        )
    }

    /// 对齐 TS Library/index.tsx:353-355：已关联/已拒绝/待确认·N%。
    /// 孤立 XMP 状态 → 可本地化文案；未知状态记日志并回退通用文案，
    /// 绝不把原始状态码/诊断字符串直显给用户（审查 P3）。
    private static func orphanStatusText(_ status: String) -> String {
        switch status {
        case "pending": return GatherLocalization.l("待处理")
        case "failed": return GatherLocalization.l("上次处理失败")
        case "resolved", "kept", "restored": return GatherLocalization.l("已处理")
        default:
            GatherLogger.log("library orphan status unmapped: \(status)", level: .debug)
            return GatherLocalization.l("状态未知")
        }
    }

    /// 孤立 XMP 错误码 → 本地化文案；非错误码诊断只进日志 + 通用文案。
    private static func orphanErrorText(_ raw: String) -> String {
        LibraryViewModel.userFacingText(for: raw)
    }

    private static func candidateStatusText(_ status: AssetLinkCandidateStatus) -> String {
        switch status {
        case .accepted: return GatherLocalization.l("已关联")
        case .rejected: return GatherLocalization.l("已拒绝")
        case .pending: return GatherLocalization.l("待确认")
        }
    }

    private static func basename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private var moreFiltersLabel: String {
        let count = viewModel.advancedFilterCount
        return count > 0 ? String(format: GatherLocalization.l("更多筛选（%lld）"), count) : GatherLocalization.l("更多筛选")
    }

    private func filterSelect(_ placeholder: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        Picker(placeholder, selection: selection) {
            Text(placeholder).tag("")
            ForEach(options, id: \.1) { label, value in
                Text(label).tag(value)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 150)
        .onChange(of: selection.wrappedValue) { _, _ in viewModel.onFilterChanged() }
    }

    // MARK: 工具栏（TS toolbar：loading/totalCount + range）

    private var toolbar: some View {
        HStack(spacing: 16) {
            if viewModel.phase == .loading {
                Text(GatherLocalization.l("加载中…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(String(format: GatherLocalization.l("共 %lld 张逻辑照片"), viewModel.total))
                    .font(.callout)
                Text(viewModel.rangeText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isFetching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    // MARK: 内容（TS 卡片网格 + 分页）

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView(GatherLocalization.l("加载照片中…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Text(String(format: GatherLocalization.l("加载照片失败：%@"), message))
                    .foregroundStyle(GatherTheme.error)
                Button(GatherLocalization.l("重试")) {
                    Task { await viewModel.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            VStack(spacing: 0) {
                if viewModel.photos.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(GatherLocalization.l("没有符合条件的照片"))
                            .font(.headline)
                        Text(GatherLocalization.l("调整或清除筛选条件以查看全部照片"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(GatherLocalization.l("清除筛选")) {
                            viewModel.clearFilters()
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.activeFilterCount == 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(viewModel.photos, id: \.assetId) { photo in
                                LibraryCardView(photo: photo) {
                                    onOpenSession(photo.sessionId)
                                }
                            }
                        }
                        .padding(24)
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Button(GatherLocalization.l("上一页")) {
                        viewModel.prevPage()
                    }
                    .disabled(viewModel.page == 0)
                    Text("\(viewModel.page + 1) / \(max(1, Int(ceil(Double(viewModel.total) / Double(LibraryViewModel.pageSize)))))")
                        .font(.callout)
                        .monospacedDigit()
                    Button(GatherLocalization.l("下一页")) {
                        viewModel.nextPage()
                    }
                    .disabled(!viewModel.hasNextPage)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - 照片卡片（TS Library card：缩略图 + 文件名 + 星级 + 色标 + 会话）

private struct LibraryCardView: View {
    let photo: GlobalPhotoResult
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    PhotoThumbnailView(path: photo.filepath, size: 512)
                        // 占位/加载中/失败三态同尺寸（防跳动）：固定高 110 并撑满卡宽。
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(height: 110)
                        .clipped()
                        .background(Color.gatherSurface)
                    if photo.status == "missing" {
                        Text(GatherLocalization.l("离线"))
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                Text(photo.filename)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(Self.starText(photo.rating))
                    .font(.footnote)
                    .foregroundStyle(Color.ratingStar)
                Text(String(format: GatherLocalization.l("%@ · %@"), photo.label.isEmpty ? "无色标" : photo.label, photo.sessionNames.joined(separator: "、")))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !photo.keywords.isEmpty {
                    Text(photo.keywords.prefix(4).joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gatherSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isHovered ? GatherTheme.primary.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .shadow(color: isHovered ? GatherTheme.shadowMd : Color.clear, radius: 8, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(GatherLocalization.l("打开"), action: onOpen)
            if let url = finderURLForPath(photo.filepath) {
                Divider()
                Button(GatherLocalization.l("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .onHover { isHovered = $0 }
    }

    /// TS: rating 星级（★ 重复 + ☆ 补齐）。
    static func starText(_ rating: Double) -> String {
        let count = Int(rating)
        guard count > 0 else { return GatherLocalization.l("未评级") }
        return String(repeating: "★", count: count) + String(repeating: "☆", count: max(0, 5 - count))
    }
}

/// TS: COLOR_LABELS（culling.color.* 中文键值）。
private enum LibraryColorOption: CaseIterable {
    case red, orange, yellow, green, blue, pink, purple

    static let all: [LibraryColorOption] = [.red, .orange, .yellow, .green, .blue, .pink, .purple]

    var value: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .purple: return "Purple"
        }
    }

    var label: String {
        switch self {
        case .red: return GatherLocalization.l("红")
        case .orange: return GatherLocalization.l("橙")
        case .yellow: return GatherLocalization.l("黄")
        case .green: return GatherLocalization.l("绿")
        case .blue: return GatherLocalization.l("蓝")
        case .pink: return GatherLocalization.l("粉")
        case .purple: return GatherLocalization.l("紫")
        }
    }
}

private extension Color {
    /// 星级文字色：GatherTheme.warning（浅色 #D4944F）在 gatherSurface 上
    /// 对比不足，改用深棕/亮金动态变体（手法同 C1StatusCapsule.dynamicText）。
    static var ratingStar: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hexString: isDark ? "#E5B27B" : "#8A5A1F")
        })
    }
}

private extension NSColor {
    convenience init(hexString: String) {
        var value: UInt64 = 0
        Scanner(string: hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString).scanHexInt64(&value)
        self.init(
            srgbRed: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
