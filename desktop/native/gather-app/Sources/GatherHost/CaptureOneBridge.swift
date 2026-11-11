// Capture One 宿主桥：只负责显式用户操作，不自动读取、刷新或清理元数据。
// AppleScript 错误在这里归一化为稳定错误码，页面才能在 reload 成功后才放行
// confirm_sync/cleanup。
//
// Wave1（2026-11-11，task-6）修 P0-1/P0-2 的脚本契约：
//   · 选中读取改成 application 级 selected variants + parent image.path（G1）；
//   · reload metadata 按当前选中的 variant 逐个调用（sdef 的直接参数是 variant），
//     无选中时抛 .noSelection 而不是盲发（G2）；
//   · 以上均以本机 C1 16.7.8.16 的 CaptureOne.sdef 行号为依据，写在脚本注释里。
import Foundation
import GatherProtocol
import GatherUI

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
//
// P1 §3.10.2/§3.10.3（本波新增，均不改变既有成员语义）：
//   · selectVariants(paths:)  —— 在 C1 中选中给定照片：AppleScript 单值 whose 匹配，
//     失败回退 open -a（NSWorkspace.open 的等价物，**可能触发 C1 导入**，UI 必须标注）；
//   · adjustmentHints(paths:) —— 读 XMP 里的 crs: 字段，提示"预览可能不含 C1 调整"。

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

// P1 §3.10.2/§3.10.3 的 DTO（C1SelectionOutcome / C1AdjustmentHint 等）声明在 GatherUI
// 的 CullingViewModel+Writeback.swift（UI 端口），本文件只负责实现与脚本。

public final class CaptureOneBridge: CaptureOneBridging, @unchecked Sendable {
    private static let sharedStorage = CaptureOneBridgeStorage()

    /// 页面（Dashboard 新建工作区）未显式注入桥时取全局实例；bootstrap 注册。
    /// 读写经 sharedStorage 的锁（见上），公开语义与原先的静态存储属性一致。
    public static var shared: CaptureOneBridge? {
        get { sharedStorage.current }
        set { sharedStorage.current = newValue }
    }

    private let recordReloadAck: (String) throws -> Void
    /// AppleScript 执行接缝（nil = 真跑 osascript）。
    ///
    /// 为什么需要：脚本契约（对象归属/直接参数类型）与错误语义（无选中不盲发、
    /// 失败不吞）是本域最容易回归的部分，而真机验证要触发 TCC 自动化授权。
    /// 注入假运行器后，这些语义可以在单测里直接断言，运行时仍走 osascript。
    private let appleScriptRunner: (@Sendable (String) async throws -> String)?

    /// - Parameter recordReloadAck：Capture One 脚本成功后的持久 ack 写入。
    ///   生产由组合根的 AppRuntime.recordReloadAck 提供（同一 SessionRepo
    ///   写库语义）；测试可注入空实现/闭包。B8.3b-2b 起不再接收命令面。
    /// - Parameter appleScriptRunner：AppleScript 执行接缝（仅测试注入）。
    public init(
        recordReloadAck: @escaping (String) throws -> Void = { _ in },
        appleScriptRunner: (@Sendable (String) async throws -> String)? = nil
    ) {
        self.recordReloadAck = recordReloadAck
        self.appleScriptRunner = appleScriptRunner
    }

    public func selectedPhotoPaths() async throws -> [String] {
        let appName = try await captureOneApplicationName()
        let output = try await runAppleScript(Self.selectedVariantsScript(appName: appName))
        return output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
    }

