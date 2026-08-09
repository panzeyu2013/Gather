// desktop/native/gather-core/Sources/GatherCore/Protocol/Export.swift
// TS 源: packages/shared/src/protocol/export.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: ExportPreviewParams
public struct ExportPreviewParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var options: ExportOptions

    public init(sessionId: String, options: ExportOptions) {
        self.sessionId = sessionId
        self.options = options
    }
}

// TS: ExportExecuteParams
public struct ExportExecuteParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var options: ExportOptions
    public var confirmed: Bool

    public init(sessionId: String, options: ExportOptions, confirmed: Bool) {
        self.sessionId = sessionId
        self.options = options
        self.confirmed = confirmed
    }
}

// TS: ExportCancelParams
public struct ExportCancelParams: Codable, Equatable, Sendable {
    public init() {}
}

// TS: ExportReportParams
public struct ExportReportParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var reportType: String
    public var format: String? // TS: format?

    public init(sessionId: String, reportType: String, format: String? = nil) {
        self.sessionId = sessionId
        self.reportType = reportType
        self.format = format
    }
}

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
public struct ExportPreviewFile: Codable, Equatable, Sendable {
    public var photoId: String
    public var filename: String
    public var fileSize: Int

    public init(photoId: String, filename: String, fileSize: Int) {
        self.photoId = photoId
        self.filename = filename
        self.fileSize = fileSize
    }
}

// TS: ExportPreview
public struct ExportPreview: Codable, Equatable, Sendable {
    public var totalFiles: Int
    public var totalSizeBytes: Int
    public var freeSpaceBytes: Int
    public var files: [ExportPreviewFile]

    public init(totalFiles: Int, totalSizeBytes: Int, freeSpaceBytes: Int, files: [ExportPreviewFile]) {
        self.totalFiles = totalFiles
        self.totalSizeBytes = totalSizeBytes
        self.freeSpaceBytes = freeSpaceBytes
        self.files = files
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
