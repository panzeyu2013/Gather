// desktop/native/gather-app/Sources/GatherHost/GatherAppDelegate.swift
// Phase 4.2：macOS deep-link、导入面板、应用生命周期。
//
// Phase 4 收口：菜单只有 SwiftUI 一份（.commands）。本类不再构建/补齐任何
// AppKit 菜单（实测 NSApp.mainMenu 由 SwiftUI 提供 File/Edit/View/Window/Help，
// 旧兜底会用 selector 定义第二套菜单）。导入面板与 C1 导入只经
// RootShellDependencies 的 typed 闭包被调用。

import AppKit
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherUI


public enum GatherDeepLink {
    /// 深链格式：gather://import?file=<path>，每个 file
    /// 单独校验扩展名/文件存在性，重复项去重；URLComponents 已经完成一次
    /// percent decode，不能再解码，否则文件名中的字面 % 会损坏。
    public static func importFiles(from url: URL) -> [String] {
        importFiles(from: url, supportedExtensions: RAWDecoder.supportedExtensions)
    }

    public static func importFiles(
        from url: URL,
        supportedExtensions: Set<String>
    ) -> [String] {
        if url.isFileURL {
            return importFiles(fromFileURL: url, supportedExtensions: supportedExtensions)
        }
        guard url.scheme == "gather", url.host == "import" else { return [] }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var paths: [String] = []
        for item in items where item.name == "file" {
            guard let raw = item.value, !raw.isEmpty else { continue }
            paths.append(raw)
        }
        var seen = Set<String>()
        return paths.compactMap { rawPath in
            guard let path = validatedFilePath(rawPath, supportedExtensions: supportedExtensions),
                  seen.insert(path).inserted else { return nil }
            return path
        }
    }

    /// Finder/openFiles 传入的是真实 file URL，而不是 gather:// 深链。
    /// 目录也按菜单导入规则递归展开，避免把 Finder 打开的图片静默丢弃。
    public static func importFiles(
        fromFileURL url: URL
    ) -> [String] {
        importFiles(fromFileURL: url, supportedExtensions: RAWDecoder.supportedExtensions)
    }

    public static func importFiles(
        fromFileURL url: URL,
        supportedExtensions: Set<String>
    ) -> [String] {
        let fileManager = FileManager.default
        let root = url.standardizedFileURL
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var candidates: [String] = []
        if (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            candidates = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )?.compactMap { $0 as? URL }.map(\.path) ?? []
        } else {
            candidates = [root.path]
        }
        var seen = Set<String>()
        return candidates.compactMap { path in
            guard let valid = validatedFilePath(path, supportedExtensions: supportedExtensions),
                  seen.insert(valid).inserted else { return nil }
            return valid
        }
    }

    private static func validatedFilePath(_ rawPath: String, supportedExtensions: Set<String>) -> String? {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let ext = ".\(URL(fileURLWithPath: path).pathExtension.lowercased())"
        guard supportedExtensions.contains(ext), FileManager.default.fileExists(atPath: path) else { return nil }
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return path
    }
}

/// Dock/激活重开时「打开主窗口」的进程级桥（Wave4b / P2-16）。
///
/// applicationShouldHandleReopen 在 delegate 里没有 SwiftUI 环境，无法直接
/// openWindow(id:)；GatherApp 在主窗口内容出现时装一个闭包进来，delegate 在
/// 找不到主窗口（例如第二屏还开着时 ⌘W 关掉了主窗口）时用它恢复主窗口场景。
@MainActor
public final class GatherReopenBridge {
    public static let shared = GatherReopenBridge()

    private var handler: (() -> Void)?

    private init() {}

    /// 由 GatherApp 的窗口内容安装（重复安装 = 覆盖，窗口重建后重新装）。
    public func install(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// 注销（测试或窗口拆除后调用；未注册时静默）。
    public func uninstall() {
        handler = nil
    }

    /// 请求打开主窗口；桥未安装时静默（保持旧行为，不崩）。
    public func reopenMainWindow() {
        handler?()
    }
}

/// Dock 重开决策（Wave4b / P2-16；纯逻辑可单测）。
///
/// 旧实现的 guard !flag else { return true } 让第二屏常驻时 hasVisibleWindows
/// 恒为 true：⌘W 关掉主窗口后点 Dock 直接返回，主窗口永远不回来。新语义只看
/// 「主窗口是否存在」——存在就前置；不存在就请求 SwiftUI 重新打开主窗口场景。
public enum GatherReopenPolicy {
    public enum Action: Equatable, Sendable {
        /// 主窗口还在（可能最小化/被第二屏挡住）：解除最小化并前置。
        case focusMainWindow
        /// 主窗口已不存在：请求 SwiftUI 重开主窗口场景。
        case requestMainWindowOpen
    }