    /// 让 C1 重新读取**当前选中 variant** 的源文件元数据，成功后才写 durable ack。
    ///
    /// G2 契约：C1 16.7 sdef 里 reload metadata 的直接参数是 variant
    /// （CaptureOne.sdef:1852-1855；document 不在可响应对象里），因此脚本对
    /// 选中项逐个调用。没有选中项时脚本返回 0，这里抛 .noSelection —— 绝不
    /// 向 document 盲发、也不在脚本失败时伪造 ack（否则 confirm/finalize 会在
    /// 假 ack 上继续推进）。
    public func reloadMetadata(sessionId: String) async throws {
        let appName = try await captureOneApplicationName()
        let output = try await runAppleScript(Self.reloadMetadataScript(appName: appName))
        guard let reloaded = Self.reloadedVariantCount(from: output) else {
            // 脚本成功但报告形状不认识：C1 字典/脚本行为变了的信号，必须保留原文。
            throw CaptureOneBridgeError.scriptFailed(
                "unexpected reload metadata report: \(output)")
        }
        guard reloaded > 0 else { throw CaptureOneBridgeError.noSelection }
        // C1 需要一个短暂窗口读取 XMP；只有脚本成功且确有变体被重载才写入 durable ack。
        try await Task.sleep(for: .milliseconds(500))
        try recordReloadAck(sessionId)
    }

    /// 在 Capture One 中选中给定照片（§3.10.2）。
    ///
    /// 顺序：
    /// 1. 过滤非法/不存在的路径 → notFound（不 fallback：绝不因为"文件不在"而触发导入）；
    /// 2. AppleScript 按 image.path 逐路径匹配（variant 没有 path，只能经 parent
    ///    image 反查），再按 sdef 的 select 契约（直接参数是 document、variant/
    ///    variants 是具名参数，CaptureOne.sdef:1956-1966）一次选中该图片的 variant；
    /// 3. 脚本语法/字典不可用（C1 版本太老）或 osascript 执行失败 → `open -a <app>`
    ///    （等价 NSWorkspace.open，**可能触发 C1 导入**），结果里 method 标明来源。
    ///    例外（C7）：脚本内部 `on error` 的 `error:<msg>` 报告就是**执行失败**，
    ///    直接抛 C1_SCRIPT_FAILED、不兜底 —— 旧实现会把它当"未找到"（单路径）
    ///    或整批导入（多路径）。
    ///
    /// 脚本成功但一条都没匹配（照片不在当前目录）：返回 appleScript + 全部 notFound，
    /// **不** fallback —— 否则会把"不在当前目录"变成"导入一批新文件"。
    public func selectVariants(paths: [String]) async throws -> C1SelectionOutcome {
        var seen = Set<String>()
        var requested: [String] = []
        var notFound: [String] = []
        for raw in paths {
            let path = (raw as NSString).standardizingPath
            guard path.hasPrefix("/") else {
                notFound.append(raw)
                continue
            }
            guard seen.insert(path).inserted else { continue }
            if FileManager.default.fileExists(atPath: path) {
                requested.append(path)
            } else {
                notFound.append(path)
            }
        }
        guard !requested.isEmpty else {
            return C1SelectionOutcome(
                method: .appleScript, paths: [], notFound: notFound, appName: nil)
        }

        let appName = try await captureOneApplicationName()
        // 只把"跑脚本"放进 do/catch：解析与兜底分支移到 do 之外，这样脚本执行失败
        // （含下面的 "error:" 报告）的抛出不会被 catch 二次兜底成一次多余的 open -a。
        let output: String
        do {
            output = try await runAppleScript(
                Self.selectVariantsScript(appName: appName, paths: requested))
        } catch let error as CaptureOneBridgeError {
            switch error {
            case .notRunning, .notAuthorized, .noDocument, .noSelection, .timedOut:
                // 应用状态问题不是脚本能力问题：原样抛出，让 UI 显示预检原因。
                throw error
            case .scriptFailed(let message):
                let reason: C1SelectionFallbackReason = Self.looksLikeUnsupported(
                    message: message) ? .scriptUnsupported
                    : .scriptFailed(code: GatherErrorCode.C1_SCRIPT_FAILED.rawValue)
                return try await openInCaptureOne(
                    appName: appName, paths: requested, notFound: notFound, reason: reason)
            }
        } catch {
            return try await openInCaptureOne(
                appName: appName, paths: requested, notFound: notFound,
                reason: .scriptFailed(code: GatherErrorCode.C1_SCRIPT_FAILED.rawValue))
        }
        // C7：脚本**成功执行**但内部 on error 明确报了错（"error:<msg>"，见
        // selectVariantsScript 的 on error 分支）——这是执行失败，既不兜底
        // （open -a 会把整批文件导入 C1），也不能被当成"没匹配到"。
        // 原实现两条路都错：单路径时错误串恰好 1 行 = requested.count，被解析成
        // "不是 1" → 全部 notFound（用户看到"未找到"）；多路径时行数不等 →
        // scriptUnsupported → 兜底 open -a 整批导入。所以这里先判前缀、直接抛。
        if let reported = Self.reportedScriptError(in: output) {
            throw CaptureOneBridgeError.scriptFailed(reported)
        }
        let flags = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if flags.count == requested.count {
            var selected: [String] = []
            for (index, flag) in flags.enumerated() where flag == "1" {
                selected.append(requested[index])
            }
            notFound.append(contentsOf: requested.enumerated()
                .filter { flags[$0.offset] != "1" }
                .map { $0.element })
            return C1SelectionOutcome(
                method: .appleScript, paths: selected,
                notFound: notFound, appName: appName)
        }
        // 输出形状不认识（脚本被旧版 C1 静默改写等）→ 走兜底。
        return try await openInCaptureOne(
            appName: appName, paths: requested, notFound: notFound,
            reason: .scriptUnsupported)
    }

