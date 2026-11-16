import CaptureOnePlugins
import Cocoa

// Gather 的 Capture One「Open With」插件：把 C1 选中文件交给 gather://import。
//
// Wave5 batch8（A2/N4）：URL 显式带 source=capture-one，Host 侧由
// GatherAppDelegate.isCaptureOneSource(_:) 识别并走 C1 语义导入（判断快照 +
// capture-one 来源标 + C1 默认命名），不再是"通用本地导入"。
class GatherLink: COPluginBase, COOpenWithPlugin {
    func openWithActions(withFileInfo info: [String: NSNumber], pluginRole _: COOpenWithPluginRole) throws -> [COPluginAction] {
        let fileCount = info.values.map { $0.intValue }.reduce(0, +)
        guard fileCount > 0 else { return [] }
        return [Self.sendToGatherAction]
    }

    func startOpen(with task: COFileHandlingPluginTask, progress _: @escaping COPluginTaskProgress) throws -> COPluginActionOpenWithResult {
        guard let files = task.files, !files.isEmpty else {
            throw GatherLinkError.noFiles
        }

        var components = URLComponents()
        components.scheme = "gather"
        components.host = "import"
        // Wave5 batch8（A2/N4）：source=capture-one 与 file 并列放在同一 query。
        // Host 的路由形状不变（仍是 .importFiles），source 只决定导入语义；
        // 解析器只读 file item，多余的 source 不影响文件提取（见
        // GatherDeepLink.importFiles 与 GatherAppDelegate.isCaptureOneSource）。
        components.queryItems = [URLQueryItem(name: "source", value: "capture-one")]
            + files.map { URLQueryItem(name: "file", value: $0) }

        guard let url = components.url else {
            throw GatherLinkError.invalidURL
        }

        // 问题 10（第三轮审查）：旧实现忽略 NSWorkspace.open 的返回值、固定
        // status=true 并抑制通知 —— 没有 URL handler 或 Launch Services 拒绝时
        // 也会显示成功。这里如实上报。
        let opened = NSWorkspace.shared.open(url)
        let result = COPluginActionOpenWithResult(status: opened)
        result.suppressNotification = opened
        return result
    }

    func tasks(for action: COPluginAction, forFiles files: [String]) throws -> [COFileHandlingPluginTask] {
        guard action.isEqual(to: Self.sendToGatherAction) else {
            throw GatherLinkError.invalidAction
        }
        return [COFileHandlingPluginTask(action: action, files: files)]
    }

    static let sendToGatherAction: COPluginAction = {
        let action = COPluginAction(displayName: "Send to Gather")
        action.identifier = "com.gather.capture-one-link.importAction"
        // 问题 10：原生应用的 bundle id 是 com.gather.desktop.native（旧的
        // com.gather.desktop 是 Electron 版），优先原生、回退旧版避免无图标。
        let bundleIDs = ["com.gather.desktop.native", "com.gather.desktop"]
        for bundleID in bundleIDs {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            action.image = NSWorkspace.shared.icon(forFile: appURL.path)
                break
            }
        }
        return action
    }()
}

enum GatherLinkError: LocalizedError {
    case noFiles
    case invalidURL
    case invalidAction

    var errorDescription: String? {
        switch self {
        case .noFiles: return "No files provided to send to Gather."
        case .invalidURL: return "Failed to create Gather URL."
        case .invalidAction: return "Invalid action requested."
        }
    }
}
