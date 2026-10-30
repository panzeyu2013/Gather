// desktop/native/gather-app/Sources/GatherUI/Curation/CollectionView.swift
// P1 下一波 §3.8.1 / §3.8.3：集合内容视图 + 跨工作区重复视图。
//
// 集合视图的排序契约（与 CollectionRepo 对应）：
// - 网格顺序 = collection_items.position 升序，**没有排序控件**（手动集合的顺序
//   是用户资产，不能被"按日期"覆盖）；
// - ⌘↑/⌘↓ 与拖放都只发"移到某张之前/之后"，服务端正常只写 1 行 position；
// - 视图不做本地乐观重排：移动成功后重新拉取（顺序真相只在库里，避免双真相）。
//
// 视图模型由视图自己从环境端口构造（宿主只需注入 CurationServices），
// 这样 Library 侧栏只需要传一个摘要，不必持有任何 VM 生命周期。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: - 集合视图模型

@MainActor
@Observable
final class CollectionViewModel {
    private let album: any AlbumAPI

    private(set) var collection: CollectionSummary
    private(set) var items: [CollectionMember] = []
    private(set) var isLoading = false
    private(set) var isMutating = false
    var actionError: CommandError?

    init(album: any AlbumAPI, collection: CollectionSummary) {
        self.album = album
        self.collection = collection
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await album.collectionItems(collection.id)
            actionError = nil
        } catch {
            actionError = CommandError(error)
        }
    }

    /// 移除成员（只动集合，不动照片文件）。
    func remove(photoId: String) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await album.removeCollectionItems(
                CollectionItemsInput(collectionId: collection.id, photoIds: [photoId])
            )
            await load()
        } catch {
            actionError = CommandError(error)
        }
    }

    /// 把 photoId 移到 beforePhotoId 之前；beforePhotoId = nil 表示移到末尾。
    func move(photoId: String, before beforePhotoId: String?) async {
        guard !isMutating, photoId != beforePhotoId else { return }
        let anchors = Self.anchors(
            photoId: photoId,
            beforePhotoId: beforePhotoId,
            items: items
        )
        isMutating = true
        defer { isMutating = false }
        do {
            try await album.moveCollectionItem(
                CollectionMoveInput(
                    collectionId: collection.id,
                    photoId: photoId,
                    afterPhotoId: anchors.after,
                    beforePhotoId: beforePhotoId
                )
            )
            await load()
        } catch {
            actionError = CommandError(error)
        }
    }

    /// ⌘↑ / ⌘↓：与相邻一张交换（同样走"移到某张之前/之后"）。
    func moveBy(photoId: String, offset: Int) async {
        guard let index = items.firstIndex(where: { $0.photoId == photoId }) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        // 下移必须锚到"目标位置的下一张之前"；锚到紧邻下一张会原地不动。
        let beforeId: String?
        if offset > 0 {
            let next = target + 1
            beforeId = items.indices.contains(next) ? items[next].photoId : nil
        } else {
            beforeId = items[target].photoId
        }
        await move(photoId: photoId, before: beforeId)
    }

    /// 计算拖放锚点（纯函数，便于单测）：before 的上一张作为 after；
    /// 拖到末尾时用"最后一张非自身"作为 after。
    static func anchors(
        photoId: String,
        beforePhotoId: String?,
        items: [CollectionMember]
    ) -> (after: String?, before: String?) {
        if let beforePhotoId,
           let index = items.firstIndex(where: { $0.photoId == beforePhotoId }) {
            let after = index > 0 ? items[index - 1].photoId : nil
            return (after == photoId ? nil : after, beforePhotoId)
        }
        let after = items.last(where: { $0.photoId != photoId })?.photoId
        return (after, nil)
    }
}

// MARK: - 集合内容视图

/// 集合网格（有序、可拖放、⌘↑/⌘↓ 微调）。
struct CollectionView: View {
    let collection: CollectionSummary
    let onClose: () -> Void

    @Environment(\.curationServices) private var services
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var model: CollectionViewModel?

    var body: some View {
        Group {
            if let model {
                CollectionContent(model: model, onClose: onClose)
            } else {
                GatherEmptyState(
                    icon: "square.stack.3d.up.slash",
                    title: l10n("集合不可用"),
                    message: l10n("宿主未注入 AlbumAPI。")
                )
            }
        }
        .task {
            if model == nil, let album = services.album {
                model = CollectionViewModel(album: album, collection: collection)
            }
            await model?.load()
        }
    }
}

