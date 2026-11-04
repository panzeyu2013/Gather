// desktop/native/gather-app/Sources/GatherUI/Culling/C1RoundTripPorts.swift
// C1 往返端口与相关值类型（§3.10）。
//
// #6 S1b：这批类型原本与 CullingViewModel 的写回扩展挤在 +Writeback.swift 开头，
// 其中两个是 public 协议（Host 侧的 C1RoundTripCoordinator 要实现它们）。搬出来
// 是为了让写回扩展只留下 VM 的方法体。
//
// 顺带删除一个空的 Notification.Name 扩展（通道名已迁到 GatherEventCenter，#11 之后
// 它只剩注释，是零引用的死声明）。
import Foundation
import GatherProtocol

// MARK: - C1 往返端口（§3.10）
//
// UI 只声明能力面，不 import GatherHost：生产的 C1RoundTripCoordinator 在 Host 侧
// 实现这两个端口（并同时是 `any CaptureOneBridging` 的纯委托），组合根把它当
// `captureOne` 传给 CullingViewModel —— 这样手动 reload 与自动 reload 共用同一条
// 串行队列，互相不会打架。

/// 自动 reload 端口（Host 的 C1RoundTripCoordinator 实现）。
///
/// @MainActor：协调器是主线程状态机（定时器/队列都在主 actor），
/// 非隔离的同步方法无法满足 @MainActor 协议要求，故整条端口声明在主 actor 上。
@MainActor
public protocol C1RoundTripReloading: AnyObject {
    /// 手动 reload（按钮）：与自动 reload 共用串行队列。
    func reloadMetadata(sessionId: String) async throws
    /// 交付状态变化：内部 debounce（1.5s）+ 合并 + 串行。
    func noteDeliveryStateChanged(sessionId: String)
    /// 最近一次自动 reload 失败（nil = 无）；UI 读它显示非阻塞提示。
    func currentAutoReloadFailure() -> C1AutoReloadFailure?
    func clearAutoReloadFailure()
}

/// C1 往返的扩展能力（§3.10.2 选中 / §3.10.3 调整提示）。
@MainActor
public protocol C1RoundTripExtending: AnyObject {
    func selectVariants(paths: [String]) async throws -> C1SelectionOutcome
    func adjustmentHints(paths: [String]) -> [C1AdjustmentHint]
}

/// 自动 reload 失败（UI 文案："C1 未重载：<code>，请在 C1 手动 Load Metadata"）。
public struct C1AutoReloadFailure: Equatable, Sendable {
    public let sessionId: String
    public let code: String
    public let message: String
    public let attemptedAt: String

    public init(sessionId: String, code: String, message: String, attemptedAt: String) {
        self.sessionId = sessionId
        self.code = code
        self.message = message
        self.attemptedAt = attemptedAt
    }
}

public enum C1SelectionMethod: Equatable, Sendable {
    /// AppleScript 按路径匹配后 select：只改 C1 选中，不导入。
    case appleScript
    /// 兜底：让 C1 打开这些文件，**可能触发导入**（UI 必须标注）。
    case workspace(reason: C1SelectionFallbackReason)
}

public enum C1SelectionFallbackReason: Equatable, Sendable {
    /// 旧版 C1 不支持按路径 select（提示升级 C1 / 改用访达）。
    case scriptUnsupported
    /// 脚本执行失败（码值取 GatherErrorCode）。
    case scriptFailed(code: String)
}

public struct C1SelectionOutcome: Equatable, Sendable {
    public let method: C1SelectionMethod
    /// 已选中/已打开的路径。
    public let paths: [String]
    /// 当前文档里找不到的路径（不 fallback、不导入）。
    public let notFound: [String]
    public let appName: String?

    public init(
        method: C1SelectionMethod,
        paths: [String],
        notFound: [String],
        appName: String?
    ) {
        self.method = method
        self.paths = paths
        self.notFound = notFound
        self.appName = appName
    }
}

/// 归一化裁剪框（0…1，左上原点），来自 crs:CropTop/Left/Bottom/Right。
public struct C1CropRect: Equatable, Sendable {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public var width: Double { max(0, right - left) }
    public var height: Double { max(0, bottom - top) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// 一张照片的 C1 调整提示（有 crs: 字段即提示"预览可能不含 C1 调整"）。
public struct C1AdjustmentHint: Equatable, Sendable {
    public let photoPath: String
    public let xmpPath: String?
    public let hasAdjustments: Bool
    /// crs:Angle（度，正数=顺时针）。
    public let angle: Double?
    public let cropRect: C1CropRect?
    /// 命中的 crs: 属性名（排序后，最多 12 个）。
    public let attributeNames: [String]

    public init(
        photoPath: String,
        xmpPath: String?,
        hasAdjustments: Bool,
        angle: Double?,
        cropRect: C1CropRect?,
        attributeNames: [String]
    ) {
        self.photoPath = photoPath
        self.xmpPath = xmpPath
        self.hasAdjustments = hasAdjustments
        self.angle = angle
        self.cropRect = cropRect
        self.attributeNames = attributeNames
    }

    public static func none(photoPath: String) -> C1AdjustmentHint {
        C1AdjustmentHint(
            photoPath: photoPath, xmpPath: nil, hasAdjustments: false,
            angle: nil, cropRect: nil, attributeNames: [])
    }
}

