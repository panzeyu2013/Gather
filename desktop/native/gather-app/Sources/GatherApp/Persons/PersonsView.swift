// desktop/native/gather-app/Sources/GatherApp/Persons/PersonsView.swift
// Phase 3.5：人脸库 SwiftUI 页面，替换 /persons 的 React 页面。

import SwiftUI
import AppKit
import GatherCore

struct PersonsView: View {
    @Bindable var viewModel: PersonsViewModel
    let onReview: (String) -> Void
    @State private var showCreate = false

    init(viewModel: PersonsViewModel, onReview: @escaping (String) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.onReview = onReview
    }

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: 300)
            Divider()
            detailPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await viewModel.load() }
        .sheet(isPresented: $showCreate) {
            CreatePersonSheet { name in
                await viewModel.create(name: name)
            }
        }
    }

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("人脸库").font(.title2.weight(.semibold))
                Spacer()
                Button { showCreate = true } label: {
                    Image(systemName: "plus")
                }
                .help("新建人物")
            }
            .padding(16)

            TextField("搜索人物", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            if case .failed(let error) = viewModel.phase {
                Text("加载失败：\(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            List(viewModel.filteredPersons, id: \.id) { person in
                Button {
                    try? viewModel.select(person.id)
                } label: {
                    PersonListRow(person: person, selected: viewModel.selected?.id == person.id)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let person = viewModel.selected {
            PersonDetailView(person: person, viewModel: viewModel, onReview: onReview)
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
            avatar
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
    @State private var name = ""
    @State private var notes = ""
    @State private var showDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
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
                            Task { await viewModel.saveSelected(name: name, notes: notes) }
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
                            if let sessionId = person.photos.first?.sessionId {
                                onReview(sessionId)
                            }
                        }
                    }
                }
                Section("记录") {
                    LabeledContent("创建时间", value: person.createdAt)
                    LabeledContent("更新时间", value: person.updatedAt)
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
        .alert("删除人物？", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await viewModel.deleteSelected() } }
        } message: {
            Text("人物关联关系将被删除，照片文件不会被删除。")
        }
    }
}

private struct CreatePersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let onCreate: (String) async -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建人物").font(.title2.weight(.semibold))
            TextField("人物名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("创建") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task {
            if await onCreate(value) { dismiss() }
        }
    }
}
