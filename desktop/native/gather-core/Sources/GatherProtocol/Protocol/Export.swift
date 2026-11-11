// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Export.swift
// TS 源: packages/shared/src/protocol/export.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: scope（export.ts 内联联合 'selected' | 'filtered' | 'session'）
public enum ExportScope: String, Codable, CaseIterable, Equatable, Sendable {
    case selected
    case filtered
    case session
}

// TS: variantPolicy（export.ts 内联联合 'preferred' | 'raw' | 'jpeg' | 'all'）
public enum ExportVariantPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case preferred
    case raw
    case jpeg
    case all
}

// TS: format（export.ts 内联联合 'original' | 'jpeg' | 'tiff'）
public enum ExportFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case original
    case jpeg
    case tiff
}

// TS: tiffCompression（export.ts 内联联合 'none' | 'lzw' | 'deflate'）
public enum ExportTiffCompression: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case lzw
    case deflate
}

/// 导出目标色彩空间（P0-5 / Wave1 新增，无 TS 对应）。
///
/// `nil`（ExportOptions.colorSpace 缺省）= 不转换，保持原片色彩（旧行为）。
/// 非 nil 时转码链把像素重绘进目标色彩空间，并让 JPEG/TIFF 携带对应 ICC profile。
public enum ExportColorSpace: String, Codable, CaseIterable, Equatable, Sendable {
    case sRGB = "sRGB"
    case displayP3 = "display-p3"
    /// Adobe RGB 1998（印厂/杂志交付）。
    case adobeRGB1998 = "adobe-rgb-1998"
}

/// 输出锐化参数（P0-5 / Wave1 新增，无 TS 对应）。
///
/// 语义是 unsharp mask：在**最终输出像素**上做（缩图之后），只改灰度过渡、
/// 不改尺寸。`nil`（ExportOptions.sharpening 缺省）= 不锐化（旧行为）。
public struct ExportSharpening: Codable, Equatable, Sendable {
    /// 模糊半径（输出像素）。0.5-1 适合屏幕缩图，1-3 适合打印。
    public var radius: Double
    /// 强度（0-2）：0 = 不锐化，越大边缘对比越强。
    public var intensity: Double

    public init(radius: Double = 1, intensity: Double = 0.5) {
        self.radius = radius
        self.intensity = intensity
    }
}

// TS: watermark.type（export.ts 内联联合 'text' | 'image'）
public enum ExportWatermarkType: String, Codable, CaseIterable, Equatable, Sendable {
    case text
    case image
}

// TS: watermark.position（export.ts 内联联合 'center' | 'bottom-right' | 'bottom-left'）
public enum ExportWatermarkPosition: String, Codable, CaseIterable, Equatable, Sendable {
    case center
    case bottomRight = "bottom-right"
    case bottomLeft = "bottom-left"
}

// TS: ExportOptions.watermark（内联匿名对象）
//
// Wave2：image 类型落地（logo PNG 合成）。text 用 content 当水印文字；
// image 用 content 当 logo 文件路径，imageScale/imageMargin 是可选的版式参数
//（旧 JSON 没有这两个键 → nil = 0.2 / 0.02 的默认版式，行为可预期）。
public struct ExportWatermark: Codable, Equatable, Sendable {
    public var type: ExportWatermarkType
    /// text = 水印文字；image = logo 绝对路径（PNG/JPEG/TIFF，ImageIO 可解即可）。
    public var content: String
    public var position: ExportWatermarkPosition
    public var opacity: Double
    public var fontSize: Double? // TS: fontSize?
    /// image 专用：logo 宽度上限 = 输出宽度 × 该比例（0.02-1）；nil = 0.2。
    /// 只缩小不放大：logo 比目标宽度小的时候保持原始像素。
    public var imageScale: Double?
    /// image 专用：logo 距画面边缘的距离 = 输出宽度 × 该比例（0-0.25）；
    /// nil = 0.02；position == .center 时忽略。
    public var imageMargin: Double?

    public init(
        type: ExportWatermarkType,
        content: String,
        position: ExportWatermarkPosition,
        opacity: Double,
        fontSize: Double? = nil,
        imageScale: Double? = nil,
        imageMargin: Double? = nil
    ) {
        self.type = type
        self.content = content
        self.position = position
        self.opacity = opacity
        self.fontSize = fontSize
        self.imageScale = imageScale
        self.imageMargin = imageMargin
    }
}

