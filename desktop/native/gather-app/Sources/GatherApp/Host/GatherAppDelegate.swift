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
}

public enum GatherDeepLink {
    /// 深链格式：gather://import?file=<path>，每个 file
    /// 单独校验扩展名/文件存在性，重复项去重；URLComponents 已经完成一次
    /// percent decode，不能再解码，否则文件名中的字面 % 会损坏。
    public static func importFiles(from url: URL) -> [String] {
        importFiles(from: url, supportedExtensions: GatherCoreImageExtensions.all)
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
        importFiles(fromFileURL: url, supportedExtensions: GatherCoreImageExtensions.all)
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

private enum GatherCoreImageExtensions {
    static let all: Set<String> = [
        ".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp",
        ".cr2", ".cr3", ".nef", ".nrw", ".arw", ".raf", ".dng",
        ".orf", ".rw2", ".pef", ".srw", ".srf", ".x3f", ".3fr",
        ".fff", ".mef", ".mos", ".iiq", ".eip", ".erf", ".kdc", ".mrw",
    ]
}

@MainActor
public final class GatherAppDelegate: NSObject, NSApplicationDelegate {
    public var onImportFiles: (([String]) -> Void)? {
        didSet { flushPendingImports() }
    }
    public var onCaptureOneImport: (() async throws -> [String])?

    private var pendingImportURLs: [URL] = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
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
        let isChinese = Locale.current.language.languageCode?.identifier == "zh"
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: isChinese ? "关于 Gather" : "About Gather", action: nil, keyEquivalent: ""))
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
        let fileItem = NSMenuItem(title: isChinese ? "文件" : "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        let viewMenu = NSMenu(title: isChinese ? "显示" : "View")
        viewMenu.addItem(NSMenuItem(title: isChinese ? "切换侧栏" : "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "0"))
        let viewItem = NSMenuItem(title: isChinese ? "显示" : "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
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
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let urls = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []
        let files = urls.filter { url in
            let ext = ".\(url.pathExtension.lowercased())"
            guard GatherCoreImageExtensions.all.contains(ext),
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
            NotificationCenter.default.post(
                name: GatherAppNotification.captureOneError,
                object: "C1_NOT_CONFIGURED"
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
