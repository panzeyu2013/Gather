// desktop/native/gather-app/Sources/GatherUI/Metadata/KeywordLibrarySheet.swift
// Wave2 task-13：关键词库（受控词表）管理面板。
//
// 能力：
// - 树形浏览（按层级缩进 + 展开/折叠），每行显示使用次数与同义词标记；
// - 新建根/子级、改名（含子孙级联，服务端事务化）、合并到已有路径、编辑同义词、
//   删除（默认只删空叶子；"级联删除"需明确勾选）；
// - 全部写操作走 MetadataAPI 的 Confirmed<T> 入口，UI 只在真实确认弹窗里构造
//   Confirmed（D-011）；
// - 只改词库索引，不写 XMP：提示文案写清"下次写回才进 XMP"。
//
// 错误呈现：仓储业务错误统一为 GatherError(.METADATA_KEYWORDS_INVALID)，
// params["reason"] 由服务层给出中文原因；本面板按本地文案路径展示（不吞原因）。
import SwiftUI
import GatherProtocol

struct KeywordLibrarySheet: View {
    let api: any MetadataAPI

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var nodes: [KeywordLibraryNode] = []
    @State private var expanded: Set<String> = []
    @State private var selectedPath: String?
    @State private var errorText: String?
    @State private var isBusy = false
    @State private var isLoading = true

    @State private var newPath = ""
    @State private var renameText = ""
    @State private var mergeTarget = ""
    @State private var synonymsText = ""
    @State private var cascadeDelete = false
    @State private var pendingDelete = false

    private var selectedNode: KeywordLibraryNode? {
        nodes.first { $0.path == selectedPath }
    }

