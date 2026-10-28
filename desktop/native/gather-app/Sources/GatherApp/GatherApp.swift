// desktop/native/gather-app/Sources/GatherApp/GatherApp.swift
// Phase 3.0 宿主与桥：App 入口与场景（窗口/设置/菜单）。
//
// Cut 3 / 3b-1：启动装配与原生导入分别抽到 Sources/GatherHost/AppBootstrap.swift
// 与 Sources/GatherHost/AppImport.swift。
// Cut 3 / 3b-2+3：本文件所在的 GatherApp 是唯一可执行 target（只依赖
// GatherHost + GatherUI）；3b-1 的迁移期转发已删除，调用点改到 Host/UI 的
// 真实定义（AppBootstrap / AppImport）。
//
// 当前形态：RootView 与所有页面均为 SwiftUI；宿主只经 AppComposition/AppServices
// 的 typed API 访问 GatherDomain，不再持有字符串命令面。
// 数据库：Application Support/Gather/gather.sqlite（由 AppBootstrap 打开）。
// native app 不依赖 renderer 资产。
import SwiftUI
import AppKit
import GatherUI
import GatherHost

@main
struct GatherApp: App {
    @NSApplicationDelegateAdaptor(GatherAppDelegate.self) private var appDelegate
    /// Cut 3 / 3b-1：数据库、组合根、AppServices、页面 provider、C1 桥与
    /// Delegate 回调全部由 AppBootstrap 装配；场景只读 `scene`/`errorMessage`。
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        // Cut 4 / 4a-3a：语言唯一来源是 bootstrap.languageStore。读一次
        // language 让 Scene body 对语言建立 Observation 依赖——旧实现靠
        // @State commandsLanguageVersion 计数强制重建 .commands，计数器已删。
        // 值本身参与菜单文案构造（GatherAppCommands(language:)）。
        let menuLanguage = bootstrap.languageStore.language
        // Cut 4 / 4b-3：bootstrap 未就绪时的兜底文案（初始化中/失败/重试）同样在
        // 渲染期按当前语言解析——Scene body 读 l10n 即建立 Observation 依赖，
        // 切语言后占位界面跟着换语言（不再读进程级 appLanguage）。
        let l10n = bootstrap.languageStore.l10n
        // Phase 4 收口：读 installed 建立 Observation 依赖；RootView 安装/清理
        // handler 时 Scene body 重建 Commands，菜单禁用态随之刷新。
        let installedCommands = bootstrap.commandCenter.installed
        // 单窗口语义（Phase 4 收口）：命令中心是 SceneState 级唯一实例，菜单
        // handler 绑定当前 RootView。用 Window 而不是 WindowGroup，从构造上排除
        // 「第二个窗口共享/覆盖 handler」的未定义状态；⌘N 是新建工作区，不是新窗口。
        Window("Gather", id: GatherWindowID.main) {
            Group {
                if let scene = bootstrap.scene {
                    VStack(spacing: 0) {
                        // 一次性提示（当前只有「旧库已归档并重建」）：可关闭、不阻断。
                        if let notice = bootstrap.noticeMessage {
                            NativeBanner(
                                text: notice,
                                color: GatherTheme.warning,
                                onDismiss: { bootstrap.dismissNotice() })
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        }
                        // Cut 4 / 4a-2a-2：外壳只吃 SceneState 装配好的依赖包 +
                        // SessionStore；页面 VM 一律经 workspace 取，宿主不再传
                        // AppServices/provider 进 RootView。
                        RootView(
                            deps: scene.rootDeps,
                            sessionStore: scene.sessionStore,
                            // 4a-3a：语言唯一写入口；外壳文案由它的 l10n 驱动。
                            languageStore: scene.languageStore,
                            // Phase 4：菜单/快捷键命令中心。
                            commandCenter: scene.commandCenter
                        )
                    }
                } else if let message = bootstrap.errorMessage {
                    GatherEmptyState(
                        icon: "exclamationmark.triangle",
                        title: l10n("初始化失败"),
                        message: message
                    ) {
                        Button(l10n("重试")) {
                            Task { await start() }
                        }
                        .gatherPrimaryActionButton()
                    }
                    .frame(minWidth: 520, minHeight: 380)
                } else {
                    ProgressView(l10n("初始化中…"))
                        .controlSize(.large)
                        .frame(minWidth: 520, minHeight: 380)
                }
            }
            .task {
                await start()
            }
            .onOpenURL { url in
                appDelegate.handle(url)
            }
        }
        // N08 / Phase 4 收口：菜单只有 SwiftUI 这一条轨。AppDelegate 不构建任何
        // AppKit 菜单（也没有兜底分支）；标准菜单项的语言跟随系统语言，
        // 应用内切换语言只重渲染窗口内容（见 docs/DEVELOPMENT.md「本地化体系」）。
        .commands {
            GatherAppCommands(
                language: menuLanguage,
                commands: bootstrap.commandCenter,
                installed: installedCommands
            )
        }
        .windowStyle(.automatic)
        // 原生默认窗口尺寸：不再依赖 .frame(minWidth:) 撑开窗口。
        #if DEBUG
        .defaultSize(
            width: DebugLaunchOptions.windowWidth ?? 1180,
            height: DebugLaunchOptions.windowHeight ?? 780
        )
        #else
        .defaultSize(width: 1180, height: 780)
        #endif
        // 原生「设置」窗口：⌘, 由系统提供，最小化/缩放按钮自动变灰，
        // 窗口位置与打开的 pane 由系统记忆。取代旧版在内容区切换设置页。
        //
        // Cut 1 / B8.2d：与 RootView 同一套 typed 装配（session/settings/culling）；
        // bootstrap 未完成时只显示占位。
        Settings {
            if let scene = bootstrap.scene {
                SettingsView(
                    session: scene.appServices.session,
                    settings: scene.appServices.settings,
                    culling: scene.appServices.culling,
                    captureOne: scene.captureOneBridge,
                    // 4a-3a：设置页 setLanguage 只经 LanguageStore 写入。
                    languageStore: scene.languageStore,
                    // P0 / B0：维护域（备份/恢复/诊断）；Preview/旧调用不传时隐藏分区。
                    maintenance: scene.appServices.maintenance,
                    cancelPendingRestore: scene.cancelPendingRestore
                )
            } else {
                ProgressView(l10n("初始化中…"))
                    .controlSize(.large)
                    .frame(width: 580, height: 480)
            }
        }
        .defaultSize(width: 640, height: 620)
    }

    /// 启动入口：AppBootstrap 负责装配/失败态；重试按钮与 `.task` 共用。
    private func start() async {
        // QA/实机验收：`--data-dir <path>`、环境变量或偏好
        // `GatherApplicationSupportDirectory` 可把数据目录指向隔离路径，
        // 避免读写用户真实库；生产都不设时仍走 Application Support/Gather。
        let arguments = ProcessInfo.processInfo.arguments
        let argumentPath: String? = {
            guard let index = arguments.firstIndex(of: "--data-dir"),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }()
        let override = (argumentPath
            ?? ProcessInfo.processInfo.environment["GATHER_APPLICATION_SUPPORT_DIR"]
            ?? UserDefaults.standard.string(forKey: "GatherApplicationSupportDirectory"))
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        await bootstrap.startup(
            delegate: appDelegate, applicationSupportDirectory: override)
    }
}

// Cut 3 / 3b-2：3b-1 的「迁移期委托」已删除——DashboardViewModel 走 Protocol 的
// JobCreateParams.metadataScan、LiveSessionAPI ↔ AppImport、测试 ↔ AppBootstrap 直接引用。
