// desktop/native/gather-app/Sources/GatherApp/Persons/PersonsView.swift
// Phase 3.5：人脸库 SwiftUI 页面，替换 /persons 的 React 页面。
// 对齐 TS Persons/index.tsx 与 PersonDetail.tsx：
// - 错误展示：创建/保存/删除失败经 NativeBanner 红色横幅渲染（P0）；创建失败时
//   sheet 保持打开并在 sheet 内展示错误。
// - 状态展示：空态（暂无人物 + 引导文案 + 新建 CTA）、加载态（进度指示 +
//   加载中…）、搜索无结果态（未找到匹配的人物 + 尝试其他关键词）。

import SwiftUI
import AppKit
import GatherCore

struct PersonsView: View {
    @Bindable var viewModel: PersonsViewModel
    let onReview: (String) -> Void
    /// 对齐旧版 PersonDetail「前往人脸审核」：跳转到人脸关键词页并按角色名
    /// （person.name, sessionId）预筛选。由 RootView 注入；nil 时回退 onReview(sessionId)。
    var onReviewFaceRole: ((String, String) -> Void)? = nil
    @State private var showCreate = false

    init(
        viewModel: PersonsViewModel,
        onReview: @escaping (String) -> Void = { _ in },
        onReviewFaceRole: ((String, String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onReview = onReview
        self.onReviewFaceRole = onReviewFaceRole
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.actionError {
                NativeBanner(text: "操作失败：\(error)", color: GatherTheme.error)
            }
            HStack(spacing: 0) {
                listPane
                    .frame(width: 300)
                Divider()
                detailPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gatherBackground)
        .task { await viewModel.load() }
        .sheet(isPresented: $showCreate) {
            CreatePersonSheet(viewModel: viewModel) { name in
                await viewModel.create(name: name)
            }
            .onAppear { viewModel.clearActionError() }
        }
    }

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("人脸库").font(.system(size: 24, weight: .bold))
                Spacer()
                // 对齐 TS Persons/index.tsx：搜索与新建按钮仅在有人物时展示，
                // 空态由 emptyState 提供新建 CTA。
                if !viewModel.persons.isEmpty {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .help("新建人物")
                }
            }
            .padding(16)

            if !viewModel.persons.isEmpty {
                TextField("搜索姓名…", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            listContent
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.phase {
        case .loading:
            // 对齐 TS persons.loading = "加载中..."；省略号按全站风格统一为 "…"。
            VStack(spacing: 10) {
                ProgressView()
                Text("加载中…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text("加载失败：\(error)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await viewModel.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        case .loaded:
            if viewModel.persons.isEmpty {
                emptyState
            } else if viewModel.filteredPersons.isEmpty {
                noMatchState
            } else {
                List(viewModel.filteredPersons, id: \.id) { person in
                    Button {
                        viewModel.select(person.id)
                    } label: {
                        PersonListRow(person: person, selected: viewModel.selected?.id == person.id)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
    }

    /// 对齐 TS persons.emptyTitle / persons.emptyHint / persons.new。
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("暂无人物").font(.headline)
            Text("新建人物以开始建立人脸库")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("新建人物") { showCreate = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// 对齐 TS persons.noMatch / persons.noMatchHint。
    private var noMatchState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("未找到匹配的人物").font(.headline)
            Text("尝试其他关键词")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let person = viewModel.selected {
            PersonDetailView(
                person: person,
                viewModel: viewModel,
                onReview: onReview,
                onReviewFaceRole: onReviewFaceRole
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
                Text("选择一个人物")
                    .foregroundStyle(.secondary)
                Button("新建人物") { showCreate = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PersonListRow: View {
    let person: PersonData
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // 对齐旧版 Persons 列表头像：圆形（64px→42px 适配原生侧栏行）。
            avatar
                .frame(width: 42, height: 42)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).lineLimit(1)
                Text("\(person.photoCount) 张照片 · \(person.sessionCount) 个工作区")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var avatar: some View {
        if let path = person.thumbnailPath, !path.isEmpty {
            PhotoThumbnailView(path: path, size: 96)
        } else if let base64 = person.thumbnailBase64, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Text(String(person.name.prefix(1))).font(.headline)
            }
        }
    }
}

private struct PersonDetailView: View {
    let person: PersonDetailData
    @Bindable var viewModel: PersonsViewModel
    let onReview: (String) -> Void
    var onReviewFaceRole: ((String, String) -> Void)? = nil
    @State private var name = ""
    @State private var notes = ""
    @State private var showDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 对齐旧版 PersonDetail 顶部「← 返回人脸库」链接：点击清空选中回列表。
            Button {
                viewModel.deselect()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                    Text("返回人脸库")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.top, 16)

            HStack(alignment: .center, spacing: 16) {
                avatar
                VStack(alignment: .leading, spacing: 5) {
                    Text("人物详情").font(.caption).foregroundStyle(.secondary)
                    Text(person.name).font(.largeTitle.weight(.bold))
                    Text("\(person.totalPhotoCount) 张照片 · \(person.sessionCount) 个工作区")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("删除", role: .destructive) { showDelete = true }
            }
            .padding(24)

            Form {
                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                    HStack {
                        Spacer()
                        Button("保存") {
                            Task {
                                let ok = await viewModel.saveSelected(name: name, notes: notes)
                                if ok {
                                    GatherToastCenter.shared.show(type: .success, message: "人物信息已保存")
                                } else {
                                    GatherToastCenter.shared.show(type: .error, message: viewModel.actionError ?? "保存失败")
                                }
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("人脸匹配") {
                    if person.keywords.isEmpty {
                        Text("尚未设置人物关键字").foregroundStyle(.secondary)
                    } else {
                        Text(person.keywords.joined(separator: ", "))
                            .font(.callout)
                    }
                    LabeledContent("匹配阈值", value: String(format: "%.2f", person.matchThreshold))
                    if !person.photos.isEmpty {
                        Button("在当前工作区复核人脸") {
                            // 对齐旧版 PersonDetail.tsx:158-162：携带
                            // ?role=encodeURIComponent(person.name) 预筛选；
                            // 未注入 onReviewFaceRole 时回退旧行为。
                            if let onReviewFaceRole {
                                if let sessionId = person.photos.first?.sessionId {
                                    onReviewFaceRole(person.name, sessionId)
                                }
                            } else if let sessionId = person.photos.first?.sessionId {
                                onReview(sessionId)
                            }
                        }
                    }
                }
                Section("记录") {
                    LabeledContent("创建时间", value: Self.dateText(person.createdAt))
                    LabeledContent("更新时间", value: Self.dateText(person.updatedAt))
                }
            }
            .formStyle(.grouped)

            Divider()
            Text("关联照片").font(.headline).padding(.horizontal, 24).padding(.top, 16)
            if person.photos.isEmpty {
                Text("暂无关联照片").foregroundStyle(.secondary).padding(24)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(person.photos, id: \.photoId) { photo in
                            VStack(alignment: .leading, spacing: 4) {
                                PhotoThumbnailView(path: photo.filepath, size: 240, placeholderSize: CGSize(width: 150, height: 110))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(photo.filename).font(.caption).lineLimit(1)
                                Text(photo.sessionName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .onAppear {
            name = person.name
            notes = person.notes
        }
        .onChange(of: person.id) { _, _ in
            name = person.name
            notes = person.notes
        }
        .confirmationDialog("删除人物？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    let ok = await viewModel.deleteSelected()
                    if ok {
                        GatherToastCenter.shared.show(type: .success, message: "人物已删除")
                    } else {
                        GatherToastCenter.shared.show(type: .error, message: viewModel.actionError ?? "删除失败")
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除「\(person.name)」吗？此操作将从人脸库中移除该人物及其所有关联的人脸数据。")
        }
    }

    /// 对齐旧版 PersonDetail 头像：80×80 圆形；无照片时主色底 + 36px 首字。
    @ViewBuilder
    private var avatar: some View {
        if let path = person.thumbnailPath, !path.isEmpty {
            PhotoThumbnailView(path: path, size: 160)
                .frame(width: 80, height: 80)
                .clipShape(Circle())
        } else if let base64 = person.thumbnailBase64, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 80)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(Color.accentColor)
                Text(String(person.name.prefix(1)))
                    .font(.system(size: 36, weight: .bold))
                    // 暗色模式 primary 为亮橙，白字对比不足 → 深棕。
                    .foregroundStyle(Color(red: 61 / 255, green: 56 / 255, blue: 51 / 255))
            }
            .frame(width: 80, height: 80)
        }
    }

    /// 对齐旧版 PersonDetail.tsx:192 `new Date(createdAt).toLocaleDateString()`：
    /// 仅日期、无时分。zh 环境固定 `yyyy年M月d日`，其余语言按系统区域日期模板
    /// （zh 判定与 SettingsViewModel.dateText 的 Locale.preferredLanguages
    /// 前缀检查同源；页面无 ui_language 访问通道，沿用系统区域近似）。
    private static func dateText(_ iso: String) -> String {
        guard let date = parseISO8601(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true {
            formatter.dateFormat = "yyyy年M月d日"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMd")
        }
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}

private struct CreatePersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @Bindable var viewModel: PersonsViewModel
    let onCreate: (String) async -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建人物").font(.title2.weight(.semibold))
            TextField("输入人物姓名", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            // 创建失败时 sheet 保持打开并在下方展示错误。
            if let errorText = viewModel.actionError, !errorText.isEmpty {
                Text("操作失败：\(errorText)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("创建") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task {
            if await onCreate(value) {
                GatherToastCenter.shared.show(type: .success, message: "人物已创建")
                dismiss()
            } else {
                GatherToastCenter.shared.show(type: .error, message: viewModel.actionError ?? "创建失败")
            }
        }
    }
}
