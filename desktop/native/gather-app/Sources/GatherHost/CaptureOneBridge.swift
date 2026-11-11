// Capture One 宿主桥：只负责显式用户操作，不自动读取、刷新或清理元数据。
// AppleScript 错误在这里归一化为稳定错误码，页面才能在 reload 成功后才放行
// confirm_sync/cleanup。
//
// Wave1（2026-11-11，task-6）修 P0-1/P0-2 的脚本契约：
//   · 选中读取改成 application 级 selected variants + parent image.path（G1）；
//   · reload metadata 按当前选中的 variant 逐个调用（sdef 的直接参数是 variant），
//     无选中时抛 .noSelection 而不是盲发（G2）；
//   · 以上均以本机 C1 16.7.8.16 的 CaptureOne.sdef 行号为依据，写在脚本注释里。
//
// Wave2（2026-11-11，task-11）加只读的判断数据导出（G3）：
//   · selectedVariantSnapshot()：一次脚本读出当前选中 variant 的 parent image.path +
//     rating / color tag / pick / keywords，解析成 C1VariantJudgement（映射在应用层）；
//   · 行式记录 + TAB 字段分隔 + 反斜杠转义（路径/关键词可含任意字符），畸形行跳过并
//     计数而不是整批失败；脚本失败仍上浮，由导入侧降级为"仅按文件导入"。
//
// Wave5（2026-11-11，task-11 / Batch1 C1 写回正确性）：
//   · R1：变体级写回**写前回读**每个 image 的 variant 数（variantCountReadScript）；
//     恰好 1 个才写，多个不猜目标 → 报告 skippedMultiVariant；回读失败上浮不盲写；
//   · R3：notFound 且照片在磁盘、父目录唯一时用 C1 browse（sdef:678-684）切集合后
//     重读/重试一次；browse 失败只记 warn（不吞错、不谎报命中）；
//   · R12：selectVariantsScript 在 select 前 deselect 当前选中（sdef:1967），
//     "在 C1 中显示"的提示与 C1 实际选中一致。
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
    /// P2（Wave4b）：本机是否安装 C1（Hot Folder 提示等 UI 据此 gate）。
    private let isC1Installed: () -> Bool
    /// P2（Wave4b）：本会话「已写盘」的照片路径（自动 reload 前先 select，避免必然 noSelection）。
    private let writtenPhotoPaths: (String) throws -> [String]

    /// - Parameter recordReloadAck：Capture One 脚本成功后的持久 ack 写入。
    ///   生产由组合根的 AppRuntime.recordReloadAck 提供（同一 SessionRepo
    ///   写库语义）；测试可注入空实现/闭包。B8.3b-2b 起不再接收命令面。
    /// - Parameter appleScriptRunner：AppleScript 执行接缝（仅测试注入）。
    /// - Parameter isC1Installed：本机是否安装 Capture One（默认走进程级快照）。
    /// - Parameter writtenPhotoPaths：本会话已写盘照片路径（默认不起作用 = 旧行为）。
    public init(
        recordReloadAck: @escaping (String) throws -> Void = { _ in },
        appleScriptRunner: (@Sendable (String) async throws -> String)? = nil,
        isC1Installed: (() -> Bool)? = nil,
        writtenPhotoPaths: @escaping (String) throws -> [String] = { _ in [] }
    ) {
        self.recordReloadAck = recordReloadAck
        self.appleScriptRunner = appleScriptRunner
        self.isC1Installed = isC1Installed ?? { C1Installation.isInstalled() }
        self.writtenPhotoPaths = writtenPhotoPaths
    }

    /// P2（Wave4b）：Hot Folder 提示等 UI 只在装了 C1 时展示；同步读（进程级快照）。
    public var c1Installed: Bool { isC1Installed() }

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
    private func browse(toDirectory directory: String, appName: String) async -> Bool {
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
    private func readVariantCounts(paths: [String], appName: String) async throws -> [Int] {
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
          set selectedVariantsList to {}
          try
            set selectedVariantsList to selected variants
          on error
            -- P2（Wave4b）受控回退：该属性在部分 C1 版本 deprecated/hidden；不可读时退回
            -- primary variant（单张），避免整个读取失效。空选中仍按空处理（不误导入）。
            try
              set primaryVariant to primary variant
              if primaryVariant is not missing value then set selectedVariantsList to {primaryVariant}
            end try
          end try
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
    ///   `variants`，`:1956-1966`）——旧脚本把 variant 当直接参数，16.7 会拒绝；
    /// - **R12（Wave5）**：select 的语义是"加入当前集选中"（`:1956` "Add one or more
    ///   variants to the current collection's selection"），旧实现只加不减 → UI 提示
    ///   "已在 C1 中显示 N 张"与 C1 实际选中（旧选中 + N）不符。sdef:1967 有配对的
    ///   deselect（直接参数同样是 document、variants 是具名参数），因此 select 前先
    ///   清掉当前选中，让"显示"= 真正替换选中。
    ///
    /// 输出：每条路径一行 "1"/"0"，与 paths 同序（调用方据此算 notFound）；
    /// `on error` 分支返回单行 `"error:<msg>"`，由 reportedScriptError(in:) 先筛出
    /// 并当脚本失败抛出（C7：不能被当"未找到"，也不能兜底 open -a）。
    ///
    /// - Parameter deselectFirst：true = 先清掉当前选中（默认；"在 C1 中显示"是替换语义）。
    ///   false = 只追加选中，供 R3 的 browse 重试用（重试只带 notFound 的照片，
    ///   清选中会把第一批已选中的照片从 C1 选中里抹掉）。
    static func selectVariantsScript(
        appName: String,
        paths: [String],
        deselectFirst: Bool = true
    ) -> String {
        let literals = paths.map(appleScriptLiteral).joined(separator: ", ")
        let deselectBlock = deselectFirst ? """
            -- R12：select 只"加入"选中；先 deselect 当前选中，最终选中 = 本批命中项。
            -- 读不到/清不掉选中是受控降级（继续 select），不让它把整次"显示"变成脚本失败。
            set previousSelection to {}
            try
              set previousSelection to selected variants
            end try
            if (count of previousSelection) > 0 then
              try
                deselect targetDoc variants previousSelection
              end try
            end if
        """ : ""
        return """
        tell application "\(appName)"
          try
            set targetDoc to current document
        \(deselectBlock)
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

    /// R3（Wave5）：让 C1 把浏览集合切到指定目录（sdef:678-684，
    /// `browse <document> to path <folder>`，cocoa key thePath）。
    ///
    /// 为什么需要：写回/选中/"在 C1 中显示"的作用域都是 C1 **当前集合**
    /// （sdef:325-334 document 的 image 元素、:736），Gather 从不切换集合 → 跨集合
    /// 一律 0 命中（notFound）且旧实现没有补救。这里只做"切集合"这一件事：
    /// 切不切、切到哪个目录由调用方决定（**唯一父目录**才切，不猜）。
    ///
    /// 输出："1" = 已切；失败走 `on error` 返回 `error:<msg>`（调用方用
    /// reportedScriptError 判定并记日志——切集合失败不得被当成"没找到"吞掉）。
    static func browseScript(appName: String, path: String) -> String {
        """
        tell application "\(appName)"
          try
            set targetDoc to current document
            browse targetDoc to path \(appleScriptLiteral(path))
            return "1"
          on error theErr
            return "error:" & (theErr as text)
          end try
        end tell
        """
    }

    /// R1（Wave5）只读脚本：一次读回每个 image 在**当前集合**里的 variant 数。
    ///
    /// 为什么必须先读：变体级写回的目标是启发式（已 pick 否则 variant 1），同一 image
    /// 有多个 variant 时会改错目标且不可逆（96 号 §10 把"写错 variant"判 P0）。
    /// 数量是唯一能安全判定的信号：
    /// - 0 → 不在当前集合（notFound，可按父目录 browse 补救一次）；
    /// - 1 → 唯一目标，维持原写回；
    /// - >1 → 不猜目标，整条跳过（skippedMultiVariant），由用户回 C1 选变体后重试。
    ///
    /// C1 16.7 sdef 依据：document 的 image 元素 = 当前集合（`:325-334`、`:736`）；
    /// variant 是 image 的子元素（`variants of theImage`），自身没有 path（`:1081`/`:1541`）。
    /// 输出：每条请求路径一行十进制计数，与 paths 同序（解析见 parseVariantCounts）。
    static func variantCountReadScript(appName: String, paths: [String]) -> String {
        let literals = paths.map(appleScriptLiteral).joined(separator: ", ")
        return """
        tell application "\(appName)"
          set targetDoc to current document
          set report to ""
          repeat with p in {\(literals)}
            set matches to (every image of targetDoc whose path is p)
            if (count of matches) > 0 then
              set theImage to (item 1 of matches)
              set report to report & ((count of (variants of theImage)) as text) & linefeed
            else
              set report to report & "0" & linefeed
            end if
          end repeat
          return report
        end tell
        """
    }

    /// 写前回读报告解析：行数必须等于请求路径数、每行必须是非负整数；否则 nil
    ///（形状不认识 = 脚本契约变了，调用方带原文抛 C1_SCRIPT_FAILED，绝不按"未知"盲写）。
    static func parseVariantCounts(_ output: String, expected: Int) -> [Int]? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count == expected else { return nil }
        var counts: [Int] = []
        counts.reserveCapacity(lines.count)
        for line in lines {
            guard let count = Int(line), count >= 0 else { return nil }
            counts.append(count)
        }
        return counts
    }

    /// R1 写前回读的分区（纯函数：C1BridgeWave3Tests 直接驱动）。
    ///
    /// counts 与 items 同序（parseVariantCounts 保证行数相等）；越界按"当前集合里没有"
    /// 处理（保守：宁可 notFound 也不写错 variant）。
    static func partitionVariantTargets(
        items: [C1VariantWritebackItem],
        counts: [Int]
    ) -> C1VariantTargetPartition {
        var result = C1VariantTargetPartition(writable: [], multiVariant: [], notFound: [])
        for (index, item) in items.enumerated() {
            let count = index < counts.count ? counts[index] : 0
            if count == 0 {
                result.notFound.append(item)
            } else if count == 1 {
                result.writable.append(item)
            } else {
                result.multiVariant.append(item.photoPath)
            }
        }
        return result
    }

    /// R3：notFound 里**磁盘上存在**的照片的唯一父目录（nil = 不存在/不唯一 → 不切集合）。
    ///
    /// 为什么要求文件存在：切集合只对"C1 在看别的目录"有效；文件本身不在盘上时切过去
    /// 也找不到，只会打断用户当前的 C1 视图。
    static func singleParentDirectory(of paths: [String]) -> String? {
        var directory: String?
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let parent = TSPath.dirname(path)
            guard !parent.isEmpty, parent != path else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            if let directory, directory != parent { return nil }
            directory = parent
        }
        return directory
    }

    /// select 报告 → 命中/未命中（纯函数：与 flags 同序；非 "1" 一律按未命中，沿用旧口径）。
    static func splitSelectionReport(
        flags: [String],
        requested: [String],
        selected: inout [String],
        missing: inout [String]
    ) {
        for (index, flag) in flags.enumerated() where index < requested.count {
            if flag == "1" {
                selected.append(requested[index])
            } else {
                missing.append(requested[index])
            }
        }
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
          set selectedVariantsList to {}
          try
            set selectedVariantsList to selected variants
          on error
            -- P2（Wave4b）受控回退 primary variant（不整体失败）。
            try
              set primaryVariant to primary variant
              if primaryVariant is not missing value then set selectedVariantsList to {primaryVariant}
            end try
          end try
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

    // MARK: - G3：导出选中 variant 的判断数据（只读）

    /// G3 只读脚本：导出当前选中 variant 的判断数据。
    ///
    /// C1 16.7 sdef 依据（本机 CaptureOne.sdef，16.7.8.16）：
    /// - selected variants 是 application 属性（`:244-247`；前端文档浏览器的选中项）；
    /// - 路径：variant 没有 path，路径在 parent image（`:1081`）的 path（`:1541`）；
    /// - 判断：rating（`:1097`）、color tag（`:1096`）、pick（`:1084`）是 variant 属性；
    /// - 关键词：variant 的 keyword 元素（`:1073`）→ keyword.name（`:966`）；
    /// - 无文档时先取 current document 抛错（宿主归一到 C1_NO_DOCUMENT）。
    ///
    /// 输出契约：P 行 = TAB 分隔的 4 个带前缀字段（P=路径、R=rating、T=color tag、
    /// K=pick 0/1）；W 行 = 一个关键词（挂到最近一条 P 记录）。值内的反斜杠 /
    /// 换行 / 回车 / TAB 由 escapeField 转义（路径与关键词可含任意字符），解析见
    /// parseVariantJudgements。转义只影响可读性，不改变 AppleScript 侧的数据语义。
    static func selectedVariantJudgementsScript(appName: String) -> String {
        #"""
        on escapeField(theText)
          set savedDelimiters to AppleScript's text item delimiters
          set AppleScript's text item delimiters to "\\"
          set parts to text items of theText
          set AppleScript's text item delimiters to "\\\\"
          set theText to parts as text
          set AppleScript's text item delimiters to linefeed
          set parts to text items of theText
          set AppleScript's text item delimiters to "\\n"
          set theText to parts as text
          set AppleScript's text item delimiters to return
          set parts to text items of theText
          set AppleScript's text item delimiters to "\\r"
          set theText to parts as text
          set AppleScript's text item delimiters to tab
          set parts to text items of theText
          set AppleScript's text item delimiters to "\\t"
          set theText to parts as text
          set AppleScript's text item delimiters to savedDelimiters
          return theText
        end escapeField

        tell application "\#(appName)"
          set frontDocument to current document
          set selectedVariantsList to {}
          try
            set selectedVariantsList to selected variants
          on error
            -- P2（Wave4b）受控回退 primary variant（不整体失败）。
            try
              set primaryVariant to primary variant
              if primaryVariant is not missing value then set selectedVariantsList to {primaryVariant}
            end try
          end try
          set output to ""
          repeat with v in selectedVariantsList
            set parentImage to parent image of v
            set pickFlag to "0"
            if pick of v then set pickFlag to "1"
            set output to output & "P" & my escapeField(path of parentImage) & tab & "R" & (rating of v as text) & tab & "T" & (color tag of v as text) & tab & "K" & pickFlag & linefeed
            repeat with k in (keywords of v)
              set output to output & "W" & my escapeField(name of k) & linefeed
            end repeat
          end repeat
          return output
        end tell
        """#
    }

    /// 解析 G3 只读脚本输出（纯函数：测试直接驱动，不执行脚本）。
    ///
    /// 畸形行（前缀不认识 / 缺字段 / 数字非法 / W 行前面没有 P 记录）跳过并计入
    /// malformedLines：G3 的失败语义是「没有判断数据可映射」，而不是「整批失败」。
    static func parseVariantJudgements(_ output: String) -> C1VariantJudgementParseResult {
        var judgements: [C1VariantJudgement] = []
        var malformed: [String] = []
        var currentPath: String?
        var currentRating = 0
        var currentTag = 0
        var currentPick = false
        var currentKeywords: [String] = []

        func flush() {
            guard let path = currentPath, !path.isEmpty else { return }
            // rating 只有 0…5 合法；越界按上下界钳制（不整行丢弃，评级仍是可用信号）。
            judgements.append(C1VariantJudgement(
                photoPath: path,
                rating: max(0, min(5, currentRating)),
                colorTag: currentTag,
                pick: currentPick,
                keywords: currentKeywords))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            switch line.first {
            case "P":
                flush()
                currentPath = nil
                currentKeywords = []
                let fields = line.dropFirst()
                    .split(separator: "\t", omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count == 4,
                      fields[1].hasPrefix("R"),
                      fields[2].hasPrefix("T"),
                      fields[3].hasPrefix("K"),
                      let rating = Int(fields[1].dropFirst()),
                      let tag = Int(fields[2].dropFirst()) else {
                    malformed.append(line)
                    continue
                }
                let pickRaw = String(fields[3].dropFirst())
                guard pickRaw == "0" || pickRaw == "1" else {
                    malformed.append(line)
                    continue
                }
                currentPath = Self.unescapeVariantField(fields[0])
                currentRating = rating
                currentTag = tag
                currentPick = pickRaw == "1"
            case "W":
                guard currentPath != nil else {
                    malformed.append(line)
                    continue
                }
                currentKeywords.append(
                    Self.unescapeVariantField(String(line.dropFirst())))
            default:
                malformed.append(line)
            }
        }
        flush()
        return C1VariantJudgementParseResult(
            judgements: judgements, malformedLines: malformed)
    }

    /// 还原脚本 escapeField 的转义：\\ → \、\n → 换行、\r → 回车、\t → TAB。
    /// 未知转义原样保留（不吞数据；是否需要报错由调用方按诊断决定）。
    static func unescapeVariantField(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                result.append("\\")
                break
            }
            switch escaped {
            case "\\": result.append("\\")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            default:
                result.append("\\")
                result.append(escaped)
            }
        }
        return result
    }

    // MARK: - Wave3 / G4：变体级写回（在线通道；XMP 通道保留为离线兜底）

    /// 单次写回的条目上限：AppleScript 单次脚本过长会变慢/超时，调用方负责分批。
    static let maxVariantWritebackItems = 500

    /// 把文件级判断按 variant 写回 C1（在线通道）。
    ///
    /// 流程：路径 → `every image of targetDoc whose path is p`，取该 image 的 variants；
    /// 目标 variant = 已 pick 的那个，否则 position 1；**只写目标 variant**，
    /// 同一 image 其余 variant 原值不动（G5：多 variant 不互相覆盖）。
    /// 写属性：rating / color tag / pick。**A3：pick 只表达 keep**（写 true）；
    /// reject/unreviewed 一律不写 pick —— C1 16.7 sdef 没有 reject 位（:1084），
    /// 写 false 会取消 C1 已有的 pick 且读回只能当 unreviewed（不可逆）。
    /// 不写任何关键词：G4 明确禁止用 culling:keep 污染 C1 词库。
    ///
    /// 收口：写的是 C1 catalog 本身（已是权威），因此**不**再对同一 variant 调
    /// reload metadata（那会把盘上旧 XMP 读回、覆盖刚写入的判断）。**全部命中**时
    /// 才沿用 durable reload-ack（sessions.reload_acked_at），confirm/finalize 门禁
    /// 照常放行；部分成功（notFound/skipped/skippedMultiVariant）不写 ack
    ///（A1：避免门禁误放行）。
    /// 离线/未运行时仍走原 XMP 写回（本方法不触碰 XMP）。
    ///
    /// Wave5（2026-11-11，task-11）补两层安全：
    /// - **R1 写前回读**：先用只读脚本读每个 image 在当前集合里的 variant 数。
    ///   0 → notFound；1 → 维持原写回；>1 → **不猜目标**，整条跳过并进
    ///   skippedMultiVariant（写错 variant 不可逆，96 号 §10 判 P0）。
    ///   回读脚本失败 = 拿不到目标信息，直接上浮 C1_SCRIPT_FAILED（绝不盲写）。
    /// - **R3 作用域补救**：先写当前集合里能写的，再对 notFound（磁盘上存在、父目录
    ///   唯一）让 C1 `browse` 切到该目录后**只重试这些**（重读一次变体数；仍 notFound
    ///   才如实报，UI 提示"C1 当前集合未包含这些照片"）。browse 失败只记 warn，
    ///   不吞错也不谎报成功。
    ///
    /// 【口径已确认 2026-11-11（Lead/产品批准）】**不要**把这里"修"成先 reload 再写/写后 reload：
    /// 变体级写回取代的是"写 XMP 再让 C1 Load"这条链路；若需要 XMP 权威（离线兜底），
    /// 用户应显式走「写回 XMP…」再手动 Load/手动 ack。
    public func writeVariantJudgements(
        sessionId: String?,
        items: [C1VariantWritebackItem]
    ) async throws -> C1VariantWritebackReport {
        var unique: [C1VariantWritebackItem] = []
        var seen = Set<String>()
        var notFound: [String] = []
        var skipped = 0
        for item in items {
            let path = item.photoPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else {
                notFound.append(item.photoPath)
                continue
            }
            // 去重键用 canonical（fold /private 前缀），脚本仍用原始路径匹配 C1 登记值。
            let key = ScanPath.canonical(path)
            guard seen.insert(key).inserted else { continue }
            guard unique.count < Self.maxVariantWritebackItems else {
                skipped += 1
                continue
            }
            unique.append(C1VariantWritebackItem(
                photoPath: path,
                rating: max(0, min(5, item.rating)),
                // 越界色标按 None(0) 写：宁可清色标也不把非法整数塞进 C1。
                colorTag: C1ColorTagMapping.label(for: item.colorTag) == nil ? 0 : item.colorTag,
                pick: item.pick))
        }
        guard !unique.isEmpty else {
            return C1VariantWritebackReport(written: 0, notFound: notFound, skipped: skipped)
        }

        let appName = try await captureOneApplicationName()
        // R1：写前回读变体数（脚本失败上浮，绝不按"未知"盲写）。
        let firstPartition = Self.partitionVariantTargets(
            items: unique,
            counts: try await readVariantCounts(
                paths: unique.map(\.photoPath), appName: appName))
        var multiVariant = firstPartition.multiVariant
        var written = 0

        // 第一批：写当前集合里**唯一 variant** 的目标（启发式此时等价于唯一目标）。
        let first = try await writeVariantItems(firstPartition.writable, appName: appName)
        written += first.written
        notFound.append(contentsOf: first.notFound)

        // R3：当前集合里没有的照片若磁盘上存在、父目录唯一 → 让 C1 browse 切到该目录，
        // 然后**只重试这些**（重读一次变体数；已写的第一批不受影响）。只重试一次。
        let missingItems = firstPartition.notFound
        if !missingItems.isEmpty,
           let directory = Self.singleParentDirectory(of: missingItems.map(\.photoPath)),
           await browse(toDirectory: directory, appName: appName) {
            var retried: C1VariantTargetPartition?
            do {
                retried = Self.partitionVariantTargets(
                    items: missingItems,
                    counts: try await readVariantCounts(
                        paths: missingItems.map(\.photoPath), appName: appName))
            } catch {
                // 切集合后回读失败：保留第一次的 notFound（不吞错：日志带原文）。
                GatherLogger.log(
                    "c1.variant_writeback browse=\(directory) 回读失败: \(error)",
                    level: .warn)
                notFound.append(contentsOf: missingItems.map(\.photoPath))
            }
            if let retried {
                multiVariant.append(contentsOf: retried.multiVariant)
                notFound.append(contentsOf: retried.notFound.map(\.photoPath))
                // 第二批的写回脚本失败仍然上浮（不是"找不到"，不能混成 notFound）。
                let second = try await writeVariantItems(retried.writable, appName: appName)
                written += second.written
                notFound.append(contentsOf: second.notFound)
            }
        } else {
            notFound.append(contentsOf: missingItems.map(\.photoPath))
        }

        // A1：部分写回**不解门禁**。reload-acked 是会话级"C1 已看到新值"的断言
        // （DeliveryCoordinator.requireReloadAck 用它放行 confirm/finalize→清理备份），
        // notFound/skipped/skippedMultiVariant 非空说明有请求没写进 C1；此时写 ack 会让
        // 交付在 C1 仍显示旧值时被确认/清理。只有全部命中（且确有写入）才写 ack。
        if written > 0, notFound.isEmpty, skipped == 0,
           multiVariant.isEmpty, let sessionId {
            // C1 catalog 已是权威值：写 durable ack 让 confirm/finalize 门禁放行，
            // 但绝不再触发 reload（会把旧 XMP 读回覆盖判断）。ack 写失败只记日志，
            // 不掩盖"C1 已写入"的事实（: ack 是会话级簿记，不是写入结果）。
            do { try recordReloadAck(sessionId) } catch {
                GatherLogger.log(
                    "c1.variant_writeback ack failed: \(error)", level: .warn)
            }
        }
        return C1VariantWritebackReport(
            written: written, notFound: notFound, skipped: skipped,
            skippedMultiVariant: multiVariant)
    }

    /// 对一批**已确认唯一 variant** 的条目发一次写回脚本；逐条判定写入/未命中。
    ///
    /// 未命中（脚本回 "0"）如实进 notFound：回读到写入之间用户可能切了集合/删了图，
    /// 这是真实结果，不重试也不假装成功。脚本/报告形状失败上浮 C1_SCRIPT_FAILED。
    private func writeVariantItems(
        _ items: [C1VariantWritebackItem],
        appName: String
    ) async throws -> (written: Int, notFound: [String]) {
        guard !items.isEmpty else { return (0, []) }
        let output = try await runAppleScript(
            Self.variantWritebackScript(appName: appName, items: items), timeout: 30)
        guard let flags = Self.parseVariantWritebackReport(output, expected: items.count) else {
            throw CaptureOneBridgeError.scriptFailed(
                "unexpected variant writeback report: \(output)")
        }
        var written = 0
        var notFound: [String] = []
        for (index, flag) in flags.enumerated() {
            if flag == "1" {
                written += 1
            } else {
                notFound.append(items[index].photoPath)
            }
        }
        return (written, notFound)
    }

    /// 写回脚本（internal：脚本契约由 C1BridgeWave3Tests 文本断言）。
    ///
    /// 输入只包含**写前回读确认过**的单 variant image（Wave5 / R1：多 variant 已在
    /// partitionVariantTargets 里整条跳过），因此下面的"已 pick 否则 variant 1"启发式
    /// 只会落在唯一那个 variant 上，不再有"改错 variant"的风险。
    ///
    /// 输出：每条请求路径一行 "1"/"0"，与 items 同序（解析见 parseVariantWritebackReport）。
    static func variantWritebackScript(
        appName: String,
        items: [C1VariantWritebackItem]
    ) -> String {
        var blocks: [String] = []
        for item in items {
            let rating = max(0, min(5, item.rating))
            let tag = C1ColorTagMapping.label(for: item.colorTag) == nil ? 0 : item.colorTag
            var lines = [
                "    set matches to (every image of targetDoc whose path is \(appleScriptLiteral(item.photoPath)))",
                "    if (count of matches) > 0 then",
                "      set theImage to (item 1 of matches)",
                "      set targetVariant to missing value",
                "      repeat with v in (variants of theImage)",
                "        if pick of v then set targetVariant to v",
                "      end repeat",
                "      if targetVariant is missing value then set targetVariant to variant 1 of theImage",
                "      if targetVariant is not missing value then",
                "        set rating of targetVariant to \(rating)",
                "        set color tag of targetVariant to \(tag)",
            ]
            // A3：C1 无 reject 位 → 只写 keep（true）。false 视为"不写"：
            // 保留 C1 现值比写入一个不可逆的 false 更安全（淘汰不写回 C1）。
            if item.pick == true {
                lines.append("        set pick of targetVariant to true")
            }
            lines.append(contentsOf: [
                "        set report to report & \"1\" & linefeed",
                "      else",
                "        set report to report & \"0\" & linefeed",
                "      end if",
                "    else",
                "      set report to report & \"0\" & linefeed",
                "    end if",
            ])
            blocks.append(lines.joined(separator: "\n"))
        }
        return """
        tell application "\(appName)"
          set targetDoc to current document
          set report to ""
        \(blocks.joined(separator: "\n"))
          return report
        end tell
        """
    }

    /// 写回报告解析：每行 "1"/"0"，行数必须等于请求条目数；否则 nil（契约不匹配）。
    static func parseVariantWritebackReport(_ output: String, expected: Int) -> [String]? {
        let flags = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard flags.count == expected, flags.allSatisfy({ $0 == "1" || $0 == "0" }) else {
            return nil
        }
        return flags
    }
}

/// G3 只读脚本的解析结果（internal：C1BridgeWave2Tests 直接驱动纯函数）。
struct C1VariantJudgementParseResult: Equatable {
    let judgements: [C1VariantJudgement]
    /// 无法解析的行原文：只进日志/诊断，导入侧不因畸形行失败。
    let malformedLines: [String]
}

/// R1 写前回读的分区结果（internal：C1BridgeWave3Tests 直接驱动纯函数）。
///
/// writable = 当前集合里恰好 1 个 variant（唯一目标，维持原写回）；
/// multiVariant = 多个 variant（不猜目标，整条跳过）；
/// notFound = 当前集合里没有（可按父目录 browse 补救一次）。
struct C1VariantTargetPartition: Equatable {
    var writable: [C1VariantWritebackItem]
    var multiVariant: [String]
    var notFound: [C1VariantWritebackItem]
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
