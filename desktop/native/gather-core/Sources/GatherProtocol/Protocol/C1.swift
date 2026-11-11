// desktop/native/gather-core/Sources/GatherProtocol/Protocol/C1.swift
// Cut 3 / 3b-0：Capture One 宿主桥的公共表面从 gather-app 的
// Host/CaptureOneBridge.swift 上移到协议层（E-17）：
//   · C1PreflightStatus   —— 四层预检 DTO（c1-preflight.ts 形状）；
//   · CaptureOneBridgeError —— 桥接错误（码值取 GatherErrorCode）；
//   · CaptureOneBridging  —— UI 唯一可见的能力面（实现仍留 GatherHost）。
//
// 本文件只依赖同 target 的错误码/路径工具（GatherErrorCode / ScanPath / TSPath）
// 与 Foundation 的只读目录列举，不含 AppleScript / 子进程代码——那些是实现
// 细节，继续留在 Host/CaptureOneBridge.swift。3b-0 只做类型搬家与
// conformance；UI 改持 `any CaptureOneBridging`（并删掉 3 处默认自建）在
// 3b-3 做，届时静态脚本入口按 `type(of: bridge).documentProbeScript(appName:)`
// 调用（协议静态要求无法通过实例调用）。
//
// recordReloadAck 不在协议里：它是 CaptureOneBridge.init 注入的持久化闭包
// （生产为 AppRuntime.recordReloadAck），不是 UI 可调用的能力成员。
//
// Wave1（2026-11-11，task-6）在 G1/G2 上补齐两处：
//   · CaptureOneBridgeError 增加 .noSelection —— C1 16.7 sdef 里 reload metadata
//     的直接参数是 variant，本机没有选中项时"没有可重载的对象"，必须显式报错
//     而不是盲发（码值复用 C1_NO_SELECTED_PHOTOS：同为"请在 C1 中选照片"）；
//   · 补 CodedError 一致性：码值仍取 GatherErrorCode（单一事实源），同时让
//     C1RoundTripCoordinator 的失败提示拿得到具体码，不再一律显示 C1_SCRIPT_FAILED。
//
// Wave3（2026-11-11，task-18）：
//   · 变体级写回 DTO + `writeVariantJudgements` 协议要求（默认实现 = 未接线降级）；
//   · color tag 双向映射 C1ColorTagMapping（G3 读/G4 写共用一张表）；
//   · C1 Session 三目录识别 C1SessionDirectoryResolver（纯逻辑，目录列举可注入）；
//   · C1HotFolderCaveat：Hot Folder 不可检测的能力边界（不假装检测）。

import Foundation

/// TS: C1HealthLite —— 四层预检布尔位 + 超时标记（c1-preflight.ts 形状）。
public struct C1PreflightStatus: Equatable, Sendable {
    public var reachable: Bool
    public var appRunning: Bool
    public var automationAuthorized: Bool
    public var documentOpen: Bool
    /// 探针超时（Apple Events -1712 / 探针被杀）：此时不得声称自动化已授权。
    public var timedOut: Bool
    public var appName: String?

    public init(
        reachable: Bool,
        appRunning: Bool,
        automationAuthorized: Bool,
        documentOpen: Bool,
        timedOut: Bool,
        appName: String? = nil
    ) {
        self.reachable = reachable
        self.appRunning = appRunning
        self.automationAuthorized = automationAuthorized
        self.documentOpen = documentOpen
        self.timedOut = timedOut
        self.appName = appName
    }
}

/// Capture One 桥的稳定错误。码值统一取 GatherErrorCode（单一事实源：
/// UI 按码取本地化文案，枚举外的裸字符串会绕过本地化并逃过交叉契约测试）。
public enum CaptureOneBridgeError: Error, Equatable, CustomStringConvertible, Sendable, CodedError {
    case notRunning
    case noDocument
    case notAuthorized
    case timedOut
    /// C1 当前没有选中的 variant。
    ///
    /// 语义：reload metadata 在 C1 16.7 sdef 里的直接参数是 variant
    /// （CaptureOne.sdef:1852-1855），没有选中项时不存在可重载对象。此时不允许
    /// "假装成功"，也不允许退化成 document 级盲发——直接报码，让用户先在 C1
    /// 选片（或用「在 Capture One 中显示」把照片选中）。
    case noSelection
    case scriptFailed(String)

