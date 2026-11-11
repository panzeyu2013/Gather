// desktop/native/gather-core/Sources/GatherProtocol/Protocol/C1.swift
// Cut 3 / 3b-0：Capture One 宿主桥的公共表面从 gather-app 的
// Host/CaptureOneBridge.swift 上移到协议层（E-17）：
//   · C1PreflightStatus   —— 四层预检 DTO（c1-preflight.ts 形状）；
//   · CaptureOneBridgeError —— 桥接错误（码值取 GatherErrorCode）；
//   · CaptureOneBridging  —— UI 唯一可见的能力面（实现仍留 GatherHost）。
//
// 本文件只依赖 GatherErrorCode，不含 AppleScript / 子进程代码——那些是实现
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