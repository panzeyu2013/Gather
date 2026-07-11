import CaptureOnePlugins
import Cocoa

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
        components.queryItems = files.map {
            URLQueryItem(name: "file", value: $0)
        }

        guard let url = components.url else {
            throw GatherLinkError.invalidURL
        }

        NSWorkspace.shared.open(url)

        let result = COPluginActionOpenWithResult(status: true)
        result.suppressNotification = true
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
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.gather.desktop") {
            action.image = NSWorkspace.shared.icon(forFile: appURL.path)
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
