// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryView+Content.swift
// Cut 4 / 4c-2c：壳层数据驱动内容（页面骨架 / 索引头 / 选择栏 / 空态 / 灯箱呈现）
// 与入口意图消费，原 GalleryView.swift 222-241、397-492、499-703 行逐字搬移。
// Lightbox 的呈现与本页生命周期入口留在同一文件；网格行内 .onAppear 在 GalleryGrid。
import SwiftUI
import GatherProtocol

extension GalleryView {
    // MARK: - 页面结构（头部已移入窗口 chrome）

    var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.actionError {
                // 旧版裸红字 → 原生提示条（图标 + 语义色底）。
                NativeBanner(
                    text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                    color: GatherTheme.error
                )
                .padding(.horizontal, GatherMetrics.Layout.pageGutter)
                .padding(.top, 12)
            }
            indexHeaderRow
            if !viewModel.selectedIds.isEmpty {
                selectionBar
            }
            content
        }
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
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(minHeight: 26)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: copy.kind)
        }
    }

    @ViewBuilder
    private func indexHeaderContent(_ copy: GalleryIndexHeaderCopy) -> some View {
        switch copy.kind {
        case .scanning:
            Text(copy.text)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let percent = copy.percent {
                // TS ProgressBar 语义 → 原生线性进度条 + 百分比（计数：.callout）。
                ProgressView(value: Double(percent), total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                    .accessibilityLabel(l10n("索引进度"))
                    .accessibilityValue("\(percent)%")
                Text("\(percent)%")
                    .font(.callout.monospacedDigit())
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
            .font(.callout)
            // TS index.tsx:179-183 —— 旧版一体「索引失败，点击重试」
            // 拆为「索引失败」+ 独立「重试」按钮。
            Button(l10n("重试")) {
                Task { await viewModel.retryIndex() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .count:
            Text(copy.text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 选择栏（旧版：主色实底 + 白字白胶囊 → 系统选中色）

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Label {
                Text(l10n.format("选中 %lld 张照片", viewModel.selectedIds.count))
                    .font(GatherFont.bodyStrong)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(GatherTheme.selection)
            }
            Spacer(minLength: 0)
            Button(l10n("全选")) {
                toggleSelectAllVisible()
            }
            .buttonStyle(.borderless)
            .help(l10n("选择当前筛选下的全部照片"))
            Button(l10n("取消选择")) {
                viewModel.clearSelection()
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, GatherMetrics.Layout.pageGutter)
        .frame(height: 32)
        .background(GatherTheme.surfaceMuted)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    /// 全选/取消全选当前筛选结果（VM 只暴露 toggle，逐个切换保持单一事实源）。
    private func toggleSelectAllVisible() {
        let visible = viewModel.filteredPhotos.map(\.id)
        guard !visible.isEmpty else { return }
        let selected = viewModel.selectedIds
        if visible.allSatisfy({ selected.contains($0) }) {
            visible.forEach { viewModel.toggleSelection($0) }
        } else {
            visible.filter { !selected.contains($0) }.forEach { viewModel.toggleSelection($0) }
        }
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
            .gatherPrimaryActionButton()
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
                // menuImportFolder——那条通知的语义是「已选好目录」，接收方要求 URL，
                // nil 会被静默丢弃，按钮点了没反应。
                NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
            }
            .gatherPrimaryActionButton()
            Button(l10n("前往控制中心")) {
                // 会话页迁移：页签跳转走 environment 里的 navigator（新入口
                // 优先 open(_:in:)）；没有 navigator（预览/布局测试）时无动作。
                navigator?.open(.control, in: viewModel.sessionId)
            }
            Button(l10n("刷新")) {
                Task { await viewModel.load() }
            }
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
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
    }
}
