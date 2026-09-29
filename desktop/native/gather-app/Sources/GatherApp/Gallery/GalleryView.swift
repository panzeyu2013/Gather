// desktop/native/gather-app/Sources/GatherApp/Gallery/GalleryView.swift
// Phase 3.2 Gallery（工作区浏览）：SwiftUI 页面（宿主内直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/SessionDetail/Gallery.tsx（工具栏/选择栏/
//       justified 网格/哨兵分页/变体徽标）+ pages/SessionDetail/index.tsx（页签）
// 中文文案硬编码（项目 i18n 于 3.6 收尾，本阶段对齐 TS 默认语言 zh-CN）。
import SwiftUI
import AppKit
import GatherCore

/// 工作区页签（对齐 SessionDetail/index.tsx 的 NavLink；全部由 SwiftUI 承载）。
/// 页签文案统一由 SessionTabBar.tabTitle 提供（中英双语），此处不再持有。
enum SessionTab: String, CaseIterable, Identifiable {
    case control = "control"
    case faceKw = "face-kw"
    case duplicates
    case culling
    case export

    var id: String { rawValue }
}

struct GalleryView: View {
    @Bindable var viewModel: GalleryViewModel
    let router: SessionCommandRouter
    let onBack: () -> Void
    let onOpenSimilarity: (String) -> Void
    let onOpenTab: (String, SessionTab) -> Void
    let onOpenSettings: () -> Void
    /// 可见性门控（opacity 常驻架构）：隐藏时停止 C1 胶囊 12s 轮询。
    var isActive: Bool = true

    /// TS: DENSITY_OPTIONS（行高密度）。计算属性：static let 只求值一次，
    /// 语言切换后会残留旧语言文案。
    private var densityOptions: [(value: Double, label: String)] {
        [
            (160, GatherLocalization.l("小图")),
            (220, GatherLocalization.l("中图")),
            (300, GatherLocalization.l("大图")),
        ]
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var density = 220.0
    @State private var lightboxIndex: Int?
    /// 网格行布局缓存（避免 ScrollView 滚动时反复重算 justified 布局）。
    @State private var layoutCache: (key: String, rows: [JustifiedLayoutRow])?
    /// Lightbox 打开期间错过的终态事件：关闭后补一次刷新。
    @State private var refreshDeferredWhileLightbox = false
    /// 隐藏期间错过的事件刷新：重新可见时补一次（隐藏页不发命令）。
    @State private var refreshDeferredWhileHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.actionError {
                Text(String(format: GatherLocalization.l("操作失败：%@"), error))
                    .font(.callout)
                    .foregroundStyle(GatherTheme.error)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
            sessionHeader
            indexHeaderRow
            toolbar
            if !viewModel.selectedIds.isEmpty {
                selectionBar
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gatherBackground)
        // 隐藏页一致性：disabled / hit-testing / 无障碍三者同源（isActive）。
        .disabled(!isActive)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
        .task(id: viewModel.sessionId) {
            // 会话切换时 RootView 重建 VM 但视图身份不变（opacity 常驻）：
            // id 变化会重启本任务，保证新 VM 立即加载而非永远 loading。
            await viewModel.loadIfNeeded()
            if isActive { viewModel.startIndexStatusPolling() }
        }
        .onChange(of: viewModel.sessionId) { _, _ in
            // 双保险：.task(id:) 重启之外的路径（如会话切换发生在视图重排窗口）。
            Task { await viewModel.loadIfNeeded() }
        }
        .onChange(of: isActive) { _, active in
            // 索引头轮询门控（opacity 常驻架构）：隐藏时停掉，避免后台空转。
            if active {
                viewModel.startIndexStatusPolling()
                // 隐藏期间错过的事件刷新：重新可见时补一次（不发命令则只登记）。
                if refreshDeferredWhileHidden {
                    refreshDeferredWhileHidden = false
                    viewModel.scheduleEventRefresh()
                }
            } else {
                viewModel.stopIndexStatusPolling()
            }
        }
        .onChange(of: viewModel.filteredPhotos) { _, _ in
            // 过滤/事件刷新后行项 index 指向旧数组 —— 布局缓存立即失效，
            // 避免 count/width/density 未变时复用错位行。
            layoutCache = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobTerminal)) { notification in
            // 仅本工作区的终态事件触发重载（其他会话的索引结束不打扰浏览）。
            guard let event = notification.object as? GatherJobEvent,
                  event.job.scopeId == viewModel.sessionId else { return }
            scheduleRefreshFromEvent()
        }
        // 写路径广播（挑片决策/库变更/写回/人脸绑定）：命中本会话才刷新。
        // photo.list_page 行不含评分/色标字段，重取后随行更新的是离线态、
        // 变体徽标、人脸计数与行集合本身（照片被移除/恢复）。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
            guard let change = notification.object as? GatherDomainChange,
                  change.matches(sessionId: viewModel.sessionId),
                  [.culling, .library, .metadata, .faceKeywording].contains(change.domain) else { return }
            scheduleRefreshFromEvent()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            // 隐藏页不发命令：进度帧本身只更新缓存，但 VM 内去抖后会执行
            // workspace.status；不可见时直接丢弃，重新可见由轮询补齐。
            guard isActive else { return }
            // 索引活跃期间 jobs:progress 帧 → 索引头实时刷新（VM 内 1s 去抖）。
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.handleIndexJobProgress(event)
        }
        .sheet(isPresented: Binding(
            get: { lightboxIndex != nil },
            // SwiftUI 只在系统侧 dismiss 时回调 setter；LightboxView 的 onClose
            // 不经过这里，因此关闭逻辑统一收敛到 closeLightbox()，防止事件期间
            // 打开 Lightbox 后补刷丢失、refreshDeferredWhileLightbox 泄漏。
            set: { if !$0 { closeLightbox() } }
        )) {
            if let index = lightboxIndex {
                LightboxView(
                    photos: viewModel.filteredPhotos,
                    initialIndex: index,
                    onClose: closeLightbox
                )
                // 页面隐藏时 .disabled(true) 会随环境下沉到 sheet：显式启用灯箱。
                .disabled(false)
            }
        }
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

