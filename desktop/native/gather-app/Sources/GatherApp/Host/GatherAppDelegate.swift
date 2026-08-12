// desktop/native/gather-app/Sources/GatherApp/Host/GatherAppDelegate.swift
// Phase 4.2：macOS deep-link、菜单和多实例入口。

import AppKit
import GatherCore

public enum GatherAppNotification {
    public static let deepLink = Notification.Name("gather.deep-link")
    public static let menuNewWorkspace = Notification.Name("gather.menu.new-workspace")
    public static let menuImportFolder = Notification.Name("gather.menu.import-folder")
    public static let menuToggleSidebar = Notification.Name("gather.menu.toggle-sidebar")
    public static let captureOneError = Notification.Name("gather.capture-one.error")
    /// 设置页语言切换后广播（settings.set_language 命令处理器发出），
    /// AppDelegate 收到后按新语言重建菜单（对齐旧版 setAppLocale 即时 rebuild）。
    public static let languageChanged = Notification.Name("gather.menu.language-changed")
    /// 导入成功后由 GatherApp.importFiles 统一 post（菜单/C1/deep-link 共用），
    /// RootView 订阅后导航到新工作区并 Toast 失败计数。
    public static let importCompleted = Notification.Name("gather.import.completed")
}

/// importCompleted 通知的 userInfo 键名（契约：键名/类型以此为准，勿改）。
public enum GatherAppImportUserInfoKey {
    /// String：新创建的工作区 id。
    public static let sessionId = "sessionId"
    /// Int：导入失败的（无法读尺寸）文件数。
    public static let failedCount = "failedCount"
    /// Int：成功入库的照片数。
    public static let addedCount = "addedCount"
    /// String：失败提示的来源标签（"Capture One 文件"/"文件"），对齐旧版
    /// importFailureMessage 的 source 参数。
    public static let sourceLabel = "sourceLabel"
    /// String：失败文件示例（前 3 个文件名，顿号连接）。
    public static let examples = "examples"
}

/// 系统语言是否为中文：installMenu 的菜单文案与 importFolder 的打开面板按钮共用。
private var appUsesChinese: Bool {
    Locale.current.language.languageCode?.identifier == "zh"
}

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

@MainActor
public final class GatherAppDelegate: NSObject, NSApplicationDelegate {
    public var onImportFiles: (([String]) -> Void)? {
        didSet { flushPendingImports() }
    }
    public var onCaptureOneImport: (() async throws -> [String])?
    /// C1 菜单导入专用回调（携带 capture-one 来源标记与失败提示标签；
    /// 与 onImportFiles 区分，见 GatherApp.importFiles 的 source 参数）。
    public var onCaptureOneImportFiles: (([String]) -> Void)?

