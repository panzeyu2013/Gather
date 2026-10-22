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
public enum CaptureOneBridgeError: Error, Equatable, CustomStringConvertible, Sendable {
    case notRunning
    case noDocument
    case notAuthorized
    case timedOut
    case scriptFailed(String)

    public var description: String {
        switch self {
        case .notRunning: return GatherErrorCode.C1_NOT_RUNNING.rawValue
        case .noDocument: return GatherErrorCode.C1_NO_DOCUMENT.rawValue
        case .notAuthorized: return GatherErrorCode.C1_NOT_AUTHORIZED.rawValue
        case .timedOut: return GatherErrorCode.C1_SCRIPT_TIMEOUT.rawValue
        case .scriptFailed: return GatherErrorCode.C1_SCRIPT_FAILED.rawValue
        }
    }
}

/// UI 依赖的 Capture One 能力面（实现：CaptureOneBridge，在 GatherHost）。
///
/// 5 个成员就是 UI 现有调用面：选片路径、重载元数据、健康检查、四层预检、
/// 文档探针脚本。拆除具体类型后，UI 只持 `any CaptureOneBridging`，测试可注入
/// 替身，且 Host 与 UI 不再互相 import。
public protocol CaptureOneBridging: Sendable {
    /// 当前文档中用户已选中的 variant 路径（仅存在的绝对路径）。
    func selectedPhotoPaths() async throws -> [String]
    /// 触发 Capture One reload metadata，成功后才写 durable ack。
    func reloadMetadata(sessionId: String) async throws
    /// System Events 进程探测 + 应用名解析。
    func checkHealth() async -> Result<String, CaptureOneBridgeError>
    /// 四层预检（可达 / 运行 / 自动化授权 / 文档打开），失败回退不抛。
    func preflight() async -> C1PreflightStatus
    /// 文档探针脚本文本（预检与设置页健康检查共用）。
    static func documentProbeScript(appName: String) -> String
}