    /// 兜底：让 C1 打开这些文件（可能触发导入）。失败归一到 C1_SCRIPT_FAILED。
    private func openInCaptureOne(
        appName: String,
        paths: [String],
        notFound: [String],
        reason: C1SelectionFallbackReason
    ) async throws -> C1SelectionOutcome {
        guard Self.isSafeApplicationName(appName) else {
            throw CaptureOneBridgeError.scriptFailed("unsafe application name")
        }
        do {
            _ = try await runProcess(
                executable: Self.openExecutable,
                arguments: ["-a", appName] + paths,
                timeout: Self.openTimeout)
        } catch let error as CaptureOneBridgeError {
            throw error
        } catch {
            throw CaptureOneBridgeError.scriptFailed(String(describing: error))
        }
        return C1SelectionOutcome(
            method: .workspace(reason: reason), paths: paths,
            notFound: notFound, appName: appName)
    }

    /// 旧版 C1 的脚本错误（语法/字典不支持）与"真的执行失败"要分开提示。
    static func looksLikeUnsupported(message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("-2741")      // syntax error
            || lowercased.contains("-2753")      // 术语/字典不可用
            || lowercased.contains("expected")
            || lowercased.contains("can't get")
            || lowercased.contains("cannot get")
            || lowercased.contains("not understood")
    }

    /// 读照片的 C1 调整提示（§3.10.3）：XMP 里存在 crs: 字段时，我们的预览不一定
    /// 包含 C1 的色彩/裁剪/旋转 —— UI 必须明示，而不是让用户以为这些调整被静默忽略。
    ///
    /// 只读 sidecar 或 JPEG 头部（≤4MB）；不解析 .cos（私有格式），不碰 RAW 内部。
    /// 永不抛错：读不到就当"没有 C1 调整"，提示只是可选增强信息。
    public func adjustmentHints(paths: [String]) -> [C1AdjustmentHint] {
        paths.map { C1AdjustmentReader.hint(photoPath: $0) }
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
        // 测试接缝优先：假运行器只替代脚本执行，不改变调用方可见的错误语义。
        if let appleScriptRunner {
            return try await appleScriptRunner(script)
        }
        return try await runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: timeout)
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