    public var code: GatherErrorCode {
        switch self {
        case .notRunning: return .C1_NOT_RUNNING
        case .noDocument: return .C1_NO_DOCUMENT
        case .notAuthorized: return .C1_NOT_AUTHORIZED
        case .timedOut: return .C1_SCRIPT_TIMEOUT
        case .noSelection: return .C1_NO_SELECTED_PHOTOS
        case .scriptFailed: return .C1_SCRIPT_FAILED
        }
    }

    public var description: String { code.rawValue }
}

/// UI 依赖的 Capture One 能力面（实现：CaptureOneBridge，在 GatherHost）。
///
/// 5 个成员就是 UI 现有调用面：选片路径、重载元数据、健康检查、四层预检、
/// 文档探针脚本。拆除具体类型后，UI 只持 `any CaptureOneBridging`，测试可注入
/// 替身，且 Host 与 UI 不再互相 import。
public protocol CaptureOneBridging: Sendable {
    /// 当前文档中用户已选中的 variant 路径（仅存在的绝对路径）。
    ///
    /// C1 16.7 sdef 依据：selected variants 是 **application** 属性（当前文档
    /// 浏览器里的选中项），variant 本身没有 path，路径在 parent image 的 path。
    func selectedPhotoPaths() async throws -> [String]
    /// 让 Capture One 重新读取当前选中 variant 的源文件元数据，成功后才写 durable ack。
    ///
    /// C1 16.7 sdef 依据：reload metadata 的直接参数是 **variant**（per-variant），
    /// 没有选中项时抛 .noSelection（不盲发、不写 ack）。
    func reloadMetadata(sessionId: String) async throws
    /// System Events 进程探测 + 应用名解析。
    func checkHealth() async -> Result<String, CaptureOneBridgeError>
    /// 四层预检（可达 / 运行 / 自动化授权 / 文档打开），失败回退不抛。
    func preflight() async -> C1PreflightStatus
    /// 文档探针脚本文本（预检与设置页健康检查共用）。
    static func documentProbeScript(appName: String) -> String
    /// Wave3 / G4：把文件级判断按 variant 写回 C1（默认实现 = 未接线，见下方扩展）。
    ///
    /// 放进协议要求（而不是只做扩展方法）：扩展方法对存在类型是静态派发，
    /// 生产门面的实现必须能被 `any CaptureOneBridging` 动态派发到。
    func writeVariantJudgements(
        sessionId: String?,
        items: [C1VariantWritebackItem]
    ) async throws -> C1VariantWritebackReport
}

// MARK: - C1 变体级判断（Wave2 / G3：导入前只读）

/// 一个 C1 变体的判断数据（**原始读取值**，不做 Gather 侧映射）。
///
/// 为什么不在这里映射：C1 的 `color tag` 是裸整数（CaptureOne.sdef 只声明
/// type=integer，没有枚举），`pick` 是布尔，`rating` 是 0…5 整数。到 Gather 的
/// rating / 色标 / pickState 的映射属于应用层（GatherApplication 的
/// C1ImportJudgementService），协议层只承载「从 C1 读到了什么」。
public struct C1VariantJudgement: Equatable, Sendable {
    /// parent image 的原始绝对路径（C1 sdef：`parent image` → `image.path`）。
    public let photoPath: String
    /// C1 variant 评级 0…5。
    public let rating: Int
    /// C1 color tag 原始整数（映射表在应用层；越界值降级为不写入）。
    public let colorTag: Int
    /// C1 variant 的 pick 标志（true = 已选中/挑中）。
    public let pick: Bool
    /// variant 当前的关键词（层级路径或扁平词，按 C1 原值）。
    public let keywords: [String]

    public init(photoPath: String, rating: Int, colorTag: Int, pick: Bool, keywords: [String]) {
        self.photoPath = photoPath
        self.rating = rating
        self.colorTag = colorTag
        self.pick = pick
        self.keywords = keywords
    }
}

/// 一次「从 C1 读当前选中」的完整快照：文件路径 + 变体级判断。
///
/// paths 与 judgements 同源（同一次脚本调用），避免两次读取之间 C1 选中项漂移；
/// 只保留存在且为绝对路径的条目（与 selectedPhotoPaths 同口径）。
/// 同一 parent image 可能有多个 variant ⇒ judgements 里同一路径可出现多次，
/// 合并规则在应用层（C1ImportJudgementService），协议层不预设。
public struct C1SelectionSnapshot: Equatable, Sendable {
    /// 去重后的照片路径（按脚本输出顺序，与导入口径一致）。
    public let paths: [String]
    public let judgements: [C1VariantJudgement]