    public static func action(hasMainWindow: Bool, hasVisibleWindows: Bool) -> Action {
        _ = hasVisibleWindows
        return hasMainWindow ? .focusMainWindow : .requestMainWindowOpen
    }
}

@MainActor
public final class GatherAppDelegate: NSObject, NSApplicationDelegate {
    public var onImportFiles: (([String]) -> Void)? {
        didSet { flushPendingDeepLinks() }
    }
    /// Wave3 / task-21：gather://import?session=<id> —— 加入已有工作区。
    public var onImportFilesIntoSession: (([String], String) -> Void)? {
        didSet { flushPendingDeepLinks() }
    }
    /// Wave3 / task-21：gather://session/<id> —— 打开工作区。
    public var onOpenSession: ((String) -> Void)? {
        didSet { flushPendingDeepLinks() }
    }
    /// Wave3 / task-21：gather://photo/<id> —— 打开照片（sessionId 已由宿主解析）。
    public var onOpenPhoto: ((String, String) -> Void)? {
        didSet { flushPendingDeepLinks() }
    }
    /// 把 photoId 解析成所属 sessionId（同步只读查询；nil = 未找到）。
    public var onResolvePhotoSession: ((String) -> String?)?
    /// 深链解析失败（诊断/提示用）。
    public var onDeepLinkError: ((GatherDeepLinkError) -> Void)?
    public var onCaptureOneImport: (() async throws -> [String])?
    /// C1 菜单导入专用回调（携带 capture-one 来源标记与失败提示标签；
    /// 与 onImportFiles 区分，见 GatherApp.importFiles 的 source 参数）。
    public var onCaptureOneImportFiles: (([String]) -> Void)?
    /// 优雅停机回调（GatherApp 装配后挂载；返回前完成写回排空与 SQLite 关闭）。
    public var onPrepareForTermination: (() async -> Void)?

    /// 界面语言源（导入面板等 AppKit 文案在动作发生时取当前值，不缓存字符串）。
    public var languageStore: LanguageStore?

    private var l10n: L10n { languageStore?.l10n ?? Self.bootstrapL10n }
    private static let bootstrapL10n = L10n(language: .zhCN)

