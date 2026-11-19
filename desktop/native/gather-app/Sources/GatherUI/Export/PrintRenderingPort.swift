// desktop/native/gather-app/Sources/GatherUI/Export/PrintRenderingPort.swift
// Wave3 / task-20：打印渲染的 UI 侧接缝（layering 门禁：GatherUI 不得 import
// GatherApplication/GatherAnalysis）。
//
// 分工与 ImageDecoderPort 同构：
// - 本文件只声明"把一组照片按打印选项渲染成 PDF"这一能力 + 纯值 DTO；
//   版面算法与 PDF 绘制在 GatherApplication/Services/Export/Print*（可单测）；
// - 真正实现由 GatherHost 启动时注册（LivePrintRenderer），GatherUI 只读 registry；
// - 未注册时 registry.current() 返回 nil：打印面板显示"打印渲染不可用"，
//   预览/单元测试不需要宿主。
//
// UI 选项类型与 core 的 Print* 选项**刻意分开命名**（PrintJob*）：Host 侧要同时
// import 两边，同名会让映射代码出现歧义；LivePrintRenderer 只做字段映射。
import Foundation
import CoreGraphics
import GatherProtocol

// MARK: - 选项（UI 值类型）

/// 打印纸张预设（与 core PrintPaperPreset 一一对应）。
public enum PrintJobPaper: String, CaseIterable, Sendable, Equatable {
    case a4
    case a5
    case letter
    case photo4x6
    case photo5x7
    case photo8x10
    case custom
}

/// 打印任务形态：单图 / 多页排版。
public enum PrintJobMode: String, CaseIterable, Sendable, Equatable {
    case singleImage
    case multiPage
}

/// 单图摆放方式（与 core PrintSingleSizing 对应）。
public enum PrintJobSizing: String, CaseIterable, Sendable, Equatable {
    case fitToPage
    case custom
}

/// 页边距（点）；「离白」即四边留白。
public struct PrintJobMargins: Equatable, Sendable {
    public var top: CGFloat
    public var bottom: CGFloat
    public var leading: CGFloat
    public var trailing: CGFloat

    public init(
        top: CGFloat = 28,
        bottom: CGFloat = 28,
        leading: CGFloat = 28,
        trailing: CGFloat = 28
    ) {
        self.top = max(0, top)
        self.bottom = max(0, bottom)
        self.leading = max(0, leading)
        self.trailing = max(0, trailing)
    }

    public static let standard = PrintJobMargins()
    public static let none = PrintJobMargins(top: 0, bottom: 0, leading: 0, trailing: 0)
}

/// 打印任务选项（单图 + 多页共用一份；按 mode 取用对应字段）。
public struct PrintJobOptions: Equatable, Sendable {
    public var mode: PrintJobMode
    public var paper: PrintJobPaper
    /// paper == .custom 时的页面尺寸（点）。
    public var customPageSize: CGSize
    public var margins: PrintJobMargins
    // 单图
    public var sizing: PrintJobSizing
    public var customImageSize: CGSize
    public var borderWidth: CGFloat
    // 多页
    public var columns: Int
    public var rows: Int
    public var cellSpacing: CGFloat
    public var captionHeight: CGFloat
    public var headerHeight: CGFloat
    public var footerHeight: CGFloat
    public var headerText: String
    public var footerText: String
    public var showsPageNumbers: Bool

    public init(
        mode: PrintJobMode = .singleImage,
        paper: PrintJobPaper = .a4,
        customPageSize: CGSize = CGSize(width: 595, height: 842),
        margins: PrintJobMargins = .standard,
        sizing: PrintJobSizing = .fitToPage,
        customImageSize: CGSize = CGSize(width: 288, height: 432),
        borderWidth: CGFloat = 0,
        columns: Int = 3,
        rows: Int = 3,
        cellSpacing: CGFloat = 8,
        captionHeight: CGFloat = 16,
        headerHeight: CGFloat = 32,
        footerHeight: CGFloat = 20,
        headerText: String = "",
        footerText: String = "",
        showsPageNumbers: Bool = true
    ) {
        self.mode = mode
        self.paper = paper
        self.customPageSize = customPageSize
        self.margins = margins
        self.sizing = sizing
        self.customImageSize = customImageSize
        self.borderWidth = max(0, borderWidth)
        self.columns = min(12, max(1, columns))
        self.rows = min(20, max(1, rows))
        self.cellSpacing = max(0, cellSpacing)
        self.captionHeight = max(0, captionHeight)
        self.headerHeight = max(0, headerHeight)
        self.footerHeight = max(0, footerHeight)
        self.headerText = headerText
        self.footerText = footerText
        self.showsPageNumbers = showsPageNumbers
    }
}

/// 一张待打印的照片（UI 从 CullingAsset 映射；不含任何解码逻辑）。
public struct PrintJobItem: Equatable, Sendable {
    public var filePath: String
    public var caption: String
    public var rating: Int
    public var label: String
    public var pick: PickState
    public var keywords: [String]

    public init(
        filePath: String,
        caption: String,
        rating: Int = 0,
        label: String = "",
        pick: PickState = .unreviewed,
        keywords: [String] = []
    ) {
        self.filePath = filePath
        self.caption = caption
        self.rating = min(5, max(0, rating))
        self.label = label
        self.pick = pick
        self.keywords = keywords
    }
}

/// 一次打印渲染请求：选项 + 照片 + 目标 PDF 路径（临时文件，由调用方给）。
public struct PrintJobRequest: Equatable, Sendable {
    public var options: PrintJobOptions
    public var items: [PrintJobItem]
    public var outputPath: String

    public init(options: PrintJobOptions, items: [PrintJobItem], outputPath: String) {
        self.options = options
        self.items = items
        self.outputPath = outputPath
    }
}

/// 渲染结果（与 core PrintRenderResult 对应）。
public struct PrintJobOutcome: Equatable, Sendable {
    public let pages: Int
    public let bytes: Int
    public let failedImages: Int

    public init(pages: Int, bytes: Int, failedImages: Int) {
        self.pages = pages
        self.bytes = bytes
        self.failedImages = failedImages
    }
}

public enum PrintRenderingError: Error, Equatable, Sendable {
    /// 宿主未注册渲染实现（预览/测试/启动失败）。
    case rendererUnavailable
    /// 渲染失败（core 的 PrintRenderError 映射为文案在调用方）。
    case failed(String)
}

// MARK: - 端口 + 注册表

/// 打印渲染能力面。实现必须无状态/可并发（与 ImageDecoderPort 同契约）。
public protocol PrintRenderingPort: Sendable {
    /// 渲染 PDF 到 request.outputPath；返回页数/字节/失败张数。
    func render(_ request: PrintJobRequest) async throws -> PrintJobOutcome

    /// 纯计算页数（多页排版按每页 columns×rows 分页；单图恒为 1）：
    /// 面板在点「打印」前展示"预计 N 页"，必须与真正渲染同源。
    func pageCount(for request: PrintJobRequest) -> Int
}

/// 进程级注册表：GatherHost 启动时注册一次，视图层只读。
///
/// M12（Wave5）：存储与互斥收口到 PortRegistry（单一进程级注册表），本类型只保留
/// public API 以维持调用点不变；未注册返回 nil 而不是 crash。
public enum PrintRenderingRegistry {
    public static func install(_ port: any PrintRenderingPort) {
        PortRegistry.install(printRendering: port)
    }

    public static func current() -> (any PrintRenderingPort)? {
        PortRegistry.printRendering()
    }
}