    public init(paths: [String], judgements: [C1VariantJudgement]) {
        self.paths = paths
        self.judgements = judgements
    }

    public static let empty = C1SelectionSnapshot(paths: [], judgements: [])
}

// MARK: - Wave3：变体级写回 DTO（G4/G5）

/// Gather 文件级判断 → C1 variant 的一条写回项。
///
/// 语义：Gather 的逻辑资产是文件，C1 的判断在 variant 上。写回时由脚本把路径展开成
/// image→variants，并只写**目标 variant**（已 pick 的优先，否则 position 1），
/// 同一 image 的其余 variant 保持原值（不互相覆盖）。
///
/// - rating：0…5（越界会被钳制）；
/// - colorTag：C1 color tag 原始整数（映射见 C1ColorTagMapping）；
/// - pick：nil = 本次不写（Gather 未处理）；true = keep；false = reject。
///   C1 只有布尔 pick 位，因此 keep/reject 用 pick 写、**不写任何关键词**（旧实现用
///   culling:keep 关键词会污染 C1 词库，G4 明确禁止）。
public struct C1VariantWritebackItem: Equatable, Sendable {
    public var photoPath: String
    public var rating: Int
    public var colorTag: Int
    public var pick: Bool?

    public init(photoPath: String, rating: Int, colorTag: Int, pick: Bool?) {
        self.photoPath = photoPath
        self.rating = rating
        self.colorTag = colorTag
        self.pick = pick
    }
}

/// 变体级写回结果（逐路径：写入 / 当前文档里找不到）。
public struct C1VariantWritebackReport: Equatable, Sendable {
    /// 实际写入的 variant 数（每个路径最多一个目标 variant）。
    public var written: Int
    /// 当前文档里找不到的路径（不 fallback、不导入）。
    public var notFound: [String]
    /// 超过单次批量上限/非法路径而未处理的条目数（调用方需分批）。
    public var skipped: Int
    /// 非 nil = 该通道未接线（默认实现），调用方应退回 XMP 写回；不是错误。
    public var unsupportedReason: String?

    public init(
        written: Int = 0,
        notFound: [String] = [],
        skipped: Int = 0,
        unsupportedReason: String? = nil
    ) {
        self.written = written
        self.notFound = notFound
        self.skipped = skipped
        self.unsupportedReason = unsupportedReason
    }

    public static func unsupported(_ reason: String) -> C1VariantWritebackReport {
        C1VariantWritebackReport(unsupportedReason: reason)
    }
}

/// C1 color tag 整数的**双向**映射（唯一事实源：G3 读取与 G4 写回共用）。
///
/// C1 16.7 sdef 只声明 `color tag` 是 integer（CaptureOne.sdef:1096），没有枚举；
/// 本机 C1 的色标集合（None/Red/Orange/Yellow/Green/Blue/Pink/Purple）与 Gather
/// `CaptureOneColorLabel` 的声明序一致，映射按该顺序：0=None…7=Purple。
/// 越界整数返回 nil（不猜、不写）；真机核对点见 Wave2 报告。
public enum C1ColorTagMapping {
    public static func label(for raw: Int) -> CaptureOneColorLabel? {
        switch raw {
        // 注意：返回类型是 Optional，`.none` 会被解析成 Optional.none(nil)；
        // 这里必须显式写枚举值，否则 C1 的"无标签"会被当成"未映射"。
        case 0: return CaptureOneColorLabel.none
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        case 4: return .green
        case 5: return .blue
        case 6: return .pink
        case 7: return .purple
        default: return nil
        }
    }

    /// 反向映射（写回用）：Gather 色标 → C1 整数。
    public static func rawValue(for label: CaptureOneColorLabel) -> Int {
        switch label {
        case .none: return 0
        case .red: return 1
        case .orange: return 2
        case .yellow: return 3
        case .green: return 4
        case .blue: return 5
        case .pink: return 6
        case .purple: return 7
        }
    }

    public static func isReversible(_ raw: Int) -> Bool {
        guard let label = label(for: raw) else { return false }
        return rawValue(for: label) == raw
    }
}

// MARK: - Wave3：C1 Session 三目录识别（G6）

