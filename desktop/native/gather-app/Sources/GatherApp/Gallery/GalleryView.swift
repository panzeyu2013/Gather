// desktop/native/gather-app/Sources/GatherApp/Gallery/GalleryView.swift
// Phase 3.2 Gallery（工作区浏览）：SwiftUI 页面（宿主内直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/SessionDetail/Gallery.tsx（工具栏/选择栏/
//       justified 网格/哨兵分页/变体徽标）+ pages/SessionDetail/index.tsx（页签）
// 中文文案硬编码（项目 i18n 于 3.6 收尾，本阶段对齐 TS 默认语言 zh-CN）。
import SwiftUI
import AppKit
import GatherCore

/// 工作区页签（对齐 SessionDetail/index.tsx 的 NavLink；全部由 SwiftUI 承载）。
enum SessionTab: String, CaseIterable, Identifiable {
    case control = "control"
    case faceKw = "face-kw"
    case duplicates
    case culling
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: return "控制中心"
        case .faceKw: return "人脸"
        case .duplicates: return "重复"
        case .culling: return "挑片"
        case .export: return "导出"
        }
    }
}

struct GalleryView: View {
    @Bindable var viewModel: GalleryViewModel
    let onBack: () -> Void
    let onOpenSimilarity: (String) -> Void
    let onOpenTab: (String, SessionTab) -> Void

    /// TS: DENSITY_OPTIONS（行高密度）。
    private static let densityOptions: [(value: Double, label: String)] = [
        (160, "小图"),
        (220, "中图"),
        (300, "大图"),
    ]