    /// 把 osascript 的 stderr 归一化为稳定错误。
    ///
    /// internal（非 private）：C1BridgeWave1Tests 直接断言无文档措辞的归一结果
    /// ——这是"脚本失败不得被当成没选中"契约的一半，必须可测。
    static func classifyMessage(_ message: String) -> CaptureOneBridgeError {
        let lowercased = message.lowercased()
        if lowercased.contains("-1743") || lowercased.contains("not authorized") || lowercased.contains("not authorised") {
            return .notAuthorized
        }
        if lowercased.contains("no document") || lowercased.contains("no current document") {
            return .noDocument
        }
        // osascript 对 `current document` 取不到时的常见措辞（"Can't get current
        // document."）：同样归一到 C1_NO_DOCUMENT，让 UI 提示"先打开目录"而不是
        // 笼统的 C1_SCRIPT_FAILED（G1 之后脚本会先取 current document 做探针）。
        if lowercased.contains("current document") {
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

    /// 读取 C1 当前选中的 variant 路径（G1）。
    ///
    /// C1 16.7 sdef 依据（本机 CaptureOne.sdef，16.7.8.16）：
    /// - selected variants 是 **application** 属性（code csev，`:244-247`，
    ///   "List of selected variants in the front document's browser"）；
    ///   标了 deprecated，但 16.7 里它是唯一能一次读出多个选中项的对象面
    ///   （application 级的 `primary variant` 只有单选，`:253`）；
    /// - variant **没有 path**：路径在 `parent image`（`:1081`）的 `path`
    ///   （image.path，`:1541`，"The full path to the original image file"）。
    ///
    /// 旧脚本写成 `selected variants of current document`（对象归属错）并取
    /// `path of img`（variant 无该属性），在 16.7 上必然报错；旧实现再用
    /// `on error return ""` 把错误吞成"没有选中照片"，用户只会看到"请先选照片"。
    /// 现在**不吞错**：脚本失败由 osascript 非零退出上浮为 C1_SCRIPT_FAILED。
    static func selectedVariantsScript(appName: String) -> String {
        """
        tell application "\(appName)"
          -- 无文档时先在这里抛错（宿主归一到 C1_NO_DOCUMENT），不被当成"没有选中"。
          set frontDocument to current document
          set selectedVariantsList to selected variants
          set output to ""
          repeat with v in selectedVariantsList
            set parentImage to parent image of v
            set output to output & (path of parentImage) & linefeed
          end repeat
          return output
        end tell
        """
    }

    /// 按路径逐个匹配后 select（§3.10.2）。
    ///
    /// C1 16.7 sdef 依据：
    /// - variant 没有 path，只能经 `parent image` 反查 `image.path`（`:1081`/`:1541`）；
    /// - select 命令的直接参数是 **document**，variant 是具名参数（`variant` /
    ///   `variants`，`:1956-1966`）——旧脚本把 variant 当直接参数，16.7 会拒绝。
    ///
    /// 输出：每条路径一行 "1"/"0"，与 paths 同序（调用方据此算 notFound）；
    /// `on error` 分支返回单行 `"error:<msg>"`，由 reportedScriptError(in:) 先筛出
    /// 并当脚本失败抛出（C7：不能被当"未找到"，也不能兜底 open -a）。
    static func selectVariantsScript(appName: String, paths: [String]) -> String {
        let literals = paths.map(appleScriptLiteral).joined(separator: ", ")
        return """
        tell application "\(appName)"
          try
            set targetDoc to current document
            set report to ""
            repeat with p in {\(literals)}
              -- variant 没有 path：按 parent image 的 path 在当前 collection 里找图片。
              set matches to (every image of targetDoc whose path is p)
              if (count of matches) > 0 then
                set variantsToSelect to {}
                repeat with img in matches
                  repeat with v in (variants of img)
                    set end of variantsToSelect to v
                  end repeat
                end repeat
                -- sdef：select 的直接参数是 document，variant/variants 是具名参数。
                select targetDoc variants variantsToSelect
                set report to report & "1" & linefeed
              else
                set report to report & "0" & linefeed
              end if
            end repeat
            return report
          on error theErr
            return "error:" & (theErr as text)
          end try
        end tell
        """
    }

    /// 脚本内部 on error 的报告前缀（与 selectVariantsScript 的 `"error:"` 返回值一致）。
    static let scriptErrorPrefix = "error:"

    /// C7：把脚本的 `error:<msg>` 报告解析成可抛的错误消息（nil = 不是错误报告）。
    ///
    /// 为什么必须先判：这是 selectVariantsScript 在 `on error` 分支显式写出的，
    /// 语义是"脚本执行失败"（无当前文档、字段不存在、旧版字典不支持…），形状与
    /// `"1"/"0"` 报告完全不同。但原实现只按行数判断：单路径时 1 行 = 1 个请求，
    /// 错误串被当成"没匹配到"→ 返回 notFound；多路径时行数不等 → scriptUnsupported
    /// → 兜底 `open -a`（可能整批导入 C1）。两种都必须当脚本失败直接抛。
    ///
    /// 只认**整段输出的开头**（先 trim 空白），不用 contains：路径或消息中间出现
    /// "error:" 不能触发误判；消息体里含换行也一并保留。
    static func reportedScriptError(in output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(scriptErrorPrefix) else { return nil }
        let message = String(trimmed.dropFirst(scriptErrorPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "script reported an error" : message
    }

    /// 双引号 / 反斜杠用码点构造：避免在本文件里堆叠难读的连续转义。
    private static let appleScriptQuote = String(decoding: [0x22] as [UInt8], as: UTF8.self)
    private static let appleScriptBackslash = String(decoding: [0x5C] as [UInt8], as: UTF8.self)

    /// AppleScript 字符串字面量转义：反斜杠与双引号，然后整体加引号。
    /// 换行/回车会让脚本变成多行字面量（AppleScript 不允许），直接退化为空串。
    static func appleScriptLiteral(_ value: String) -> String {
        guard !value.unicodeScalars.contains(where: { $0.value == 0x0A || $0.value == 0x0D }) else {
            return appleScriptQuote + appleScriptQuote
        }
        let escaped = value
            .replacingOccurrences(
                of: appleScriptBackslash,
                with: appleScriptBackslash + appleScriptBackslash)
            .replacingOccurrences(
                of: appleScriptQuote,
                with: appleScriptBackslash + appleScriptQuote)
        return appleScriptQuote + escaped + appleScriptQuote
    }

    /// 兜底打开（NSWorkspace.open 的等价物：不引 AppKit、不跨 actor）。
    static let openExecutable = "/usr/bin/open"
    static let openTimeout: TimeInterval = 15

    /// G2 的 reload 脚本：按当前选中的 variant 逐个 reload。
    ///
    /// C1 16.7 sdef 依据：reload metadata（`:1852-1855`）"Reload a variant's source
    /// file metadata"，直接参数是 **variant**，命令只声明在 variant 类上响应
    /// （`:1176`）—— document 级调用在 16.7 上不成立（旧脚本正是如此）。
    /// 没有选中项时不向任何对象盲发：直接返回 "0"，宿主映射成 C1_NO_SELECTED_PHOTOS。
    ///
    /// 输出：已重载的 variant 数量（十进制字符串）。
    static func reloadMetadataScript(appName: String) -> String {
        """
        tell application "\(appName)"
          set frontDocument to current document
          set selectedVariantsList to selected variants
          set selectedCount to count of selectedVariantsList
          if selectedCount = 0 then return "0"
          repeat with v in selectedVariantsList
            reload metadata v
          end repeat
          return (selectedCount as text)
        end tell
        """
    }

    /// reload 脚本输出 → 已重载的 variant 数；nil = 报告形状不认识（契约不匹配）。
    ///
    /// 为什么要区分 nil 与 0：0 是"C1 里没有选中项"的明确语义（→ .noSelection），
    /// 而无法解析的输出说明脚本被旧/新版 C1 改写了——那是脚本契约失败，必须带
    /// 原文上浮，不能用"没选中"掩盖。
    static func reloadedVariantCount(from output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}



// MARK: - C1 调整提示（§3.10.3）

/// 从 XMP 文本里读 crs: 属性（纯解析，无 I/O），以及 sidecar/JPEG 头的定位。
public enum C1AdjustmentReader {
    /// 单次读取上限：JPEG 头部 XMP 正常 < 1MB，4MB 只是防御。
    public static let maxScanBytes = 4 << 20
    /// 提示里最多列出的属性名个数。
    public static let maxAttributeNames = 12

    /// 读一张照片的调整提示；永不抛错。
    public static func hint(photoPath: String, fileManager: FileManager = .default) -> C1AdjustmentHint {
        let sidecar = TSPath.xmpSidecarPath(photoPath)
        if fileManager.fileExists(atPath: sidecar), let text = readText(path: sidecar) {
            return parse(text, photoPath: photoPath, xmpPath: sidecar)
        }
        // 内嵌 XMP：只对 JPEG 读头。RAW 的 XMP 在私有容器里，不做猜测解析。
        let ext = (photoPath as NSString).pathExtension.lowercased()
        guard ext == "jpg" || ext == "jpeg" else {
            return .none(photoPath: photoPath)
        }
        guard let text = readText(path: photoPath) else {
            return .none(photoPath: photoPath)
        }
        return parse(text, photoPath: photoPath, xmpPath: photoPath)
    }

    /// 纯函数：从 XMP 文本里抽 crs: 字段 → 提示。
    public static func parse(
        _ xmp: String,
        photoPath: String,
        xmpPath: String?
    ) -> C1AdjustmentHint {
        let attributes = crsAttributes(in: xmp)
        guard !attributes.isEmpty else { return .none(photoPath: photoPath) }
        let names = attributes.keys.sorted().prefix(maxAttributeNames)
        return C1AdjustmentHint(
            photoPath: photoPath,
            xmpPath: xmpPath,
            hasAdjustments: true,
            angle: number(attributes["Angle"]),
            cropRect: cropRect(attributes),
            attributeNames: Array(names))
    }

    /// 扫描 name="value" 形式的 crs: 属性。
    /// 手写扫描而不是正则：属性值可能含 XMP 的引号/转义，扫描器能精确停在下个引号。
    public static func crsAttributes(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        var searchStart = text.startIndex
        while let range = text.range(of: "crs:", range: searchStart..<text.endIndex) {
            var cursor = range.upperBound
            var name = ""
            while cursor < text.endIndex, isAttributeNameChar(text[cursor]) {
                name.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            if !name.isEmpty, cursor < text.endIndex, text[cursor].asciiValue == 0x3D {
                cursor = text.index(after: cursor)
                if cursor < text.endIndex, text[cursor].asciiValue == 0x22 {
                    let valueStart = text.index(after: cursor)
                    if let endQuote = text[valueStart...].firstIndex(where: { $0.asciiValue == 0x22 }) {
                        result[name] = String(text[valueStart..<endQuote])
                        searchStart = text.index(after: endQuote)
                        continue
                    }
                }
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return result
    }

    static func isAttributeNameChar(_ char: Character) -> Bool {
        guard let value = char.asciiValue else { return false }
        if value >= 0x30, value <= 0x39 { return true }    // 0-9
        if value >= 0x41, value <= 0x5A { return true }    // A-Z
        if value >= 0x61, value <= 0x7A { return true }    // a-z
        return value == 0x5F || value == 0x2D || value == 0x2E  // _ - .
    }

    static func number(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// crs:CropTop/Left/Bottom/Right（0…1 归一化）。缺任一边或框为空 → nil。
    static func cropRect(_ attributes: [String: String]) -> C1CropRect? {
        guard let top = number(attributes["CropTop"]),
              let left = number(attributes["CropLeft"]),
              let bottom = number(attributes["CropBottom"]),
              let right = number(attributes["CropRight"]) else { return nil }
        let rect = C1CropRect(
            top: clamp01(top), left: clamp01(left),
            bottom: clamp01(bottom), right: clamp01(right))
        return rect.isEmpty ? nil : rect
    }

    static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    /// 读文件前 maxScanBytes 字节（sidecar 也走同一上限：防御超大文件）。
    static func readText(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer {
            do { try handle.close() } catch { }
        }
        do {
            let data = try handle.read(upToCount: maxScanBytes) ?? Data()
            guard !data.isEmpty else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
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