/// 内容子视图：只读模型 + 调用方法（不需要 @Bindable）。
private struct CollectionContent: View {
    let model: CollectionViewModel
    let onClose: () -> Void

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: GatherMetrics.Space.m),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error = model.actionError {
                NativeBanner(text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)))
                    .padding(.horizontal, GatherMetrics.Layout.pageGutter)
                    .padding(.top, GatherMetrics.Space.m)
            }
            content
        }
    }

    private var header: some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Label(model.collection.name, systemImage: "square.stack.3d.up.fill")
                .font(GatherFont.sectionTitle)
            Text(l10n.format("%lld 张", model.items.count))
                .font(GatherFont.label)
                .foregroundStyle(GatherTheme.secondaryText)
                .monospacedDigit()
            if model.isMutating {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
            Button {
                Task { await model.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(l10n("重新载入"))
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help(l10n("返回图库"))
        }
        .padding(.horizontal, GatherMetrics.Layout.pageGutter)
        .padding(.vertical, GatherMetrics.Space.m)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.items.isEmpty {
            ProgressView(l10n("载入集合…"))
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            GatherEmptyState(
                icon: "square.stack.3d.up.slash",
                title: l10n("集合是空的"),
                message: l10n("在图库里选中照片，再通过「加入集合」放进这里。")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: GatherMetrics.Space.m) {
                    ForEach(Array(model.items.enumerated()), id: \.element.photoId) { index, item in
                        cell(item: item, index: index)
                    }
                }
                .padding(GatherMetrics.Layout.pageGutter)
            }
        }
    }

    private func cell(item: CollectionMember, index: Int) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            ZStack(alignment: .topLeading) {
                PhotoThumbnailView(
                    path: item.filepath,
                    size: 256,
                    placeholderSize: CGSize(width: 160, height: 120)
                )
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous))
                Text("\(index + 1)")
                    .font(GatherFont.label)
                    .monospacedDigit()
                    .padding(.horizontal, GatherMetrics.Space.xs)
                    .padding(.vertical, GatherMetrics.Space.xxs)
                    .background(Capsule().fill(GatherTheme.surface.opacity(0.9)))
                    .padding(GatherMetrics.Space.xs)
            }
            Text(item.filename.isEmpty ? item.photoId : item.filename)
                .font(GatherFont.label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(GatherMetrics.Space.s)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous)
                .fill(GatherTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous)
                .strokeBorder(GatherTheme.hairline, lineWidth: 1)
        )
        .draggable(item.photoId)
        .dropDestination(for: String.self) { photoIds, _ in
            guard let moved = photoIds.first else { return false }
            Task { await model.move(photoId: moved, before: item.photoId) }
            return true
        }
        .contextMenu {
            Button(l10n("上移（⌘↑）")) {
                Task { await model.moveBy(photoId: item.photoId, offset: -1) }
            }
            Button(l10n("下移（⌘↓）")) {
                Task { await model.moveBy(photoId: item.photoId, offset: 1) }
            }
            Divider()
            Button(l10n("移出集合"), role: .destructive) {
                Task { await model.remove(photoId: item.photoId) }
            }
        }
        .help(l10n("拖放调整顺序；⌘↑/⌘↓ 微调"))
    }
}

// MARK: - 跨工作区重复视图模型

@MainActor
@Observable
final class CrossWorkspaceDuplicateViewModel {
    private let duplicate: any DuplicateAPI

    private(set) var result: GlobalDuplicateScanResult?
    private(set) var isScanning = false
    var actionError: CommandError?
    /// 是否包含视觉近似（关掉只做精确 checksum，用于哈希缺失的库）。
    var includesVisual = true

    init(duplicate: any DuplicateAPI) {
        self.duplicate = duplicate
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            result = try await duplicate.globalDuplicates(
                GlobalDuplicateScanInput(includeVisual: includesVisual)
            )
            actionError = nil
        } catch is CancellationError {
            // 切页/关面板：保留上一次结果，不报错。
        } catch {
            actionError = CommandError(error)
        }
    }
}

// MARK: - 跨工作区重复视图（只读）

/// 跨工作区重复/相似：每组显示成员所在工作区、文件名、大小。
///
/// **只读**（§3.8.3）：不提供跨工作区删除；只给"在访达显示"。
struct CrossWorkspaceDuplicatesView: View {
    let onClose: () -> Void

    @Environment(\.curationServices) private var services
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var model: CrossWorkspaceDuplicateViewModel?

    var body: some View {
        Group {
            if let model {
                CrossWorkspaceDuplicatesContent(model: model, onClose: onClose)
            } else {
                GatherEmptyState(
                    icon: "doc.on.doc",
                    title: l10n("重复扫描不可用"),
                    message: l10n("宿主未注入 DuplicateAPI。")
                )
            }
        }
        .task {
            if model == nil, let duplicate = services.duplicate {
                model = CrossWorkspaceDuplicateViewModel(duplicate: duplicate)
            }
            await model?.scan()
        }
    }
}