/// 导出子目录规则（Wave2 新增，无 TS 对应）。
///
/// 模板按 token 生成**相对**输出目录（相对 ExportOptions.destination；可用 "/"
/// 分多级）：
/// - {yyyy} {MM} {dd}：导出当天（本地时区）的年/月/日；
/// - {client} {event}：本规则里的客户名/活动名（空值 = 该目录段在解析时丢弃）；
/// - {orig}：源文件主名（**逐张**解析，会生成照片级子目录）。
///
/// 非法 token、绝对路径、路径穿越（..）与空目录段由 ExportService.validate 拒绝；
/// token 取值里的路径分隔符会被替换成 "_"，不会逃出 destination。
public struct ExportSubdirectory: Codable, Equatable, Sendable {
    /// 例："{client}/{yyyy}-{MM}-{dd}"。
    public var template: String
    /// {client} 的取值；nil/空 → 该段在解析时丢弃。
    public var client: String?
    /// {event} 的取值；nil/空 → 该段在解析时丢弃。
    public var event: String?

    public init(template: String, client: String? = nil, event: String? = nil) {
        self.template = template
        self.client = client
        self.event = event
    }

    /// 允许的 token（大小写敏感：{yyyy} 不等于 {YYYY}）。
    public static let supportedTokens: Set<String> = [
        "yyyy", "MM", "dd", "client", "event", "orig",
    ]

    /// 模板静态校验：nil = 合法，否则返回非法原因（进 EXPORT_PARAMS_INVALID 的 reason）。
    public static func validationReason(for template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return "absolutePath" }
        if trimmed.contains("\\") { return "backslash" }
        if trimmed.contains("\0") { return "nul" }
        for segment in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            let text = segment.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return "emptySegment" }
            if text == "." || text == ".." { return "pathTraversal" }
            if let bad = firstUnknownToken(in: text) {
                // 结构类错误（未闭合/悬空花括号）直接上报；未知 token 才带前缀。
                // 最终 reason 表：absolutePath / backslash / nul / emptySegment /
                // pathTraversal / unclosedToken / strayBrace / unknownToken:{name}。
                return bad.hasPrefix("{") ? "unknownToken:\(bad)" : bad
            }
        }
        return nil
    }

    /// 第一个非法 token（含悬空 "{" / "}"）；nil = 全部合法。
    private static func firstUnknownToken(in segment: String) -> String? {
        var index = segment.startIndex
        while index < segment.endIndex {
            let character = segment[index]
            if character == "}" { return "strayBrace" }
            guard character == "{" else {
                index = segment.index(after: index)
                continue
            }
            guard let close = segment[index...].firstIndex(of: "}") else {
                return "unclosedToken"
            }
            let token = String(segment[segment.index(after: index)..<close])
            if !supportedTokens.contains(token) { return "{\(token)}" }
            index = segment.index(after: close)
        }
        return nil
    }

    /// 解析成相对子目录（无首尾 "/"）；模板为空 / 解析后为空 → nil。
    ///
    /// 结果只含相对路径段：{client} 里带 "/"、".." 之类会被清洗成安全值，
    /// 永远不会出现绝对路径或 ".." 段。
    public func resolved(originalFilename: String, date: Date = Date()) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let stem = (originalFilename as NSString).deletingPathExtension
        let orderedValues: [(token: String, value: String)] = [
            ("{yyyy}", String(format: "%04d", components.year ?? 0)),
            ("{MM}", String(format: "%02d", components.month ?? 0)),
            ("{dd}", String(format: "%02d", components.day ?? 0)),
            ("{client}", Self.sanitizedTokenValue(client)),
            ("{event}", Self.sanitizedTokenValue(event)),
            ("{orig}", Self.sanitizedTokenValue(stem)),
        ]
        var segments: [String] = []
        for segment in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            var expanded = String(segment)
            for pair in orderedValues {
                expanded = expanded.replacingOccurrences(of: pair.token, with: pair.value)
            }
            // 未知 token 应由 validate 拦下；这里再兜一层，避免绕过校验的调用方
            // 把 "{foo}" 当目录名写盘。
            if expanded.contains("{") || expanded.contains("}") { continue }
            let cleaned = Self.sanitizedSegment(expanded)
            if cleaned.isEmpty || cleaned == "." || cleaned == ".." { continue }
            segments.append(cleaned)
        }
        return segments.isEmpty ? nil : segments.joined(separator: "/")
    }

    /// token 值只作为一个目录段使用：路径分隔符/控制字符一律换成 "_"。
    private static func sanitizedTokenValue(_ value: String?) -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        return sanitizedSegment(raw)
    }

    /// 目录段清洗：非法文件名字符/控制字符 → "_"，去首尾空格与点（防 "."/".."）。
    private static func sanitizedSegment(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*\0")
            .union(.controlCharacters)
        let mapped = value.unicodeScalars.map { scalar -> String in
            forbidden.contains(scalar) ? "_" : String(scalar)
        }
        return mapped.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }
}

