// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsView.swift
// Cut 4 / 4c-2d：设置页从 1,935 行拆为「壳 + View extensions + VM extensions +
// 独立支撑文件」。本文件只保留页面壳：7 个状态项（6 个 @State + @FocusState）、
// 装配 init、body 的 Form 章节顺序，以及 3 个 .task / 2 个 fileImporter /
// 2 个 gatherDestructiveConfirm 的顺序（全部逐字未动）。
// 章节实现：+Sections（横幅/保存规则/语言）/ +C1HealthSection / +FaceAnalysis /
// +Model（高级与模型推理）/ +Fields（分组字段行）。
//
// 跨文件 extension 只能访问 internal 成员：viewModel / pickingField /
// pickingModelPathKey / showAdvancedSettings / focusedFieldKey / languageStore /
// l10n 由 private 改 internal（焦点仍在同一 @FocusState 上，未换成外部 Binding）。
//
// Phase 3.6：设置与模型状态 SwiftUI 页面（TS 源：pages/Settings/index.tsx +
// C1HealthPanel.tsx）。
// - 分组设置（GROUPS：缓存/图片处理/数据库/C1 集成/元数据），label/描述抄
//   locales/zh-CN.json（settings.* 键）；数值字段带 min/max 校验，非法值禁止保存。
// - 人脸分析滑杆：常规（detect_confidence/default_eps/default_min_samples）+
//   高级（max_detections 等），保存经 SettingsAPI.set。
// - Capture One 健康面板：四层预检 + 12s 轮询 sync-state，均走类型化 API。
// - Cut 1 / B8.2d：router 兼容 init 已删除，宿主与 RootView 显式注入三个域 + C1 桥。
// - 语言切换（Cut 4 / 4a-3a）：持久化 + 广播归 SettingsAPI，本地状态只经 LanguageStore。
import SwiftUI
import GatherProtocol

