// Capture One 宿主桥：只负责显式用户操作，不自动读取、刷新或清理元数据。
// AppleScript 错误在这里归一化为稳定错误码，页面才能在 reload 成功后才放行
// confirm_sync/cleanup。
import Foundation
import GatherProtocol

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

// Cut 3 / 3b-0：CaptureOneBridgeError / C1PreflightStatus / CaptureOneBridging
// 已上移到 GatherProtocol（Protocol/C1.swift）；本文件只保留 AppleScript /
// 子进程实现与静态 shared 注册，并声明对协议的能力面 conformance。

/// `shared` 的锁保护存储（Swift 6：`nonisolated` 全局可变状态非法 #MutableGlobalVariable）。
/// `@unchecked Sendable` 的依据：唯一可变状态 `value` 只在 `lock` 临界区内读写。
private final class CaptureOneBridgeStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CaptureOneBridge?

    var current: CaptureOneBridge? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
}

public final class CaptureOneBridge: CaptureOneBridging, @unchecked Sendable {
    private static let sharedStorage = CaptureOneBridgeStorage()

    /// 页面（Dashboard 新建工作区）未显式注入桥时取全局实例；bootstrap 注册。
    /// 读写经 sharedStorage 的锁（见上），公开语义与原先的静态存储属性一致。
    public static var shared: CaptureOneBridge? {
        get { sharedStorage.current }
        set { sharedStorage.current = newValue }
    }

    private let recordReloadAck: (String) throws -> Void

    /// - Parameter recordReloadAck：Capture One 脚本成功后的持久 ack 写入。
    ///   生产由组合根的 AppRuntime.recordReloadAck 提供（同一 SessionRepo
    ///   写库语义）；测试可注入空实现/闭包。B8.3b-2b 起不再接收命令面。
    public init(recordReloadAck: @escaping (String) throws -> Void = { _ in }) {
        self.recordReloadAck = recordReloadAck
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

    /// TS: c1Health（c1-health.ts）—— 一次完成四层预检，失败即回退不抛异常：
    /// 1) reachable + appRunning（System Events 进程探测）；
    /// 2) documentOpen + automationAuthorized（向 Capture One 发 Apple Event，
    ///    超时/拒绝归到 automationAuthorized=false，其余应用侧错误视为
    ///    事件已送达 → automationAuthorized=true 且 documentOpen=false）。
    public func preflight() async -> C1PreflightStatus {
        var status = C1PreflightStatus(
            reachable: false,
            appRunning: false,
            automationAuthorized: false,
            documentOpen: false,
            timedOut: false
        )
        let probeOutput: String
        do {
            probeOutput = try await runAppleScript(Self.processProbeScript, timeout: Self.preflightProbeTimeout)
        } catch let error as CaptureOneBridgeError {
            if error == .timedOut { status.timedOut = true }
            return status
        } catch {
            return status
        }
        status.reachable = true
        let names = probeOutput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = names.first, Self.isSafeApplicationName(first) else { return status }
        status.appRunning = true
        status.appName = first
        do {
            _ = try await runAppleScript(Self.documentProbeScript(appName: first), timeout: Self.preflightProbeTimeout)
            status.automationAuthorized = true
            status.documentOpen = true
        } catch let error as CaptureOneBridgeError {
            switch error {
            case .timedOut:
                // 应用挂起或 TCC 弹窗待决：自动化通道不可用，绝不断言已授权。
                status.timedOut = true
                status.automationAuthorized = false
            case .notAuthorized:
                status.automationAuthorized = false
            default:
                // 事件已送达应用（TCC 已通过）：失败原因是缺文档或应用侧错误。
                status.automationAuthorized = true
                status.documentOpen = false
            }
        } catch {
            status.automationAuthorized = true
            status.documentOpen = false
        }
        return status
    }

    private func captureOneApplicationName() async throws -> String {
        do {
            let output = try await runAppleScript(Self.processProbeScript)
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
        try await runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: timeout)
    }

    /// 运行子进程并返回 stdout（internal：问题 7 的验收测试直接驱动大输出场景）。
    func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 15
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let completion = CaptureOneCompletionGate(continuation: continuation)

            // 问题 7（第三轮审查）：旧实现只在 terminationHandler 里读管道 ——
            // 子进程输出超过管道容量（约 64KB）时会写阻塞、永远不退出，handler
            // 也就永远不会执行。这里在 run 之前就并行持续排空两条管道。
            let drain = PipeDrainBuffer()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                drain.appendStdout(chunk)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                drain.appendStderr(chunk)
            }

            process.terminationHandler = { process in
                // 子进程已退出：摘掉 handler 并把剩余字节读干净。
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                drain.appendStdout(outputPipe.fileHandleForReading.readDataToEndOfFile())
                drain.appendStderr(errorPipe.fileHandleForReading.readDataToEndOfFile())
                let stdout = String(data: drain.stdout(), encoding: .utf8) ?? ""
                let stderr = String(data: drain.stderr(), encoding: .utf8) ?? ""
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

    /// 预检探针是诊断而非用户操作：保持快速（TS PROBE_TIMEOUT_MS = 3000）。
    private static let preflightProbeTimeout: TimeInterval = 3

    /// 与 TS PROCESS_PROBE_SCRIPT 同一形状的 System Events 进程探测脚本。
    private static let processProbeScript =
        "tell application \"System Events\" to get name of every process whose name contains \"Capture One\""

    /// TS buildDocumentProbeScript：发 Apple Event 同时探测自动化权限与文档。
    /// 共享实现：CaptureOneBridge 预检与设置页 C1 健康检查共用同一脚本文本。
    public static func documentProbeScript(appName: String) -> String {
        """
        tell application "\(appName)"
          get name of current document
        end tell
        """
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


/// 管道排空缓冲（问题 7）：readabilityHandler 与 terminationHandler 都会写入，
/// 用锁保护的引用盒子承载（Swift 6 不允许闭包捕获可变 var）。
final class PipeDrainBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); out.append(data); lock.unlock()
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); err.append(data); lock.unlock()
    }

    func stdout() -> Data {
        lock.lock(); defer { lock.unlock() }; return out
    }

    func stderr() -> Data {
        lock.lock(); defer { lock.unlock() }; return err
    }
}