/// C1 Session 的目录角色（Capture/Selects/Trash；Output 仅标注）。
public enum C1SessionDirectoryRole: String, Equatable, Sendable {
    case root
    case capture = "Capture"
    case selects = "Selects"
    case trash = "Trash"
    case output = "Output"
    case other
}

/// 识别结果：C1 Session 布局 + 安全的导入/扫描计划。
///
/// 为什么需要：C1 Session 的根目录包含 Capture（原始）、Selects（挑中/移动后的文件）、
/// Trash（淘汰）。把根目录当普通目录递归会把 Trash 淘汰件"复活"成普通资产，并在
/// Capture/Selects 之间产生重复。本布局给出**只扫 Capture** 的安全根与排除清单；
/// Selects 与 Capture 的同名去重规则见 `dedupe(captureFiles:selectsFiles:)`。
public struct C1SessionLayout: Equatable, Sendable {
    public let root: String
    public let capture: String?
    public let selects: String?
    public let trash: String?
    public let output: String?

    public init(root: String, capture: String?, selects: String?, trash: String?, output: String?) {
        self.root = root
        self.capture = capture
        self.selects = selects
        self.trash = trash
        self.output = output
    }

    /// 是否像 C1 Session（判据：存在 Capture，且至少还有 Selects/Trash 之一）。
    public var isCaptureOneSession: Bool {
        capture != nil && (selects != nil || trash != nil)
    }

    /// 建议扫描/导入根：存在 Capture 时只用它（Trash 不扫、Selects 不重复扫）。
    public var scanRoot: String { capture ?? root }

    /// 明确排除、不作为扫描根的目录（Trash 永远排除；Selects 只在存在时排除重复扫描）。
    public var excludedPaths: [String] {
        var result: [String] = []
        if let trash { result.append(trash) }
        if let selects { result.append(selects) }
        return result
    }

    /// 路径 → 目录角色（UI 标注用；按前缀匹配，大小写由调用方先归一）。
    public func role(of path: String) -> C1SessionDirectoryRole {
        if let capture, path == capture || path.hasPrefix(capture + "/") { return .capture }
        if let selects, path == selects || path.hasPrefix(selects + "/") { return .selects }
        if let trash, path == trash || path.hasPrefix(trash + "/") { return .trash }
        if let output, path == output || path.hasPrefix(output + "/") { return .output }
        if path == root { return .root }
        return .other
    }
}

/// C1 Session 目录识别与去重规划（纯逻辑：目录列举走注入接缝，单测不碰真 C1/FS）。
public enum C1SessionDirectoryResolver {
    /// 目录列举接缝：返回该目录下的**直接子项名**；不可读返回 nil。
    public typealias DirectoryLister = @Sendable (String) -> [String]?

    /// 真实文件系统列举（生产默认）。
    ///
    /// 用 do/catch 而不是 try?：cleanup ratchet 的 try_optional 指标只降不升（Sources 口径）。
    public static let fileManagerLister: DirectoryLister = { path in
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        } catch {
            return nil
        }
    }

    /// 识别 C1 Session：root 可以是 session 根，也可以是 `<root>/Capture`（UI 拿到的
    /// session.sourcePath 通常是后者）。无法识别返回 nil（普通目录，调用方保持旧行为）。
    public static func detect(
        root: String,
        listDirectory: DirectoryLister = C1SessionDirectoryResolver.fileManagerLister
    ) -> C1SessionLayout? {
        let canonical = ScanPath.canonical(root)
        if let layout = layout(root: canonical, listDirectory: listDirectory),
           layout.isCaptureOneSession {
            return layout
        }
        // session.sourcePath 可能就是 Capture 子目录：上溯一层再试。
        let parent = TSPath.dirname(canonical)
        if parent != canonical,
           let layout = layout(root: parent, listDirectory: listDirectory),
           layout.capture == canonical, layout.isCaptureOneSession {
            return layout
        }
        return nil
    }

    /// 只按目录名匹配（大小写不敏感：C1 用首字母大写，用户目录可能被改名）。
    private static func layout(
        root: String,
        listDirectory: DirectoryLister
    ) -> C1SessionLayout? {
        guard let entries = listDirectory(root) else { return nil }
        var byRole: [String: String] = [:]
        for name in entries {
            let lowered = name.lowercased()
            if byRole[lowered] != nil { continue }
            byRole[lowered] = root + "/" + name
        }
        let capture = byRole["capture"]
        guard capture != nil else { return nil }
        return C1SessionLayout(
            root: root,
            capture: capture,
            selects: byRole["selects"],
            trash: byRole["trash"],
            output: byRole["output"])
    }

    /// Selects 与 Capture 去重：按**文件名**（basename，大小写不敏感）去重，Capture 优先。
    ///
    /// C1 "Move to Selects" 会移动文件（只在一侧出现 → 必须保留）；若用户复制过，
    /// 两侧同名（只剩 Capture 优先 → 不重复导入）。返回需导入的文件 + 被判定为重复的数量。
    public static func dedupe(
        captureFiles: [String],
        selectsFiles: [String]
    ) -> (files: [String], skippedDuplicates: Int) {
        var seen = Set<String>()
        var files: [String] = []
        var skipped = 0
        for file in captureFiles {
            let key = (file as NSString).lastPathComponent.lowercased()
            guard seen.insert(key).inserted else { skipped += 1; continue }
            files.append(file)
        }
        for file in selectsFiles {
            let key = (file as NSString).lastPathComponent.lowercased()
            guard seen.insert(key).inserted else { skipped += 1; continue }
            files.append(file)
        }
        return (files, skipped)
    }
}

