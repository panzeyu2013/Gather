// desktop/native/gather-app/Sources/GatherUI/Library/LibraryView+Content.swift
// Cut 4 / 4c-2j：从 LibraryView.swift 移出状态行与内容区（原 655-786 行）。纯搬移：
// 加载/失败/空态/网格/分页与各出口逐字未动。
import SwiftUI
import GatherProtocol

extension LibraryView {

    // MARK: 状态行（TS toolbar：loading/totalCount + range）

    var statusBar: some View {
        HStack(spacing: 12) {
            if viewModel.phase == .loading {
                Text(l10n("加载中…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(l10n.format("共 %lld 张逻辑照片", viewModel.total))
                    .font(.callout)
                Text(l10n.resolve(viewModel.rangeText))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if viewModel.isFetching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    // MARK: 内容（TS 卡片网格 + 分页）

    @ViewBuilder
    var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView(l10n("加载照片中…"))
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            loadFailureState(error)
        case .loaded:
            if viewModel.photos.isEmpty {
                emptyState
            } else {
                photoGrid
            }
        }
    }

    /// 失败出口：系统空态 + 重试（不再只渲染一行红字）。
    /// 4a-3b-2a：错误以 `CommandError` 传入，文案在渲染期按当前语言解析。
    private func loadFailureState(_ error: CommandError) -> some View {
        ContentUnavailableView {
            Label(l10n("全局图库"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(l10n.format("加载照片失败：%@", CommandErrorText.resolve(error, with: l10n)))
        } actions: {
            Button(l10n("重试")) {
                Task { await viewModel.load() }
            }
            .gatherPrimaryActionButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 无结果态：系统 ContentUnavailableView + 「清除筛选」出口。
    private var emptyState: some View {
        // E 报告：空库（没有任何筛选条件）时旧实现只给一个**被禁用**的
        //「清除筛选」——用户面对死路。这里分两种语义：
        //   · 有筛选 → 清除筛选（可用）；
        //   · 无筛选 → 图库确实为空，给「导入文件夹」出口。
        ContentUnavailableView {
            Label(
                viewModel.activeFilterCount == 0
                    ? l10n("图库还没有照片")
                    : l10n("没有符合条件的照片"),
                systemImage: viewModel.activeFilterCount == 0
                    ? "photo.on.rectangle.angled"
                    : "magnifyingglass"
            )
        } description: {
            Text(viewModel.activeFilterCount == 0
                ? l10n("导入一个文件夹后，这里会汇总所有工作区的照片。")
                : l10n("调整或清除筛选条件以查看全部照片"))
        } actions: {
            if viewModel.activeFilterCount == 0 {
                Button(l10n("导入文件夹")) {
                    NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
                }
                .gatherPrimaryActionButton()
            } else {
                Button(l10n("清除筛选")) {
                    viewModel.clearFilters()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var photoGrid: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.photos, id: \.assetId) { photo in
                        LibraryCardView(
                            photo: photo,
                            onOpen: { onOpenPhoto(photo.sessionId, photo.photoId) },
                            onOpenSession: { onOpenSession(photo.sessionId) }
                        )
                    }
                }
                .padding(24)
            }
            Divider()
            pagination
        }
    }

    private var pagination: some View {
        HStack(spacing: 12) {
            Button(l10n("上一页")) {
                viewModel.prevPage()
            }
            .disabled(viewModel.page == 0)
            Text("\(viewModel.page + 1) / \(max(1, Int(ceil(Double(viewModel.total) / Double(LibraryViewModel.pageSize)))))")
                .font(.callout)
                .monospacedDigit()
            Button(l10n("下一页")) {
                viewModel.nextPage()
            }
            .disabled(!viewModel.hasNextPage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
}
