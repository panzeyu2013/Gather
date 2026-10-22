// desktop/native/gather-app/Sources/GatherUI/Dashboard/NewSessionSheet.swift
// Cut 4 / 4c-2i：自 DashboardView.swift 原样移出（新建工作区表单；原 720-960 行）。
// 行为/布局/文案不变：来源选择 + C1 四层预检 + 一跳建库入队。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: - 新建工作区（来源选择 + C1 四层预检 + metadata.scan 一跳入队）

struct NewSessionSheet: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    /// 4a-3b-2b：sheet 在 RootView 的 environment 树里。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    /// 创建成功回调（TS createMutation onSuccess → navigate /sessions/:id）。
    let onCreated: (String) -> Void

    @State private var name = ""
    @State private var nameEdited = false
    @State private var folderPath = ""
    @State private var source = DashboardViewModel.SessionSource.local

    init(
        viewModel: DashboardViewModel,
        initialFolderPath: String = "",
        onCreated: @escaping (String) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onCreated = onCreated
        _folderPath = State(initialValue: initialFolderPath)
        _name = State(initialValue: initialFolderPath.isEmpty ? "" : URL(fileURLWithPath: initialFolderPath).lastPathComponent)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 表单行交给 Form + .formStyle(.grouped) + LabeledContent：
            // 标签列、控件列、行内边距与选中高亮由系统负责。
            Form {
                nameSection
                sourceSection
                if let error = viewModel.createError {
                    // createError 是 CommandError（码/参数/诊断）：本地校验经
                    // .localized 上屏，API 诊断由 CommandErrorText 回退通用文案。
                    NativeBanner(text: CommandErrorText.resolve(error, with: l10n))
                }
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 520)
        // N10：sheet 高度贴合内容。旧的固定 440pt 在 3 行表单下留出 200pt 以上
        // 空白；Capture One 来源会多出「连接预检」区块，因此按来源给两档高度。
        .frame(height: source == .captureOne ? 430 : 330)
        .task {
            // TS：对话框打开且来源为 Capture One 时自动预检。
            if source == .captureOne {
                await viewModel.runC1Preflight()
            }
        }
        .onChange(of: source) { _, newSource in
            // TS：切换来源且名称未编辑时清空名称。
            if !nameEdited { name = "" }
            if newSource == .captureOne {
                Task { await viewModel.runC1Preflight() }
            }
        }
    }

    private var nameSection: some View {
        Section {
            LabeledContent(l10n("名称")) {
                TextField(
                    l10n("名称"),
                    text: $name,
                    prompt: Text(source == .local
                        ? l10n("自动生成")
                        : l10n("默认用文件夹名"))
                )
                .labelsHidden()
                .onChange(of: name) { _, _ in nameEdited = true }
            }
        } footer: {
            // N10：长提示从输入框 placeholder 移到分组脚注——placeholder 在标签列
            // 挤压下会被截断成「选择文件…」，而脚注有整行宽度。
            Text(source == .local
                ? l10n("选择文件夹后名称会自动生成，也可以先手动输入。")
                : l10n("留空则使用选中照片所在的文件夹名称。"))
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            Picker(l10n("导入来源"), selection: $source) {
                ForEach(DashboardViewModel.SessionSource.allCases) { option in
                    Text(option.label(with: l10n)).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        if source == .local {
            Section {
                folderRow
            }
        } else {
            Section {
                c1PreflightRows
            } header: {
                Text(l10n("Capture One 连接预检"))
            }
        }
    }

    private var canCreate: Bool {
        switch source {
        case .local:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty && !folderPath.isEmpty
        case .captureOne:
            // 名称可留空（回退文件夹名），但预检/创建进行中禁用。
            return !viewModel.isC1PreflightChecking
        }
    }

    /// TS handleSelectFolder（selectDirectory + 未编辑时用目录名填充名称）。
    ///
    /// 第三轮审计 F：改用非阻塞 `begin()`。旧实现的 `runModal()` 在 sheet 内
    /// 再开嵌套 runloop，会卡住主线程并让工具栏/菜单在新工作区表单打开期间失去响应。
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = l10n("请选择包含照片的文件夹")
        Task { @MainActor in
            let response = await panel.begin()
            guard response == .OK, let url = panel.url else { return }
            folderPath = url.path
            if !nameEdited {
                name = url.lastPathComponent
            }
        }
    }

    private var folderRow: some View {
        LabeledContent(l10n("文件夹位置")) {
            HStack(spacing: 8) {
                TextField(
                    l10n("文件夹位置"),
                    text: $folderPath,
                    prompt: Text(l10n("选择文件夹"))
                )
                .labelsHidden()
                .disabled(true)
                Button(l10n("选择文件夹"), action: chooseFolder)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { isDirectoryURL($0) }) else { return false }
            folderPath = url.path
            if !nameEdited {
                name = url.lastPathComponent
            }
            return true
        }
    }

    /// TS Dialog c1Preflight 区块：检查清单 + 通过/引导文案。
    /// 状态行 = Label + SF Symbol + 语义色（不再用裸 ✓/✗ 字形与纯颜色信号）。
    @ViewBuilder
    private var c1PreflightRows: some View {
        switch viewModel.c1Preflight {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(l10n("正在检查 Capture One 连接…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .finished(let result):
            ForEach(result.checks) { check in
                Label(
                    check.label.resolve(with: l10n),
                    systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(check.passed ? GatherTheme.success : GatherTheme.error)
            }
            if result.passed {
                Text(l10n("预检通过：导入时读取 Capture One 当前选中的照片。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let guidance = result.guidance {
                // 旧版 c1-preflight.ts：预检失败引导为 error 语义提示条。
                NativeBanner(text: guidance.resolve(with: l10n))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("创建后会立即启动照片索引；索引进度和失败重试可在任务中心查看。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(l10n("取消")) { dismiss() }
                Button(l10n("创建"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || viewModel.isCreating)
            }
        }
        .padding(16)
    }

    /// TS handleCreate：本地 → createFromDirectory；Capture One → 预检门控后
    /// 读选中照片建库（未选中报“请先在 Capture One 中选择照片”）。
    private func create() {
        // 4b-2e：动作发生时按当前界面语言解析（toast / 默认会话名），VM 不读全局。
        let l10n = self.l10n
        Task {
            let session: SessionData?
            switch source {
            case .local:
                session = await viewModel.createSession(
                    name: name.trimmingCharacters(in: .whitespaces),
                    sourcePath: folderPath,
                    with: l10n
                )
            case .captureOne:
                session = await viewModel.createSessionFromCaptureOne(
                    name: name.trimmingCharacters(in: .whitespaces),
                    with: l10n
                )
            }
            if let session {
                dismiss()
                // TS createMutation onSuccess L220：创建成功后立即跳转
                // /sessions/:id（控制中心）；toast 已由 ViewModel 展示。
                onCreated(session.id)
            }
        }
    }
}
