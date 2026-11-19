// desktop/native/gather-app/Sources/GatherHost/C1/CaptureOneBridge+Execution.swift
// M11（Wave5 / task-9）后续：CaptureOneBridge 的实例执行路径（从主文件再拆）。
// 选中读取 / reload / 预检 / 变体数回读 / AppleScript 与子进程执行；脚本文本与
// 输出解析仍分别在 CaptureOneScripts.swift / CaptureOneBridgeParser.swift。
//
// 纯搬移：搬移块与拆分前逐字节一致；仅去掉 private 以便跨文件（同 target）访问。
import Foundation
import GatherProtocol
import GatherUI

extension CaptureOneBridge {
    public func selectedPhotoPaths() async throws -> [String] {
        let appName = try await captureOneApplicationName()
        let output = try await runAppleScript(Self.selectedVariantsScript(appName: appName))
        return output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
    }

    /// 一次读取当前选中 variant 的路径 + 判断数据（Wave2 / G3，导入前使用）。
    ///
    /// 与 selectedPhotoPaths 的差异：同一 parent image 的多个 variant 各自一行判断，
    /// 因此 judgements 里同一路径可出现多次（合并规则在应用层，协议层不预设）；
    /// paths 去重保序、仍只保留存在且绝对路径的条目（与导入口径一致）。
    ///
    /// 脚本失败**上浮**（调用方据此降级为"仅按文件导入"）；本层不吞错、不伪造空快照。
    public func selectedVariantSnapshot() async throws -> C1SelectionSnapshot {
        let appName = try await captureOneApplicationName()
        let output = try await runAppleScript(
            Self.selectedVariantJudgementsScript(appName: appName))
        let parsed = Self.parseVariantJudgements(output)
        var judgements: [C1VariantJudgement] = []
        var paths: [String] = []
        var seen = Set<String>()
        for judgement in parsed.judgements {
            // 与 selectedPhotoPaths 同口径：只判绝对路径 + 存在性，不做 standardizingPath
            //（后者会解析符号链接，把 /var/… 变成 /private/var/…；路径归一在下游
            // ScanPath.canonical 统一做，导入链路与 DB 行都用同一口径）。
            let path = judgement.photoPath
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { continue }
            judgements.append(C1VariantJudgement(
                photoPath: path,
                rating: judgement.rating,
                colorTag: judgement.colorTag,
                pick: judgement.pick,
                keywords: judgement.keywords))
            if seen.insert(path).inserted { paths.append(path) }
        }
        return C1SelectionSnapshot(
            paths: paths,
            judgements: judgements,
            malformedLines: parsed.malformedLines.count)
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
        await preselectWrittenPhotos(sessionId: sessionId, appName: appName)
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

    /// P2（Wave4b）：reload metadata 是 per-variant 的，因此自动 reload 前先把**本次写盘**
    /// 的照片在 C1 里选中。
    ///
    /// 为什么要先 select：写回发生在 Gather，C1 的选中项通常停在别的照片/空选中，
    /// 直接 reload 必然 .noSelection 并被失败抑制（“回路断点”）。
    /// 选中失败**不阻断** reload：C1 可能不在当前 collection/未运行，此时退回旧行为并在
    /// 同步条给出可执行提示。
    private func preselectWrittenPhotos(sessionId: String, appName: String) async {
        let paths: [String]
        do {
            paths = try writtenPhotoPaths(sessionId)
        } catch {
            GatherLogger.log("c1.reload preselect 读取写盘路径失败: \(error)", level: .warn)
            return
        }
        guard !paths.isEmpty else { return }
        let capped = Array(paths.prefix(Self.maxVariantWritebackItems))
        do {
            let output = try await runAppleScript(
                Self.selectVariantsScript(appName: appName, paths: capped))
            if let reported = Self.reportedScriptError(in: output) {
                GatherLogger.log("c1.reload preselect 失败: \(reported)", level: .warn)
                return
            }
            GatherLogger.log(
                "c1.reload preselect session=\(sessionId) requested=\(capped.count)",
                level: .info)
        } catch {
            GatherLogger.log("c1.reload preselect 脚本失败: \(error)", level: .warn)
        }
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
    /// 脚本成功后仍有 notFound（照片不在 C1 **当前集合**）：
    /// - **R3（Wave5）**：若这些照片在磁盘上存在且父目录唯一 → `browse` 切到该目录，
    ///   再**只对这些**重试一次（追加选中，不重复 deselect）；仍找不到才如实报 notFound；
    /// - 一条都没匹配时**不** fallback `open -a` —— 否则会把"不在当前目录"变成
    ///   "导入一批新文件"。
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
            var missing: [String] = []
            Self.splitSelectionReport(
                flags: flags, requested: requested, selected: &selected, missing: &missing)
            // R3（Wave5）：没匹配上的照片若在磁盘上存在且父目录唯一 → 让 C1 切到该目录，
            // 然后**只重试这些**（deselectFirst=false：追加选中，不抹掉第一批已选中的照片；
            // 整批重跑会因为脚本先 deselect 而把第一批从 C1 选中里清掉）。
            if let directory = Self.singleParentDirectory(of: missing),
               await browse(toDirectory: directory, appName: appName) {
                do {
                    let retryOutput = try await runAppleScript(
                        Self.selectVariantsScript(
                            appName: appName, paths: missing, deselectFirst: false))
                    if let reported = Self.reportedScriptError(in: retryOutput) {
                        throw CaptureOneBridgeError.scriptFailed(reported)
                    }
                    let retryFlags = retryOutput
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if retryFlags.count == missing.count {
                        var retriedSelected: [String] = []
                        var stillMissing: [String] = []
                        Self.splitSelectionReport(
                            flags: retryFlags, requested: missing,
                            selected: &retriedSelected, missing: &stillMissing)
                        selected.append(contentsOf: retriedSelected)
                        missing = stillMissing
                    }
                } catch {
                    // 切集合后重试失败：保留第一次的真实结果（不吞错：warn 带原因）。
                    GatherLogger.log(
                        "c1.select browse=\(directory) 重试失败: \(error)", level: .warn)
                }
            }
            notFound.append(contentsOf: missing)
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

    /// R3：让 C1 切到目标目录（browse，sdef:678-684）。
    ///
    /// 失败**不吞错**：把目录与脚本报告的原因写 warn 日志并返回 false；调用方据此保留
    /// notFound 如实上报（绝不把"切不过去"当成"照片找到了"）。
    func browse(toDirectory directory: String, appName: String) async -> Bool {
        do {
            let output = try await runAppleScript(
                Self.browseScript(appName: appName, path: directory))
            if let reported = Self.reportedScriptError(in: output) {
                GatherLogger.log(
                    "c1.browse 失败 directory=\(directory): \(reported)", level: .warn)
                return false
            }
            return true
        } catch {
            GatherLogger.log(
                "c1.browse 失败 directory=\(directory): \(error)", level: .warn)
            return false
        }
    }

    /// R1：写前回读每个 image 的 variant 数（一次脚本，行数与 paths 同序）。
    ///
    /// 脚本执行/解析失败一律上浮：拿不到变体数就无法安全判定目标，"盲写"正是本波要修的
    /// P0（写错 variant 不可逆），因此宁可让 UI 提示改用「写回 XMP…」。
    func readVariantCounts(paths: [String], appName: String) async throws -> [Int] {
        let output = try await runAppleScript(
            Self.variantCountReadScript(appName: appName, paths: paths), timeout: 30)
        guard let counts = Self.parseVariantCounts(output, expected: paths.count) else {
            throw CaptureOneBridgeError.scriptFailed(
                "unexpected variant count report: \(output)")
        }
        return counts
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

    func captureOneApplicationName() async throws -> String {
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

    func runAppleScript(_ script: String, timeout: TimeInterval = 15) async throws -> String {
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
}