    /// 事件 → 刷新统一入口：可见才发命令；隐藏/Lightbox 期间只登记，
    /// 回到可见（或关闭 Lightbox）时补一次（隐藏页不发命令）。
    private func scheduleRefreshFromEvent() {
        guard isActive else {
            refreshDeferredWhileHidden = true
            return
        }
        if lightboxIndex != nil {
            // 全量重排会打断预览：登记到关闭后补刷。
            refreshDeferredWhileLightbox = true
        } else {
            viewModel.scheduleEventRefresh()
        }
    }

    /// 右键「在 Finder 中显示」的 URL：路径为空/不可用时返回 nil（跳过该项）。
    private static func finderURL(for photo: GalleryPhotoData) -> URL? {
        finderURLForPath(photo.filepath)
    }

    // MARK: 会话头部（TS SessionDetail header：返回 + 身份 + 页签 + C1 胶囊）

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: onBack) {
                    Label(GatherLocalization.l("返回工作台"), systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.gatherPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(GatherLocalization.l("当前工作区"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(viewModel.session?.name ?? GatherLocalization.l("加载中…"))
                        .font(.largeTitle.weight(.bold))
                }
                Spacer()
                // C1 状态胶囊（旧版 C1StatusCapsule：状态点 + 队列数 + 跳设置）。
                C1StatusCapsuleHost(
                    sessionId: viewModel.sessionId,
                    router: router,
                    onOpenSettings: onOpenSettings,
                    isActive: isActive
                )
                // TS index.tsx:135 —— 「设置」utility link（右邻 C1 胶囊）。
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(GatherLocalization.l("刷新"))
                .help(GatherLocalization.l("刷新"))
                Button(GatherLocalization.l("设置")) {
                    onOpenSettings()
                }
                .buttonStyle(.bordered)
            }
            SessionTabBar(
                selection: .browse,
                onBrowse: {},
                onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
                onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: 索引头（TS index.tsx:158-188 —— 照片计数/索引进度行）

    /// deriveIndexHeaderCopy（indexProgress.ts:32-63）等价行：
    /// 扫描中「正在索引 N / M（x%）」+ 确定性进度条；失败「索引失败」+ 重试；
    /// 成功/无任务「已索引 N 张照片」；photoCount==0 且无任务时不渲染。
    @ViewBuilder
    private var indexHeaderRow: some View {
        if let copy = GalleryViewModel.indexHeaderCopy(
            status: viewModel.workspaceStatus,
            photoCount: viewModel.session?.photoCount ?? 0,
            truncatedImport: viewModel.session?.truncatedImport ?? false
        ) {
            HStack(spacing: 10) {
                switch copy.kind {
                case .scanning:
                    Text(copy.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let percent = copy.percent {
                        // TS ProgressBar 语义：8px 轨道 / 圆角 4 / 主色填充
                        // / 140pt 宽 / pct 文本右对齐。
                        GatherProgressBar(
                            fraction: Double(percent) / 100,
                            width: 140,
                            accessibilityText: copy.text
                        )
                        Text("\(percent)%")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                case .error:
                    Text(copy.text)
                        .font(.callout)
                        .foregroundStyle(GatherTheme.error)
                    // TS index.tsx:179-183 —— 旧版一体「索引失败，点击重试」
                    // 拆为「索引失败」+ 独立「重试」按钮。
                    Button(GatherLocalization.l("重试")) {
                        Task { await viewModel.retryIndex() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                case .count:
                    Text(copy.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .frame(minHeight: 26)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: copy.kind)
        }
    }

    // MARK: 工具栏（TS toolbar：搜索 + 过滤 + 密度 + 变体展开）

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField(GatherLocalization.l("搜索文件名…"), text: $viewModel.search)
                .textFieldStyle(.roundedBorder)
                // 布局验收 P1 修复：固定 220 改弹性区间，窄窗口收缩、宽窗口舒展，
                // 避免英文占位文案截断。
                .frame(minWidth: 160, idealWidth: 240, maxWidth: 360)
                .onChange(of: viewModel.search) { _, _ in viewModel.searchChanged() }
            Picker(GatherLocalization.l("全部"), selection: $viewModel.filter) {
                Text(GatherLocalization.l("全部")).tag(GalleryFilter.all)
                Text(GatherLocalization.l("有人脸")).tag(GalleryFilter.hasFace)
                Text(GatherLocalization.l("无人脸")).tag(GalleryFilter.noFace)
            }
            .pickerStyle(.menu)
            .frame(minWidth: 120)
            .onChange(of: viewModel.filter) { _, _ in viewModel.filterOrVariantChanged() }
            Picker(GatherLocalization.l("中图"), selection: $density) {
                ForEach(densityOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 100)
            // TS Gallery.tsx:274-280 —— 变体展开胶囊按钮（aria-pressed 语义：
            // 激活 = primary soft 底 + 主色描边/文字，未激活 = 平底 + 边框）。
            Button {
                viewModel.expandVariants.toggle()
                viewModel.filterOrVariantChanged()
            } label: {
                Text(viewModel.expandVariants ? GatherLocalization.l("折叠 RAW/JPEG") : GatherLocalization.l("展开所有变体"))
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(viewModel.expandVariants ? GatherTheme.primary : Color.gatherTextPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(viewModel.expandVariants ? GatherTheme.primarySoft : GatherTheme.surface))
                    .overlay(Capsule().strokeBorder(viewModel.expandVariants ? GatherTheme.primary : GatherTheme.border))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(viewModel.expandVariants ? [.isSelected] : [])
            .accessibilityLabel(GatherLocalization.l("展开所有变体"))
            Spacer()
            if viewModel.isFetchingNextPage {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    // MARK: 选择栏（TS selectionBar：主色实底白字 + 右对齐「取消选择」）

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(String(format: GatherLocalization.l("选中 %lld 张照片"), viewModel.selectedIds.count))
                .font(.callout)
                .foregroundStyle(.white)
            Spacer()
            // TS Gallery.module.css:64-74 —— clearBtn margin-left:auto +
            // rgba(255,255,255,.2) 胶囊、白字。
            Button(GatherLocalization.l("取消选择")) {
                viewModel.clearSelection()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.2)))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(GatherTheme.primary)
    }

    // MARK: 内容（TS justified 网格 + 哨兵分页）

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
            let filtered = viewModel.filteredPhotos
                if filtered.isEmpty {
                    GatherEmptyState(
                        icon: "photo.on.rectangle.angled",
                        title: GatherLocalization.l("暂无照片"),
                        message: GatherLocalization.l("索引完成后照片将显示在这里")
                    ) {
                        Button(GatherLocalization.l("前往控制中心")) {
                            onOpenTab(viewModel.sessionId, .control)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                } else {
                GeometryReader { geometry in                    // 行区域实际内容宽度 = 全宽 − LazyVStack 水平 padding 24×2。
                    let rows = layoutRows(filtered: filtered, width: max(1, geometry.size.width - 48))
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                rowView(row, filtered: filtered)
                                    .frame(height: row.height)
                            }
                            // TS 哨兵：滚近末尾触发下一页（键集游标）。
                            Color.clear
                                .frame(height: 1)
                                .onAppear {
                                    Task { await viewModel.loadMoreIfNeeded() }
                                }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }
        }
    }

    /// TS: layoutJustifiedRows 的结果缓存（key 覆盖 filtered 身份 + 宽度 + 密度）。
    /// filtered 数据变化时由 .onChange(of: filteredPhotos) 整体失效；key 内
    /// 再叠首尾 id 折叠哈希，双保险防止同 count 复用错位行。
    private func layoutRows(filtered: [GalleryPhotoData], width: Double) -> [JustifiedLayoutRow] {
        let identity = filtered.reduce(0) { $0 &+ $1.id.hashValue }
        let key = "\(filtered.count)|\(width)|\(density)|\(identity)"
        if let cache = layoutCache, cache.key == key {
            return cache.rows
        }
        let source = filtered.map { GalleryAspectItem(width: Double(max(1, $0.width)), height: Double(max(1, $0.height))) }
        let rows = layoutJustifiedRows(source: source, containerWidth: width, targetRowHeight: density, gap: 8)
        layoutCache = (key, rows)
        return rows
    }

    /// 距行末的预取窗口（项数）：旧版 IntersectionObserver rootMargin
    /// 1600px ≈ 数屏；LazyVStack 行进入视口即触发，此窗口约 1-2 屏。
    private static let prefetchRemaining = 20

    private func rowView(_ row: JustifiedLayoutRow, filtered: [GalleryPhotoData]) -> some View {
        HStack(spacing: 8) {
            ForEach(row.items, id: \.index) { item in
                // 越界保护：布局缓存/数据刷新后 index 可能指向旧数组。
                if let photo = filtered[safe: item.index] {
                    Button {
                        // TS：Ctrl/⌘ 多选；普通点击打开 Lightbox。
                        if NSEvent.modifierFlags.contains(.control) || NSEvent.modifierFlags.contains(.command) {
                            viewModel.toggleSelection(photo.id)
                        } else {
                            lightboxIndex = item.index
                        }
                    } label: {
                        GalleryCellView(
                            photo: photo,
                            isSelected: viewModel.selectedIds.contains(photo.id),
                            thumbnailSize: viewModel.thumbnailSize
                        )
                        .frame(width: item.width, height: row.height)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if viewModel.selectedIds.isEmpty, let url = GalleryView.finderURL(for: photo) {
                            Button(GatherLocalization.l("在 Finder 中显示")) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }
                    .accessibilityAddTraits(viewModel.selectedIds.contains(photo.id) ? [.isSelected] : [])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // P11：滚近末尾（距末行 20 项内）即预取下一页（loadMoreIfNeeded 内部
        // hasNextPage/isFetchingNextPage 去重），快滚到底不白屏。
        .onAppear {
            let lastIndex = row.items.last?.index ?? 0
            if lastIndex >= max(0, filtered.count - Self.prefetchRemaining) {
                Task { await viewModel.loadMoreIfNeeded() }
            }
        }
    }

    // MARK: Lightbox（TS components/Lightbox：预览 + 基础元数据）
}

// MARK: - 网格单元（TS GalleryThumbnail：缩略图 + 文件名 + 变体徽标 + 选中勾）

private struct GalleryCellView: View {
    let photo: GalleryPhotoData
    let isSelected: Bool
    var thumbnailSize: Int

    /// TS: .cell:hover —— 悬停投影 + 提亮；主题色描边为原生侧增强反馈。
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoThumbnailView(path: photo.filepath, size: thumbnailSize)
                // 占位尺寸固定（防解码完成前后跳动）：始终撑满单元格。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .brightness(isHovered ? 0.03 : 0)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if photo.status == "missing" {
                        Text(GatherLocalization.l("离线"))
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                    if photo.variantCount > 1 {
                        Text(String(format: GatherLocalization.l("RAW+JPEG · %lld"), photo.variantCount))
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                }
                Text(photo.filename)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        // TS .thumbName：linear-gradient(transparent, rgba(0,0,0,.7))
                        // 底部渐变黑条（上透明 → 下 0.7 黑）。
                        LinearGradient(
                            colors: [.clear, Color.black.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                ZStack {
                    Circle().fill(GatherTheme.primary)
                    Image(systemName: "checkmark").accessibilityHidden(true)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                }
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .frame(width: 18, height: 18)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        // TS: 单元格圆角 10（--radius-sm）；选中态 = 仅 2pt 主色描边
        //（旧版 .cellSelected outline 2px inset，无填充底色）。
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(GatherTheme.backgroundSecondary)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? GatherTheme.primary : (isHovered ? GatherTheme.primary.opacity(0.55) : Color.clear),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        // TS: .cell:hover —— box-shadow 0 3px 14px rgba(0,0,0,.45) + brightness(1.05)
        // 的暖色主题等价：shadowMd（radius 9 / y 3）+ 缩略图亮度 0.03。
        .shadow(color: isHovered ? GatherTheme.shadowMd : Color.clear, radius: 9, y: 3)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Lightbox（TS components/Lightbox/Lightbox.tsx 的简化版：预览 + 元数据）

/// 越界安全的数组取值（网格行/预览共用）。
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct LightboxView: View {
    let photos: [GalleryPhotoData]
    let initialIndex: Int
    let onClose: () -> Void

    /// 当前照片 id（photos 变化时按 id 重新定位；TS Lightbox.tsx:122
    /// `if (!photo) return null` 语义，避免事件刷新缩水后下标崩溃）。
    @State private var currentID: String?
    @State private var scale = 1.0
    @State private var gestureScale = 1.0
    @State private var offset = CGSize.zero
    /// 方向键监听（TS Lightbox.tsx:148 —— ESC/←/→；ESC 由「关闭」按钮的
    /// .keyboardShortcut(.cancelAction) 承担，←/→ 在此消费）。
    @State private var keyDownMonitor: Any?
    /// 监听回调更新盒：@State 盒子引用语义稳定（body 重建不换实例），
    /// body 求值写入最新回调，保证事件触发时读到最新的 photos/currentID。
    @State private var keyHandler = LightboxKeyHandlerBox()

    init(photos: [GalleryPhotoData], initialIndex: Int, onClose: @escaping () -> Void) {
        self.photos = photos
        self.initialIndex = initialIndex
        self.onClose = onClose
        // 越界保护：initialIndex 越界时回退到第一张（photos 为空则 nil → 占位）。
        _currentID = State(initialValue: photos.indices.contains(initialIndex) ? photos[initialIndex].id : photos.first?.id)
    }

    /// TS Lightbox.tsx:122 if (!photo) return null —— 按 id 定位，取不到渲染占位。
    private var currentPhoto: GalleryPhotoData? {
        guard let currentID else { return nil }
        return photos.first { $0.id == currentID }
    }

    private var currentIndex: Int {
        guard let currentID else { return 0 }
        return photos.firstIndex { $0.id == currentID } ?? 0
    }

    var body: some View {
        ZStack {
            // 恒深色查看器背景（与挑片页查看器 GatherTheme.viewerBackground 统一）。
            GatherTheme.viewerBackground
            if let photo = currentPhoto {
                VStack(spacing: 12) {
                    HStack {
                        Text(photo.filename)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(GatherTheme.viewerTextPrimary)
                        Spacer()
                        Text("\(currentIndex + 1) / \(photos.count)")
                            .font(.callout)
                            .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.65))
                    Button(GatherLocalization.l("关闭"), action: onClose)
                        .keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    GeometryReader { geometry in
                        ZStack {
                            // allowsHitTesting(false)：scaleEffect 放大后命中区域
                            // 外溢（.clipped() 不裁剪命中），会吞掉灯箱顶部/底部
                            // 按钮的点击；手势统一挂在容器上。
                            PhotoThumbnailView(
                                path: photo.filepath,
                                size: 2048,
                                preview: true,
                                contentMode: .fit
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .scaleEffect(scale)
                            .offset(offset)
                            .allowsHitTesting(false)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(5, max(0.5, gestureScale * value))
                                }
                                .onEnded { _ in
                                    gestureScale = scale
                                    if scale <= 1 { offset = .zero }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    // TS: 缩放 ≤1 不可拖拽，>1 可平移。
                                    guard scale > 1 else { return }
                                    offset = value.translation
                                }
                        )
                        .onTapGesture(count: 2) {
                            // 双击复位（原生侧增强，对齐「重置」按钮语义）。
                            resetTransform()
                        }
                        // TS: wheel 事件 ±0.2/档、钳制 [0.5, 5]（passive:false +
                        // preventDefault 语义：消费事件防止触发滚动）。
                        .overlay {
                            ScrollWheelCatcher { deltaY in
                                guard deltaY != 0 else { return }
                                let next = min(5, max(0.5, scale + (deltaY > 0 ? -0.2 : 0.2)))
                                scale = next
                                gestureScale = next
                                if next <= 1 { offset = .zero }
                            }
                        }
                    }
                    .background(Color.black.opacity(0.9))
                    .clipped()

                    HStack(spacing: 20) {
                        metadataItem(GatherLocalization.l("尺寸"), "\(photo.width) × \(photo.height)")
                        metadataItem(GatherLocalization.l("状态"), photo.status == "missing" ? GatherLocalization.l("离线") : GatherLocalization.l("在线"))
                        metadataItem(GatherLocalization.l("人脸"), "\(photo.faceCount)")
                        if photo.variantCount > 1 {
                            metadataItem(GatherLocalization.l("变体"), "\(photo.variantCount)")
                        }
                        Spacer()
                        Button {
                            scale = max(0.5, scale - 0.25)
                            gestureScale = scale
                            if scale <= 1 { offset = .zero }
                        } label: { Image(systemName: "minus.magnifyingglass") }
                        .accessibilityLabel(GatherLocalization.l("缩小"))
                        Text("\(Int(scale * 100))%")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.8))
                            .frame(width: 44)
                        Button {
                            scale = min(5, scale + 0.25)
                            gestureScale = scale
                        } label: { Image(systemName: "plus.magnifyingglass") }
                        .accessibilityLabel(GatherLocalization.l("放大"))
                        Button(GatherLocalization.l("重置")) {
                            resetTransform()
                        }
                        Button {
                            goPrevious()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel(GatherLocalization.l("上一张"))
                        .disabled(currentIndex == 0)
                        Button {
                            goNext()
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .accessibilityLabel(GatherLocalization.l("下一张"))
                        .disabled(currentIndex == photos.count - 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                }
            } else {
                // TS if (!photo) return null —— 照片已随刷新消失：占位 + 关闭。
                VStack(spacing: 10) {
                    Text(GatherLocalization.l("照片已不可用"))
                        .font(.callout)
                        .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.65))
                    Button(GatherLocalization.l("关闭"), action: onClose)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            installKeyDownMonitor()
            bindKeyHandler()
        }
        .onDisappear {
            removeKeyDownMonitor()
        }
        .onChange(of: photos) { oldPhotos, newPhotos in
            // 事件刷新后 photos 变化：回调绑定刷新到最新数组；当前照片 id
            // 消失时不关闭（旧版「数组变化不重置」语义）——新数组非空则就近
            // 定位（沿用旧下标，钳制到边界）继续浏览，全空则停留占位态。
            bindKeyHandler()
            guard let currentID, !newPhotos.contains(where: { $0.id == currentID }) else { return }
            if !newPhotos.isEmpty {
                let previousIndex = oldPhotos.firstIndex { $0.id == currentID } ?? 0
                let fallback = min(max(0, previousIndex), newPhotos.count - 1)
                self.currentID = newPhotos[fallback].id
                resetTransform()
            }
        }
        .task(id: currentID) {
            // TS Lightbox.tsx:143-146 —— 相邻照片 preview 预加载（best-effort）。
            await Self.prefetchAdjacent(photos: photos, currentID: currentID)
        }
    }

    // MARK: 翻页（TS goNext/goPrev —— 切换照片重置缩放/位移）

    private func goNext() {
        guard currentIndex < photos.count - 1, let next = photos[safe: currentIndex + 1] else { return }
        currentID = next.id
        resetTransform()
    }

    private func goPrevious() {
        guard currentIndex > 0, let previous = photos[safe: currentIndex - 1] else { return }
        currentID = previous.id
        resetTransform()
    }

    // MARK: 方向键监听（TS 全局 keydown ←/→）

    /// 每次 body 求值后用最新 self 重建回调（photos/currentID 取当前值）。
    private func bindKeyHandler() {
        keyHandler.onArrow = { [self] isNext in
            isNext ? goNext() : goPrevious()
        }
    }

    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }
        // 仅消费落在当前 sheet（作为 sheet 弹出的 key window）的 ←/→，
        // 避免吞掉应用其他窗口（如设置窗口）里的键盘输入。
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [box = keyHandler] event in
            guard let window = event.window, window.isKeyWindow, window.sheetParent != nil else { return event }
            switch event.keyCode {
            case 123: // ←（TS ArrowLeft）
                box.onArrow?(false)
                return nil
            case 124: // →（TS ArrowRight）
                box.onArrow?(true)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyDownMonitor() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
    }

    // MARK: 相邻预加载

    /// TS Lightbox.tsx:143-146 —— 预取 index±1、±2 的 preview（best-effort，
    /// 失败静默）；解码结果落入 PhotoThumbnailCache，翻页即命中。
    private static func prefetchAdjacent(photos: [GalleryPhotoData], currentID: String?) async {
        guard let currentID, let index = photos.firstIndex(where: { $0.id == currentID }) else { return }
        let paths = [-2, -1, 1, 2].compactMap { offset -> String? in
            let target = index + offset
            guard photos.indices.contains(target) else { return nil }
            return photos[target].filepath
        }
        await withTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask(priority: .utility) {
                    // 外层 try? 不必要（Task 失败类型为 Never）；内层必须有 try?（decode 会抛错）
                    _ = await Task.detached(priority: .utility) {
                        try? PhotoThumbnailDecoder.decode(path: path, size: 2048, preview: true)
                    }.value
                }
            }
        }
    }

    private func resetTransform() {
        scale = 1
        gestureScale = 1
        offset = .zero
    }

    private func metadataItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.65))
            Text(value)
                .font(.callout)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
        }
    }
}

// MARK: - 滚轮缩放捕获器（SwiftUI 无 onScrollWheel，NSView 包装接收 wheel 事件）

/// TS Lightbox.tsx wheel 监听（passive:false + preventDefault）的等价实现：
/// 消费滚轮事件并回调缩放步进，阻止事件传播。鼠标事件转发给 nextResponder
/// （宿主 NSHostingView），保证下方 SwiftUI 手势（拖拽平移/捏合/双击）不受拦截。
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onWheel: (CGFloat) -> Void

    func makeNSView(context: Context) -> WheelCatcherNSView {
        let view = WheelCatcherNSView()
        view.onWheel = onWheel
        return view
    }

    func updateNSView(_ nsView: WheelCatcherNSView, context: Context) {
        nsView.onWheel = onWheel
    }

    final class WheelCatcherNSView: NSView {
        var onWheel: ((CGFloat) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 始终命中本视图以捕获滚动事件；鼠标事件经转发保持下方手势可用。
            self
        }

        override func scrollWheel(with event: NSEvent) {
            onWheel?(event.deltaY)
        }

        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
        override func mouseDragged(with event: NSEvent) { nextResponder?.mouseDragged(with: event) }
        override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
        override func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }
        override func rightMouseDragged(with event: NSEvent) { nextResponder?.rightMouseDragged(with: event) }
        override func rightMouseUp(with event: NSEvent) { nextResponder?.rightMouseUp(with: event) }
        override func otherMouseDown(with event: NSEvent) { nextResponder?.otherMouseDown(with: event) }
        override func otherMouseDragged(with event: NSEvent) { nextResponder?.otherMouseDragged(with: event) }
        override func otherMouseUp(with event: NSEvent) { nextResponder?.otherMouseUp(with: event) }
        override func magnify(with event: NSEvent) { nextResponder?.magnify(with: event) }
        override func rotate(with event: NSEvent) { nextResponder?.rotate(with: event) }
    }
}

/// ←/→ 键处理闭包盒：@State 实例引用稳定，监听器总能取到最新回调。
private final class LightboxKeyHandlerBox {
    var onArrow: ((Bool) -> Void)?
}
