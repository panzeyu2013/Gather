// desktop/native/gather-app/Sources/GatherUI/Library/FolderTreePanel.swift
// Wave5 batch4（task-18 / F1）：资料库左侧的物理文件夹树（只读浏览 + directory 筛选）。
//
// 边界（与 05/30 号复核报告一致）：
// - **浏览即读**：只列目录、不 stat 图片、不在树上算张数（避免整盘 IO）；
// - 树只做导航：点击目录 = 在资料库既有筛选上加 directory 前缀条件（复用
//   LibraryFilterState.directory → buildLibraryCriteria，不新增后端）；
// - 懒加载：展开某目录时才 FileManager 列它的一层子目录（隐藏目录/符号链接跳过）；
// - 根 = 当前筛选工作区的 sourcePath；没有选工作区时给空态提示；
// - Wave5 batch8（task-32）：树尾追加**外部位置**（已挂载的其它卷，F1 修法的
//   「工作区 sourcePath 为根 + 外部盘」）。外部目录才有「摄取到此工作区」动作：
//   工作区内的目录已被本工作区扫描覆盖，重新摄取只会重复登记。
// 插桩点：LibraryCurationHost 的左栏（“文件夹 / 集合”两个页签），见 LibraryView+Content。
import SwiftUI
import AppKit
import Observation
import GatherProtocol

// MARK: - 数据模型（纯值）

/// 树上的一个目录节点（path = 绝对路径，name = 最后一段）。
struct FolderTreeItem: Identifiable, Equatable, Sendable {
    let path: String
    let name: String

    var id: String { path }
}

/// 目录加载失败原因（渲染期再映射成当前语言的文案）。
enum FolderTreeError: Error, Equatable, Sendable {
    case notFound
    case notDirectory
    case unreadable
}

/// 目录筛选前缀的规则（与后端 directory startsWith 条件同一口径）。
///
/// 末尾补 "/" 是必须的：后端 SQL 是 filepath LIKE prefix || '%'，用
/// "/a/b" 会把 "/a/bc/..." 的兄弟目录也算进来；"/a/b/" 才是"该目录内"。
enum DirectoryFilterRule {
    /// 去首尾空白与末尾多余的 "/"（保留根目录的单个 "/"）。
    static func normalizedPath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// 目录 → 筛选前缀（绝对路径 + 末尾 "/"；空路径返回空串）。
    static func prefix(for path: String) -> String {
        let normalized = normalizedPath(path)
        guard !normalized.isEmpty else { return "" }
        return normalized + "/"
    }

    /// 筛选值 → 目录路径（空/纯空白 = 未筛选）。兼容用户手填无尾斜杠的前缀。
    static func normalizedFilterPath(_ prefix: String) -> String? {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = normalizedPath(trimmed)
        return normalized.isEmpty ? nil : normalized
    }

    /// 该目录是否是当前筛选目标（尾斜杠/空白差异视为同一目录）。
    static func isSelected(path: String, filterPrefix: String) -> Bool {
        guard let selected = normalizedFilterPath(filterPrefix) else { return false }
        return selected == normalizedPath(path)
    }

    /// 面包屑：根下的相对路径（"DCIM / 100CANON"）；不在根内/无根时显示绝对路径。
    static func breadcrumb(root: String?, filterPrefix: String) -> String? {
        guard let selected = normalizedFilterPath(filterPrefix) else { return nil }
        guard let root, !root.isEmpty else { return selected }
        let normalizedRoot = normalizedPath(root)
        let rootPrefix = prefix(for: normalizedRoot)
        if selected == normalizedRoot {
            let leaf = (selected as NSString).lastPathComponent
            return leaf.isEmpty ? selected : leaf
        }
        guard selected.hasPrefix(rootPrefix) else { return selected }
        let relative = String(selected.dropFirst(rootPrefix.count))
        return relative.isEmpty ? selected : relative.replacingOccurrences(of: "/", with: " / ")
    }
}

// MARK: - 目录枚举（纯函数；FolderTreeTests 直接驱动）