// TS: ExportOptions.naming（内联匿名对象）
public struct ExportNaming: Codable, Equatable, Sendable {
    public var pattern: String
    public var counterStart: Int? // TS: counterStart?
    public var dateFormat: String? // TS: dateFormat?

    public init(pattern: String, counterStart: Int? = nil, dateFormat: String? = nil) {
        self.pattern = pattern
        self.counterStart = counterStart
        self.dateFormat = dateFormat
    }
}

// TS: ExportOptions
public struct ExportOptions: Codable, Equatable, Sendable {
    public var scope: ExportScope
    /// .selected 时必填：要导出的照片 ID；服务端校验属于会话且可见。
    public var selectedPhotoIds: [String]?
    public var variantPolicy: ExportVariantPolicy? // TS: variantPolicy?
    public var format: ExportFormat
    public var quality: Double? // TS: quality?
    public var maxDimension: Int? // TS: maxDimension?
    /// Wave2：输出子目录规则（token 模板）；nil = 直接写到 destination。
    /// 预览的 outputName 会带相对子目录前缀，执行时按子目录建目录。
    public var subdirectory: ExportSubdirectory?
    /// P0-5 / Wave1：目标色彩空间；nil = 不转换（保持原片色彩）。
    public var colorSpace: ExportColorSpace?
    /// P0-5 / Wave1：写入成片元数据的 DPI（JPEG JFIF density / TIFF resolution）；
    /// nil = 不写。
    public var dpi: Int?
    /// P0-5 / Wave1：输出锐化（unsharp mask）；nil = 不锐化。
    public var sharpening: ExportSharpening?
    public var tiffCompression: ExportTiffCompression? // TS: tiffCompression?
    public var watermark: ExportWatermark? // TS: watermark?
    public var naming: ExportNaming
    public var includeXmp: Bool
    public var destination: String

    public init(
        scope: ExportScope,
        selectedPhotoIds: [String]? = nil,
        variantPolicy: ExportVariantPolicy? = nil,
        format: ExportFormat,
        quality: Double? = nil,
        maxDimension: Int? = nil,
        subdirectory: ExportSubdirectory? = nil,
        colorSpace: ExportColorSpace? = nil,
        dpi: Int? = nil,
        sharpening: ExportSharpening? = nil,
        tiffCompression: ExportTiffCompression? = nil,
        watermark: ExportWatermark? = nil,
        naming: ExportNaming,
        includeXmp: Bool,
        destination: String
    ) {
        self.scope = scope
        self.selectedPhotoIds = selectedPhotoIds
        self.variantPolicy = variantPolicy
        self.format = format
        self.quality = quality
        self.maxDimension = maxDimension
        self.subdirectory = subdirectory
        self.colorSpace = colorSpace
        self.dpi = dpi
        self.sharpening = sharpening
        self.tiffCompression = tiffCompression
        self.watermark = watermark
        self.naming = naming
        self.includeXmp = includeXmp
        self.destination = destination
    }
}

// TS: ExportPreview.files 的元素（匿名对象 { photoId, filename, fileSize }）
//
// D09：预览的一项现在描述**输出**而不是源清单。旧实现只有源文件名 + 源大小：
// 选 JPEG、改命名或遇到重名时，确认弹窗展示的清单与真正写出的文件无关。
public struct ExportPreviewFile: Codable, Equatable, Sendable {
    public var photoId: String
    /// 源文件名（保留旧字段名，不破坏既有消费者）。
    public var filename: String
    /// 源文件字节数（转码时 isSizeEstimate = true，不能当输出体积）。
    public var fileSize: Int
    /// 实际写出的文件名（重名已按策略改名）。
    public var outputName: String
    /// 输出格式：original / jpeg / tiff。
    public var format: String
    /// 是否会为该照片额外写出一个 .xmp sidecar。
    public var includesXmp: Bool
    /// 逐项可执行性诊断（源文件缺失等）；nil = 可正常导出。
    public var issue: String?
    /// fileSize 是否为估算值（转码输出无法精确预测体积）。
    public var isSizeEstimate: Bool
    /// 断点续跑中已完成、本次会跳过的项（P2-1/P2-2 审计 3）：
    /// 这类项不会失败也不会重写，UI 应说明「将跳过」而不是标成问题。
    public var willSkip: Bool

