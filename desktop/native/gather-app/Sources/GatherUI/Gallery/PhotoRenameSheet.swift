// desktop/native/gather-app/Sources/GatherUI/Gallery/PhotoRenameSheet.swift
// Wave5（Batch4 / task-19）：批量重命名 / 移动到文件夹的确认 sheet（含预演）。
//
// 交互口径（与 GalleryStackActions 同一套语言）：
// - 重命名：模板输入 + 冲突策略 + 逐项预演（旧→新/冲突）→ 用户点「重命名」才构造
//   Confirmed（源 = .userDialog），取消分支不发任何命令；
// - 移动：NSOpenPanel 选目标目录 + 策略 + 将要移动的张数/目标目录（预演）→ 确认；
// - 失败/跳过逐项列出（不静默部分成功）；模板非法时执行按钮直接禁用。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: - 延迟动作目标（sheet(item:) 需要 Identifiable）

struct PendingPhotoRename: Identifiable, Equatable {
    let photoIds: [String]
    var id: String { photoIds.joined(separator: ",") }
}

struct PendingPhotoMove: Identifiable, Equatable {
    let photoIds: [String]
    var id: String { photoIds.joined(separator: ",") }
}

extension GalleryView {
    func requestPhotoRename(photoIds: [String]) {
        guard !photoIds.isEmpty else { return }
        pendingPhotoRename = PendingPhotoRename(photoIds: photoIds.sorted())
    }

    func requestPhotoMove(photoIds: [String]) {
        guard !photoIds.isEmpty else { return }
        pendingPhotoMove = PendingPhotoMove(photoIds: photoIds.sorted())
    }

    func photoRenameSheet(_ pending: PendingPhotoRename) -> some View {
        PhotoRenameSheet(viewModel: viewModel, photoIds: pending.photoIds)
    }

    func photoMoveSheet(_ pending: PendingPhotoMove) -> some View {
        PhotoMoveSheet(viewModel: viewModel, photoIds: pending.photoIds)
    }
}

/// 冲突策略的中文名（两张 sheet 共用；默认 coexist 最安全）。
func photoFilePolicyLabel(_ policy: PhotoFileConflictPolicy, l10n: L10n) -> String {
    switch policy {
    case .skip: return l10n("跳过冲突项")
    case .replace: return l10n("覆盖目标（先备份）")
    case .coexist: return l10n("自动加序号")
    }
}

/// 冲突分类的中文名。
func photoRenameConflictLabel(_ conflict: PhotoRenameConflict, l10n: L10n) -> String {
    switch conflict {
    case .none: return l10n("可改名")
    case .targetExists: return l10n("目标已存在")
    case .duplicateTarget: return l10n("同批撞名")
    case .invalidToken: return l10n("模板/名称非法")
    case .missingSource: return l10n("源文件缺失")
    case .notInSession: return l10n("不属于该工作区")
    }
}

// MARK: - 重命名 sheet

struct PhotoRenameSheet: View {
    let viewModel: GalleryViewModel
    let photoIds: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var template = "{orig}_{seq:4}.{ext}"
    @State private var policy: PhotoFileConflictPolicy = .coexist
    @State private var preview: PhotoRenamePreview?
    @State private var isLoadingPreview = false
    @State private var isSubmitting = false
    @State private var result: PhotoRenameResult?