    @State private var density = 220.0
    @State private var lightboxIndex: Int?
    /// 网格行布局缓存（避免 ScrollView 滚动时反复重算 justified 布局）。
    @State private var layoutCache: (key: String, rows: [JustifiedLayoutRow])?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.actionError {
                Text("操作失败：\(error)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
            sessionHeader
            toolbar
            if !viewModel.selectedIds.isEmpty {
                selectionBar
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: Binding(
            get: { lightboxIndex != nil },
            set: { if !$0 { lightboxIndex = nil } }
        )) {
            if let index = lightboxIndex {
                LightboxView(
                    photos: viewModel.filteredPhotos,
                    initialIndex: index,
                    onClose: { lightboxIndex = nil }
                )
            }
        }
    }

    // MARK: 会话头部（TS SessionDetail header：返回 + 身份 + 页签）

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: onBack) {
                    Label("返回工作台", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前工作区")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.session?.name ?? "加载中…")
                        .font(.system(size: 20, weight: .bold))
                }
                Spacer()
            }
            HStack(spacing: 2) {
                tabButton(title: "浏览", isActive: true) {}
                tabButton(title: "相似度", isActive: false) {
                    onOpenSimilarity(viewModel.sessionId)
                }
                ForEach(SessionTab.allCases) { tab in
                    tabButton(title: tab.title, isActive: false) {
                        onOpenTab(viewModel.sessionId, tab)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func tabButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 工具栏（TS toolbar：搜索 + 过滤 + 密度 + 变体展开）

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("搜索文件名...", text: $viewModel.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onChange(of: viewModel.search) { _, _ in viewModel.searchChanged() }
            Picker("全部", selection: $viewModel.filter) {
                Text("全部").tag(GalleryFilter.all)
                Text("有人脸").tag(GalleryFilter.hasFace)
                Text("无人脸").tag(GalleryFilter.noFace)
            }
            .pickerStyle(.menu)
            .frame(width: 120)
            .onChange(of: viewModel.filter) { _, _ in viewModel.filterOrVariantChanged() }
            Picker("中图", selection: $density) {
                ForEach(Self.densityOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            Toggle(isOn: $viewModel.expandVariants) {
                Text(viewModel.expandVariants ? "折叠 RAW/JPEG" : "展开所有变体")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .onChange(of: viewModel.expandVariants) { _, _ in viewModel.filterOrVariantChanged() }
            Spacer()
            if viewModel.isFetchingNextPage {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    // MARK: 选择栏（TS selectionBar）

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("选中 \(viewModel.selectedIds.count) 张照片")
                .font(.callout)
            Button("取消选择") {
                viewModel.clearSelection()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.06))
    }

    // MARK: 内容（TS justified 网格 + 哨兵分页）

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView("加载照片中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Text("加载照片失败：\(message)")
                    .foregroundStyle(.red)
                Button("重试") {
                    Task { await viewModel.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            let filtered = viewModel.filteredPhotos
            if filtered.isEmpty {
                Text("暂无照片")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let rows = layoutRows(filtered: filtered, width: geometry.size.width)
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
                        .padding(16)
                    }
                }
            }
        }
    }

    /// TS: layoutJustifiedRows 的结果缓存（key 覆盖 filtered 身份 + 宽度 + 密度）。
    private func layoutRows(filtered: [GalleryPhotoData], width: Double) -> [JustifiedLayoutRow] {
        let key = "\(filtered.count)|\(width)|\(density)"
        if let cache = layoutCache, cache.key == key {
            return cache.rows
        }
        let source = filtered.map { GalleryAspectItem(width: Double(max(1, $0.width)), height: Double(max(1, $0.height))) }
        let rows = layoutJustifiedRows(source: source, containerWidth: width, targetRowHeight: density, gap: 8)
        layoutCache = (key, rows)
        return rows
    }

    private func rowView(_ row: JustifiedLayoutRow, filtered: [GalleryPhotoData]) -> some View {
        HStack(spacing: 8) {
            ForEach(row.items, id: \.index) { item in
                let photo = filtered[item.index]
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
                        isSelected: viewModel.selectedIds.contains(photo.id)
                    )
                    .frame(width: item.width, height: row.height)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Lightbox（TS components/Lightbox：预览 + 基础元数据）
}

// MARK: - 网格单元（TS GalleryThumbnail：缩略图 + 文件名 + 变体徽标 + 选中勾）

private struct GalleryCellView: View {
    let photo: GalleryPhotoData
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoThumbnailView(path: photo.filepath, size: 512)
                .clipped()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if photo.status == "missing" {
                        Text("离线")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                    if photo.variantCount > 1 {
                        Text("RAW+JPEG · \(photo.variantCount)")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                }
                Text(photo.filename)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.35))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 18, height: 18)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 2)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Lightbox（TS components/Lightbox/Lightbox.tsx 的简化版：预览 + 元数据）

private struct LightboxView: View {
    let photos: [GalleryPhotoData]
    let initialIndex: Int
    let onClose: () -> Void

    @State private var index: Int
    @State private var scale = 1.0
    @State private var gestureScale = 1.0
    @State private var offset = CGSize.zero

    init(photos: [GalleryPhotoData], initialIndex: Int, onClose: @escaping () -> Void) {
        self.photos = photos
        self.initialIndex = initialIndex
        self.onClose = onClose
        _index = State(initialValue: initialIndex)
    }

    var body: some View {
        let photo = photos[index]
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.98)
            VStack(spacing: 12) {
                HStack {
                    Text(photo.filename)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text("\(index + 1) / \(photos.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("关闭", action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                GeometryReader { geometry in
                    PhotoThumbnailView(
                        path: photo.filepath,
                        size: 2048,
                        preview: true
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
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
                                guard scale > 1 else { return }
                                offset = value.translation
                            }
                    )
                }
                .background(Color.black.opacity(0.9))
                .clipped()

                HStack(spacing: 20) {
                    metadataItem("尺寸", "\(photo.width) × \(photo.height)")
                    metadataItem("状态", photo.status == "missing" ? "离线" : "在线")
                    metadataItem("人脸", "\(photo.faceCount)")
                    if photo.variantCount > 1 {
                        metadataItem("变体", "\(photo.variantCount)")
                    }
                    Spacer()
                    Button {
                        scale = max(0.5, scale - 0.25)
                        gestureScale = scale
                        if scale <= 1 { offset = .zero }
                    } label: { Image(systemName: "minus.magnifyingglass") }
                    Text("\(Int(scale * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 44)
                    Button {
                        scale = min(5, scale + 0.25)
                        gestureScale = scale
                    } label: { Image(systemName: "plus.magnifyingglass") }
                    Button("重置") {
                        resetTransform()
                    }
                    Button {
                        index = max(0, index - 1)
                        resetTransform()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(index == 0)
                    Button {
                        index = min(photos.count - 1, index + 1)
                        resetTransform()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(index == photos.count - 1)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private func resetTransform() {
        scale = 1
        gestureScale = 1
        offset = .zero
    }

    private func metadataItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
        }
    }
}