/// 应用设置（原生版）。
///
/// 原生化要点：
/// - 由真正的 Settings scene 承载（⌘, 由系统提供，最小化/缩放自动变灰）；
/// - Form + .formStyle(.grouped)：标签列、控件列、行内边距、选中高亮、
///   分组圆角与无障碍关联全部由系统负责。取代旧版「手搓 HStack + Spacer +
///   900pt 空白走廊 + 四个魔法宽度 + 每个字段一个保存按钮」；
/// - 编辑即生效：回车（onSubmit）或选择文件即落库；
/// - 排版走系统文本样式（不再有 10pt 正文与三级同号的 .title3 标题）；
/// - 状态行用 Label + SF Symbol + 语义色，不再用 ✓/✗ 字形与纯颜色信号。
public struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    @State private var pendingReset: PendingSettingsReset?
    @State private var pendingModelInstall: PendingModelInstall?
    /// 正在用文件选择器编辑的设置项（目录项选文件夹，其余选文件）。
    @State var pickingField: SettingField?
    /// 正在用文件选择器编辑的模型路径键。
    @State var pickingModelPathKey: String?
    /// 高级设置展开状态（F11：默认收起，普通用户首屏看不到技术参数）。
    @State var showAdvancedSettings = false
    /// 当前获得焦点的设置项键（F11：失焦即提交，避免「看起来改了其实没写」）。
    /// 4c-2d：声明为 internal；3 处 onChange 所在的行构建器在 SettingsView+*.swift，
    /// 仍读写这同一个 @FocusState（没有换成外部 FocusState.Binding 副本）。
    @FocusState var focusedFieldKey: String?
    /// Cut 4 / 4a-3b-1：渲染期本地化的语言来源（外壳已注入 LanguageStore）。
    let languageStore: LanguageStore

    /// 错误文案的渲染期本地化入口（设置页是全仓唯一已接线 LanguageStore 的页面）。
    var l10n: L10n { languageStore.l10n }

    /// 生产装配（RootView / 宿主 Settings 场景）：设置 / 会话 / 挑片与 C1 桥
    /// 全部显式注入（E-17：不再在页面内自建 CaptureOneBridge）。
    public init(
        session: any SessionAPI,
        settings: any SettingsAPI,
        culling: any CullingAPI,
        captureOne: any CaptureOneBridging,
        languageStore: LanguageStore
    ) {
        self.languageStore = languageStore
        _viewModel = State(initialValue: SettingsViewModel(
            session: session,
            settings: settings,
            culling: culling,
            captureOne: captureOne,
            languageStore: languageStore
        ))
    }

    public var body: some View {
        Form {
            banners
            // F11 分块规则：首屏只放日常设置——语言、Capture One 状态、
            // 图片处理 / 写回 / 元数据 / 缓存；模型路径、输入尺寸、特征维度、
            // 数据库与人脸算法参数折叠进「高级」（默认收起）。
            saveRuleHint
            languageSection
            c1HealthSection
            ForEach(SettingsViewModel.primaryGroups) { group in
                settingsSection(group)
            }
            faceAnalysisSection
            advancedSection
        }
        .formStyle(.grouped)
        .tint(GatherTheme.accent)
        // 页面骨架（frame / 语义背景 / 窗口标题）由 DesignSystem 提供；
        // Form(.grouped)、section 顺序与其后的 toolbar / fileImporter /
        // gatherDestructiveConfirm 全部未动。
        .gatherPage(title: l10n("设置"), surface: .canvas)
        // 窗口级不透明修复务必留在最外层：Settings scene 用
        // containerBackground(for: .window) 给窗口铺 canvas，不能被页面
        // .background 取代（否则 inactive 时玻璃 titlebar 又会透出主窗口）。
        .modifier(SettingsWindowSurface())
        .frame(minWidth: 580, minHeight: 480)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.load()
                } label: {
                    Label(l10n("刷新"), systemImage: "arrow.clockwise")
                }
                .help(l10n("重新读取全部设置项"))

                Button {
                    pendingReset = PendingSettingsReset(keyCount: viewModel.values.count)
                } label: {
                    Label(l10n("恢复默认"), systemImage: "arrow.counterclockwise")
                }
                .help(l10n("把所有设置项恢复为默认值（会先确认）"))
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { pickingField != nil },
                set: { if !$0 { pickingField = nil } }
            ),
            allowedContentTypes: (pickingField?.key.hasSuffix("_dir") ?? false) ? [.folder] : [.item],
            allowsMultipleSelection: false
        ) { result in
            guard let field = pickingField else { return }
            pickingField = nil
            guard case .success(let urls) = result, let url = urls.first else { return }
            viewModel.edits[field.key] = url.path
            viewModel.saveField(field, with: l10n)
        }
        .fileImporter(
            isPresented: Binding(
                get: { pickingModelPathKey != nil },
                set: { if !$0 { pickingModelPathKey = nil } }
            ),
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: false
        ) { result in
            guard let key = pickingModelPathKey else { return }
            pickingModelPathKey = nil
            guard case .success(let urls) = result, let url = urls.first else { return }
            viewModel.edits[key] = url.path
            viewModel.saveModelPath(key: key, with: l10n)
        }
        .task { viewModel.load() }
        // 对齐 C1HealthPanel.tsx：挂载时检测一次；重检走"重新检测"按钮
        // （TS checkHealth 仅挂载时 + 手动触发，12s 定时器只轮询 sync-state）。
        .task { await viewModel.checkC1Health() }
        // 对齐 C1HealthPanel.tsx：CullingAPI.syncStatus 每 12s 轮询刷新。
        .task {
            await viewModel.refreshSyncState()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                await viewModel.refreshSyncState()
            }
        }
        // 写路径广播（XMP/同步队列）：立即刷新 C1 写回队列，不再等 12s 轮询。
        .refreshOnDomainEvents([.metadata]) {
            await viewModel.refreshSyncState()
        }
        .gatherDestructiveConfirm(
            pending: $pendingReset,
            title: l10n("恢复所有设置默认值？"),
            confirmLabel: { _ in l10n("恢复默认") },
            confirmRole: { _ in .destructive },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in viewModel.reset(confirmed: true) },
            onCancel: { _ in viewModel.reportCancellation(l10n("恢复默认设置")) }
        )
        // 模型覆盖安装：同名文件会被覆盖且不可恢复，先确认。
        .gatherDestructiveConfirm(
            pending: $pendingModelInstall,
            title: l10n("确认下载并安装人脸模型？"),
            confirmLabel: { _ in l10n("下载并覆盖") },
            confirmRole: { _ in .destructive },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in Task { await viewModel.startModelDownload() } },
            onCancel: { _ in viewModel.reportCancellation(l10n("下载并安装人脸模型")) }
        )
    }
}

#if DEBUG
#Preview("Settings · 设置") {
    PreviewFactory.settingsPage()
}
#endif


/// 设置窗口是独立的 Settings scene；inactive 时玻璃 titlebar 会把后方主窗口
/// 的内容透出来。macOS 15+ 用容器背景给窗口一个不透明 canvas，旧系统退回
/// 普通背景，避免工具栏文字像鬼影。
private struct SettingsWindowSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(GatherTheme.canvas, for: .window)
        } else {
            content.background(GatherTheme.windowBackground)
        }
    }
}
