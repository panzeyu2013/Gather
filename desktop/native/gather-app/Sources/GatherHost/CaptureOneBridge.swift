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
// Wave5 batch6（2026-11-11，task-25 / 复核 R6）：
//   · writeRejectedColorTags(paths:)：把"淘汰"写成 C1 红标（只改 color tag，raw 1），
//     复用 R1 写前回读 + R3 browse 重试；脚本内再防御"非单 variant 不写"，不写 reload-ack。
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

final class CaptureOneCompletionGate: @unchecked Sendable {
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
// 已上移到 GatherProtocol（Protocol/C1.swift）；AppleScript 执行与写回实现已按
// 职责搬到 C1/CaptureOneBridge+Execution.swift 与 +Writeback.swift；本文件保留
// 类型声明 / 存储属性 / 共享静态辅助 / 静态 shared 注册与协议 conformance。
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

    let recordReloadAck: (String) throws -> Void
    /// AppleScript 执行接缝（nil = 真跑 osascript）。
    ///
    /// 为什么需要：脚本契约（对象归属/直接参数类型）与错误语义（无选中不盲发、
    /// 失败不吞）是本域最容易回归的部分，而真机验证要触发 TCC 自动化授权。
    /// 注入假运行器后，这些语义可以在单测里直接断言，运行时仍走 osascript。
    let appleScriptRunner: (@Sendable (String) async throws -> String)?
    /// P2（Wave4b）：本机是否安装 C1（Hot Folder 提示等 UI 据此 gate）。
    private let isC1Installed: () -> Bool
    /// P2（Wave4b）：本会话「已写盘」的照片路径（自动 reload 前先 select，避免必然 noSelection）。
    let writtenPhotoPaths: (String) throws -> [String]

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

    static func classify(_ error: Error) -> CaptureOneBridgeError {
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
    static let preflightProbeTimeout: TimeInterval = 3

    /// 与 TS PROCESS_PROBE_SCRIPT 同一形状的 System Events 进程探测脚本。
    static let processProbeScript =
        "tell application \"System Events\" to get name of every process whose name contains \"Capture One\""

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

    /// 脚本内部 on error 的报告前缀（与 selectVariantsScript 的 `"error:"` 返回值一致）。
    static let scriptErrorPrefix = "error:"

    /// 兜底打开（NSWorkspace.open 的等价物：不引 AppKit、不跨 actor）。
    static let openExecutable = "/usr/bin/open"
    static let openTimeout: TimeInterval = 15

    // MARK: - Wave3 / G4：变体级写回（在线通道；XMP 通道保留为离线兜底）

    /// 单次写回的条目上限：AppleScript 单次脚本过长会变慢/超时，调用方负责分批。
    static let maxVariantWritebackItems = 500

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
