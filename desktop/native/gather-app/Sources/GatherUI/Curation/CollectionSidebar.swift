// desktop/native/gather-app/Sources/GatherUI/Curation/CollectionSidebar.swift
// P1 下一波 §3.8.1 / §3.8.3：图库侧栏的策展入口（集合 + 跨工作区重复）。
//
// 为什么用环境端口而不是直接持有 AppServices：GatherUI 只依赖 GatherProtocol
// （layering 门禁），AlbumAPI / DuplicateAPI 都在协议层，因此侧栏只声明
// "我需要这两个域的能力"，由宿主在壳层注入一次：
//
//     .environment(\.curationServices, CurationServices(
//         album: dependencies.album,
//         duplicate: dependencies.duplicate))
//
// 预览分析（直方图/合焦/AF）不走这里：它由宿主在启动时注册进
// PreviewAnalysisRegistry（见 Culling/ViewerOverlays），UI 只读注册表——
// 这样 GatherUI 不需要 import GatherAnalysis 就能拿到分析结果。
//
// 未注入时侧栏照常渲染，但集合区显示"未接线"且禁用新建——宁可显式空态，
// 也不假装有数据。
import SwiftUI
import GatherProtocol

// MARK: - 宿主端口

/// 策展能力包（环境注入；三项都可缺省）。
public struct CurationServices: Sendable {
    /// 集合 / 堆栈（AlbumAPI 的策展段；未接线时 nil）。
    public var album: (any AlbumAPI)?
    /// 跨工作区重复（DuplicateAPI.globalDuplicates）。
    public var duplicate: (any DuplicateAPI)?

    public init(
        album: (any AlbumAPI)? = nil,
        duplicate: (any DuplicateAPI)? = nil
    ) {
        self.album = album
        self.duplicate = duplicate
    }

    public static let unavailable = CurationServices()
}

private struct CurationServicesKey: EnvironmentKey {
    static let defaultValue = CurationServices.unavailable
}

public extension EnvironmentValues {
    /// 策展能力包（未注入 = .unavailable）。
    var curationServices: CurationServices {
        get { self[CurationServicesKey.self] }
        set { self[CurationServicesKey.self] = newValue }
    }
}

// MARK: - 选中项

/// 侧栏选中项（集合视图 / 跨工作区重复视图都按它切换内容区）。
///
/// 集合分支带整摘要而不只是 id：内容视图要展示名称与张数，再去查一次列表
/// 等于多一次往返，且容易和侧栏的列表错位。
public enum CurationSidebarSelection: Equatable, Sendable {
    case collection(CollectionSummary)
    case crossWorkspaceDuplicates
}

// MARK: - 侧栏

/// 图库侧栏：集合分组 + 跨工作区重复入口。
///
/// 只负责"列出来 + 发选中回调"；集合内容、排序、拖拽都在 CollectionView。
/// 数据加载走 AlbumAPI.collections(sessionId)（会话级；sessionId = nil 时禁用）。
public struct CollectionSidebar: View {
    /// 当前会话（Library 的会话筛选）；nil = 全局视图，集合不可用。
    let sessionId: String?
    @Binding var selection: CurationSidebarSelection?

    @Environment(\.curationServices) private var services
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var collections: [CollectionSummary] = []
    /// 列表读取失败（侧栏内联提示"集合加载失败"）。
    /// 只用于 reload()：建集合失败走 actionError，不能借用这条文案（D8）。
    @State private var loadFailed = false
    @State private var showCreateSheet = false
    @State private var newName = ""
    @State private var isWorking = false
    /// Wave2（task-15）：集合运算（并/交/差）sheet 的状态。
    @State private var showCombineSheet = false
    @State private var combineName = ""
    @State private var combineOperation: CollectionSetOperation = .union
    @State private var combineSelected: Set<String> = []
    /// 新建集合失败（sheet 内展示，保留已输入名称，弹窗不关）。
    @State private var actionError: CommandError?
    /// Wave2 收尾（task-27）：重命名/移动 sheet 的目标与草稿。
    @State private var showRenameSheet = false
    @State private var renameTarget: CollectionSummary?
    @State private var renameName = ""
    /// 树折叠状态持久化（按节点全路径；纯展示状态，SceneStorage 随窗口恢复）。
    /// 命名路径变化（重命名/移动）后旧 key 会失效，属可接受的展示层代价。
    @SceneStorage("curation.collectionTree.collapsed") private var collapsedPathsRaw = ""