    private var pendingImportURLs: [URL] = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        installMenu()
        // 设置页切语言后重建菜单文案（对齐旧版 setAppLocale 即时 rebuild）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildMenu),
            name: GatherAppNotification.languageChanged,
            object: nil
        )
    }

    @objc private func rebuildMenu() {
        installMenu()
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        _ = application
        urls.forEach(handle)
    }

    public func application(_ application: NSApplication, openFiles filenames: [String]) {
        _ = application
        for filename in filenames { handle(URL(fileURLWithPath: filename)) }
        NSApp.reply(toOpenOrPrint: .success)
    }

    public func handle(_ url: URL) {
        let files = GatherDeepLink.importFiles(from: url)
        guard !files.isEmpty else { return }
        if let onImportFiles {
            onImportFiles(files)
        } else {
            pendingImportURLs.append(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func flushPendingImports() {
        guard let onImportFiles else { return }
        let urls = pendingImportURLs
        pendingImportURLs.removeAll()
        for url in urls {
            let files = GatherDeepLink.importFiles(from: url)
            if !files.isEmpty { onImportFiles(files) }
        }
    }

    private func installMenu() {
        let isChinese = appUsesChinese
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: isChinese ? "关于 Gather" : "About Gather", action: nil, keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: isChinese ? "隐藏 Gather" : "Hide Gather", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: isChinese ? "退出 Gather" : "Quit Gather", action: #selector(quit), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileMenu = NSMenu(title: isChinese ? "文件" : "File")
        fileMenu.addItem(NSMenuItem(title: isChinese ? "新建工作区" : "New Workspace", action: #selector(newWorkspace), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: isChinese ? "导入文件夹" : "Import Folder", action: #selector(importFolder), keyEquivalent: "o"))
        let captureOneItem = NSMenuItem(
            title: isChinese ? "从 Capture One 导入" : "Import from Capture One",
            action: #selector(importFromCaptureOne),
            keyEquivalent: "i"
        )
        captureOneItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(captureOneItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: isChinese ? "关闭窗口" : "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let fileItem = NSMenuItem(title: isChinese ? "文件" : "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        // 编辑菜单（对齐旧版 menu.ts：文本编辑快捷键全套）。
        let editMenu = NSMenu(title: isChinese ? "编辑" : "Edit")
        editMenu.addItem(NSMenuItem(title: isChinese ? "撤销" : "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: isChinese ? "重做" : "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: isChinese ? "剪切" : "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: isChinese ? "复制" : "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: isChinese ? "粘贴" : "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: isChinese ? "全选" : "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: isChinese ? "编辑" : "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let viewMenu = NSMenu(title: isChinese ? "显示" : "View")
        viewMenu.addItem(NSMenuItem(title: isChinese ? "切换侧栏" : "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "0"))
        let viewItem = NSMenuItem(title: isChinese ? "显示" : "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        // 窗口菜单（对齐旧版：最小化/缩放/全部置于前台）。
        let windowMenu = NSMenu(title: isChinese ? "窗口" : "Window")
        windowMenu.addItem(NSMenuItem(title: isChinese ? "最小化" : "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: isChinese ? "缩放" : "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: isChinese ? "全部置于前台" : "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        let windowItem = NSMenuItem(title: isChinese ? "窗口" : "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)

        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    @objc private func newWorkspace() {
        NotificationCenter.default.post(name: GatherAppNotification.menuNewWorkspace, object: nil)
    }

    @objc private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = appUsesChinese ? "导入" : "Import"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let urls = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []
        let files = urls.filter { url in
            let ext = ".\(url.pathExtension.lowercased())"
            guard RAWDecoder.supportedExtensions.contains(ext),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
            return values.isRegularFile == true
        }
        if !files.isEmpty {
            onImportFiles?(files.map(\.path))
        } else {
            NotificationCenter.default.post(name: GatherAppNotification.menuImportFolder, object: directory)
        }
    }

    @objc private func toggleSidebar() {
        NotificationCenter.default.post(name: GatherAppNotification.menuToggleSidebar, object: nil)
    }

    @objc private func importFromCaptureOne() {
        guard let onCaptureOneImport else {
            // bootstrap 完成前 onCaptureOneImport 尚未挂载（菜单在启动早期即可
            // 触发），此时不是 Capture One 未配置，而是宿主初始化未完成：
            // 报 GATHER_BOOTSTRAPPING 让 UI 提示"正在初始化，请稍后再试"，
            // 避免误导用户去检查 C1 配置。
            NotificationCenter.default.post(
                name: GatherAppNotification.captureOneError,
                object: "GATHER_BOOTSTRAPPING"
            )
            return
        }
        Task { @MainActor in
            do {
                let files = try await onCaptureOneImport()
                if files.isEmpty {
                    NotificationCenter.default.post(
                        name: GatherAppNotification.captureOneError,
                        object: "C1_NO_SELECTED_PHOTOS"
                    )
                } else if let onCaptureOneImportFiles {
                    onCaptureOneImportFiles(files)
                } else {
                    onImportFiles?(files)
                }
            } catch {
                NotificationCenter.default.post(
                    name: GatherAppNotification.captureOneError,
                    object: String(describing: error)
                )
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