    public init(
        photoId: String,
        filename: String,
        fileSize: Int,
        outputName: String? = nil,
        format: String = "original",
        includesXmp: Bool = false,
        issue: String? = nil,
        isSizeEstimate: Bool = false,
        willSkip: Bool = false
    ) {
        self.photoId = photoId
        self.filename = filename
        self.fileSize = fileSize
        self.outputName = outputName ?? filename
        self.format = format
        self.includesXmp = includesXmp
        self.issue = issue
        self.isSizeEstimate = isSizeEstimate
        self.willSkip = willSkip
    }

    /// P2-6（审计 3）：新字段全部用 decodeIfPresent 兜默认值，旧 JSON 仍可解码
    ///（合成 init(from:) 会把新字段当必需 key，旧载荷直接解不了）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        photoId = try container.decode(String.self, forKey: .photoId)
        filename = try container.decode(String.self, forKey: .filename)
        fileSize = try container.decode(Int.self, forKey: .fileSize)
        outputName = try container.decodeIfPresent(String.self, forKey: .outputName) ?? filename
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? "original"
        includesXmp = try container.decodeIfPresent(Bool.self, forKey: .includesXmp) ?? false
        issue = try container.decodeIfPresent(String.self, forKey: .issue)
        isSizeEstimate = try container.decodeIfPresent(Bool.self, forKey: .isSizeEstimate) ?? false
        willSkip = try container.decodeIfPresent(Bool.self, forKey: .willSkip) ?? false
    }
}

// TS: ExportPreview
public struct ExportPreview: Codable, Equatable, Sendable {
    /// 照片数（历史字段，语义未变）。
    public var totalFiles: Int
    /// 源文件字节合计（转码时不等于输出体积）。
    public var totalSizeBytes: Int
    public var freeSpaceBytes: Int
    public var files: [ExportPreviewFile]
    /// 照片数（= totalFiles，显式命名以避免"照片/文件"混用）。
    public var photoCount: Int
    /// 会写出的 XMP sidecar 数（只计源侧确实存在 sidecar 的项）。
    public var sidecarCount: Int
    /// 真正会写到磁盘的文件数 = photoCount + sidecarCount；确认文案必须用它。
    public var physicalFileCount: Int
    /// 有可执行性问题（源文件缺失等）的项数。
    public var issueCount: Int

    public init(
        totalFiles: Int,
        totalSizeBytes: Int,
        freeSpaceBytes: Int,
        files: [ExportPreviewFile],
        photoCount: Int? = nil,
        sidecarCount: Int = 0,
        physicalFileCount: Int? = nil,
        issueCount: Int = 0
    ) {
        self.totalFiles = totalFiles
        self.totalSizeBytes = totalSizeBytes
        self.freeSpaceBytes = freeSpaceBytes
        self.files = files
        self.photoCount = photoCount ?? totalFiles
        self.sidecarCount = sidecarCount
        self.physicalFileCount = physicalFileCount ?? (self.photoCount + sidecarCount)
        self.issueCount = issueCount
    }

    /// P2-6（审计 3）：新计数用 decodeIfPresent 兜默认值，旧 JSON 仍可解码。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalFiles = try container.decode(Int.self, forKey: .totalFiles)
        totalSizeBytes = try container.decode(Int.self, forKey: .totalSizeBytes)
        freeSpaceBytes = try container.decode(Int.self, forKey: .freeSpaceBytes)
        files = try container.decode([ExportPreviewFile].self, forKey: .files)
        photoCount = try container.decodeIfPresent(Int.self, forKey: .photoCount) ?? totalFiles
        sidecarCount = try container.decodeIfPresent(Int.self, forKey: .sidecarCount) ?? 0
        physicalFileCount = try container.decodeIfPresent(Int.self, forKey: .physicalFileCount)
            ?? (photoCount + sidecarCount)
        issueCount = try container.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
    }
}

// TS: ExportResult
public struct ExportResult: Codable, Equatable, Sendable {
    public var totalFiles: Int
    public var exported: Int
    public var failed: Int
    public var skipped: Int
    public var errors: [String]

    public init(totalFiles: Int, exported: Int, failed: Int, skipped: Int, errors: [String]) {
        self.totalFiles = totalFiles
        self.exported = exported
        self.failed = failed
        self.skipped = skipped
        self.errors = errors
    }
}

// TS: ReportData.format（export.ts 内联联合 'csv' | 'md'）
public enum ReportFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case csv
    case md
}

// TS: ReportData
public struct ReportData: Codable, Equatable, Sendable {
    public var path: String
    public var content: String
    public var format: ReportFormat

    public init(path: String, content: String, format: ReportFormat) {
        self.path = path
        self.content = content
        self.format = format
    }
}