    private static let maxPreviewRows = 200

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("批量重命名"))
                .font(GatherFont.sectionTitle)
            Text(l10n("按模板改名（复用导入的重命名 token）：{yyyy} {MM} {dd} {HH} {mm} {ss} {orig} {ext} {camera} {seq:4}。扩展名必须与原文件一致。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextField(l10n("重命名模板"), text: $template)
                .textFieldStyle(.roundedBorder)
                .font(GatherFont.labelRegular)
            HStack(spacing: GatherMetrics.Space.m) {
                Picker(l10n("冲突时"), selection: $policy) {
                    ForEach(PhotoFileConflictPolicy.allCases, id: \.self) { value in
                        Text(photoFilePolicyLabel(value, l10n: l10n)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                Spacer(minLength: 0)
                Text(l10n.format("已选 %lld 张", photoIds.count))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
            }
            previewSection
            if let result { resultSection(result) }
            HStack {
                Spacer(minLength: 0)
                Button(l10n("取消")) { dismiss() }
                    .gatherButton(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(isSubmitting)
                Button(l10n("重命名")) { Task { await submit() } }
                    .gatherButton(.primary)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!canSubmit)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 560)
        .task(id: template) { await refreshPreview() }
    }

    private var canSubmit: Bool {
        Self.canSubmit(preview: preview, isSubmitting: isSubmitting)
    }

    /// 执行按钮门禁（纯函数，供 PhotoRenameTests 直接驱动）：
    /// 至少一张可改名、模板无非法 token、且没有在途提交。
    static func canSubmit(preview: PhotoRenamePreview?, isSubmitting: Bool) -> Bool {
        guard !isSubmitting, let preview, preview.unavailableReason == nil else { return false }
        return preview.invalidTokens.isEmpty && preview.renameable > 0
    }

    @ViewBuilder
    private var previewSection: some View {
        if let preview, let reason = preview.unavailableReason {
            Text(reason)
                .font(GatherFont.labelRegular)
                .foregroundStyle(GatherTheme.secondaryText)
        } else if let preview {
            if !preview.invalidTokens.isEmpty {
                Text(l10n.format(
                    "模板含无法识别的 token：%@（整批不执行）",
                    preview.invalidTokens.joined(separator: " ")))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(.red)
            }
            Text(l10n.format(
                "预演：可改名 %lld 张；冲突 %lld 张（按上面的策略处理）。",
                preview.renameable, preview.conflicts))
                .font(GatherFont.labelRegular)
                .foregroundStyle(GatherTheme.secondaryText)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                    ForEach(
                        Array(preview.items.prefix(Self.maxPreviewRows)),
                        id: \.photoId
                    ) { item in
                        HStack(spacing: GatherMetrics.Space.s) {
                            Text(item.oldFilename)
                                .font(GatherFont.labelRegular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("→")
                                .foregroundStyle(GatherTheme.secondaryText)
                            Text(item.newFilename.isEmpty ? "—" : item.newFilename)
                                .font(GatherFont.labelRegular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(photoRenameConflictLabel(item.conflict, l10n: l10n))
                                .font(GatherFont.labelRegular)
                                .foregroundStyle(
                                    item.conflict == .none
                                        ? GatherTheme.secondaryText : .red)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            if isLoadingPreview {
                ProgressView().controlSize(.small)
            }
        } else if isLoadingPreview {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func resultSection(_ result: PhotoRenameResult) -> some View {
        Text(l10n.format(
            "完成：已重命名 %lld 张，跳过 %lld 张，失败 %lld 张。",
            result.renamed, result.skipped, result.failed.count))
            .font(GatherFont.labelRegular)
        if !result.failed.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                    ForEach(result.failed, id: \.photoId) { failure in
                        Text("\(failure.path)：\(failure.message)")
                            .font(GatherFont.labelRegular)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }

    private func refreshPreview() async {
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        // 输入防抖：模板逐字符输入时不打一次 RPC。
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        preview = await viewModel.previewPhotoRename(
            photoIds: photoIds, template: template)
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        result = await viewModel.performPhotoRename(
            photoIds: photoIds, template: template, policy: policy)
        if let result, result.failed.isEmpty { dismiss() }
    }
}

// MARK: - 移动 sheet

struct PhotoMoveSheet: View {
    let viewModel: GalleryViewModel
    let photoIds: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var destination = ""
    @State private var policy: PhotoFileConflictPolicy = .coexist
    @State private var isSubmitting = false
    @State private var result: PhotoMoveResult?

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("移动到文件夹"))
                .font(GatherFont.sectionTitle)
            Text(l10n("把所选照片连同同名 XMP 一起移到目标文件夹；库内路径随之更新（不删除任何文件）。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: GatherMetrics.Space.s) {
                Button(l10n("选择目标文件夹…")) { chooseDestination() }
                    .gatherButton(.secondary)
                Text(destination.isEmpty ? l10n("未选择") : destination)
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Picker(l10n("同名文件冲突时"), selection: $policy) {
                ForEach(PhotoFileConflictPolicy.allCases, id: \.self) { value in
                    Text(photoFilePolicyLabel(value, l10n: l10n)).tag(value)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 300)
            // 预演：目标目录 + 张数 + 策略（磁盘冲突在执行时逐项返回 skipped/failed）。
            Text(l10n.format(
                "预演：将把 %lld 张照片移到上面选择的文件夹；目标已存在的同名文件按「%@」处理。",
                photoIds.count, photoFilePolicyLabel(policy, l10n: l10n)))
                .font(GatherFont.labelRegular)
                .foregroundStyle(GatherTheme.secondaryText)
            if let result { resultSection(result) }
            HStack {
                Spacer(minLength: 0)
                Button(l10n("取消")) { dismiss() }
                    .gatherButton(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(isSubmitting)
                Button(l10n("移动")) { Task { await submit() } }
                    .gatherButton(.primary)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(isSubmitting || destination.isEmpty)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 560)
    }

    @ViewBuilder
    private func resultSection(_ result: PhotoMoveResult) -> some View {
        Text(l10n.format(
            "完成：已移动 %lld 张，跳过 %lld 张，失败 %lld 张。",
            result.moved, result.skipped, result.failed.count))
            .font(GatherFont.labelRegular)
        if !result.failed.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                    ForEach(result.failed, id: \.photoId) { failure in
                        Text("\(failure.path)：\(failure.message)")
                            .font(GatherFont.labelRegular)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = l10n("移动到此处")
        panel.message = l10n("选择移动目标文件夹（照片与同名 XMP 会一起移动）")
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.path
        }
    }

    private func submit() async {
        guard !isSubmitting, !destination.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        result = await viewModel.performPhotoMove(
            photoIds: photoIds, destinationRoot: destination, policy: policy)
        if let result, result.failed.isEmpty { dismiss() }
    }
}