    private var pendingImportURLs: [URL] = []
    /// 启动早期到达、handler 尚未挂载的深链（按 URL 原样留存，挂载后重放）。
    private var pendingRouteURLs: [URL] = []

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// 单窗口 scene 的 Dock 重开路径：⌘W 之后点击 Dock 图标时把主窗口带回前台。
    ///
    /// 只认 GatherWindowID.main 派生的窗口（SwiftUI Window scene 的标识形如
    /// main-AppWindow-1），避免把同时打开的「设置」窗当前台。Wave4b / P2-16：
    /// 不再以 hasVisibleWindows 提前返回——第二屏常驻时它恒为 true，会把「主窗口
    /// 已被 ⌘W 关掉」的情况吞掉。主窗口不存在时经 GatherReopenBridge 请求 SwiftUI
    /// 重开主窗口场景；应用内的显式入口仍是「显示主窗口」命令。
    public func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        let main = sender.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(GatherWindowID.main) == true
        })
        switch GatherReopenPolicy.action(
            hasMainWindow: main != nil, hasVisibleWindows: flag
        ) {
        case .focusMainWindow:
            guard let main else { return true }
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
            return true
        case .requestMainWindowOpen:
            GatherReopenBridge.shared.reopenMainWindow()
            return true
        }
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        _ = application
        urls.forEach(handle)
    }

    /// 最近一次处理的深链（V2 审计）：SwiftUI 的 .onOpenURL 与 AppKit 的
    /// application(_:open:) 会对同一次「用 Gather 打开」都回调，而导入不是幂等的
    /// （每次都会新建工作区）→ 同一个 URL 在极短时间内只处理一次。
    private var lastHandledURL: (url: URL, at: Date)?

    public func handle(_ url: URL) {
        if let last = lastHandledURL, last.url == url, Date().timeIntervalSince(last.at) < 1.0 {
            return
        }
        lastHandledURL = (url, Date())
        switch GatherDeepLinkParser.parse(url) {
        case .invalid(let error):
            GatherLogger.log("deep link rejected: \(error.description)", level: .warn)
            onDeepLinkError?(error)
        case .route(let route):
            dispatch(route, url: url)
        }
    }

    private func dispatch(_ route: GatherDeepLinkRoute, url: URL) {
        switch route {
        case .importFiles(let files):
            if let onImportFiles {
                onImportFiles(files)
            } else {
                pendingImportURLs.append(url)
            }
        case .importIntoSession(let sessionId, let files):
            if let onImportFilesIntoSession {
                onImportFilesIntoSession(files, sessionId)
            } else {
                pendingRouteURLs.append(url)
            }
        case .openSession(let sessionId):
            if let onOpenSession {
                onOpenSession(sessionId)
            } else {
                pendingRouteURLs.append(url)
            }
        case .openPhoto(let photoId):
            guard let onOpenPhoto,
                  let sessionId = onResolvePhotoSession?(photoId) else {
                pendingRouteURLs.append(url)
                break
            }
            onOpenPhoto(sessionId, photoId)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// handler 挂载后重放启动早期到达的深链；仍未挂载的保留到下次。
    private func flushPendingDeepLinks() {
        let imports = pendingImportURLs
        pendingImportURLs.removeAll()
        for url in imports {
            if case .route(.importFiles(let files)) = GatherDeepLinkParser.parse(url) {
                onImportFiles?(files)
            }
        }
        let routes = pendingRouteURLs
        pendingRouteURLs.removeAll()
        for url in routes {
            switch GatherDeepLinkParser.parse(url) {
            case .route(let route):
                switch route {
                case .importFiles(let files):
                    if let onImportFiles { onImportFiles(files) } else { pendingImportURLs.append(url) }
                case .importIntoSession(let sessionId, let files):
                    if let onImportFilesIntoSession {
                        onImportFilesIntoSession(files, sessionId)
                    } else { pendingRouteURLs.append(url) }
                case .openSession(let sessionId):
                    if let onOpenSession { onOpenSession(sessionId) } else { pendingRouteURLs.append(url) }
                case .openPhoto(let photoId):
                    if let onOpenPhoto, let sessionId = onResolvePhotoSession?(photoId) {
                        onOpenPhoto(sessionId, photoId)
                    } else { pendingRouteURLs.append(url) }
                }
            case .invalid(let error):
                onDeepLinkError?(error)
            }
        }
    }

    // MARK: - 导入动作（RootShellDependencies typed 闭包调用）

    /// 「导入文件夹…」：宿主负责面板，UI 只消费选择结果（不再 post 通知）。
    func chooseImportFolder() async -> ImportFolderSelection {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = l10n("导入")
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let directory = panel.url else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                // P1-1：这里选择的是**目录**，必须按目录会话创建。
                // 旧实现把目录递归枚举成照片文件再走 files 分支，导致
                // sessions.source_path 为空：之后整目录重扫 noSourcePath、
                // 摄取目标校验永远失败、目录监听不启动。
                // 文件级导入仍由 Finder 拖入 / 打开文件 / deep-link 走 .files。
                continuation.resume(returning: .directory(directory))
            }
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window, completionHandler: handle)
            } else {
                panel.begin(completionHandler: handle)
            }
        }
    }

    /// 「从 Capture One 导入」：错误统一转成错误码 toast（RootView 订阅）。
    func captureOneImport() async {
        guard let onCaptureOneImport else {
            // bootstrap 完成前 onCaptureOneImport 尚未挂载（菜单在启动早期即可
            // 触发），此时不是 Capture One 未配置，而是宿主初始化未完成：
            // 报 GATHER_BOOTSTRAPPING 让 UI 提示"正在初始化，请稍后再试"，
            // 避免误导用户去检查 C1 配置。
            NotificationCenter.default.post(
                name: GatherAppNotification.captureOneError,
                object: GatherErrorCode.GATHER_BOOTSTRAPPING.rawValue
            )
            return
        }
        do {
            let files = try await onCaptureOneImport()
            if files.isEmpty {
                NotificationCenter.default.post(
                    name: GatherAppNotification.captureOneError,
                    object: GatherErrorCode.C1_NO_SELECTED_PHOTOS.rawValue
                )
            } else if let onCaptureOneImportFiles {
                onCaptureOneImportFiles(files)
            } else {
                onImportFiles?(files)
            }
        } catch {
            // 订阅方把载荷当**错误码**查文案表，而 String(describing:) 是英文
            // 诊断文本 → 永远落通用兜底。这里显式转成码：
            // CaptureOneBridgeError.description 本身就是 GatherErrorCode 的 rawValue。
            let code = (error as? CaptureOneBridgeError)?.description
                ?? GatherErrorCode.C1_SCRIPT_FAILED.rawValue
            NotificationCenter.default.post(
                name: GatherAppNotification.captureOneError,
                object: code
            )
        }
    }

    /// ADR-023 落地：退出前优雅停机（停调度/排空写回/关 SQLite），完成后
    /// 再真正终止。回调未挂载（bootstrap 失败）时立即退出。
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let onPrepareForTermination else { return .terminateNow }
        Task { @MainActor in
            await onPrepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
