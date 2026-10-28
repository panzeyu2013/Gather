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
public struct ExportWatermark: Codable, Equatable, Sendable {
    public var type: ExportWatermarkType
    public var content: String
    public var position: ExportWatermarkPosition
    public var opacity: Double
    public var fontSize: Double? // TS: fontSize?

    public init(type: ExportWatermarkType, content: String, position: ExportWatermarkPosition, opacity: Double, fontSize: Double? = nil) {
        self.type = type
        self.content = content
        self.position = position
        self.opacity = opacity
        self.fontSize = fontSize
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
    public var variantPolicy: ExportVariantPolicy? // TS: variantPolicy?
    public var format: ExportFormat
    public var quality: Double? // TS: quality?
    public var maxDimension: Int? // TS: maxDimension?
    public var tiffCompression: ExportTiffCompression? // TS: tiffCompression?
    public var watermark: ExportWatermark? // TS: watermark?
    public var naming: ExportNaming
    public var includeXmp: Bool
    public var destination: String

    public init(
        scope: ExportScope,
        variantPolicy: ExportVariantPolicy? = nil,
        format: ExportFormat,
        quality: Double? = nil,
        maxDimension: Int? = nil,
        tiffCompression: ExportTiffCompression? = nil,
        watermark: ExportWatermark? = nil,
        naming: ExportNaming,
        includeXmp: Bool,
        destination: String
    ) {
        self.scope = scope
        self.variantPolicy = variantPolicy
        self.format = format
        self.quality = quality
        self.maxDimension = maxDimension
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