enum FolderTreeLoader {
    /// 根节点：必须存在且是目录（不存在 = notFound；是文件 = notDirectory）。
    static func rootEntry(
        _ path: String, fileManager: FileManager = .default
    ) throws -> FolderTreeItem {
        let normalized = DirectoryFilterRule.normalizedPath(path)
        guard !normalized.isEmpty else { throw FolderTreeError.notFound }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory) else {
            throw FolderTreeError.notFound
        }
        guard isDirectory.boolValue else { throw FolderTreeError.notDirectory }
        let leaf = (normalized as NSString).lastPathComponent
        return FolderTreeItem(path: normalized, name: leaf.isEmpty ? normalized : leaf)
    }

    /// 列一层子目录：只要目录（文件/隐藏项/符号链接跳过），按 Finder 习惯排序。
    static func childDirectories(
        of path: String, fileManager: FileManager = .default
    ) throws -> [FolderTreeItem] {
        let url = URL(fileURLWithPath: DirectoryFilterRule.normalizedPath(path))
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw FolderTreeError.unreadable
        }
        var entries: [FolderTreeItem] = []
        for child in children {
            let values: URLResourceValues
            do {
                values = try child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                continue
            }
            // 只收真实目录：符号链接可能成环（照片盘上的软链目录），不跟。
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let name = child.lastPathComponent
            guard !name.isEmpty, !name.hasPrefix(".") else { continue }
            entries.append(FolderTreeItem(
                path: child.standardizedFileURL.path, name: name))
        }
        return entries.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 已挂载的其它卷（外部位置）：卷根本身不摄取、工作区所在卷不重复列出。
    ///
    /// 只保留「不在工作区 sourcePath 内、且不包含工作区根」的卷：从工作区所在盘
    /// 的卷根摄取只会命中同一批文件的去重，属于误操作面；外部盘才是 F1 的目标。
    static func mountedExternalRoots(
        workspaceRoot: String?, fileManager: FileManager = .default
    ) -> [FolderTreeItem] {
        guard let workspaceRoot, !workspaceRoot.isEmpty else { return [] }
        let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]) ?? []
        let candidates = urls.map { url in
            FolderTreeItem(path: url.path, name: url.lastPathComponent)
        }
        return selectExternalRoots(candidates: candidates, workspaceRoot: workspaceRoot)
    }

    /// 纯筛选（测试直接驱动）：候选卷 → 外部根列表。
    static func selectExternalRoots(
        candidates: [FolderTreeItem], workspaceRoot: String?
    ) -> [FolderTreeItem] {
        guard let workspaceRoot else { return [] }
        let root = DirectoryFilterRule.normalizedPath(workspaceRoot)
        guard !root.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [FolderTreeItem] = []
        for candidate in candidates {
            let path = DirectoryFilterRule.normalizedPath(candidate.path)
            // 卷根 "/" 是系统盘、不是外部位置；工作区所在卷（含工作区根）也不列。
            guard !path.isEmpty, path != "/", path != root else { continue }
            guard !root.hasPrefix(path + "/") else { continue }
            guard seen.insert(path).inserted else { continue }
            let name = candidate.name.isEmpty
                ? (path as NSString).lastPathComponent
                : candidate.name
            result.append(FolderTreeItem(path: path, name: name))
        }
        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - 懒加载树模型

/// 一个可见行（把已展开的树拍平成 List 行，避免递归 View 类型）。
struct FolderTreeRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case empty
        case unreadable
    }

    let path: String
    let name: String
    let depth: Int
    let kind: Kind

    /// 只有真实目录行才提供「用此目录新建工作区…」：空目录占位/不可读占位
    /// 没有可用的绝对路径，右键菜单里也不该出现该动作。
    var canCreateWorkspace: Bool { kind == .directory }

    /// 是否提供「摄取到此工作区…」（Wave5 batch8 / task-32）。
    ///
    /// 只有「工作区之外的真实目录」才需要摄取到该工作区：
    /// - 未选工作区 / 空/不可读占位行 → false；
    /// - 树根（depth 0）→ false：目录 = 工作区根（或卷根）不摄取，避免把工作区
    ///   重新摄取到自己；
    /// - 工作区 sourcePath 内的目录 → false：已在当前工作区扫描范围内，再摄取只会
    ///   命中全库去重（默认 skip）而重复登记；
    /// - 外部挂载卷下的目录（不在 sourcePath 内）→ true。
    func canIngestToWorkspace(workspaceRoot: String?) -> Bool {
        guard kind == .directory, depth > 0, let workspaceRoot else { return false }
        let root = DirectoryFilterRule.normalizedPath(workspaceRoot)
        let folder = DirectoryFilterRule.normalizedPath(path)
        guard !root.isEmpty, !folder.isEmpty, folder != root else { return false }
        return !folder.hasPrefix(root + "/")
    }

    var id: String {
        switch kind {
        case .directory: return "dir:" + path
        case .empty: return "empty:" + path
        case .unreadable: return "error:" + path
        }
    }
}

