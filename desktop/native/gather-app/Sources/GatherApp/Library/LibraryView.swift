// desktop/native/gather-app/Sources/GatherApp/Library/LibraryView.swift
// Phase 3.2 Library（全局图库）：SwiftUI 页面（宿主内直连 GatherCore，不走 WKWebView）。
// TS 源: desktop/src/renderer/pages/Library/index.tsx（筛选面板/工具栏/卡片网格/分页）
// 中文文案硬编码（项目 i18n 于 3.6 收尾，本阶段对齐 TS 默认语言 zh-CN）。
import SwiftUI
import AppKit
import GatherCore

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    let onOpenSession: (String) -> Void

    @State private var showAdvancedFilters = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.actionError {
                Text("查询失败：\(error)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
            header
            filterPanel
            Divider()
            toolbar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.load()
        }
    }

    // MARK: 头部（TS Library header：eyebrow + title + subtitle + 工作区选择）

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("照片资产")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("全局图库")
                    .font(.system(size: 24, weight: .bold))
                Text("以同一逻辑照片为单位，跨工作区浏览、筛选和管理。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("全部工作区", selection: $viewModel.sessionFilter) {
                Text("全部工作区").tag("")
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
        .padding(.vertical, 16)
    }

    // MARK: 筛选面板（TS filterPanel：主筛选 + 更多筛选 + 操作）

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("搜索文件名", text: $viewModel.filter.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onChange(of: viewModel.filter.search) { _, _ in viewModel.onFilterChanged() }
                filterSelect(
                    "全部星级",
                    selection: $viewModel.filter.rating,
                    options: [1, 2, 3, 4, 5].map { ("至少 \($0) 星", "\($0)") }
                )
                filterSelect(
                    "全部颜色",
                    selection: $viewModel.filter.label,
                    options: LibraryColorOption.all.map { ($0.label, $0.value) }
                )
                filterSelect(
                    "全部在线状态",
                    selection: $viewModel.filter.status,
                    options: [("在线", "online"), ("离线", "missing")]
                )
            }
            if showAdvancedFilters {
                HStack(spacing: 8) {
                    TextField("关键词", text: $viewModel.filter.keyword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .onChange(of: viewModel.filter.keyword) { _, _ in viewModel.onFilterChanged() }
                    TextField("人物", text: $viewModel.filter.person)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .onChange(of: viewModel.filter.person) { _, _ in viewModel.onFilterChanged() }
                    TextField("目录路径前缀", text: $viewModel.filter.directory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onChange(of: viewModel.filter.directory) { _, _ in viewModel.onFilterChanged() }
                    TextField("全部存储卷", text: $viewModel.filter.volume)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .onChange(of: viewModel.filter.volume) { _, _ in viewModel.onFilterChanged() }
                    filterSelect(
                        "全部重复状态",
                        selection: $viewModel.filter.duplicates,
                        options: [("有重复候选", "yes"), ("无重复候选", "no")]
                    )
                    filterSelect(
                        "全部导入时间",
                        selection: $viewModel.filter.recentDays,
                        options: [("最近 24 小时", "1"), ("最近 7 天", "7"), ("最近 30 天", "30")]
                    )
                }
            }
            HStack(spacing: 12) {
                Button(showAdvancedFilters ? "收起更多筛选" : moreFiltersLabel) {
                    showAdvancedFilters.toggle()
                }
                .buttonStyle(.link)
                Button("清除筛选") {
                    viewModel.clearFilters()
                }
                .disabled(viewModel.activeFilterCount == 0)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var moreFiltersLabel: String {
        let count = viewModel.advancedFilterCount
        return count > 0 ? "更多筛选（\(count)）" : "更多筛选"
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
                Text("加载中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("共 \(viewModel.total) 张逻辑照片")
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
            ProgressView("加载照片中…")
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
            VStack(spacing: 0) {
                if viewModel.photos.isEmpty {
                    Text("没有符合条件的照片")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                    Button("上一页") {
                        viewModel.prevPage()
                    }
                    .disabled(viewModel.page == 0)
                    Text("\(viewModel.page + 1) / \(max(1, Int(ceil(Double(viewModel.total) / Double(LibraryViewModel.pageSize)))))")
                        .font(.callout)
                        .monospacedDigit()
                    Button("下一页") {
                        viewModel.nextPage()
                    }
                    .disabled(!viewModel.hasNextPage)
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - 照片卡片（TS Library card：缩略图 + 文件名 + 星级 + 色标 + 会话）

private struct LibraryCardView: View {
    let photo: GlobalPhotoResult
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    PhotoThumbnailView(path: photo.filepath, size: 512)
                        .frame(height: 110)
                        .clipped()
                        .background(Color(nsColor: .controlBackgroundColor))
                    if photo.status == "missing" {
                        Text("离线")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                Text(photo.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(Self.starText(photo.rating))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("\(photo.label.isEmpty ? "无色标" : photo.label) · \(photo.sessionNames.joined(separator: "、"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !photo.keywords.isEmpty {
                    Text(photo.keywords.prefix(4).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// TS: rating 星级（★ 重复 + ☆ 补齐）。
    static func starText(_ rating: Double) -> String {
        let count = Int(rating)
        guard count > 0 else { return "未评级" }
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
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        case .pink: return "粉"
        case .purple: return "紫"
        }
    }
}
