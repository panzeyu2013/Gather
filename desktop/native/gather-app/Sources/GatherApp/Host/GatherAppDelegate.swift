// desktop/native/gather-app/Sources/GatherApp/Host/GatherAppDelegate.swift
// Phase 4.2：macOS deep-link、菜单和多实例入口。

import AppKit
import GatherCore

public enum GatherAppNotification {
    public static let menuNewWorkspace = Notification.Name("gather.menu.new-workspace")
    public static let menuImportFolder = Notification.Name("gather.menu.import-folder")
    /// 「用户要求导入文件夹」入口通知（F02）：任何 UI 入口（侧栏工具栏按钮、
    /// 空图库的导入按钮…）统一 post 本通知；AppDelegate 收到后打开目录选择器，
    /// 与「文件 ▸ 导入文件夹…」(⌘O) 走同一条流程。
    ///
    /// 与 menuImportFolder 的区别（二者不可混用）：
    /// - importFolderRequest：**还没选目录**，只是一个入口请求；载荷恒为 nil。
    /// - menuImportFolder：**已经选好目录但没有可导入的 RAW 文件**，
    ///   载荷必须是非空的目录 URL，接收方据此打开新建工作区表单。
    ///   旧实现里 UI 入口误用了后者并传 nil，接收方要求 URL 于是静默丢弃，
    ///   表现就是「点了导入没反应」。
    public static let importFolderRequest = Notification.Name("gather.menu.import-folder-request")
    /// 「从 Capture One 导入」入口通知（N08）：SwiftUI Commands 的菜单项与
    /// AppKit 菜单共用同一动作，避免两套菜单各自实现一遍。
    public static let captureOneImportRequest = Notification.Name("gather.menu.capture-one-import-request")
    public static let menuToggleSidebar = Notification.Name("gather.menu.toggle-sidebar")
    public static let menuOpenSettings = Notification.Name("gather.menu.open-settings")
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
    /// 优雅停机回调（GatherApp 装配后挂载；返回前完成写回排空与 SQLite 关闭）。
    public var onPrepareForTermination: (() async -> Void)?