/// 物理目录树的懒加载状态：setRoot 读根一层；展开目录时才读该层。
@MainActor
@Observable
final class FolderTreeModel {
    private(set) var rootPath: String?
    private(set) var root: FolderTreeItem?
    private(set) var rootError: FolderTreeError?
    private(set) var expandedPaths: Set<String> = []
    private(set) var failedPaths: Set<String> = []

    private var childrenByPath: [String: [FolderTreeItem]] = [:]
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// 换根（nil/空 = 没有可浏览的工作区根）；根变化才重置状态。
    func setRoot(_ path: String?) {
        let normalized: String?
        if let path {
            let candidate = DirectoryFilterRule.normalizedPath(path)
            normalized = candidate.isEmpty ? nil : candidate
        } else {
            normalized = nil
        }
        guard normalized != rootPath else { return }
        rootPath = normalized
        reload()
    }

    /// 重新读取根与根一层（头部刷新按钮）。
    func reload() {
        root = nil
        rootError = nil
        expandedPaths = []
        failedPaths = []
        childrenByPath = [:]
        guard let rootPath else { return }
        do {
            let entry = try FolderTreeLoader.rootEntry(rootPath, fileManager: fileManager)
            root = entry
            expandedPaths.insert(entry.path)
            do {
                childrenByPath[entry.path] = try FolderTreeLoader.childDirectories(
                    of: entry.path, fileManager: fileManager)
            } catch {
                // 根存在但列不出：按不可读空态处理（有重试出口）。
                rootError = .unreadable
            }
        } catch let error as FolderTreeError {
            rootError = error
        } catch {
            rootError = .unreadable
        }
    }

    func isExpanded(_ path: String) -> Bool {
        expandedPaths.contains(path)
    }

    func children(of path: String) -> [FolderTreeItem] {
        childrenByPath[path] ?? []
    }

    func toggleExpansion(_ path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
            loadChildrenIfNeeded(path)
        }
    }

    private func loadChildrenIfNeeded(_ path: String) {
        guard childrenByPath[path] == nil, !failedPaths.contains(path) else { return }
        do {
            childrenByPath[path] = try FolderTreeLoader.childDirectories(
                of: path, fileManager: fileManager)
        } catch {
            failedPaths.insert(path)
        }
    }

    /// 拍平当前可见树（根 + 已展开层的目录 + 空/不可读占位行）。
    func visibleRows() -> [FolderTreeRow] {
        guard let root else { return [] }
        var rows: [FolderTreeRow] = [
            FolderTreeRow(path: root.path, name: root.name, depth: 0, kind: .directory),
        ]
        appendChildren(of: root.path, depth: 1, into: &rows)
        return rows
    }

    private func appendChildren(
        of path: String, depth: Int, into rows: inout [FolderTreeRow]
    ) {
        guard expandedPaths.contains(path) else { return }
        if failedPaths.contains(path) {
            rows.append(FolderTreeRow(path: path, name: "", depth: depth, kind: .unreadable))
            return
        }
        guard let children = childrenByPath[path] else { return }
        if children.isEmpty {
            rows.append(FolderTreeRow(path: path, name: "", depth: depth, kind: .empty))
            return
        }
        for child in children {
            rows.append(FolderTreeRow(
                path: child.path, name: child.name, depth: depth, kind: .directory))
            appendChildren(of: child.path, depth: depth + 1, into: &rows)
        }
    }
}

// MARK: - 面板

/// 资料库左侧的文件夹树面板。
///
/// 依赖全部经参数注入（rootPath / 当前 directory 筛选 / 选择回调），不直接持有
/// LibraryViewModel：面板只负责浏览与触发筛选，筛选状态仍由 VM 单一持有。
struct FolderTreePanel: View {
    let rootPath: String?
    let rootTitle: String?
    let selectedDirectoryPrefix: String
    let onSelectDirectory: (String) -> Void
    let onClearDirectory: () -> Void
    /// 右键「用此目录新建工作区…」：传当前目录绝对路径。默认 no-op，便于
    /// 预览/独立测试；生产由 LibraryView ← RootView 注入（切工作台 + 预填目录）。
    let onCreateWorkspace: @MainActor (String) -> Void
    /// 右键「摄取到此工作区…」：传当前目录绝对路径（仅外部位置的真实目录行）。
    /// 默认 no-op；确认弹窗在 LibraryView（本面板只负责发起）。
    let onIngestFolder: @MainActor (String) -> Void

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    @State private var model = FolderTreeModel()
    /// 树尾「外部位置」的卷根（挂载卷枚举，刷新按钮/换根时更新）。
    @State private var externalRootPaths: [String] = []

