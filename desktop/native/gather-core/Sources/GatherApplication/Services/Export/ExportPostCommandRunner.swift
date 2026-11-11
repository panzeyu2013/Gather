// desktop/native/gather-core/Sources/GatherApplication/Services/Export/ExportPostCommandRunner.swift
// Wave3 / task-21：导出后命令钩子（runner / 报告层，不进 ExportService 内部）。
//
// 契约：
// - 用户配置的是一段**命令模板**（settings.export_post_command），占位符
//   {dir}=输出根目录、{session}=会话 id、{manifest}=本次 manifest 路径；
// - 模板按空白拆成参数数组执行，**绝不经过 shell**：占位符替换发生在拆分之后，
//   每个 token 原样成为 argv 元素，不存在引号/管道/重定向注入面；
// - 有超时（settings.export_post_command_timeout_seconds，钳制 1…600 秒）；
// - 失败/超时/不可执行只产生 OutputPostCommandOutcome，不抛错、不改交付结果；
//   调用方把结果写回 OutputRunSummary.postCommand 并回写 manifest。
//
// 为什么放在 GatherApplication/Services/Export：它属于导出域，但不属于
// ExportService（交付编排）本身；LiveExportAPI 在整套交付返回后调用。
import Foundation
import GatherProtocol
#if canImport(Darwin)
import Darwin
#endif

/// 导出后命令钩子的配置（从 settings 读出后由组合根注入）。
public struct ExportPostCommandConfiguration: Equatable, Sendable {
    public var template: String
    public var timeoutSeconds: Double

    public init(template: String, timeoutSeconds: Double = 30) {
        self.template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let finite = timeoutSeconds.isFinite ? timeoutSeconds : 30
        self.timeoutSeconds = max(1, min(600, finite))
    }
}

/// 组合根注入的钩子：读配置 + 执行 + 回写 manifest（LiveExportAPI 只调 runIfConfigured）。
public struct ExportPostCommandHook: Sendable {
    public var configuration: @Sendable () -> ExportPostCommandConfiguration?

    public init(configuration: @escaping @Sendable () -> ExportPostCommandConfiguration?) {
        self.configuration = configuration
    }

    /// 未配置 → nil（不产生任何副作用）；已配置 → 执行并返回结果（manifest 回写 best-effort）。
    public func runIfConfigured(
        sessionId: String,
        destinationRoot: String,
        manifestPath: String
    ) async -> OutputPostCommandOutcome? {
        guard let configuration = configuration() else { return nil }
        let outcome = await ExportPostCommandRunner.run(
            configuration, sessionId: sessionId,
            destinationRoot: destinationRoot, manifestPath: manifestPath)
        if !ExportPostCommandRunner.attach(outcome, toManifestAt: manifestPath) {
            GatherLogger.log(
                "export post-command: manifest attach failed (path=\(manifestPath))", level: .warn)
        }
        GatherLogger.log(
            "export post-command: exit=\(outcome.exitCode.map(String.init) ?? "-")"
                + " timedOut=\(outcome.timedOut) durationMs=\(outcome.durationMilliseconds)",
            level: outcome.exitCode == 0 && !outcome.timedOut ? .info : .warn)
        return outcome
    }
}

/// 命令模板展开与执行。
public enum ExportPostCommandRunner {
    /// 输出尾部最多保留的字节数（审计够用，不把整段日志塞进 manifest）。
    public static let maxOutputBytes = 4096
    public static let defaultExecutableLookup = "/usr/bin/env"

    // MARK: - 模板