private struct CrossWorkspaceDuplicatesContent: View {
    @Bindable var model: CrossWorkspaceDuplicateViewModel
    let onClose: () -> Void

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error = model.actionError {
                NativeBanner(text: l10n.format("扫描失败：%@", CommandErrorText.resolve(error, with: l10n)))
                    .padding(.horizontal, GatherMetrics.Layout.pageGutter)
                    .padding(.top, GatherMetrics.Space.m)
            }
            content
        }
    }

    private var header: some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Label(l10n("跨工作区重复"), systemImage: "doc.on.doc")
                .font(GatherFont.sectionTitle)
            if model.isScanning {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
            Toggle(l10n("包含视觉近似"), isOn: $model.includesVisual)
                .toggleStyle(.checkbox)
                .onChange(of: model.includesVisual) { _, _ in
                    Task { await model.scan() }
                }
            Button {
                Task { await model.scan() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning)
            .help(l10n("重新扫描"))
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help(l10n("返回图库"))
        }
        .padding(.horizontal, GatherMetrics.Layout.pageGutter)
        .padding(.vertical, GatherMetrics.Space.m)
    }

    @ViewBuilder
    private var content: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
                summary(result)
                if result.groups.isEmpty {
                    GatherEmptyState(
                        icon: "checkmark.circle",
                        title: l10n("没有跨工作区重复"),
                        message: l10n("同一张照片在多个工作区出现时会列在这里。")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
                            ForEach(result.groups) { group in
                                groupCard(group)
                            }
                        }
                        .padding(GatherMetrics.Layout.pageGutter)
                    }
                }
            }
        } else if model.isScanning {
            ProgressView(l10n("扫描中…"))
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GatherEmptyState(
                icon: "doc.on.doc",
                title: l10n("跨工作区重复"),
                message: l10n("扫描全部工作区的 checksum 与视觉哈希。")
            )
        }
    }

    private func summary(_ result: GlobalDuplicateScanResult) -> some View {
        HStack(spacing: GatherMetrics.Space.m) {
            Text(l10n.format(
                "精确 %lld 组 · 视觉 %lld 组",
                result.exactGroupCount,
                result.visualGroupCount
            ))
            .font(GatherFont.label)
            .foregroundStyle(GatherTheme.secondaryText)
            if result.missingChecksumCount > 0 {
                Text(l10n.format("%lld 张未计算 checksum", result.missingChecksumCount))
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.warningText)
            }
            if result.truncated {
                Text(l10n("结果已截断"))
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.warningText)
            }
        }
        .padding(.horizontal, GatherMetrics.Layout.pageGutter)
        .padding(.top, GatherMetrics.Space.s)
    }

    private func groupCard(_ group: GlobalDuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            HStack(spacing: GatherMetrics.Space.xs) {
                Text(group.kind == .exact ? l10n("精确重复") : l10n("视觉近似"))
                    .font(GatherFont.label)
                    .padding(.horizontal, GatherMetrics.Space.xs)
                    .padding(.vertical, GatherMetrics.Space.xxs)
                    .background(Capsule().fill(
                        group.kind == .exact
                            ? GatherTheme.info.opacity(0.18)
                            : GatherTheme.warning.opacity(0.18)
                    ))
                Text(l10n.format("%lld 个工作区", group.sessionCount))
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.secondaryText)
                Spacer(minLength: 0)
            }
            ForEach(group.members, id: \.photoId) { member in
                memberRow(member)
            }
        }
        .padding(GatherMetrics.Space.m)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous)
                .fill(GatherTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous)
                .strokeBorder(GatherTheme.hairline, lineWidth: 1)
        )
    }

    private func memberRow(_ member: GlobalDuplicateMember) -> some View {
        HStack(spacing: GatherMetrics.Space.s) {
            PhotoThumbnailView(
                path: member.filepath,
                size: 96,
                placeholderSize: CGSize(width: 48, height: 48)
            )
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous))
            VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                Text(member.sessionName.isEmpty ? member.sessionId : member.sessionName)
                    .font(GatherFont.cardTitle)
                    .lineLimit(1)
                Text(member.filename.isEmpty ? member.photoId : member.filename)
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if member.fileSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: member.fileSize, countStyle: .file))
                    .font(GatherFont.mono)
                    .foregroundStyle(GatherTheme.secondaryText)
            }
            Button(l10n("在访达显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: member.filepath)])
            }
            .buttonStyle(.link)
        }
    }
}