    init(
        rootPath: String?,
        rootTitle: String?,
        selectedDirectoryPrefix: String,
        onSelectDirectory: @escaping (String) -> Void,
        onClearDirectory: @escaping () -> Void,
        onCreateWorkspace: @escaping @MainActor (String) -> Void = { _ in },
        onIngestFolder: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.rootPath = rootPath
        self.rootTitle = rootTitle
        self.selectedDirectoryPrefix = selectedDirectoryPrefix
        self.onSelectDirectory = onSelectDirectory
        self.onClearDirectory = onClearDirectory
        self.onCreateWorkspace = onCreateWorkspace
        self.onIngestFolder = onIngestFolder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            header
            breadcrumb
            content
            Spacer(minLength: 0)
        }
        .padding(GatherMetrics.Space.m)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(GatherTheme.surfaceMuted)
        .task(id: rootPath) { reloadTree(forceReload: false) }
    }

    /// 重读工作区根 + 重新枚举外部位置（换根/手动刷新/根错误重试共用）。
    ///
    /// forceReload = true 时即使根没变也强制重读一层（刷新按钮/错误重试）；
    /// 换根路径由 setRoot 自己读取（force 为 false 避免重复扫描）。
    private func reloadTree(forceReload: Bool) {
        model.setRoot(rootPath)
        if forceReload {
            model.reload()
        }
        externalRootPaths = rootPath == nil
            ? []
            : FolderTreeLoader.mountedExternalRoots(workspaceRoot: rootPath).map(\.path)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
            HStack(spacing: GatherMetrics.Space.xs) {
                Label(l10n("文件夹"), systemImage: "folder")
                    .font(GatherFont.eyebrow)
                    .foregroundStyle(GatherTheme.secondaryText)
                Spacer(minLength: 0)
                Button { reloadTree(forceReload: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(GatherFont.label)
                        .foregroundStyle(GatherTheme.secondaryText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n("刷新目录树"))
                .accessibilityLabel(l10n("刷新目录树"))
                .disabled(rootPath == nil)
            }
            if let rootTitle, !rootTitle.isEmpty {
                Text(rootTitle)
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rootPath ?? "")
            }
        }
    }

    @ViewBuilder
    private var breadcrumb: some View {
        if let text = DirectoryFilterRule.breadcrumb(
            root: rootPath, filterPrefix: selectedDirectoryPrefix) {
            HStack(spacing: GatherMetrics.Space.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GatherTheme.accent)
                Text(text)
                    .font(GatherFont.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(selectedDirectoryPrefix)
                Spacer(minLength: 0)
                Button { onClearDirectory() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(GatherFont.labelRegular)
                        .foregroundStyle(GatherTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(l10n("清除目录筛选"))
                .accessibilityLabel(l10n("清除目录筛选"))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if rootPath == nil {
            Text(l10n("选择一个工作区后可按目录浏览"))
                .font(GatherFont.labelRegular)
                .foregroundStyle(GatherTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else if let rootError = model.rootError {
            VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
                Text(errorText(rootError))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(l10n("重试")) { reloadTree(forceReload: true) }
                    .gatherButton(.secondary, size: .small)
            }
        } else if model.root != nil {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                    ForEach(model.visibleRows()) { row in
                        FolderTreeRowView(
                            row: row,
                            model: model,
                            selectedDirectoryPrefix: selectedDirectoryPrefix,
                            onSelect: onSelectDirectory,
                            onCreateWorkspace: onCreateWorkspace,
                            onIngestFolder: onIngestFolder,
                            workspaceRootPath: rootPath,
                            isExternalRoot: false)
                    }
                    if !externalRootPaths.isEmpty {
                        Divider()
                            .padding(.vertical, GatherMetrics.Space.xs)
                        Label(l10n("外部位置"), systemImage: "externaldrive")
                            .font(GatherFont.eyebrow)
                            .foregroundStyle(GatherTheme.secondaryText)
                        ForEach(externalRootPaths, id: \.self) { path in
                            FolderTreeExternalRootView(
                                rootPath: path,
                                workspaceRootPath: rootPath,
                                selectedDirectoryPrefix: selectedDirectoryPrefix,
                                onSelect: onSelectDirectory,
                                onCreateWorkspace: onCreateWorkspace,
                                onIngestFolder: onIngestFolder)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } else {
            // setRoot 的同步读取只占一帧；给个进度指示，避免面板空白闪一下。
            ProgressView()
                .controlSize(.small)
        }
    }

    private func errorText(_ error: FolderTreeError) -> String {
        switch error {
        case .notFound, .notDirectory, .unreadable:
            return l10n("无法读取该目录")
        }
    }
}

// MARK: - 行

private struct FolderTreeRowView: View {
    let row: FolderTreeRow
    let model: FolderTreeModel
    let selectedDirectoryPrefix: String
    let onSelect: (String) -> Void
    let onCreateWorkspace: @MainActor (String) -> Void
    let onIngestFolder: @MainActor (String) -> Void
    /// 当前工作区 sourcePath（判断「摄取到此工作区」是否可用）；nil = 未选工作区。
    let workspaceRootPath: String?
    /// 外部位置的卷根行：用磁盘图标区分，不当作工作区内的目录。
    let isExternalRoot: Bool

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private var isSelected: Bool {
        row.kind == .directory
            && DirectoryFilterRule.isSelected(
                path: row.path, filterPrefix: selectedDirectoryPrefix)
    }

    var body: some View {
        HStack(spacing: GatherMetrics.Space.xs) {
            switch row.kind {
            case .directory:
                Button { model.toggleExpansion(row.path) } label: {
                    Image(systemName: model.isExpanded(row.path)
                        ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(GatherTheme.secondaryText)
                        .frame(width: 12, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isExpanded(row.path)
                    ? l10n("收起目录") : l10n("展开目录"))
                Image(systemName: isExternalRoot ? "externaldrive" : "folder")
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(isSelected ? GatherTheme.accent : GatherTheme.secondaryText)
                Text(row.name)
                    .font(GatherFont.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(row.path) }
                    .help(row.path)
                Spacer(minLength: 0)
            case .empty:
                Text(l10n("空文件夹"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
                Spacer(minLength: 0)
            case .unreadable:
                Text(l10n("无法读取此目录"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.errorText)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 10 + 2)
        .padding(.vertical, 1)
        .background(selectionHighlight)
        .contentShape(Rectangle())
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var selectionHighlight: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(GatherTheme.accent.opacity(0.16))
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if row.kind == .directory {
            if row.canIngestToWorkspace(workspaceRoot: workspaceRootPath) {
                Button(l10n("摄取到此工作区…")) {
                    onIngestFolder(row.path)
                }
                Divider()
            }
            Button(l10n("用此目录新建工作区…")) {
                onCreateWorkspace(row.path)
            }
            Divider()
            Button(l10n("在 Finder 中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: row.path)])
            }
            Button(l10n("复制目录路径")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(row.path, forType: .string)
                GatherToastCenter.shared.show(
                    type: .info, message: l10n("已复制目录路径"))
            }
        }
    }
}

// MARK: - 外部位置（挂载卷）

/// 外部位置的一棵懒加载树：每个挂载卷独立 model（卸载/不可读时整段退化为提示）。
///
/// 外部目录是唯一可「摄取到此工作区」的目录：工作区 sourcePath 内的目录已被
/// 本工作区扫描覆盖，重新摄取只会命中库内去重。行视图与工作区树共用，
/// 卷根行用 externaldrive 图标区分。
private struct FolderTreeExternalRootView: View {
    let rootPath: String
    let workspaceRootPath: String?
    let selectedDirectoryPrefix: String
    let onSelect: (String) -> Void
    let onCreateWorkspace: @MainActor (String) -> Void
    let onIngestFolder: @MainActor (String) -> Void

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    @State private var model = FolderTreeModel()

    var body: some View {
        Group {
            if model.rootError != nil {
                Text(l10n("无法读取该目录"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.errorText)
            } else {
                ForEach(model.visibleRows()) { row in
                    FolderTreeRowView(
                        row: row,
                        model: model,
                        selectedDirectoryPrefix: selectedDirectoryPrefix,
                        onSelect: onSelect,
                        onCreateWorkspace: onCreateWorkspace,
                        onIngestFolder: onIngestFolder,
                        workspaceRootPath: workspaceRootPath,
                        isExternalRoot: row.depth == 0)
                }
            }
        }
        .task(id: rootPath) { model.setRoot(rootPath) }
    }
}