    public init(
        sessionId: String?,
        selection: Binding<CurationSidebarSelection?>
    ) {
        self.sessionId = sessionId
        self._selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            collectionsSection
            Divider()
            crossWorkspaceSection
            Spacer(minLength: 0)
        }
        .padding(GatherMetrics.Space.m)
        .frame(minWidth: 200, idealWidth: 216, maxWidth: 260, alignment: .topLeading)
        .background(GatherTheme.surfaceMuted)
        .task(id: sessionId) { await reload() }
        .sheet(isPresented: $showCreateSheet) { createSheet }
        .sheet(isPresented: $showCombineSheet) { combineSheet }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
    }

    // MARK: 集合

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            HStack(spacing: GatherMetrics.Space.xs) {
                Label(l10n("集合"), systemImage: "square.stack.3d.up")
                    .font(GatherFont.eyebrow)
                    .foregroundStyle(GatherTheme.secondaryText)
                Spacer(minLength: 0)
                Button {
                    newName = ""
                    // 打开即清旧错误：上一次失败的红字不该跟着新的一次输入。
                    actionError = nil
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
                .help(l10n("新建集合"))
                .accessibilityLabel(l10n("新建集合"))
                // Wave2（task-15）：并/交/差（至少两个集合才有意义）。
                Button {
                    openCombineSheet()
                } label: {
                    Image(systemName: "square.on.square.dashed")
                }
                .buttonStyle(.plain)
                .disabled(!canCombine)
                .help(l10n("集合运算"))
                .accessibilityLabel(l10n("集合运算"))
            }
            if services.album == nil {
                Text(l10n("集合未接线（宿主未注入 AlbumAPI）"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
            } else if sessionId == nil {
                Text(l10n("选择一个工作区后可管理集合"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
            } else if loadFailed {
                Text(l10n("集合加载失败"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.errorText)
            } else if collections.isEmpty {
                Text(l10n("还没有集合"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
            } else {
                // Wave2 收尾（task-27）：扁平集合按命名路径组装成树；
                // 父节点允许是隐式分组节点（没有对应集合记录）。
                ForEach(CollectionTree.build(collections)) { node in
                    AnyView(treeRow(node))
                }
            }
        }
    }

    private var canCreate: Bool {
        services.album != nil && sessionId != nil && !isWorking
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("新建集合"))
                .font(GatherFont.sectionTitle)
            TextField(l10n("集合名称或路径"), text: $newName)
                .textFieldStyle(.roundedBorder)
            Text(l10n("用 / 表示层级，例如 客户A/精选；开头/结尾/连续的分隔符与非法字符会被拒绝。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !newName.isEmpty, let issue = CollectionPathInput.validate(newName) {
                Text(l10n(issue.messageKey))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = actionError {
                // 失败就地展示（sheet 不关、名称不丢），文案与其它页面同一漏斗：
                // 旧实现借用 loadFailed → 侧栏写"集合加载失败"，把"建集合失败"
                // 说成了"读列表失败"（D8）。
                Text(l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: GatherMetrics.Space.s) {
                Spacer(minLength: 0)
                Button(l10n("取消")) { showCreateSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .gatherButton(.secondary)
                Button(l10n("创建")) {
                    Task { await createCollection() }
                }
                .keyboardShortcut(.defaultAction)
                .gatherButton(.primary)
                .disabled(CollectionPathInput.validate(newName) != nil || isWorking)
            }
        }
        .padding(GatherMetrics.Space.xl)
        .frame(minWidth: 360)
    }

    // MARK: 集合运算（Wave2 / task-15）

    /// 至少两个集合才有"运算"语义。
    private var canCombine: Bool {
        services.album != nil && sessionId != nil && collections.count >= 2 && !isWorking
    }

    private var combineSheet: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("集合运算"))
                .font(GatherFont.sectionTitle)
            TextField(l10n("新集合名称"), text: $combineName)
                .textFieldStyle(.roundedBorder)
            Picker(l10n("运算方式"), selection: $combineOperation) {
                Text(l10n("并集")).tag(CollectionSetOperation.union)
                Text(l10n("交集")).tag(CollectionSetOperation.intersection)
                Text(l10n("差集（第一个减去其余）")).tag(CollectionSetOperation.difference)
            }
            .labelsHidden()
            Text(l10n("结果会保存成一个新的手动集合，可继续拖拽排序。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n("参与运算的集合"))
                .font(GatherFont.eyebrow)
                .foregroundStyle(GatherTheme.secondaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
                    ForEach(collections) { collection in
                        Toggle(isOn: combineBinding(for: collection.id)) {
                            HStack(spacing: GatherMetrics.Space.xs) {
                                Text(collection.name)
                                    .font(GatherFont.body)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(collection.itemCount)")
                                    .font(GatherFont.mono)
                                    .foregroundStyle(GatherTheme.secondaryText)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 220)
            if combineSelected.count < 2 {
                Text(l10n("至少选择两个集合"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
            }
            if let error = actionError {
                Text(l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: GatherMetrics.Space.s) {
                Spacer(minLength: 0)
                Button(l10n("取消")) { showCombineSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .gatherButton(.secondary)
                Button(l10n("创建")) {
                    Task { await combineCollections() }
                }
                .keyboardShortcut(.defaultAction)
                .gatherButton(.primary)
                .disabled(!canSubmitCombine)
            }
        }
        .padding(GatherMetrics.Space.xl)
        .frame(minWidth: 380)
    }

    /// 提交条件：名称非空 + 至少两个集合 + 不在进行中。
    private var canSubmitCombine: Bool {
        !isWorking
            && combineSelected.count >= 2
            && !combineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func combineBinding(for collectionId: String) -> Binding<Bool> {
        Binding(
            get: { combineSelected.contains(collectionId) },
            set: { isOn in
                if isOn {
                    combineSelected.insert(collectionId)
                } else {
                    combineSelected.remove(collectionId)
                }
            }
        )
    }

    private func openCombineSheet() {
        // 默认勾选前两个集合（最常见的 2 集合运算），并按并集预填默认名。
        combineSelected = Set(collections.prefix(2).map(\.id))
        combineOperation = .union
        combineName = l10n.format(
            "%@ 合集",
            collections.prefix(2).map(\.name).joined(separator: " + "))
        actionError = nil
        showCombineSheet = true
    }

    private func combineCollections() async {
        guard let album = services.album, let sessionId else { return }
        let name = combineName.trimmingCharacters(in: .whitespacesAndNewlines)
        // 选中顺序影响差集语义（第一个是被减数）：按侧栏列表顺序取，保证可预期。
        let ordered = collections.map(\.id).filter { combineSelected.contains($0) }
        guard !name.isEmpty, ordered.count >= 2 else { return }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            let created = try await album.combineCollections(
                Confirmed(CollectionCombineInput(
                    sessionId: sessionId,
                    name: name,
                    operation: combineOperation,
                    collectionIds: ordered
                ), source: .userDialog)
            )
            // #11：新集合是库级数据变更（侧栏/图库「加入集合」菜单都读它）。
            GatherEventCenter.postDomainChange(.library, sessionId: sessionId)
            showCombineSheet = false
            await reload()
            selection = .collection(created)
        } catch {
            actionError = CommandError(error)
        }
    }

    // MARK: 跨工作区

    private var crossWorkspaceSection: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            Label(l10n("跨工作区"), systemImage: "rectangle.on.rectangle.angled")
                .font(GatherFont.eyebrow)
                .foregroundStyle(GatherTheme.secondaryText)
            row(
                title: l10n("跨工作区重复"),
                count: nil,
                systemImage: "doc.on.doc",
                isSelected: selection == .crossWorkspaceDuplicates
            ) {
                selection = .crossWorkspaceDuplicates
            }
            if services.duplicate == nil {
                Text(l10n("重复扫描未接线（宿主未注入 DuplicateAPI）"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
            }
        }
    }

    // MARK: 行

    private func row(
        title: String,
        count: Int?,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: GatherMetrics.Space.xs) {
                Image(systemName: systemImage)
                    .foregroundStyle(isSelected ? GatherTheme.accent : GatherTheme.secondaryText)
                Text(title)
                    .font(GatherFont.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(GatherFont.mono)
                        .foregroundStyle(GatherTheme.secondaryText)
                }
            }
            .padding(.vertical, GatherMetrics.Space.xs)
            .padding(.horizontal, GatherMetrics.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous)
                    .fill(isSelected ? GatherTheme.selectionFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 数据

    private func reload() async {
        guard let album = services.album, let sessionId else {
            collections = []
            loadFailed = false
            return
        }
        do {
            collections = try await album.collections(sessionId)
            loadFailed = false
        } catch is CancellationError {
            // task(id:) 切工作区取消旧请求：保留现有列表，不当成加载失败。
            return
        } catch {
            collections = []
            loadFailed = true
        }
    }

    private func createCollection() async {
        guard let album = services.album, let sessionId else { return }
        // 权威校验在服务端（CurationPath），这里先做同一规则的前置校验：
        // 非法输入不发请求，红字留在 sheet 里（已输入内容不丢）。
        guard let name = CollectionPathInput.normalizedPath(newName) else {
            if let issue = CollectionPathInput.validate(newName) {
                actionError = CommandError.localized(issue.messageKey)
            }
            return
        }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            let created = try await album.createCollection(
                CollectionCreateInput(sessionId: sessionId, name: name)
            )
            // #11：新建集合是库级数据变更（图库「加入集合」菜单、其它页的集合侧栏都读它）。
            GatherEventCenter.postDomainChange(.library, sessionId: sessionId)
            showCreateSheet = false
            // 新建子集合后自动展开其祖先，否则用户看不到刚建的那一项。
            expandAncestors(of: created.name)
            await reload()
            selection = .collection(created)
        } catch {
            // 建集合失败 ≠ 列表读取失败：只置 actionError（sheet 内联红字），
            // 不能置 loadFailed——那会让侧栏改口成"集合加载失败"并盖住已输入的名称。
            actionError = CommandError(error)
        }
    }

    // MARK: - 集合树（Wave2 收尾 / task-27）

    /// 递归渲染（AnyView 打断 some View 的递归类型；集合树深度通常在个位数）。
    private func treeRow(_ node: CollectionTreeNode) -> AnyView {
        if node.children.isEmpty {
            return AnyView(nodeLabelRow(node))
        }
        return AnyView(
            DisclosureGroup(isExpanded: expansionBinding(for: node.path)) {
                VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
                    ForEach(node.children) { child in
                        AnyView(treeRow(child))
                    }
                }
                .padding(.leading, GatherMetrics.Space.m)
            } label: {
                nodeLabelRow(node)
            }
        )
    }

    /// 单行标签：隐式分组节点不可选中（只是命名层级）；落库集合单击即选中。
    private func nodeLabelRow(_ node: CollectionTreeNode) -> some View {
        HStack(spacing: GatherMetrics.Space.xs) {
            Image(systemName: node.isGroup ? "folder" : "square.stack.3d.up.fill")
                .foregroundStyle(
                    isSelected(node) ? GatherTheme.accent : GatherTheme.secondaryText)
            Text(node.displayName)
                .font(GatherFont.body)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !node.isGroup {
                Text("\(node.itemCount)")
                    .font(GatherFont.mono)
                    .foregroundStyle(GatherTheme.secondaryText)
            }
        }
        .padding(.vertical, GatherMetrics.Space.xs)
        .padding(.horizontal, GatherMetrics.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous)
                .fill(isSelected(node) ? GatherTheme.selectionFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let collection = node.collection {
                selection = .collection(collection)
            }
        }
        .contextMenu { nodeContextMenu(node) }
        .help(node.isGroup
              ? l10n("分组节点：只是命名层级，没有对应的集合记录")
              : l10n("单击打开集合；右键可重命名/移动或新建子集合"))
    }

    private func isSelected(_ node: CollectionTreeNode) -> Bool {
        guard let collection = node.collection else { return false }
        if case .collection(let selected)? = selection {
            return selected.id == collection.id
        }
        return false
    }

    @ViewBuilder
    private func nodeContextMenu(_ node: CollectionTreeNode) -> some View {
        if let collection = node.collection {
            Button(l10n("重命名/移动…")) {
                renameTarget = collection
                renameName = collection.name
                actionError = nil
                showRenameSheet = true
            }
        }
        Button(l10n("新建子集合…")) {
            newName = node.path + "/"
            actionError = nil
            showCreateSheet = true
        }
    }

    private var collapsedPaths: Set<String> {
        Set(collapsedPathsRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    private func expansionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedPaths.contains(path) },
            set: { expanded in
                var next = collapsedPaths
                if expanded {
                    next.remove(path)
                } else {
                    next.insert(path)
                }
                collapsedPathsRaw = next.sorted().joined(separator: "\n")
            }
        )
    }

    /// 展开某路径的全部祖先（新建子集合后让新项可见）。
    private func expandAncestors(of fullName: String) {
        let segments = fullName.split(separator: "/").map(String.init)
        guard segments.count > 1 else { return }
        var next = collapsedPaths
        for depth in 1..<segments.count {
            next.remove(segments.prefix(depth).joined(separator: "/"))
        }
        collapsedPathsRaw = next.sorted().joined(separator: "\n")
    }

    // MARK: - 重命名 / 移动 sheet

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("重命名/移动集合"))
                .font(GatherFont.sectionTitle)
            if let target = renameTarget {
                Text(l10n.format("当前：%@", target.name))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TextField(l10n("新的名称或路径"), text: $renameName)
                .textFieldStyle(.roundedBorder)
            Text(l10n("改最后一段 = 改名；改父路径 = 移动；父集合改名会连同子集合一起移动。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !renameName.isEmpty, let issue = CollectionPathInput.validate(renameName) {
                Text(l10n(issue.messageKey))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = actionError {
                Text(l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: GatherMetrics.Space.s) {
                Spacer(minLength: 0)
                Button(l10n("取消")) { showRenameSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .gatherButton(.secondary)
                Button(l10n("保存")) {
                    Task { await renameCollection() }
                }
                .keyboardShortcut(.defaultAction)
                .gatherButton(.primary)
                .disabled(CollectionPathInput.validate(renameName) != nil || isWorking)
            }
        }
        .padding(GatherMetrics.Space.xl)
        .frame(minWidth: 380)
    }

    private func renameCollection() async {
        guard let album = services.album, let target = renameTarget, let sessionId else {
            return
        }
        guard let name = CollectionPathInput.normalizedPath(renameName) else {
            if let issue = CollectionPathInput.validate(renameName) {
                actionError = CommandError.localized(issue.messageKey)
            }
            return
        }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            try await album.renameCollection(
                CollectionRenameInput(collectionId: target.id, name: name))
            // #11：集合改名/移动是库级数据变更（图库「加入集合」菜单、其它页侧栏都读它）。
            GatherEventCenter.postDomainChange(.library, sessionId: sessionId)
            showRenameSheet = false
            expandAncestors(of: name)
            await reload()
            if let updated = collections.first(where: { $0.id == target.id }) {
                selection = .collection(updated)
            }
        } catch {
            actionError = CommandError(error)
        }
    }
}
