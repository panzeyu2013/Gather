// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryView+Content.swift
// Cut 4 / 4c-2c：壳层数据驱动内容（页面骨架 / 索引头 / 选择栏 / 空态 / 灯箱呈现）
// 与入口意图消费，原 GalleryView.swift 222-241、397-492、499-703 行逐字搬移。
// Lightbox 的呈现与本页生命周期入口留在同一文件；网格行内 .onAppear 在 GalleryGrid。
import SwiftUI
import AppKit
import GatherProtocol

extension GalleryView {
    // MARK: - 页面结构（头部已移入窗口 chrome）

    var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.actionError {
                // 旧版裸红字 → 原生提示条（图标 + 语义色底）。
                NativeBanner(
                    text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                    color: GatherTheme.error,
                    onDismiss: { viewModel.actionError = nil }
                )
                .padding(.horizontal, GatherMetrics.Layout.pageGutter)
                .padding(.top, GatherMetrics.Space.m)
                .transition(.opacity)
            }
            searchRow
            indexHeaderRow
            if !viewModel.loadedPhotos.isEmpty {
                selectionBar
            }
            content
        }
        // 横幅淡入淡出：错误出现时不再把整页内容硬顶下去。
        .gatherAnimatePresence(viewModel.actionError != nil)
        .confirmationDialog(
            l10n("确认批量操作？"),
            isPresented: Binding(
                get: { pendingGalleryBatch != nil },
                set: { if !$0 { pendingGalleryBatch = nil } }),
            titleVisibility: .visible
        ) {
            Button(l10n("应用批量更改"), role: .destructive) {
                if let pending = pendingGalleryBatch {
                    pendingGalleryBatch = nil
                    applyBatchCulling(pending.patch)
                }
            }
            Button(l10n("取消"), role: .cancel) { pendingGalleryBatch = nil }
        } message: {
            if let pending = pendingGalleryBatch {
                Text(l10n.format(
                    "将对 %lld 张照片执行“%@”；会立即写入数据库。",
                    pending.count, pending.label))
            }
        }
    }

    /// 内容区搜索：固定 320pt，留在网格内容列内；不放进 toolbar，
    /// 避免 inspector 打开时输入框横跨内容列和右栏。
    private var searchRow: some View {
        HStack(spacing: 10) {
            GatherSearchField(
                text: $viewModel.search,
                prompt: l10n("搜索文件名…"),
                clearLabel: l10n("清除搜索")
            )
            .frame(minWidth: 180, maxWidth: 320)
            // P1 下一波 §3.7.3：保存/恢复查询（搜索框右侧菜单）。
            savedSearchMenu
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GatherMetrics.Layout.pageGutter)
        .padding(.top, GatherMetrics.Space.s)
        .padding(.bottom, GatherMetrics.Space.xxs)
    }

    // MARK: - Lightbox 呈现

    var lightboxPresented: Binding<Bool> {
        Binding(
            get: { lightboxIndex != nil },
            // SwiftUI 只在系统侧 dismiss 时回调 setter；LightboxView 的 onClose
            // 不经过这里，因此关闭逻辑统一收敛到 closeLightbox()，防止事件期间
            // 打开 Lightbox 后补刷丢失、refreshDeferredWhileLightbox 泄漏。
            set: { if !$0 { closeLightbox() } }
        )
    }

    @ViewBuilder
    var lightboxSheet: some View {
        if let index = lightboxIndex {
            LightboxView(
                photos: viewModel.filteredPhotos,
                initialIndex: index,
                onClose: closeLightbox
            )
        }
    }

    /// N07 / D08：把目标照片定位并打开查看器（一次性）。
    ///
    /// 旧实现只在下标已经在 `filteredPhotos` 里时才打开：目标排在第 200 张之后
    /// （初始页大小 200）时，页面只会停在图库首页，用户看不到"查看照片"的结果——
    /// 除非自己恰好滚到目标附近。现在改为**主动向后取页直到找到**（有上限 + 结束后
    /// 未找到也会给出明确反馈），再由 index 打开查看器。
    ///
    /// 匹配顺序：photoId 优先（精确），其次 filepath（相似度成员行只带路径）。
    func locatePendingPhotoIfNeeded() async {
        guard pendingInitialPhotoId != nil || pendingInitialPhotoPath != nil else { return }
        // 审计 2 P2-4：三态分别处理——「不存在」「超出扫描范围」「取页失败」
        // 旧实现只返回 Bool，三种情况都报「可能已被移除」（瞬时失败会让用户以为照片没了）。
        switch await viewModel.locatePendingPhoto(
            photoId: pendingInitialPhotoId,
            photoPath: pendingInitialPhotoPath
        ) {
        case .found:
            openPendingPhotoIfAvailable(viewModel.filteredPhotos)
        case .notFound:
            // 被删除/不属于本工作区：清掉待定并给出明确反馈，不再静默等待。
            viewModel.reportPhotoTargetMissing()
            pendingInitialPhotoId = nil
            pendingInitialPhotoPath = nil
        case .outOfRange:
            // 目标在工作区里但在扫描上限之外：给可执行建议，同样清掉待定。
            viewModel.reportPhotoTargetOutOfRange()
            pendingInitialPhotoId = nil
            pendingInitialPhotoPath = nil
        case .failed:
            // 取页失败/被新的导航取代：保留待定与原始错误，用户可以重试。
            viewModel.reportPhotoLocateFailed()
        }
    }

    /// 照片就位后打开查看器（一次性）。匹配顺序：photoId 优先，其次 filepath。
    func openPendingPhotoIfAvailable(_ photos: [GalleryPhotoData]) {
        var index: Int?
        if let photoId = pendingInitialPhotoId {
            index = photos.firstIndex { $0.id == photoId }
        }
        if index == nil, let path = pendingInitialPhotoPath {
            index = photos.firstIndex { $0.filepath == path }
        }
        guard let index else { return }
        pendingInitialPhotoId = nil
        pendingInitialPhotoPath = nil
        lightboxIndex = index
    }

    /// Lightbox 关闭的统一出口：onClose 与 sheet binding setter 共用。
    /// 消费事件期间标记的补刷并复位标志，避免标志泄漏。
    private func closeLightbox() {
        lightboxIndex = nil
        if refreshDeferredWhileLightbox {
            refreshDeferredWhileLightbox = false
            scheduleRefreshFromEvent()
        }
    }

    /// 事件 → 刷新统一入口：Lightbox 期间只登记，关闭后补一次。
    /// 隐藏门控已收进 VM（scheduleEventRefresh / setVisible），这里不再读
    /// view-local 的可见性 / refreshDeferredWhileHidden（4a-2c 已删除 isActive）。
    func scheduleRefreshFromEvent() {
        if lightboxIndex != nil {
            // 全量重排会打断预览：登记到关闭后补刷。
            refreshDeferredWhileLightbox = true
        } else {
            viewModel.scheduleEventRefresh()
        }
    }

    // MARK: - 索引头（TS index.tsx:158-188 —— 照片计数/索引进度行）

    /// deriveIndexHeaderCopy（indexProgress.ts:32-63）等价行：
    /// 扫描中「正在索引 N / M（x%）」+ 原生进度条；失败「索引失败」+ 重试；
    /// 成功/无任务「已索引 N 张照片」；photoCount==0 且无任务时不渲染。
    /// Cut 4 / 4b-2i：VM 的纯推导函数改为接收显式 L10n（不再读进程全局），
    /// 文案在本行渲染时按当前语言解析。
    @ViewBuilder
    private var indexHeaderRow: some View {
        if let copy = GalleryViewModel.indexHeaderCopy(
            status: viewModel.workspaceStatus,
            photoCount: viewModel.session?.photoCount ?? 0,
            truncatedImport: viewModel.session?.truncatedImport ?? false,
            with: l10n
        ) {
            // D-1（审计 3/5）：索引头是最后一个不可滚动的固定横排（文案 + 140pt 进度条
            // + 百分比），窄窗口下会把内容最小宽度顶上去。改为横向可滚动 + 固定分隔线，
            // 与挑片 infoBar 同一处理方式（不再用 Spacer 抢宽度）。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    indexHeaderContent(copy)
                    if viewModel.isFetchingNextPage {
                        Divider().frame(height: 14)
                        ProgressView()
                            .controlSize(.small)
                            .help(l10n("加载照片中…"))
                    }
                }
            }
            .padding(.horizontal, GatherMetrics.Layout.pageGutter)
            .padding(.top, GatherMetrics.Space.s)
            .padding(.bottom, GatherMetrics.Space.s)
            .frame(minHeight: 26)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: copy.kind)
        }
    }

    @ViewBuilder
    private func indexHeaderContent(_ copy: GalleryIndexHeaderCopy) -> some View {
        switch copy.kind {
        case .scanning:
            Text(copy.text)
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
            if let percent = copy.percent {
                // TS ProgressBar 语义 → 原生线性进度条 + 百分比（计数：.callout）。
                ProgressView(value: Double(percent), total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                    .accessibilityLabel(l10n("索引进度"))
                    .accessibilityValue("\(percent)%")
                Text("\(percent)%")
                    .font(GatherFont.mono)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
        case .error:
            // 状态色不做正文前景：图标承担颜色语义，正文保持 .primary。
            Label {
                Text(copy.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(GatherTheme.error)
            }
            .font(GatherFont.secondary)
            // TS index.tsx:179-183 —— 旧版一体「索引失败，点击重试」
            // 拆为「索引失败」+ 独立「重试」按钮。
            Button(l10n("重试")) {
                Task { await viewModel.retryIndex() }
            }
            .gatherButton(.secondary, size: .small)
        case .count:
            Text(copy.text)
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 选择栏（旧版：主色实底 + 白字白胶囊 → 系统选中色）

    private var selectionBar: some View {
        HStack(spacing: GatherMetrics.Space.m) {
            Label {
                Text(l10n.format("选中 %lld 张照片", viewModel.selectedIds.count))
                    .font(GatherFont.bodyStrong)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(GatherTheme.selection)
            }
            Spacer(minLength: 0)
            Button(l10n("全选筛选结果")) {
                Task { await viewModel.selectAllInScope() }
            }
            .gatherButton(.tertiary, size: .small)
            .disabled(viewModel.filteredPhotos.isEmpty)
            .help(l10n("按当前搜索与筛选条件选择全部照片（最多 20,000 张）"))
            Menu(l10n("批量操作")) {
                Button(l10n("保留")) {
                    requestBatchCulling(
                        CullingUpdatePatch(pickState: .picked), label: l10n("保留"))
                }
                Button(l10n("淘汰")) {
                    requestBatchCulling(
                        CullingUpdatePatch(pickState: .rejected), label: l10n("淘汰"))
                }
                Menu(l10n("评分")) {
                    ForEach(0...5, id: \.self) { rating in
                        Button("\(rating)") {
                            requestBatchCulling(
                                CullingUpdatePatch(rating: Double(rating)),
                                label: "\(rating) ★")
                        }
                    }
                }
                Menu(l10n("色标")) {
                    ForEach(CaptureOneColorLabel.allCases, id: \.self) { label in
                        Button(CullingDisplayFormat.title(label, with: l10n)) {
                            requestBatchCulling(
                                CullingUpdatePatch(colorLabel: label),
                                label: CullingDisplayFormat.title(label, with: l10n))
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(viewModel.selectedIds.isEmpty)
            stackMenu
            Button(l10n("导出所选")) {
                navigator?.openExport(
                    viewModel.sessionId,
                    intent: .selected(Array(viewModel.selectedIds)))
            }
            .gatherButton(.secondary, size: .small)
            .disabled(viewModel.selectedIds.isEmpty)
            Button(l10n("在灯箱中比较")) {
                openSelectedInLightbox()
            }
            .gatherButton(.tertiary, size: .small)
            .disabled(viewModel.selectedIds.isEmpty)
            Button(l10n("在 Finder 中显示")) {
                revealSelectedInFinder()
            }
            .gatherButton(.tertiary, size: .small)
            .disabled(viewModel.selectedIds.isEmpty)
            Button(l10n("取消选择")) {
                viewModel.clearSelection()
            }
            .gatherButton(.tertiary, size: .small)
            .disabled(viewModel.selectedIds.isEmpty)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, GatherMetrics.Layout.pageGutter)
        .frame(height: 32)
        .background(GatherTheme.surfaceMuted)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    /// P2-2：网格键盘游标移动；首帧无游标时从首张或首个已选项开始。
    func moveGalleryCursor(by delta: Int) {
        let photos = viewModel.filteredPhotos
        guard !photos.isEmpty else { return }
        // 多选时 Set 无序：锚点按可见顺序取首个选中项，方向键才不会跳随机照片。
        let anchor = keyboardCursorId
            ?? photos.first(where: { viewModel.selectedIds.contains($0.id) })?.id
        let start = anchor.flatMap { id in photos.firstIndex { $0.id == id } } ?? 0
        let next = min(max(0, start + delta), photos.count - 1)
        let id = photos[next].id
        keyboardCursorId = id
        viewModel.clearSelection()
        viewModel.toggleSelection(id)
        // 游标移出视口 = 看不见的选中项。把目标行交给网格滚过去。
        galleryScrollTarget = rowIndex(containing: next)
    }

    /// 某个 filtered 下标落在哪一行（justified 网格的行由布局缓存给出）。
    /// 布局还没算出来（首帧/空网格）时返回 nil，滚动自然跳过。
    func rowIndex(containing index: Int) -> Int? {
        layoutCache.rowIndex(containing: index)
    }

    func toggleGalleryCursor() {
        let photos = viewModel.filteredPhotos
        guard !photos.isEmpty else { return }
        // 游标可能停在筛选前的旧照片：必须回落到当前可见集合，
        // 否则空格会把“看不见的照片”选进批次。
        let id: String
        if let cursor = keyboardCursorId, photos.contains(where: { $0.id == cursor }) {
            id = cursor
        } else if let selected = viewModel.selectedIds.first(where: { candidate in
            photos.contains { $0.id == candidate }
        }) {
            id = selected
        } else {
            id = photos[0].id
        }
        keyboardCursorId = id
        viewModel.toggleSelection(id)
    }

    func openGalleryCursor() {
        let photos = viewModel.filteredPhotos
        guard !photos.isEmpty else { return }
        let id = keyboardCursorId
            ?? viewModel.selectedIds.first
            ?? photos[0].id
        if let index = photos.firstIndex(where: { $0.id == id }) {
            lightboxIndex = index
        }
    }
    /// P2-2：批量动作——灯箱打开首个选中项（灯箱内可继续 ←/→）。
    func openSelectedInLightbox() {
        guard let id = viewModel.filteredPhotos
            .first(where: { viewModel.selectedIds.contains($0.id) })?.id,
              let index = viewModel.filteredPhotos.firstIndex(where: { $0.id == id }) else {
            return
        }
        lightboxIndex = index
    }

    /// P2-2：先记录待确认批次；确认后才调用批量写入。
    func requestBatchCulling(_ patch: CullingUpdatePatch, label: String) {
        guard !viewModel.selectedIds.isEmpty else { return }
        pendingGalleryBatch = PendingGalleryBatch(
            patch: patch, count: viewModel.selectedIds.count, label: label)
    }

    /// P2-2：批量评分/色标/保留/淘汰，走 CullingAPI.batchUpdate（≤10k/次）。
    func applyBatchCulling(_ patch: CullingUpdatePatch) {
        let ids = Array(viewModel.selectedIds)
        guard !ids.isEmpty else { return }
        Task {
            do {
                var applied = 0
                for start in stride(from: 0, to: ids.count, by: 10_000) {
                    let end = min(start + 10_000, ids.count)
                    let input = try CullingBatchUpdateInput(
                        sessionId: viewModel.sessionId,
                        photoIds: Array(ids[start..<end]),
                        patch: patch)
                    let results = try await culling.batchUpdate(input)
                    viewModel.recordBatchStates(results)
                    applied += results.flatMap(\.states).count
                }
                GatherEventCenter.postDomainChange(.culling, sessionId: viewModel.sessionId)
                GatherToastCenter.shared.show(
                    type: .success,
                    message: l10n.format("已更新 %lld 张照片", applied))
            } catch {
                GatherToastCenter.shared.show(
                    type: .error,
                    message: CommandErrorText.resolve(CommandError(error), with: l10n))
            }
        }
    }

    /// P2-2：批量动作——Finder 中显示全部选中照片。
    func revealSelectedInFinder() {
        let urls = viewModel.filteredPhotos
            .filter { viewModel.selectedIds.contains($0.id) }
            .compactMap { finderURLForPath($0.filepath) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - 内容（TS justified 网格 + 哨兵分页）

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView(l10n("加载照片中…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            loadFailureView(error)
        case .loaded:
            loadedContent
        }
    }

    /// 加载失败：系统空态视图 + 明确出口（重试），不再是裸红字。
    /// 4a-3b-2a：错误以 `CommandError` 传入，文案在渲染期按当前语言解析。
    private func loadFailureView(_ error: CommandError) -> some View {
        ContentUnavailableView {
            Label(
                l10n.format("加载照片失败：%@", CommandErrorText.resolve(error, with: l10n)),
                systemImage: "exclamationmark.triangle"
            )
        } actions: {
            Button(l10n("重试")) {
                Task { await viewModel.load() }
            }
            .gatherButton(.primary)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var loadedContent: some View {
        let filtered = viewModel.filteredPhotos
        if filtered.isEmpty {
            if viewModel.loadedPhotos.isEmpty {
                emptyLibraryView
            } else {
                noMatchView
            }
        } else {
            gridView(filtered)
        }
    }

    /// 真空库：给「导入文件夹 / 前往控制中心 / 刷新」三条出口，而不是错误文案。
    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label(l10n("暂无照片"), systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(l10n("索引完成后照片将显示在这里"))
        } actions: {
            Button(l10n("导入文件夹")) {
                // F02：走统一入口（宿主打开目录选择器）。不再 post 带 nil 载荷的
                // menuImportFolder——旧通知的语义是「已选好目录」，接收方要求 URL，
                // nil 会被静默丢弃，按钮点了没反应；现在只剩统一入口请求。
                NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
            }
            .gatherButton(.primary)
            Button(l10n("前往控制中心")) {
                // 会话页迁移：页签跳转走 environment 里的 navigator（新入口
                // 优先 open(_:in:)）；没有 navigator（预览/布局测试）时无动作。
                navigator?.open(.control, in: viewModel.sessionId)
            }
            .gatherButton(.secondary)
            Button(l10n("刷新")) {
                Task { await viewModel.load() }
            }
            .gatherButton(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
    }

    /// 搜索/筛选无结果：清除筛选永远可点。
    private var noMatchView: some View {
        ContentUnavailableView {
            Label(l10n("没有符合条件的照片"), systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(l10n("调整或清除筛选条件以查看全部照片"))
        } actions: {
            Button(l10n("清除筛选")) {
                viewModel.search = ""
                viewModel.filter = .all
                viewModel.filterOrVariantChanged()
            }
            .gatherButton(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
    }
}

/// 图库批量动作的待确认上下文（确认后才调用 CullingAPI）。
struct PendingGalleryBatch: Identifiable {
    let id = UUID()
    let patch: CullingUpdatePatch
    let count: Int
    let label: String
}