    /// 可见行：父级链全部展开才显示（折叠父级 = 隐藏整棵子树）。
    private var visibleNodes: [KeywordLibraryNode] {
        nodes.filter { node in
            var ancestor = node.parentPath
            while let current = ancestor {
                if !expanded.contains(current) { return false }
                ancestor = nodes.first { $0.path == current }?.parentPath
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(l10n("关键词库"))
                    .font(GatherFont.cardTitle)
                Spacer()
                Button(l10n("刷新")) { Task { await reload() } }
                    .gatherButton(.tertiary, size: .small)
                    .disabled(isBusy)
                Button(l10n("关闭")) { dismiss() }
                    .gatherButton(.secondary)
                    .disabled(isBusy)
            }
            Text(l10n("词库只影响补全与检索；改名/合并不会立刻改写 XMP，下次关键词写回才写入 dc:subject 与 lr:hierarchicalSubject。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorText {
                Text(errorText)
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: GatherMetrics.Space.m) {
                treePane
                editorPane
            }
            .frame(maxHeight: 520)

            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 760)
        .task { await reload() }
        .confirmationDialog(
            l10n("删除这个关键词？"),
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button(cascadeDelete ? l10n("级联删除（含子孙与照片关键词）") : l10n("删除"),
                   role: .destructive) {
                Task { await deleteSelected() }
            }
            Button(l10n("取消"), role: .cancel) {}
        } message: {
            Text(cascadeDelete
                 ? l10n("将删除该词及其全部子孙，并从照片关键词索引里移除。XMP 不会自动改写。")
                 : l10n("只有无照片、无子级、无同义词的关键词可以删除。"))
        }
    }

    // MARK: - 树

    private var treePane: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            HStack {
                Text(l10n("词库树"))
                    .font(GatherFont.label)
                Spacer()
                Text(l10n.format("%lld 个关键词", nodes.count))
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if nodes.isEmpty {
                Text(l10n("词库为空：可先新建一个根关键词，或在挑片页写回关键词后自动生成。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(GatherMetrics.Space.s)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                        ForEach(visibleNodes) { node in
                            nodeRow(node)
                        }
                    }
                }
                .frame(width: 360)
            }
        }
        .frame(width: 380, alignment: .leading)
    }

    private func nodeRow(_ node: KeywordLibraryNode) -> some View {
        let hasChildren = KeywordLibraryTree.hasChildren(of: node.path, in: nodes)
        let isSelected = node.path == selectedPath
        return HStack(spacing: GatherMetrics.Space.xs) {
            Button {
                if expanded.contains(node.path) {
                    expanded.remove(node.path)
                } else {
                    expanded.insert(node.path)
                }
            } label: {
                Image(systemName: expanded.contains(node.path)
                      ? "chevron.down" : "chevron.right")
                    .font(GatherFont.label)
                    .opacity(hasChildren ? 1 : 0)
            }
            .buttonStyle(.borderless)
            .disabled(!hasChildren)
            .accessibilityLabel(l10n("展开或折叠子级"))

            Text(node.name)
                .font(GatherFont.secondary)
                .lineLimit(1)
            if !node.synonyms.isEmpty {
                Image(systemName: "text.badge.plus")
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(l10n("有同义词"))
            }
            Spacer(minLength: 0)
            Text("\(node.usageCount)")
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, GatherMetrics.Space.xxs)
        .padding(.leading, CGFloat(node.depth - 1) * GatherMetrics.Space.l)
        .padding(.horizontal, GatherMetrics.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous)
                .fill(isSelected ? GatherTheme.accent.opacity(0.16) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { select(node) }
    }

    // MARK: - 编辑器

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(selectedNode?.path ?? l10n("未选择关键词"))
                .font(GatherFont.bodyStrong)
                .lineLimit(2)
            if let node = selectedNode {
                Text(l10n.format("使用次数 %lld · 深度 %lld · 同义词 %lld",
                                 node.usageCount, node.depth, node.synonyms.count))
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
            }

            Group {
                Text(l10n("新建"))
                    .font(GatherFont.label)
                HStack {
                    TextField(selectedNode == nil ? l10n("根关键词名称，或 A|B 层级路径")
                              : l10n("子级名称"), text: $newPath)
                        .textFieldStyle(.roundedBorder)
                    Button(l10n("新建")) { Task { await createKeyword() } }
                        .gatherButton(.secondary, size: .small)
                        .disabled(isBusy || newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Group {
                Text(l10n("改名"))
                    .font(GatherFont.label)
                HStack {
                    TextField(l10n("新的关键词名称"), text: $renameText)
                        .textFieldStyle(.roundedBorder)
                    Button(l10n("改名")) { Task { await renameSelected() } }
                        .gatherButton(.secondary, size: .small)
                        .disabled(isBusy || selectedPath == nil
                                  || renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Group {
                Text(l10n("合并到（目标路径，合并后源关键词删除）"))
                    .font(GatherFont.label)
                HStack {
                    TextField(l10n("既有目标路径，如 Travel|Paris"), text: $mergeTarget)
                        .textFieldStyle(.roundedBorder)
                    Button(l10n("合并")) { Task { await mergeSelected() } }
                        .gatherButton(.secondary, size: .small)
                        .disabled(isBusy || selectedPath == nil
                                  || mergeTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                Text(l10n("同义词（逗号分隔；参与补全与检索，不写 XMP）"))
                    .font(GatherFont.label)
                TextField(l10n("例如：旅, trip, travel"), text: $synonymsText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(l10n("保存同义词")) { Task { await saveSynonyms() } }
                        .gatherButton(.secondary, size: .small)
                        .disabled(isBusy || selectedPath == nil)
                }
            }

            Divider()

            HStack(spacing: GatherMetrics.Space.s) {
                Toggle(l10n("允许级联删除"), isOn: $cascadeDelete)
                    .toggleStyle(.checkbox)
                    .font(GatherFont.label)
                Spacer()
                Button(l10n("删除…")) { pendingDelete = true }
                    .gatherButton(.destructive, size: .small)
                    .disabled(isBusy || selectedPath == nil)
            }
        }
        .padding(GatherMetrics.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 动作

    private func select(_ node: KeywordLibraryNode) {
        selectedPath = node.path
        renameText = node.name
        mergeTarget = ""
        synonymsText = node.synonyms.joined(separator: ", ")
        if !node.synonyms.isEmpty { expanded.insert(node.path) }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            nodes = try await api.keywordLibrary(try KeywordLibraryQuery())
            if let selectedPath, !nodes.contains(where: { $0.path == selectedPath }) {
                self.selectedPath = nil
            }
            errorText = nil
        } catch {
            present(error)
        }
    }

    private func createKeyword() async {
        guard !isBusy else { return }
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fullPath: String
        if let selectedNode {
            fullPath = trimmed.contains("|") ? trimmed : selectedNode.path + "|" + trimmed
        } else {
            fullPath = trimmed
        }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await api.createKeyword(Confirmed(
                try KeywordCreateInput(path: fullPath), source: .userDialog))
            newPath = ""
            errorText = nil
            GatherEventCenter.postDomainChange(.metadata, sessionId: nil)
            await reload()
        } catch {
            present(error)
        }
    }

    private func renameSelected() async {
        guard let node = selectedNode, !isBusy else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parent = node.parentPath.map { $0 + "|" } ?? ""
        let newFull = parent + trimmed
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await api.renameKeyword(Confirmed(
                try KeywordRenameInput(from: node.path, to: newFull), source: .userDialog))
            selectedPath = newFull
            renameText = trimmed
            errorText = nil
            GatherEventCenter.postDomainChange(.metadata, sessionId: nil)
            await reload()
        } catch {
            present(error)
        }
    }

    private func mergeSelected() async {
        guard let node = selectedNode, !isBusy else { return }
        let target = mergeTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await api.mergeKeywords(Confirmed(
                try KeywordMergeInput(source: node.path, target: target), source: .userDialog))
            selectedPath = target
            mergeTarget = ""
            errorText = nil
            GatherEventCenter.postDomainChange(.metadata, sessionId: nil)
            await reload()
        } catch {
            present(error)
        }
    }

    private func saveSynonyms() async {
        guard let node = selectedNode, !isBusy else { return }
        let synonyms = synonymsText
            .split(whereSeparator: { $0 == "," || $0 == "、" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await api.setKeywordSynonyms(Confirmed(
                try KeywordSynonymsInput(path: node.path, synonyms: synonyms),
                source: .userDialog))
            errorText = nil
            GatherEventCenter.postDomainChange(.metadata, sessionId: nil)
            await reload()
        } catch {
            present(error)
        }
    }

    private func deleteSelected() async {
        guard let node = selectedNode, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await api.deleteKeyword(Confirmed(
                try KeywordDeleteInput(path: node.path, cascade: cascadeDelete),
                source: .userDialog))
            selectedPath = nil
            errorText = nil
            GatherEventCenter.postDomainChange(.metadata, sessionId: nil)
            await reload()
        } catch {
            present(error)
        }
    }

    private func present(_ error: any Error) {
        if let gather = error as? GatherError, gather.code == .METADATA_KEYWORDS_INVALID {
            let reason = gather.params["reason"] ?? ""
            errorText = CommandErrorText.resolve(
                CommandError.localized("词库操作失败：%@", params: [reason]), with: l10n)
        } else {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }
}
