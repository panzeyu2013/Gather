// desktop/native/gather-app/Sources/GatherUI/Gallery/LightboxView.swift
// Cut 4 / 4c-2c：灯箱（预览 + 元数据 + 缩放/平移 + 相邻预加载）与滚轮捕获，
// 原 GalleryView.swift 949-1318、1320-1362 行逐字搬移。
// 视图身份（currentID/scale）不进外层 .id：翻页/缩放不重建视图树。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: - Lightbox（TS components/Lightbox/Lightbox.tsx 的简化版：预览 + 元数据）

struct LightboxView: View {
    let photos: [GalleryPhotoData]
    let initialIndex: Int
    let onClose: () -> Void

    /// Cut 4 / 4b-2i：灯箱文案（关闭/尺寸/状态/缩放/翻页）与页面同一语言源。
    /// 显式 init 只接管值属性，本属性由 SwiftUI 安装视图时注入，不参与 init。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// 当前照片 id（photos 变化时按 id 重新定位；TS Lightbox.tsx:122
    /// if (!photo) return null 语义，避免事件刷新缩水后下标崩溃）。
    @State private var currentID: String?
    /// 可见区域细节层（去抖 150ms 后更新）。
    @State private var detailTileState: PhotoViewerGeometry.DetailTile?
    @State private var detailTileTask: Task<Void, Never>?
    @State private var scale = 1.0
    @State private var gestureScale = 1.0
    @State private var offset = CGSize.zero
    /// 本次拖拽起点基线（审计 B-C2）：translation 相对手势起点，不叠加基线
    /// 会让松手后的下一次拖拽弹回原点。
    @State private var dragStartOffset = CGSize.zero
    /// ←/→ 键：.onKeyPress 需要焦点，灯箱出现时把焦点交给查看器容器
    /// （旧版用 NSEvent.addLocalMonitorForEvents 全局监听，已删除）。
    @FocusState private var keysFocused: Bool

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
                photoViewer(photo)
            } else {
                unavailableView
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .focusable()
        .focusEffectDisabled()
        .focused($keysFocused)
        .onKeyPress(.leftArrow) {
            goPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            goNext()
            return .handled
        }
        .onAppear { keysFocused = true }
        .onChange(of: photos) { oldPhotos, newPhotos in
            // 事件刷新后 photos 变化：当前照片 id 消失时不关闭（旧版「数组变化
            // 不重置」语义）——新数组非空则就近定位（沿用旧下标，钳制到边界）
            // 继续浏览，全空则停留占位态。
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

    // MARK: 主体（照片 + 顶部文件名行 + 底部元数据行）

    private func photoViewer(_ photo: GalleryPhotoData) -> some View {
        VStack(spacing: 12) {
            headerRow(photo)
            zoomableImage(photo)
            footerRow(photo)
        }
    }

    private func headerRow(_ photo: GalleryPhotoData) -> some View {
        HStack(spacing: 12) {
            Text(photo.filename)
                .font(GatherFont.sectionTitle)
                .lineLimit(1)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
            Spacer(minLength: 0)
            Text("\(currentIndex + 1) / \(photos.count)")
                .font(GatherFont.mono)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.75))
            Button(l10n("关闭"), action: onClose)
                .keyboardShortcut(.cancelAction)
                .help(l10n("关闭"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func zoomableImage(_ photo: GalleryPhotoData) -> some View {
        GeometryReader { geometry in
            ZStack {
                // allowsHitTesting(false)：scaleEffect 放大后命中区域外溢
                //（.clipped() 不裁剪命中），会吞掉灯箱顶部/底部按钮的点击；
                // 手势统一挂在容器上。
                // 底层：整图基准档位图（构图 + 手势 + 立即显示）。
                PhotoThumbnailView(
                    path: photo.filepath,
                    size: PhotoDetailTier.baseDimension,
                    preview: true,
                    contentMode: .fit,
                    placeholderSurface: GatherTheme.viewerSurface,
                    placeholderTextColor: GatherTheme.viewerTextSecondary
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .allowsHitTesting(false)
                // 可见区域细节层（同审片台）：只解当前看得到的那一块。
                if let tile = detailTileState {
                    PhotoDetailTileView(
                        path: photo.filepath,
                        normalizedRect: tile.normalizedRect,
                        targetPixel: PhotoViewerGeometry.tilePixelSize(
                            viewRect: tile.viewRect,
                            budgetDimension: PhotoDetailTier.maxDimension
                        )
                    )
                    .frame(width: max(0, tile.viewRect.width), height: max(0, tile.viewRect.height))
                    .position(x: tile.viewRect.midX, y: tile.viewRect.midY)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                // macOS 14：MagnificationGesture 已废弃，改 MagnifyGesture。
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(5, max(0.5, gestureScale * value.magnification))
                    }
                    .onEnded { _ in
                        gestureScale = scale
                        if scale <= 1 {
                            offset = .zero
                            dragStartOffset = .zero
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        // TS: 缩放 ≤1 不可拖拽，>1 可平移。
                        guard scale > 1 else { return }
                        offset = PanOffset.apply(start: dragStartOffset, translation: value.translation)
                    }
                    .onEnded { _ in
                        dragStartOffset = offset
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
            // 可见区域细节层：缩放或平移停止 150ms 后重算可见矩形（只重解那一块）。
            .onChange(of: scale) { _, _ in scheduleDetailTileUpdate(photo: photo, containerSize: geometry.size) }
            .onChange(of: offset) { _, _ in scheduleDetailTileUpdate(photo: photo, containerSize: geometry.size) }
            .onAppear { scheduleDetailTileUpdate(photo: photo, containerSize: geometry.size) }
        }
        .background(Color.black.opacity(0.9))
        .clipped()
    }

    private func footerRow(_ photo: GalleryPhotoData) -> some View {
        HStack(spacing: 20) {
            metadataItem(l10n("尺寸"), "\(photo.width) × \(photo.height)")
            metadataItem(
                l10n("状态"),
                photo.status == "missing" ? l10n("离线") : l10n("在线")
            )
            metadataItem(l10n("人脸"), "\(photo.faceCount)")
            if photo.variantCount > 1 {
                metadataItem(l10n("变体"), "\(photo.variantCount)")
            }
            Spacer(minLength: 0)
            Button {
                zoom(by: -0.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help(l10n("缩小"))
            .accessibilityLabel(l10n("缩小"))
            Text("\(Int(scale * 100))%")
                .font(GatherFont.mono)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.8))
                .frame(width: 52)
            Button {
                zoom(by: 0.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help(l10n("放大"))
            .accessibilityLabel(l10n("放大"))
            Button(l10n("重置")) {
                resetTransform()
            }
            .help(l10n("重置"))
            Button {
                goPrevious()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help(l10n("上一张"))
            .accessibilityLabel(l10n("上一张"))
            .disabled(currentIndex == 0)
            Button {
                goNext()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help(l10n("下一张"))
            .accessibilityLabel(l10n("下一张"))
            .disabled(currentIndex == photos.count - 1)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    /// TS if (!photo) return null —— 照片已随刷新消失：占位 + 关闭。
    /// 查看器是恒深色表面，这里保留查看器文字色（系统 ContentUnavailableView
    /// 在浅色外观下会给出深色文字，压在深色查看器上不可读）。
    private var unavailableView: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .imageScale(.large)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.75))
                .accessibilityHidden(true)
            Text(l10n("照片已不可用"))
                .font(GatherFont.cardTitle)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
            Button(l10n("关闭"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
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

    private func zoom(by delta: Double) {
        let next = min(5, max(0.5, scale + delta))
        scale = next
        gestureScale = next
        if next <= 1 { offset = .zero }
    }

    // MARK: 相邻预加载

    /// TS Lightbox.tsx:143-146 —— 预取 index±1、±2 的 preview（best-effort，
    /// 失败静默）；解码结果落入 PhotoThumbnailCache，翻页即命中。
    private static func prefetchAdjacent(photos: [GalleryPhotoData], currentID: String?) async {
        guard let currentID, let index = photos.firstIndex(where: { $0.id == currentID }) else { return }
        // 只预取紧邻的两张（-2/+2 的收益远低于它占用的解码名额）。
        let paths = [-1, 1].compactMap { offset -> String? in
            let target = index + offset
            guard photos.indices.contains(target) else { return nil }
            return photos[target].filepath
        }
        // A-1（性能审计）：旧实现解 2048 且**从不写缓存**（decode 只返回 Data），
        // 而灯箱显示用 baseDimension(2560) —— 缓存键不匹配 ⇒ 100% 无效解码，
        // 还占掉 4 个解码名额。现在：只预取相邻 2 张、键与显示完全一致、命中即跳过、
        // 串行且每张前检查取消。
        for path in paths {
            guard !Task.isCancelled else { return }
            let key = PhotoThumbnailCache.key(path: path, size: PhotoDetailTier.baseDimension, preview: true)
            if PhotoThumbnailCache.image(for: key) != nil { continue }
            // 走统一异步入口：受解码闸门（并发 4）、同键去重与磁盘缓存管；
            // 裸 Task.detached 会绕开闸门导致并发无界（第一轮自查发现的副作用）。
            guard let data = try? await PhotoThumbnailDecoder.decodeAsync(
                path: path,
                size: PhotoDetailTier.baseDimension,
                preview: true
            ) else { continue }
            guard !Task.isCancelled, let image = NSImage(data: data) else { continue }
            PhotoThumbnailCache.setImage(image, for: key)
        }
    }

    private func resetTransform() {
        scale = 1
        gestureScale = 1
        offset = .zero
        dragStartOffset = .zero
        detailTileTask?.cancel()
        detailTileState = nil
    }

    /// 可见区域细节层：缩放/平移停止 150ms 后重算可见矩形（只重解那一块）。
    private func scheduleDetailTileUpdate(photo: GalleryPhotoData, containerSize: CGSize) {
        let imageSize = CGSize(width: Double(photo.width), height: Double(photo.height))
        let zoom = Double(scale)
        let pan = offset
        detailTileTask?.cancel()
        detailTileTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            detailTileState = PhotoViewerGeometry.detailTile(
                imageSize: imageSize,
                viewSize: containerSize,
                zoom: zoom,
                panOffset: pan,
                backingPixelBudget: PhotoDetailTier.baseDimension
            )
        }
    }

    /// 适配显示尺寸的最长边（pt）：与 contentMode .fit 的几何一致（灯箱档位用）。
    static func fitPoints(imageSize: CGSize, containerSize: CGSize) -> Double {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else { return 0 }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return Double(max(imageSize.width, imageSize.height) * scale)
    }

    private func metadataItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(GatherFont.labelRegular)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.7))
            Text(value)
                .font(GatherFont.body)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
        }
        .accessibilityElement(children: .combine)
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
