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

    /// 界面语言源（导入面板等 AppKit 文案在动作发生时取当前值，不缓存字符串）。
    public var languageStore: LanguageStore?

    private var l10n: L10n { languageStore?.l10n ?? Self.bootstrapL10n }
    private static let bootstrapL10n = L10n(language: .zhCN)

    private var pendingImportURLs: [URL] = []

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
                if files.isEmpty {
                    continuation.resume(returning: .directory(directory))
                } else {
                    continuation.resume(returning: .files(files.map(\.path)))
                }
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
