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
    /// 打开人物关联照片（第三轮审计 E）：(sessionId, photoId)。
    var onOpenPhoto: ((String, String) -> Void)? = nil
    /// 当前工作区（D12）：复核按钮优先落在它上面；nil 时按钮文案带工作区名。
    var currentSessionId: String? = nil
    /// 可见性门控：外壳已改为按目的地条件构建页面，此参数只用于跳过不可见时的加载
    /// （不再配合 .disabled/.allowsHitTesting/.accessibilityHidden 隐藏页面）。
    var isActive: Bool = true
    @State private var showCreate = false

    init(
        viewModel: PersonsViewModel,
        onReview: @escaping (String) -> Void = { _ in },
        onReviewFaceRole: ((String, String) -> Void)? = nil,
        onOpenPhoto: ((String, String) -> Void)? = nil,
        currentSessionId: String? = nil,
        isActive: Bool = true
    ) {
        self.viewModel = viewModel
        self.onReview = onReview
        self.onReviewFaceRole = onReviewFaceRole
        self.onOpenPhoto = onOpenPhoto
        self.currentSessionId = currentSessionId
        self.isActive = isActive
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.actionError, !showCreate {
                NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error), color: GatherTheme.error)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            // 两栏可拖拽（HSplitView）：删掉固定 300pt 与手绘选中态，
            // 列表用系统 List(selection:).listStyle(.sidebar)。
            HSplitView {
                listPane
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                detailPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GatherTheme.windowBackground)
        // 页面名进窗口标题（旧版是列表栏里的 26pt H1，与侧栏条目重复）。
        .navigationTitle(GatherLocalization.l("人脸库"))
        // 搜索进工具栏：系统放大镜、清除按钮、Esc 取消；不再自绘圆角输入框。
        .searchable(
            text: $viewModel.searchText,
            prompt: Text(GatherLocalization.l("搜索姓名…"))
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Label(GatherLocalization.l("新建人物"), systemImage: "plus")
                }
                .help(GatherLocalization.l("新建人物"))
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        // 隐藏时不建加载 Task（启动即跑 person.list/person.get 的旧行为删除）；
        // 重新可见 → id 变化触发一次加载。
        .task(id: isActive) {
            guard isActive else { return }
            await viewModel.load()
        }
        // 写路径广播（person.* 与 fkw 绑定/解绑 → 人物域）：可见时按域刷新，
        // 隐藏时不发请求（重新可见由上面的 .task 统一补一次）。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
            guard let change = notification.object as? GatherDomainChange,
                  change.domain == .persons,
                  change.origin != PersonsViewModel.changeOrigin,
                  isActive else { return }
            Task { await viewModel.load() }
        }
        .sheet(isPresented: $showCreate) {
            CreatePersonSheet(viewModel: viewModel) { name in
                await viewModel.create(name: name)
            }
            .onAppear { viewModel.clearActionError() }
        }
    }

    private var listPane: some View {
        listContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 系统选中：外观、上下键、⌘ 取消选中交给 List。
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { viewModel.selected?.id },
            set: { newValue in
                guard let newValue else { return }
                viewModel.select(newValue)
            }
        )
    }

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView(GatherLocalization.l("加载中…"))
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            // 加载失败必须给出口（不再是自绘感叹号 + 裸按钮）。
            ContentUnavailableView {
                Label(GatherLocalization.l("加载失败"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(String(format: GatherLocalization.l("加载失败：%@"), error))
            } actions: {
                Button(GatherLocalization.l("重试")) {
                    Task { await viewModel.load() }
                }
                .help(GatherLocalization.l("重新读取人脸库"))
            }
        case .loaded:
            if viewModel.persons.isEmpty {
                emptyState
            } else if viewModel.filteredPersons.isEmpty {
                noMatchState
            } else {
                List(selection: selectionBinding) {
                    ForEach(viewModel.filteredPersons, id: \.id) { person in
                        PersonListRow(person: person)
                            .tag(person.id)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel(GatherLocalization.l("人物列表"))
            }
        }
    }

    /// 对齐 TS persons.emptyTitle / persons.emptyHint / persons.new。
    private var emptyState: some View {
        ContentUnavailableView {
            Label(GatherLocalization.l("暂无人物"), systemImage: "person.2")
        } description: {
            Text(GatherLocalization.l("新建人物以开始建立人脸库"))
        } actions: {
            Button(GatherLocalization.l("新建人物")) { showCreate = true }
                .gatherPrimaryActionButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 对齐 TS persons.noMatch / persons.noMatchHint：系统「搜索无结果」外观。
    private var noMatchState: some View {
        ContentUnavailableView.search(text: viewModel.searchText)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let person = viewModel.selected {
            PersonDetailView(
                person: person,
                viewModel: viewModel,
                onReview: onReview,
                onReviewFaceRole: onReviewFaceRole,
                onOpenPhoto: onOpenPhoto,
                currentSessionId: currentSessionId
            )
        } else if viewModel.persons.isEmpty {
            // N10：空库时的主动作只有一个——左侧空态已经给出「新建人物」，
            // 右侧不再放第二个同权按钮（旧实现工具栏 + 左 + 右三处并列，
            // 而右侧还写着「从左侧列表选择一个人物」，指向一个空列表）。
            ContentUnavailableView {
                Label(GatherLocalization.l("人脸库还是空的"), systemImage: "person.crop.circle")
            } description: {
                Text(GatherLocalization.l("新建人物后，就可以把工作区里的人脸簇绑定到角色上。"))
            }
        } else {
            ContentUnavailableView {
                Label(GatherLocalization.l("未选择人物"), systemImage: "person.crop.circle")
            } description: {
                Text(GatherLocalization.l("从左侧列表选择一个人物"))
            }
        }
    }
}

private struct PersonListRow: View {
    let person: PersonData

    var body: some View {
        HStack(spacing: 8) {
            // 侧栏行保持紧凑：28pt 头像（42pt 圆形头像会把每行撑到 ~54pt）。
            avatar
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).lineLimit(1)
                Text(String(format: GatherLocalization.l("%lld 张照片 · %lld 个工作区"), person.photoCount, person.sessionCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .frame(minHeight: 24)
        // 不再手绘选中底色（系统 List 选中外观自动跟随外观/增强对比度）；
        // 行内容整体合并给辅助技术，计数不会被 label 覆盖掉。
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var avatar: some View {
        if let path = person.thumbnailPath, !path.isEmpty {
            PhotoThumbnailView(path: path, size: 64)
        } else if let base64 = person.thumbnailBase64, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            // 首字占位：品牌色只做低透明度底，文字用系统前景色
            // （旧版按浅/深两态硬编码 RGB，且不会跟随增强对比度）。
            ZStack {
                GatherTheme.accent.opacity(0.18)
                Text(String(person.name.prefix(1)))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(GatherTheme.primaryText)
            }
        }
    }
}

private struct PersonDetailView: View {
    let person: PersonDetailData
    @Bindable var viewModel: PersonsViewModel
    let onReview: (String) -> Void
    var onReviewFaceRole: ((String, String) -> Void)? = nil
    /// 打开具体照片（第三轮审计 E）：「关联照片」网格原先只有缩略图 + 文件名，
    /// 看得到却打不开——用户只能自己回工作区再找一遍。
    var onOpenPhoto: ((String, String) -> Void)? = nil
    /// 当前工作区（D12）：复核按钮优先落在它上面。
    var currentSessionId: String? = nil

    /// 复核落点（D12）：优先**当前工作区**，其次关联照片里的第一个工作区。
    ///
    /// 旧实现直接用 `person.photos.first?.sessionId`：人物跨多个工作区时，
    /// 第一项不一定是用户当前所在的工作区，按钮却写着「在当前工作区复核」——
    /// 文案与真实目标不一致。取不到当前工作区时按钮文案改为带工作区名，
    /// 让用户知道会去哪里。
    private var reviewTarget: (sessionId: String, sessionName: String)? {
        if let current = currentSessionId,
           let match = person.photos.first(where: { $0.sessionId == current }) {
            return (match.sessionId, match.sessionName)
        }
        guard let first = person.photos.first else { return nil }
        return (first.sessionId, first.sessionName)
    }

    private var reviewLabel: String {
        guard let target = reviewTarget else { return GatherLocalization.l("复核人脸") }
        if target.sessionId == currentSessionId { return GatherLocalization.l("在当前工作区复核人脸") }
        return String(format: GatherLocalization.l("在「%@」复核人脸"), target.sessionName)
    }
    @State private var name = ""
    @State private var notes = ""
    @State private var showDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 详情栏标题：26pt H1 +「人物详情」眉标删除（页面名由窗口标题承载，
            // 在列表里切换人物即可，不需要「返回人脸库」这种伪导航）。
            HStack(alignment: .center, spacing: 16) {
                avatar
                VStack(alignment: .leading, spacing: 5) {
                    Text(person.name).font(.title2.weight(.semibold))
                    Text(String(format: GatherLocalization.l("%lld 张照片 · %lld 个工作区"), person.totalPhotoCount, person.sessionCount))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(24)

            Form {
                Section(GatherLocalization.l("基本信息")) {
                    TextField(GatherLocalization.l("名称"), text: $name)
                    TextField(GatherLocalization.l("备注"), text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                    HStack {
                        Spacer()
                        Button(GatherLocalization.l("保存")) {
                            Task {
                                let ok = await viewModel.saveSelected(name: name, notes: notes)
                                if ok {
                                    GatherToastCenter.shared.show(type: .success, message: GatherLocalization.l("人物信息已保存"))
                                } else {
                                    // 错误已由就近 toast 呈现；清空 actionError，
                                    // 避免页面级 NativeBanner 同源重复提示。
                                    GatherToastCenter.shared.show(type: .error, message: viewModel.actionError ?? GatherLocalization.l("保存失败"))
                                    viewModel.clearActionError()
                                }
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section(GatherLocalization.l("人脸匹配")) {
                    if person.keywords.isEmpty {
                        Text(GatherLocalization.l("尚未设置人物关键字")).foregroundStyle(.secondary)
                    } else {
                        Text(person.keywords.joined(separator: ", "))
                            .font(.callout)
                    }
                    LabeledContent(GatherLocalization.l("匹配阈值"), value: String(format: "%.2f", person.matchThreshold))
                    if let target = reviewTarget {
                        Button(reviewLabel) {
                            // 对齐旧版 PersonDetail.tsx:158-162：携带
                            // ?role=encodeURIComponent(person.name) 预筛选；
                            // 未注入 onReviewFaceRole 时回退旧行为。
                            if let onReviewFaceRole {
                                onReviewFaceRole(person.name, target.sessionId)
                            } else {
                                onReview(target.sessionId)
                            }
                        }
                        .help(String(
                            format: GatherLocalization.l("在该工作区的人脸审核页按角色「%@」复核"),
                            person.name
                        ))
                    }
                }
                Section(GatherLocalization.l("记录")) {
                    LabeledContent(GatherLocalization.l("创建时间"), value: Self.dateText(person.createdAt))
                    LabeledContent(GatherLocalization.l("更新时间"), value: Self.dateText(person.updatedAt))
                }
                // 关联照片放进 Form 的 Section：整个详情栏只有一个滚动区
                // （旧版 Form 与照片网格各自滚动，滚轮命中哪个区域不可预测）。
                Section(GatherLocalization.l("关联照片")) {
                    if person.photos.isEmpty {
                        Text(GatherLocalization.l("暂无关联照片")).foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                            ForEach(person.photos, id: \.photoId) { photo in
                                Button {
                                    // 打开该照片所在工作区的图库并直接看这张（N07 通道）。
                                    onOpenPhoto?(photo.sessionId, photo.photoId)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        PhotoThumbnailView(
                                            path: photo.filepath,
                                            size: 240,
                                            placeholderSize: CGSize(width: 110, height: 74)
                                        )
                                        // 统一 3:2（多数 RAW 的宽高比），避免 .adaptive
                                        // 列宽变化时留下右侧空隙与裁切比例不一致。
                                        .aspectRatio(3 / 2, contentMode: .fill)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.sm))
                                        Text(photo.filename).font(.callout).lineLimit(1)
                                        Text(photo.sessionName)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(onOpenPhoto == nil)
                                .help(GatherLocalization.l("打开这张照片"))
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                // 破坏性动作用 Form 尾部的一个普通行，不再放在标题栏右侧最显眼处。
                Section {
                    HStack {
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            showDelete = true
                        } label: {
                            Text(GatherLocalization.l("删除人物"))
                        }
                        .foregroundStyle(GatherTheme.error)
                        .help(GatherLocalization.l("删除该人物及其人脸绑定数据"))
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            name = person.name
            notes = person.notes
        }
        .onChange(of: person.id) { _, _ in
            name = person.name
            notes = person.notes
        }
        .alert(GatherLocalization.l("删除人物？"), isPresented: $showDelete) {
            // 与共享确认弹窗同理：宿主页隐藏时不能被 isActive 的 disabled 连坐。
            Button(GatherLocalization.l("删除"), role: .destructive) {
                Task {
                    let ok = await viewModel.deleteSelected(confirmed: true)
                    if ok {
                        GatherToastCenter.shared.show(type: .success, message: GatherLocalization.l("人物已删除"))
                    } else {
                        // 错误已由就近 toast 呈现；清空 actionError，
                        // 避免页面级 NativeBanner 同源重复提示。
                        GatherToastCenter.shared.show(type: .error, message: viewModel.actionError ?? GatherLocalization.l("删除失败"))
                        viewModel.clearActionError()
                    }
                }
            }
            .disabled(false)
            Button(GatherLocalization.l("取消"), role: .cancel) {
                GatherToastCenter.shared.show(
                    type: .info,
                    message: String(format: GatherLocalization.l("已取消删除「%@」，未执行任何更改"), person.name)
                )
            }
            .disabled(false)
        } message: {
            Text(String(format: GatherLocalization.l("确定要删除「%@」吗？将从人脸库移除该人物及其 %lld 张关联照片、%lld 个工作区的人脸绑定数据。此操作不可撤销。"), person.name, person.totalPhotoCount, person.sessionCount))
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
            // 首字占位：品牌色只做低透明度底，文字用系统前景色。
            // （旧版主色实底 + 白字在深色模式约 2.7:1。）
            ZStack {
                Circle().fill(GatherTheme.accent.opacity(0.18))
                Text(String(person.name.prefix(1)))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(GatherTheme.primaryText)
            }
            .frame(width: 80, height: 80)
        }
    }

    /// 对齐旧版 PersonDetail.tsx:192 `new Date(createdAt).toLocaleDateString()`：
    /// 仅日期、无时分。zh 环境固定 `yyyy年M月d日`，其余语言按系统区域日期模板
    /// （zh 判定与 SettingsViewModel.dateText 的 Locale.preferredLanguages
    /// 前缀检查同源；页面无 ui_language 访问通道，沿用系统区域近似）。
    private static func dateText(_ iso: String) -> String {
        guard let date = parseISO8601Date(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true {
            formatter.dateFormat = "yyyy年M月d日"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMd")
        }
        return formatter.string(from: date)
    }
}

private struct CreatePersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @Bindable var viewModel: PersonsViewModel
    let onCreate: (String) async -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(GatherLocalization.l("新建人物")).font(.title2.weight(.semibold))
            TextField(GatherLocalization.l("输入人物姓名"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                // 打开即可直接输入（旧版需要先点一下输入框）。
                .defaultFocus($nameFocused, true)
                .onSubmit { submit() }
            // 创建失败时 sheet 保持打开并在下方展示错误（状态色只落在图标上）。
            if let errorText = viewModel.actionError, !errorText.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(GatherTheme.error)
                        .accessibilityHidden(true)
                    Text(String(format: GatherLocalization.l("操作失败：%@"), errorText))
                        .font(.callout)
                }
            }
            HStack {
                Spacer()
                Button(GatherLocalization.l("取消"), role: .cancel) { dismiss() }
                Button(GatherLocalization.l("创建")) { submit() }
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
                GatherToastCenter.shared.show(type: .success, message: GatherLocalization.l("人物已创建"))
                dismiss()
            } else {
                GatherToastCenter.shared.show(type: .error, message: viewModel.actionError ?? GatherLocalization.l("创建失败"))
            }
        }
    }
}
