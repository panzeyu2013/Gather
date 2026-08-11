// Capture One 宿主桥：只负责显式用户操作，不自动读取、刷新或清理元数据。
// AppleScript 错误在这里归一化为稳定错误码，页面才能在 reload 成功后才放行
// confirm_sync/cleanup。
import Foundation
import GatherCore

private final class CaptureOneCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

public enum CaptureOneBridgeError: Error, Equatable, CustomStringConvertible, Sendable {
    case notRunning
    case noDocument
    case notAuthorized
    case timedOut
    case scriptFailed(String)

    public var description: String {
        switch self {
        case .notRunning: return "C1_NOT_RUNNING"
        case .noDocument: return "C1_NO_DOCUMENT"
        case .notAuthorized: return "C1_NOT_AUTHORIZED"
        case .timedOut: return "C1_SCRIPT_TIMEOUT"
        case .scriptFailed: return "C1_SCRIPT_FAILED"
        }
    }
}

public final class CaptureOneBridge: @unchecked Sendable {
    private let recordReloadAck: (String) throws -> Void

    public init(recordReloadAck: @escaping (String) throws -> Void = { _ in }) {
        self.recordReloadAck = recordReloadAck
    }

    public convenience init(router: CommandRouter) {
        self.init(recordReloadAck: { sessionId in
            guard let router = router as? SessionCommandRouter else { return }
            try router.recordCaptureOneReloadAck(sessionId: sessionId)
        })
    }

    public func selectedPhotoPaths() async throws -> [String] {
        let appName = try await captureOneApplicationName()
        let output = try await runAppleScript(Self.selectedVariantsScript(appName: appName))
        return output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
    }

    public func reloadMetadata(sessionId: String) async throws {
        let appName = try await captureOneApplicationName()
        _ = try await runAppleScript(Self.reloadMetadataScript(appName: appName))
        // C1 需要一个短暂窗口读取 XMP；只有脚本成功才写入 durable ack。
        try await Task.sleep(for: .milliseconds(500))
        try recordReloadAck(sessionId)
    }

    public func checkHealth() async -> Result<String, CaptureOneBridgeError> {
        do {
            return .success(try await captureOneApplicationName())
        } catch let error as CaptureOneBridgeError {
            return .failure(error)
        } catch {
            return .failure(.scriptFailed(String(describing: error)))
        }
    }

    private func captureOneApplicationName() async throws -> String {
        do {
            let output = try await runAppleScript(
                "tell application \"System Events\" to get name of every process whose name contains \"Capture One\""
            )
            guard let name = output
                .split(separator: ",")
                .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) else {
                throw CaptureOneBridgeError.notRunning
            }
            guard Self.isSafeApplicationName(name) else {
                throw CaptureOneBridgeError.scriptFailed("unsafe application name")
            }
            return name
        } catch let error as CaptureOneBridgeError {
            throw error
        } catch {
            throw Self.classify(error)
        }
    }

    private func runAppleScript(_ script: String, timeout: TimeInterval = 15) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let completion = CaptureOneCompletionGate(continuation: continuation)

            process.terminationHandler = { process in
                let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    completion.finish(.success(stdout))
                } else {
                    completion.finish(.failure(Self.classifyMessage(stderr)))
                }
            }

            do {
                try process.run()
            } catch {
                completion.finish(.failure(CaptureOneBridgeError.scriptFailed(error.localizedDescription)))
                return
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                completion.finish(.failure(CaptureOneBridgeError.timedOut))
            }
        }
    }

    private static func classify(_ error: Error) -> CaptureOneBridgeError {
        classifyMessage(String(describing: error))
    }

    private static func classifyMessage(_ message: String) -> CaptureOneBridgeError {
        let lowercased = message.lowercased()
        if lowercased.contains("-1743") || lowercased.contains("not authorized") || lowercased.contains("not authorised") {
            return .notAuthorized
        }
        if lowercased.contains("no document") || lowercased.contains("no current document") {
            return .noDocument
        }
        if lowercased.contains("-1712") || lowercased.contains("timed out") {
            return .timedOut
        }
        return .scriptFailed(message.isEmpty ? "osascript failed" : message)
    }

    private static func isSafeApplicationName(_ name: String) -> Bool {
        name.range(of: #"^Capture One( [A-Za-z0-9 ._+()$-]*)?$"#, options: .regularExpression) != nil
    }

    private static func selectedVariantsScript(appName: String) -> String {
        """
        tell application "\(appName)"
          try
            set output to ""
            set selectedImages to selected variants of current document
            repeat with img in selectedImages
              set output to output & (path of img as text) & linefeed
            end repeat
            return output
          on error
            return ""
          end try
        end tell
        """
    }

    private static func reloadMetadataScript(appName: String) -> String {
        """
        tell application "\(appName)"
          reload metadata of current document
        end tell
        """
    }
}