    /// 展开模板为 argv。空模板（或展开后首 token 为空）返回 nil。
    ///
    /// 拆分先于替换：{dir} 等值里即使含空格/引号，也只落在单个 argv 元素内。
    public static func arguments(
        template: String,
        sessionId: String,
        destinationRoot: String,
        manifestPath: String
    ) -> [String]? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        var expanded = tokens.map {
            replacePlaceholders(
                in: $0, sessionId: sessionId,
                destinationRoot: destinationRoot, manifestPath: manifestPath)
        }
        expanded.removeAll { $0.isEmpty }
        return expanded.isEmpty ? nil : expanded
    }

    /// 单 token 占位符替换（纯函数，测试直接驱动）。
    public static func replacePlaceholders(
        in token: String,
        sessionId: String,
        destinationRoot: String,
        manifestPath: String
    ) -> String {
        token
            .replacingOccurrences(of: "{dir}", with: destinationRoot)
            .replacingOccurrences(of: "{session}", with: sessionId)
            .replacingOccurrences(of: "{manifest}", with: manifestPath)
    }

    // MARK: - 执行

    /// 执行钩子；永不抛错（所有失败都折叠成 Outcome）。
    public static func run(
        _ configuration: ExportPostCommandConfiguration,
        sessionId: String,
        destinationRoot: String,
        manifestPath: String
    ) async -> OutputPostCommandOutcome {
        await Task.detached(priority: .utility) {
            execute(
                configuration, sessionId: sessionId,
                destinationRoot: destinationRoot, manifestPath: manifestPath)
        }.value
    }

    static func execute(
        _ configuration: ExportPostCommandConfiguration,
        sessionId: String,
        destinationRoot: String,
        manifestPath: String
    ) -> OutputPostCommandOutcome {
        let template = configuration.template
        guard let expanded = arguments(
            template: template, sessionId: sessionId,
            destinationRoot: destinationRoot, manifestPath: manifestPath) else {
            return OutputPostCommandOutcome(
                command: template, error: "empty command template")
        }
        let first = expanded[0]
        let program: String
        let programArguments: [String]
        if first.contains("/") {
            program = first
            programArguments = Array(expanded.dropFirst())
        } else {
            // 不带路径 = 走 PATH 查找；用 /usr/bin/env 的 execvp 语义，仍然不经 shell。
            program = defaultExecutableLookup
            programArguments = expanded
        }
        if program.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: program) else {
                return OutputPostCommandOutcome(
                    command: template,
                    error: "command is not executable: " + program)
            }
        }

        let stdoutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-post-command-out-" + UUID().uuidString)
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-post-command-err-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil),
              let stdoutHandle = FileHandle(forWritingAtPath: stdoutURL.path),
              let stderrHandle = FileHandle(forWritingAtPath: stderrURL.path) else {
            return OutputPostCommandOutcome(
                command: template, error: "cannot create temporary output files")
        }
        defer {
            // best-effort 清理：用 do/catch 而不是 try?（cleanup ratchet 只降不升）。
            do {
                try stdoutHandle.close()
                try stderrHandle.close()
                try FileManager.default.removeItem(at: stdoutURL)
                try FileManager.default.removeItem(at: stderrURL)
            } catch {
                // 临时文件删不掉只影响 /tmp 占用，不影响交付结果。
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = programArguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        let startedAt = Date()
        do {
            try process.run()
        } catch {
            return OutputPostCommandOutcome(
                command: template,
                error: "failed to launch: " + String(describing: error))
        }

        let deadline = startedAt.addingTimeInterval(configuration.timeoutSeconds)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // 被 terminate 后给 2 秒收尾；仍不退出则升级 SIGKILL，避免钩子把导出流程挂死。
        if timedOut {
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        let durationMilliseconds = max(
            0, Int(Date().timeIntervalSince(startedAt) * 1000))

        let tail = outputTail(stdout: stdoutURL, stderr: stderrURL)
        if timedOut {
            return OutputPostCommandOutcome(
                command: template, exitCode: nil, timedOut: true,
                durationMilliseconds: durationMilliseconds,
                error: "timed out after \(Int(configuration.timeoutSeconds))s",
                outputTail: tail)
        }
        let exitCode = Int(process.terminationStatus)
        return OutputPostCommandOutcome(
            command: template, exitCode: exitCode, timedOut: false,
            durationMilliseconds: durationMilliseconds,
            error: exitCode == 0 ? nil : "command exited with status \(exitCode)",
            outputTail: tail)
    }

    static func outputTail(stdout: URL, stderr: URL) -> String? {
        var chunks: [String] = []
        for url in [stdout, stderr] {
            let data: Data
            do { data = try Data(contentsOf: url) } catch { continue }
            guard !data.isEmpty else { continue }
            let tail = data.count > maxOutputBytes
                ? Data(data.suffix(maxOutputBytes)) : data
            if let text = String(data: tail, encoding: .utf8), !text.isEmpty {
                chunks.append(text)
            }
        }
        guard !chunks.isEmpty else { return nil }
        let joined = chunks.joined(separator: "\n")
        return joined.count > maxOutputBytes
            ? String(joined.suffix(maxOutputBytes)) : joined
    }

    // MARK: - 报告回写

    /// 把钩子结果写回已落盘的 manifest（best-effort）。
    ///
    /// manifest 是 OutputService 写的 OutputRunSummary JSON；这里只补一个可选键，
    /// 读不出/解码失败/写失败都返回 false（由调用方记日志），绝不把交付判成失败。
    @discardableResult
    public static func attach(
        _ outcome: OutputPostCommandOutcome,
        toManifestAt path: String
    ) -> Bool {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return false }
        let decoder = JSONDecoder()
        var summary: OutputRunSummary
        do { summary = try decoder.decode(OutputRunSummary.self, from: data) } catch {
            return false
        }
        summary.postCommand = outcome
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded: Data
        do { encoded = try encoder.encode(summary) } catch { return false }
        do {
            try encoded.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