// MARK: - Wave3：C1 Hot Folder 的**能力边界**（G12）

/// C1 Hot Folder 协同的能力边界。
///
/// C1 16.7 sdef 没有读取 Hot Folder 设置的命令/属性（本机字典核对：无 hot folder
/// 术语），因此 Gather **无法检测**某个目录是否被 C1 监视。UI 只给风险提示
///（C1HotFolderNotice），绝不假装"已检测"。
public enum C1HotFolderCaveat {
    /// 是否具备检测能力（固定 false：C1 不在 AppleScript 面暴露该设置）。
    public static let canDetect = false
    /// 稳定诊断串（日志/诊断用；面向用户的中文提示走 l10n 表）。
    public static let undetectedReason =
        "C1 does not expose hot folder settings via AppleScript"
}
// MARK: - Wave3：变体级写回能力（CaptureOneBridging 扩展点）

public extension CaptureOneBridging {
    /// 把文件级判断按 variant 写回 C1；默认实现 = 未接线（调用方退回 XMP 写回）。
    ///
    /// 为什么默认实现返回 unsupported 而不是抛错：写回是可选增强，未接线时
    /// 用户应看到"请用 XMP 写回"的明确降级，而不是一条错误。
    func writeVariantJudgements(
        sessionId: String?,
        items: [C1VariantWritebackItem]
    ) async throws -> C1VariantWritebackReport {
        _ = sessionId
        _ = items
        return .unsupported("variant writeback not wired")
    }
}
/// C1 往返（手动 reload / 选中）的稳定错误。
///
/// 为什么在协议层：原先定义在 GatherHost 的 C1RoundTripCoordinator，但
/// GatherUI 的 CullingViewModel 必须按码上屏（reload 失败提示），而 GatherUI
/// 不得 import GatherHost（build.sh 分层检查）。Wave1 / task-6 起上移到这里，
/// code 仍取 GatherErrorCode 的 rawValue（单一事实源）。
public enum C1RoundTripError: Error, Equatable, CustomStringConvertible, Sendable {
    /// 预检不通过（手动 reload 用）：按缺什么给最贴近的既有码值。
    case preflightUnavailable(appRunning: Bool, documentOpen: Bool)
    case bridgeFailed(code: String, message: String)

    public var code: String {
        switch self {
        case .preflightUnavailable(let appRunning, let documentOpen):
            if !appRunning { return GatherErrorCode.C1_NOT_RUNNING.rawValue }
            if !documentOpen { return GatherErrorCode.C1_NO_DOCUMENT.rawValue }
            return GatherErrorCode.C1_NOT_AUTHORIZED.rawValue
        case .bridgeFailed(let code, _):
            return code
        }
    }

    public var description: String {
        switch self {
        case .preflightUnavailable(let appRunning, let documentOpen):
            let detail = !appRunning ? "Capture One 未运行"
                : (!documentOpen ? "Capture One 未打开文档" : "自动化权限不可用")
            return code + ": " + detail
        case .bridgeFailed(let code, let message):
            return message.isEmpty ? code : code + ": " + message
        }
    }
}