// desktop/native/gather-app/Sources/GatherUI/Culling/CullingKeywordPanel.swift
// P0 / K0：检查器关键词面板（delta 草稿 → 只读预览 → 一次确认 → 写回 → 重试）。
import SwiftUI
import GatherProtocol

// MARK: - 流式 chips 布局

private struct KeywordFlowLayout: Layout {
    var spacing: CGFloat = GatherMetrics.Space.s
    var lineSpacing: CGFloat = GatherMetrics.Space.xs

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(
            width: maxWidth.isFinite ? maxWidth : max(0, x - spacing),
            height: y + lineHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - 面板

struct CullingKeywordPanel: View {
    let viewModel: CullingViewModel
    let isBusy: Bool

    private enum Sheet: String, Identifiable {
        case preview
        case confirm
        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var activeSheet: Sheet?
    @FocusState private var inputFocused: Bool

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private var disabled: Bool { isBusy || viewModel.isKeywordBusy }
    private var targetsEmpty: Bool { viewModel.keywordTargetAssets.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Button("") { inputFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            if let error = viewModel.keywordError {
                Text(CommandErrorText.resolve(error, with: l10n))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if targetsEmpty {
                Text(l10n("请先选择照片"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            } else {
                inputRow
                if inputFocused, !viewModel.keywordSuggestions.isEmpty {
                    suggestions
                }
                keywordChips
                countsRow
                actionRow
                if let result = viewModel.keywordResult {
                    resultRow(result)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: viewModel.keywordSelectionSignature) { _, _ in
            let hasDraft = !viewModel.keywordAdded.isEmpty
                || !viewModel.keywordRemoved.isEmpty
                || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasDraft {
                // 切换照片前不清草稿；旧 selection 的预览必须失效。
                inputFocused = false
                viewModel.clearKeywordPreviewForSelectionChange()
            } else {
                query = ""
                inputFocused = false
                viewModel.resetKeywordDraft()
            }
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                viewModel.clearKeywordSuggestions()
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await viewModel.loadKeywordSuggestions(prefix: trimmed)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .preview: previewSheet
            case .confirm: applyConfirmationSheet
            }
        }
    }

    // MARK: - 输入

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            if viewModel.keywordTargetCount > 500 {
                Text(l10n("一次最多修改 500 张照片，请减少选择"))
                    .gatherText(.secondary)
                    .foregroundStyle(GatherTheme.warning)
            }
            inputField
        }
    }

    private var inputField: some View {
        HStack(spacing: GatherMetrics.Space.xs) {
            TextField(l10n("添加关键词…"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .disabled(disabled || !viewModel.keywordCanEdit)
                .onSubmit { commitQuery() }
                .accessibilityLabel(l10n("添加关键词…"))
            Button {
                commitQuery()
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(disabled || query.trimmingCharacters(in: .whitespaces).isEmpty)
            .help(l10n("添加关键词"))
            .accessibilityLabel(l10n("添加关键词"))
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            ForEach(viewModel.keywordSuggestions, id: \.self) { suggestion in
                Button {
                    viewModel.addKeyword(suggestion)
                    query = ""
                    viewModel.clearKeywordSuggestions()
                    inputFocused = true
                } label: {
                    Text(suggestion)
                        .font(GatherFont.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(EdgeInsets(
                    top: GatherMetrics.Space.xxs,
                    leading: GatherMetrics.Space.xs,
                    bottom: GatherMetrics.Space.xxs,
                    trailing: GatherMetrics.Space.xs
                ))
            }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               !viewModel.keywordSuggestions.contains(where: {
                   KeywordNormalizer.fold($0) == KeywordNormalizer.fold(trimmed)
               }),
               KeywordNormalizer.normalize(trimmed) != nil {
                Button {
                    viewModel.addKeyword(trimmed)
                    query = ""
                    viewModel.clearKeywordSuggestions()
                    inputFocused = true
                } label: {
                    Label(l10n.format("创建「%@」", trimmed), systemImage: "plus")
                        .font(GatherFont.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(EdgeInsets(
                    top: GatherMetrics.Space.xxs,
                    leading: GatherMetrics.Space.xs,
                    bottom: GatherMetrics.Space.xxs,
                    trailing: GatherMetrics.Space.xs
                ))
            }
        }
        .padding(GatherMetrics.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous)
                .fill(GatherTheme.surfaceMuted)
        )
    }

    // MARK: - chips

    private var keywordChips: some View {
        Group {
            if viewModel.keywordEffectiveKeywords.isEmpty {
                Text(l10n("无关键词"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            } else {
                KeywordFlowLayout(spacing: GatherMetrics.Space.s, lineSpacing: GatherMetrics.Space.xs) {
                    ForEach(viewModel.keywordEffectiveKeywords, id: \.self) { keyword in
                        chip(keyword)
                    }
                }
            }
        }
    }

    private func chip(_ keyword: String) -> some View {
        let isAdded = viewModel.keywordIsAdded(keyword)
        let isPartial = viewModel.keywordIsPartial(keyword)
        return HStack(spacing: GatherMetrics.Space.xs) {
            Text(isPartial ? "— " + keyword : keyword)
                .font(GatherFont.secondary)
                .lineLimit(1)
                .accessibilityLabel(
                    isPartial ? l10n.format("部分照片包含关键词 %@", keyword) : keyword
                )
            Button {
                viewModel.removeKeyword(keyword)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(disabled || !viewModel.keywordCanEdit)
            .accessibilityLabel(l10n.format("移除关键词 %@", keyword))
        }
        .padding(EdgeInsets(
            top: GatherMetrics.Space.xs,
            leading: GatherMetrics.Space.s,
            bottom: GatherMetrics.Space.xs,
            trailing: GatherMetrics.Space.s
        ))
        .background(
            Capsule().fill(isAdded ? GatherTheme.accent.opacity(0.18) : GatherTheme.surfaceMuted)
        )
        .overlay(
            Capsule().strokeBorder(
                isAdded ? GatherTheme.accent.opacity(0.45) : GatherTheme.hairline,
                lineWidth: 1
            )
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - 计数 / 动作 / 结果

    private var countsRow: some View {
        Text(l10n.format(
            "已选 %lld 张 · 新增 %lld · 移除 %lld",
            viewModel.keywordTargetCount,
            viewModel.keywordAdded.count,
            viewModel.keywordRemoved.count
        ))
        .font(GatherFont.secondary)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var actionRow: some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Button(l10n("预览写回")) {
                Task {
                    await viewModel.previewKeywordWriteback()
                    if viewModel.keywordPreview != nil { activeSheet = .preview }
                }
            }
            .disabled(disabled || !viewModel.keywordCanPreview)

            Button(l10n("确认写入")) {
                activeSheet = .confirm
            }
            .disabled(disabled || !viewModel.keywordCanApply)
            .buttonStyle(.borderedProminent)
        }
    }

    private func resultRow(_ result: MetadataKeywordApplyResult) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            Text(l10n.format(
                "已写入 %lld · 失败 %lld · 跳过 %lld",
                result.result.written,
                result.result.failed,
                result.result.skipped
            ))
            .font(GatherFont.secondary)
            .foregroundStyle(result.result.failed > 0 ? GatherTheme.warning : .secondary)
            .monospacedDigit()

            if result.result.failed > 0 {
                Button(l10n("重试元数据写回")) {
                    Task { await viewModel.retryKeywordWriteback() }
                }
                .font(GatherFont.secondary)
                .disabled(disabled)
            }
        }
    }

    // MARK: - preview / confirm sheets

    private var previewSheet: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("关键词写回预览"))
                .font(GatherFont.sectionTitle)
            if let preview = viewModel.keywordPreview {
                previewContent(preview)
            } else {
                Text(l10n("无变更"))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(l10n("取消")) { activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(l10n("确认写入")) {
                    Task {
                        await viewModel.applyKeywordWriteback()
                        if viewModel.keywordError == nil { activeSheet = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(disabled || !viewModel.keywordCanApply)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 560, height: 440)
    }

    private func previewContent(_ preview: WritebackPreview) -> some View {
        let created = preview.items.filter { $0.preview?.willCreate == true }.count
        let external = preview.items.filter { $0.preview?.externalChanged == true }.count
        let blocked = preview.items.filter {
            $0.xmpStatus == "blocked" || $0.xmpStatus == "failed"
        }.count
        return VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(l10n.format(
                "共 %lld 个 XMP · %lld 张照片",
                preview.items.count,
                preview.affectedPhotos
            ))
            .font(GatherFont.bodyStrong)
            Text(l10n.format(
                "新建 %lld · 更新 %lld · 外部修改 %lld · 不可写 %lld",
                created,
                max(0, preview.items.count - created),
                external,
                blocked
            ))
            .font(GatherFont.secondary)
            .foregroundStyle(blocked > 0 ? GatherTheme.warning : .secondary)
            if blocked > 0 {
                Text(l10n("受保护或读取失败的文件不能整批写入；请逐张处理后再试。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.warning)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
                    ForEach(Array(preview.items.prefix(30).enumerated()), id: \.offset) { _, item in
                        previewRow(item)
                    }
                }
            }
        }
    }

    private func previewRow(_ item: WritebackItem) -> some View {
        let name = URL(fileURLWithPath: item.photoPath).lastPathComponent
        let before = item.preview?.before.keywords?.joined(separator: " · ") ?? "—"
        let after = item.preview?.after.keywords?.joined(separator: " · ") ?? "—"
        return VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            HStack(spacing: GatherMetrics.Space.xs) {
                Text(name)
                    .font(GatherFont.secondary.weight(.semibold))
                    .lineLimit(1)
                if item.preview?.willCreate == true {
                    Text(l10n("新建 XMP"))
                        .font(GatherFont.label)
                        .padding(EdgeInsets(
                            top: GatherMetrics.Space.xxs,
                            leading: GatherMetrics.Space.s,
                            bottom: GatherMetrics.Space.xxs,
                            trailing: GatherMetrics.Space.s
                        ))
                        .background(Capsule().fill(GatherTheme.surfaceMuted))
                }
                if item.preview?.externalChanged == true {
                    Text(l10n("检测到外部冲突"))
                        .font(GatherFont.label)
                        .foregroundStyle(GatherTheme.warning)
                }
                if item.xmpStatus == "blocked" {
                    Text(l10n("来源受保护"))
                        .font(GatherFont.label)
                        .foregroundStyle(GatherTheme.warning)
                } else if item.xmpStatus == "failed" {
                    Text(l10n("读取失败"))
                        .font(GatherFont.label)
                        .foregroundStyle(GatherTheme.warning)
                }
            }
            Text(before)
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(after)
                .font(GatherFont.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(
            top: GatherMetrics.Space.xxs,
            leading: 0,
            bottom: GatherMetrics.Space.xxs,
            trailing: 0
        ))
    }

    private var applyConfirmationSheet: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("确认写入关键词？"))
                .font(GatherFont.sectionTitle)
            Text(l10n.format(
                "将向 %lld 张照片写入关键词（新增 %lld、移除 %lld）。只修改 XMP，不修改原图；写入前会备份，可在写回记录中恢复。",
                viewModel.keywordTargetCount,
                viewModel.keywordAdded.count,
                viewModel.keywordRemoved.count
            ))
            .font(GatherFont.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(l10n("取消")) { activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(l10n("确认写入")) {
                    activeSheet = nil
                    Task { await viewModel.applyKeywordWriteback() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 440)
    }

    private func commitQuery() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        viewModel.addKeyword(value)
        query = ""
        viewModel.clearKeywordSuggestions()
        inputFocused = true
    }
}
