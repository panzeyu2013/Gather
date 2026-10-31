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
    /// 新建集合失败（sheet 内展示，保留已输入名称，弹窗不关）。
    @State private var actionError: CommandError?

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
                ForEach(collections) { collection in
                    row(
                        title: collection.name,
                        count: collection.itemCount,
                        systemImage: "square.stack.3d.up.fill",
                        isSelected: selection == .collection(collection)
                    ) {
                        selection = .collection(collection)
                    }
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
            TextField(l10n("集合名称"), text: $newName)
                .textFieldStyle(.roundedBorder)
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
                Button(l10n("创建")) {
                    Task { await createCollection() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        }
        .padding(GatherMetrics.Space.xl)
        .frame(minWidth: 360)
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
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            let created = try await album.createCollection(
                CollectionCreateInput(sessionId: sessionId, name: name)
            )
            showCreateSheet = false
            await reload()
            selection = .collection(created)
        } catch {
            // 建集合失败 ≠ 列表读取失败：只置 actionError（sheet 内联红字），
            // 不能置 loadFailed——那会让侧栏改口成"集合加载失败"并盖住已输入的名称。
            actionError = CommandError(error)
        }
    }
}