    private var pendingImportURLs: [URL] = []
    private var sidebarVisible = true
    private var sidebarMenuItem: NSMenuItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        installMenu()
        ensureStandardMenus()
        // D11：SwiftUI 会在场景装配/语言变化后重建主菜单，把 installMenu 建的
        // 「文件/编辑」丢掉。窗口每次成为 key 时按缺失项补齐（幂等，几乎零成本）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        // 设置页切语言后重建菜单文案（对齐旧版 setAppLocale 即时 rebuild）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildMenu(_:)),
            name: GatherAppNotification.languageChanged,
            object: nil
        )
        // F02：UI 的「导入文件夹」入口统一请求宿主打开目录选择器。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImportFolderRequest(_:)),
            name: GatherAppNotification.importFolderRequest,
            object: nil
        )
        // N08：SwiftUI Commands 菜单项「从 Capture One 导入」。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCaptureOneImportRequest(_:)),
            name: GatherAppNotification.captureOneImportRequest,
            object: nil
        )
    }

    @objc private func handleCaptureOneImportRequest(_ notification: Notification) {
        _ = notification
        importFromCaptureOne()
    }

    /// 与「文件 ▸ 导入文件夹…」共用同一面板与后续流程（唯一导入入口）。
    @objc private func handleImportFolderRequest(_ notification: Notification) {
        _ = notification
        importFolder()
    }

    /// 语言切换：只切应用语言，**不再重装 AppKit 菜单**。
    ///
    /// V2 审计确认：运行态的菜单是 SwiftUI 场景菜单（.commands），installMenu 装的
    /// NSApp.mainMenu 会被它覆盖；在这里再装一次等于从 SwiftUI 手里「抢回」菜单，
    /// 于是菜单定义在「AppKit 版」与「SwiftUI 版」之间来回跳。菜单文案的语言跟随
    /// 由 GatherApp 层的语言版本号驱动 .commands 重建（GatherAppCommands）。
    @objc private func rebuildMenu(_ notification: Notification) {
        if let language = notification.object as? String {
            GatherLocalization.setAppLanguage(language)
        }
        // 语言变化后 SwiftUI 会用新语言重建 Commands 菜单；先撤掉上一轮补的
        // （标题语言已过期），再按当前主菜单的缺失情况补。
        ensureStandardMenus()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        _ = notification
        ensureStandardMenus()
        // A8（审计 4）：SwiftUI 可能在场景装配/Commands 重建时再替换一次主菜单，
        // 把刚补的项丢掉。等一轮 runloop 后再核一次（幂等，无重复注入风险）。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            self.ensureStandardMenus()
        }
    }

    /// 已由本类补进主菜单的项（语言切换时先撤再补，避免同义菜单叠加）。
    private var injectedMenus: [NSMenuItem] = []

    /// D11：标准菜单兜底合并（幂等）。
    ///
    /// 运行态观察到主菜单只有 Gather／显示／窗口／帮助，文件与编辑整块缺失、⌘N/⌘O
    /// 无响应：SwiftUI 用自己构建的主菜单替换 NSApp.mainMenu，installMenu 建的那份
    /// 在运行态消失。谁在什么时机覆盖谁取决于 SwiftUI 版本，不能只靠「保留一个构建方」
    /// 的假设——这里改为**按缺失项补齐**：主菜单没有「文件」/「编辑」时补一份，
    /// 动作复用与工具栏/深链相同的通知与 delegate selector（不新增第二条实现），
    /// 已有则完全不动（SwiftUI 的命令菜单优先）。
    private func ensureStandardMenus() {
        for item in injectedMenus {
            item.menu?.removeItem(item)
        }
        injectedMenus.removeAll()
        guard let main = NSApp.mainMenu else { return }
        // 去重不能只看**当前语言**的标题：语言切换瞬间或双语菜单并存时，SwiftUI 侧
        // 的菜单可能仍叫另一个语言的名字，只按本地化标题判断会补出第二份「文件」
        // ——两个 ⌘N/⌘O 同时注册（快捷键冲突，行为不可预测）。
        // 因此同时按「已知双语标题」与「是否已含同动作项」两个条件判定。
        // A7（审计 4）：探针必须与**语言**解耦。SwiftUI 的标准菜单标题跟系统/bundle
        // 语言，而 GatherLocalization 跟应用内 ui_language，两者不一致时按标题判定
        // 会误判「没有文件菜单」→ 每次窗口成为 key 都再注入一份，最终两套 文件/编辑
        // 和两套 ⌘N/⌘O/⌘W。这里改为语义判定：只要已有「⌘N 新建」的菜单就认为文件菜单存在。
        let existing = main.items.compactMap(\.submenu)
        let hasFileMenu = existing.contains {
            menuContainsKeyEquivalent($0, "n", [.command])
                || menuContainsAction($0, #selector(newWorkspace))
                || menuContainsAction($0, #selector(importFolder))
        }
        let hasEditMenu = existing.contains {
            ["编辑", "Edit"].contains($0.title) || menuContainsAction($0, Selector(("undo:")))
        }
        var insertIndex = 1
        if !hasFileMenu {
            let item = NSMenuItem(title: GatherLocalization.l("文件"), action: nil, keyEquivalent: "")
            item.submenu = makeStandardFileMenu()
            main.insertItem(item, at: min(insertIndex, main.items.count))
            injectedMenus.append(item)
            insertIndex += 1
        }
        if !hasEditMenu {
            let item = NSMenuItem(title: GatherLocalization.l("编辑"), action: nil, keyEquivalent: "")
            item.submenu = makeStandardEditMenu()
            main.insertItem(item, at: min(insertIndex, main.items.count))
            injectedMenus.append(item)
        }
    }

    /// 菜单（含子菜单）里是否已有某个快捷键——与语言无关的存在性探针（A7）。
    private func menuContainsKeyEquivalent(_ menu: NSMenu, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        for item in menu.items {
            if item.keyEquivalent == key, item.keyEquivalentModifierMask.contains(modifiers) { return true }
            if let submenu = item.submenu,
               menuContainsKeyEquivalent(submenu, key, modifiers) { return true }
        }
        return false
    }

    /// 菜单（含子菜单）里是否已有某个动作——用于跨语言去重。
    private func menuContainsAction(_ menu: NSMenu, _ action: Selector) -> Bool {
        for item in menu.items {
            if item.action == action { return true }
            if let submenu = item.submenu, menuContainsAction(submenu, action) { return true }
        }
        return false
    }

    /// 文件菜单：与 GatherAppCommands 的同名项走同一条通知/选择器路径。
    private func makeStandardFileMenu() -> NSMenu {
        let menu = NSMenu(title: GatherLocalization.l("文件"))
        menu.addItem(NSMenuItem(title: GatherLocalization.l("新建工作区"), action: #selector(newWorkspace), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: GatherLocalization.l("导入文件夹"), action: #selector(importFolder), keyEquivalent: "o"))
        let captureOne = NSMenuItem(title: GatherLocalization.l("从 Capture One 导入"), action: #selector(importFromCaptureOne), keyEquivalent: "i")
        captureOne.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(captureOne)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: GatherLocalization.l("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        return menu
    }

    /// 编辑菜单：文本编辑标准动作（响应链），缺了它输入框连 ⌘C/⌘V 都没有。
    private func makeStandardEditMenu() -> NSMenu {
        let menu = NSMenu(title: GatherLocalization.l("编辑"))
        menu.addItem(NSMenuItem(title: GatherLocalization.l("撤销"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: GatherLocalization.l("重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: GatherLocalization.l("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: GatherLocalization.l("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: GatherLocalization.l("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: GatherLocalization.l("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        return menu
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
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
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: GatherLocalization.l("关于 Gather"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        // 原生设置窗口：动作经通知交给 SwiftUI 的 openSettings 环境动作
        //（macOS 14+ 公开 API）。showSettingsWindow: 是 SwiftUI 私有 selector，
        // 不在 AppKit SDK 中，不使用。
        appMenu.addItem(NSMenuItem(
            title: GatherLocalization.l("设置…"),
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        let services = NSMenuItem(title: GatherLocalization.l("服务"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: GatherLocalization.l("隐藏 Gather"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: GatherLocalization.l("隐藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        let showAll = NSMenuItem(title: GatherLocalization.l("显示全部"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "H")
        showAll.keyEquivalentModifierMask = [.option]
        appMenu.addItem(showAll)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: GatherLocalization.l("退出 Gather"), action: #selector(quit), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileMenu = NSMenu(title: GatherLocalization.l("文件"))
        fileMenu.addItem(NSMenuItem(title: GatherLocalization.l("新建工作区"), action: #selector(newWorkspace), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: GatherLocalization.l("导入文件夹"), action: #selector(importFolder), keyEquivalent: "o"))
        let captureOneItem = NSMenuItem(
            title: GatherLocalization.l("从 Capture One 导入"),
            action: #selector(importFromCaptureOne),
            keyEquivalent: "i"
        )
        captureOneItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(captureOneItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: GatherLocalization.l("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let fileItem = NSMenuItem(title: GatherLocalization.l("文件"), action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        // 编辑菜单（对齐旧版 menu.ts：文本编辑快捷键全套）。
        let editMenu = NSMenu(title: GatherLocalization.l("编辑"))
        editMenu.addItem(NSMenuItem(title: GatherLocalization.l("撤销"), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: GatherLocalization.l("重做"), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: GatherLocalization.l("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: GatherLocalization.l("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: GatherLocalization.l("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: GatherLocalization.l("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: GatherLocalization.l("编辑"), action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let viewMenu = NSMenu(title: GatherLocalization.l("显示"))
        let sidebarItem = NSMenuItem(
            title: GatherLocalization.l(sidebarVisible ? "隐藏侧栏" : "显示侧栏"),
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarItem.keyEquivalentModifierMask = [.option, .command]
        sidebarMenuItem = sidebarItem
        viewMenu.addItem(sidebarItem)
        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(title: GatherLocalization.l("进入全屏"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreenItem)
        let viewItem = NSMenuItem(title: GatherLocalization.l("显示"), action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        // 窗口菜单（对齐旧版：最小化/缩放/全部置于前台）。
        let windowMenu = NSMenu(title: GatherLocalization.l("窗口"))
        windowMenu.addItem(NSMenuItem(title: GatherLocalization.l("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: GatherLocalization.l("缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: GatherLocalization.l("全部置于前台"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        let windowItem = NSMenuItem(title: GatherLocalization.l("窗口"), action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)

        let helpMenu = NSMenu(title: GatherLocalization.l("帮助"))
        helpMenu.addItem(NSMenuItem(title: GatherLocalization.l("Gather 帮助"), action: #selector(openHelp), keyEquivalent: ""))
        let helpItem = NSMenuItem(title: GatherLocalization.l("帮助"), action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)

        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    @objc private func newWorkspace() {
        NotificationCenter.default.post(name: GatherAppNotification.menuNewWorkspace, object: nil)
    }

    /// ⌘,：转发给 SwiftUI 环境里的 openSettings（由 RootView 订阅并调用）。
    @objc private func openSettings() {
        NotificationCenter.default.post(name: GatherAppNotification.menuOpenSettings, object: nil)
    }

    @objc private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = GatherLocalization.l("导入")
        // 非阻塞：以 sheet 形式挂在当前窗口上，不再用 runModal 卡住主线程
        // 与整个应用的事件循环。
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
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
                self?.onImportFiles?(files.map(\.path))
            } else {
                NotificationCenter.default.post(name: GatherAppNotification.menuImportFolder, object: directory)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        sidebarVisible.toggle()
        sidebarMenuItem?.title = GatherLocalization.l(sidebarVisible ? "隐藏侧栏" : "显示侧栏")
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
                // 用枚举而不是裸字符串：文案表有一条「不得含枚举之外的码」的契约测试。
                object: GatherErrorCode.GATHER_BOOTSTRAPPING.rawValue
            )
            return
        }
        Task { @MainActor in
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
                // F 报告：订阅方把载荷当**错误码**查文案表，而 String(describing:)
                // 是英文诊断文本 → 永远落通用兜底。这里显式转成码：
                // CaptureOneBridgeError.description 本身就是 GatherErrorCode 的 rawValue。
                let code = (error as? CaptureOneBridgeError)?.description
                    ?? GatherErrorCode.C1_SCRIPT_FAILED.rawValue
                NotificationCenter.default.post(
                    name: GatherAppNotification.captureOneError,
                    object: code
                )
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// 帮助菜单：打开项目主页（仓库 README 与使用文档）。
    @objc private func openHelp() {
        if let url = URL(string: "https://github.com/panzeyu2013/Gather") {
            NSWorkspace.shared.open(url)
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
