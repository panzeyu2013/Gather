// desktop/native/gather-core/Sources/GatherCore/Services/ExportService.swift
// Phase 3.6：原生导出管线。
//
// 该服务刻意保持在 GatherCore：预览、文件规划、断点续作、原图复制、
// ImageIO 转码与报告生成必须由同一条受控路径完成，不能让 WebView 直接
// 访问任意文件系统路径。命令层只负责参数解码和 JobService 编排。

import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import CoreText
#endif

public struct NativeExportProgress: Equatable, Sendable {
    public let sessionId: String
    public let current: Int
    public let total: Int
    public let fileName: String
    public let bytesWritten: Int
    public let status: String
    public let errorMessage: String?

    public init(
        sessionId: String,
        current: Int,
        total: Int,
        fileName: String,
        bytesWritten: Int,
        status: String,
        errorMessage: String? = nil
    ) {
        self.sessionId = sessionId
        self.current = current
        self.total = total
        self.fileName = fileName
        self.bytesWritten = bytesWritten
        self.status = status
        self.errorMessage = errorMessage
    }
}

public struct NativeExportResumeState {
    public var destinations: [String: String]
    public var completedPhotoIds: Set<String>
    public var onPlanned: ((String, String) -> Void)?
    public var onPlanReady: (() -> Void)?
    public var onCompleted: ((String) -> Void)?

    public init(
        destinations: [String: String] = [:],
        completedPhotoIds: Set<String> = [],
        onPlanned: ((String, String) -> Void)? = nil,
        onPlanReady: (() -> Void)? = nil,
        onCompleted: ((String) -> Void)? = nil
    ) {
        self.destinations = destinations
        self.completedPhotoIds = completedPhotoIds
        self.onPlanned = onPlanned
        self.onPlanReady = onPlanReady
        self.onCompleted = onCompleted
    }
}

public enum ExportServiceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case destinationInvalid
    case destinationAbsoluteRequired
    case destinationRootForbidden
    case destinationInsideSession
    case formatInvalid
    case variantPolicyInvalid
    case originalTransformNotAllowed
    case namingEmpty
    case namingInvalidCharacters
    case qualityInvalid
    case maxDimensionInvalid
    case startIndexInvalid
    case watermarkTypeUnsupported
    case watermarkTextEmpty
    case watermarkOpacityInvalid
    case watermarkFontSizeInvalid
    case scopeUnsupported
    case sessionNotFound
    case sourceMissing(String)
    case exportPathInvalid
    case formatUnsupported
    case rawConvertUnsupported
    case xmpConflict
    case cancelled

    public var description: String {
        switch self {
        case .destinationInvalid: return "EXPORT_DIR_INVALID"
        case .destinationAbsoluteRequired: return "EXPORT_DIR_ABSOLUTE_REQUIRED"
        case .destinationRootForbidden: return "EXPORT_DIR_ROOT_FORBIDDEN"
        case .destinationInsideSession: return "EXPORT_DIR_INSIDE_SESSION"
        case .formatInvalid: return "EXPORT_FORMAT_INVALID"
        case .variantPolicyInvalid: return "EXPORT_VARIANT_POLICY_INVALID"
        case .originalTransformNotAllowed: return "EXPORT_ORIGINAL_NO_TRANSFORM"
        case .namingEmpty: return "EXPORT_NAMING_EMPTY"
        case .namingInvalidCharacters: return "EXPORT_NAMING_INVALID_CHARS"
        case .qualityInvalid: return "EXPORT_JPEG_QUALITY_INVALID"
        case .maxDimensionInvalid: return "EXPORT_MAX_DIMENSION_INVALID"
        case .startIndexInvalid: return "EXPORT_START_INDEX_INVALID"
        case .watermarkTypeUnsupported: return "EXPORT_WATERMARK_TYPE_UNSUPPORTED"
        case .watermarkTextEmpty: return "EXPORT_WATERMARK_TEXT_EMPTY"
        case .watermarkOpacityInvalid: return "EXPORT_WATERMARK_OPACITY_INVALID"
        case .watermarkFontSizeInvalid: return "EXPORT_WATERMARK_FONT_SIZE_INVALID"
        case .scopeUnsupported: return "EXPORT_SCOPE_UNSUPPORTED"
        case .sessionNotFound: return "SESSION_NOT_FOUND"
        case .sourceMissing: return "EXPORT_SOURCE_MISSING"
        case .exportPathInvalid: return "EXPORT_PATH_INVALID"
        case .formatUnsupported: return "EXPORT_FORMAT_UNSUPPORTED"
        case .rawConvertUnsupported: return "EXPORT_RAW_CONVERT_UNSUPPORTED"
        case .xmpConflict: return "EXPORT_XMP_CONFLICT"
        case .cancelled: return "CANCELLED"
        }
    }

    public var errorDescription: String? { description }
}

/// 导出服务：原图安全复制、JPEG/TIFF 转码、断点续作和报告。
public final class ExportService {
    private let photoRepo: PhotoRepo
    private let sessionRepo: SessionRepo
    private let connection: DBConnection
    private let cancelLock = NSLock()
    private var cancelledSessions = Set<String>()

    public init(photoRepo: PhotoRepo, sessionRepo: SessionRepo, connection: DBConnection) {
        self.photoRepo = photoRepo
        self.sessionRepo = sessionRepo
        self.connection = connection
    }

    public func cancel(sessionId: String) {
        cancelLock.lock()
        cancelledSessions.insert(sessionId)
        cancelLock.unlock()
    }

    public func preview(sessionId: String, options: ExportOptions) throws -> ExportPreview {
        try validate(options)
        try assertDestinationOutsideSource(sessionId: sessionId, destination: options.destination)
        let files = try filteredPhotos(sessionId: sessionId, options: options).map { photo in
            let size = (try? FileManager.default.attributesOfItem(atPath: photo.filepath)[.size] as? NSNumber)
                .map { Int($0.int64Value) } ?? 0
            return ExportPreviewFile(photoId: photo.id, filename: photo.filename, fileSize: size)
        }
        let total = files.reduce(0) { $0 + $1.fileSize }
        return ExportPreview(
            totalFiles: files.count,
            totalSizeBytes: total,
            freeSpaceBytes: freeSpace(at: options.destination),
            files: files
        )
    }

    public func execute(
        sessionId: String,
        options: ExportOptions,
        onProgress: ((NativeExportProgress) -> Void)? = nil,
        resume: NativeExportResumeState? = nil
    ) throws -> ExportResult {
        try validate(options)
        try assertDestinationOutsideSource(sessionId: sessionId, destination: options.destination)
        setCancelled(sessionId, value: false)

        let photos = try filteredPhotos(sessionId: sessionId, options: options)
        let sessionName = try sessionRepo.get(id: sessionId)?.name ?? sessionId
        let destination = URL(fileURLWithPath: options.destination).standardizedFileURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var state = resume ?? NativeExportResumeState()
        var usedNames = Set<String>()
        var plans: [(photo: PhotoProjectionRow, name: String, url: URL)] = []

        for (index, photo) in photos.enumerated() {
            var name = state.destinations[photo.id]
            let existingResume = name.map {
                state.completedPhotoIds.contains(photo.id) &&
                FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path)
            } ?? false
            if name == nil || (!existingResume && name.map { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path) } == true) {
                name = resolveName(
                    photo: photo,
                    options: options,
                    counter: (options.naming.counterStart ?? 1) + index,
                    sessionName: sessionName
                )
                name = uniqueName(name!, usedNames: &usedNames, destination: destination)
                state.destinations[photo.id] = name!
                state.onPlanned?(photo.id, name!)
            } else {
                usedNames.insert(name!.lowercased())
            }
            plans.append((photo, name!, destination.appendingPathComponent(name!)))
        }
        state.onPlanReady?()

        var exported = 0
        var failed = 0
        var skipped = 0
        var completed = 0
        var errors: [String] = []

        for plan in plans {
            if isCancelled(sessionId) {
                skipped += 1
                continue
            }
            if state.completedPhotoIds.contains(plan.photo.id),
               FileManager.default.fileExists(atPath: plan.url.path) {
                exported += 1
                completed += 1
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.name, bytesWritten: 0, status: "done"))
                continue
            }

            var created = false
            do {
                try assertDestinationPath(plan.url, inside: destination)
                if options.format == .original {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: plan.photo.filepath), to: plan.url)
                    created = true
                } else {
                    let temporary = destination.appendingPathComponent(
                        ".\(plan.name).gather-export-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
                    )
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try convert(source: plan.photo.filepath, destination: temporary, options: options)
                    try FileManager.default.copyItem(at: temporary, to: plan.url)
                    created = true
                }
                if options.includeXmp {
                    try copyXMPIfPresent(sourcePath: plan.photo.filepath, destinationPath: plan.url.path)
                }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: plan.url.path)[.size] as? NSNumber)
                    .map { Int($0.int64Value) } ?? 0
                exported += 1
                completed += 1
                state.completedPhotoIds.insert(plan.photo.id)
                state.onCompleted?(plan.photo.id)
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.name, bytesWritten: bytes, status: "done"))
            } catch ExportServiceError.cancelled {
                skipped += 1
            } catch {
                if created { try? FileManager.default.removeItem(at: plan.url) }
                let message = error is ExportServiceError ? String(describing: error) : (error as NSError).localizedDescription
                errors.append("\(plan.photo.filename): \(message)")
                failed += 1
                completed += 1
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.photo.filename, bytesWritten: 0,
                    status: "error", errorMessage: message))
            }
        }

        return ExportResult(
            totalFiles: plans.count,
            exported: exported,
            failed: failed,
            skipped: skipped,
            errors: errors
        )
    }

    public func generateReport(
        sessionId: String,
        reportType: String,
        format: String? = nil
    ) throws -> ReportData {
        let requested = format == "md" ? ReportFormat.md : ReportFormat.csv
        switch reportType {
        case "session_summary":
            let rows = try connection.prepare(
                "SELECT filename, filepath, status FROM photos WHERE session_id = ? ORDER BY rowid"
            ).query([.text(sessionId)])
            if requested == .csv {
                var content = "filename,filepath,status\n"
                content += rows.map {
                    [($0[0].textValue ?? ""), ($0[1].textValue ?? ""), ($0[2].textValue ?? "")]
                        .map(Self.csvField).joined(separator: ",")
                }.joined(separator: "\n")
                return ReportData(path: "", content: content, format: .csv)
            }
            var content = "# Session summary\n\n"
            content += "Total photos: \(rows.count)\n\n"
            content += "| # | Filename | Path | Status |\n|---:|---|---|---|\n"
            for (index, row) in rows.enumerated() {
                content += "| \(index + 1) | \(Self.mdField(row[0].textValue ?? "")) | \(Self.mdField(row[1].textValue ?? "")) | \(Self.mdField(row[2].textValue ?? "")) |\n"
            }
            return ReportData(path: "", content: content, format: .md)

        case "person":
            let rows = try connection.prepare(
                """
                SELECT rb.role_name, rb.keywords, fc.label, fc.member_count
                FROM role_bindings rb
                JOIN face_clusters fc ON rb.cluster_id = fc.id
                WHERE rb.session_id = ? ORDER BY rb.role_name
                """
            ).query([.text(sessionId)])
            var content = "# Person report\n\nBindings: \(rows.count)\n\n"
            content += "| Role | Keywords | Cluster | Members |\n|---|---|---|---:|\n"
            for row in rows {
                let keywords = (try? JSONValue.parse(row[1].textValue ?? "[]"))?.arrayValue?.joined(separator: ", ") ?? ""
                content += "| \(Self.mdField(row[0].textValue ?? "")) | \(Self.mdField(keywords)) | \(Self.mdField(row[2].textValue ?? "")) | \(row[3].intValue ?? 0) |\n"
            }
            return ReportData(path: "", content: content, format: .md)

        case "keyword":
            let rows = try connection.prepare(
                "SELECT DISTINCT keywords FROM role_bindings WHERE session_id = ? AND keywords != '[]'"
            ).query([.text(sessionId)])
            var keywords = Set<String>()
            for row in rows {
                keywords.formUnion((try? JSONValue.parse(row[0].textValue ?? "[]"))?.arrayValue ?? [])
            }
            let culling = try connection.prepare(
                "SELECT DISTINCT decision FROM culling_decisions WHERE session_id = ? AND decision != 'pending'"
            ).query([.text(sessionId)])
            for row in culling {
                if row[0].textValue == "keep" { keywords.insert("culling:keep") }
                if row[0].textValue == "reject" { keywords.insert("culling:reject") }
            }
            var content = "# Keyword report\n\n"
            content += keywords.sorted().map { "- \(Self.mdField($0))" }.joined(separator: "\n")
            if !keywords.isEmpty { content += "\n" }
            return ReportData(path: "", content: content, format: .md)

        default:
            return ReportData(path: "", content: "", format: requested)
        }
    }

    // MARK: - Validation and planning

    private func validate(_ options: ExportOptions) throws {
        guard !options.destination.isEmpty else { throw ExportServiceError.destinationInvalid }
        guard options.destination.hasPrefix("/") else { throw ExportServiceError.destinationAbsoluteRequired }
        let destination = URL(fileURLWithPath: options.destination).standardizedFileURL.path
        guard destination != "/" else { throw ExportServiceError.destinationRootForbidden }
        guard ExportFormat.allCases.contains(options.format) else { throw ExportServiceError.formatInvalid }
        if let policy = options.variantPolicy, !ExportVariantPolicy.allCases.contains(policy) {
            throw ExportServiceError.variantPolicyInvalid
        }
        if options.format == .original, options.maxDimension != nil || options.watermark != nil {
            throw ExportServiceError.originalTransformNotAllowed
        }
        guard !options.naming.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExportServiceError.namingEmpty
        }
        if options.naming.pattern.contains("/") || options.naming.pattern.contains("\\") || options.naming.pattern.contains("\0") {
            throw ExportServiceError.namingInvalidCharacters
        }
        if let quality = options.quality, quality.rounded() != quality || quality < 1 || quality > 100 {
            throw ExportServiceError.qualityInvalid
        }
        if let maxDimension = options.maxDimension, maxDimension < 1 {
            throw ExportServiceError.maxDimensionInvalid
        }
        if let start = options.naming.counterStart, start < 0 {
            throw ExportServiceError.startIndexInvalid
        }
        if let watermark = options.watermark {
            guard watermark.type == .text else { throw ExportServiceError.watermarkTypeUnsupported }
            guard !watermark.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExportServiceError.watermarkTextEmpty
            }
            guard watermark.opacity.isFinite, watermark.opacity >= 0, watermark.opacity <= 1 else {
                throw ExportServiceError.watermarkOpacityInvalid
            }
            if let fontSize = watermark.fontSize, !fontSize.isFinite || fontSize < 1 || fontSize > 1000 {
                throw ExportServiceError.watermarkFontSizeInvalid
            }
        }
    }

    private func assertDestinationOutsideSource(sessionId: String, destination: String) throws {
        guard let session = try sessionRepo.get(id: sessionId) else { throw ExportServiceError.sessionNotFound }
        guard !session.sourcePath.isEmpty else { return }
        let dest = canonicalPath(destination)
        let source = canonicalPath(session.sourcePath)
        if dest == source || isPathInside(dest, source) {
            throw ExportServiceError.destinationInsideSession
        }
    }

    private func filteredPhotos(sessionId: String, options: ExportOptions) throws -> [PhotoProjectionRow] {
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
        guard options.scope == .session else { throw ExportServiceError.scopeUnsupported }
        let scoped = photos.filter { $0.status != "removed" }
        let policy = options.variantPolicy ?? .preferred
        if policy == .all { return scoped }

        let raw: Set<String> = [".3fr", ".arw", ".cr2", ".cr3", ".dng", ".fff", ".gpr", ".iiq", ".mos", ".nef", ".nrw", ".orf", ".pef", ".raf", ".raw", ".rw2", ".rwl", ".sr2", ".srf", ".srw", ".x3f"]
        let jpeg: Set<String> = [".jpg", ".jpeg"]
        var groups: [String: [PhotoProjectionRow]] = [:]
        for photo in scoped { groups[photo.assetId ?? photo.id, default: []].append(photo) }
        return groups.values.compactMap { variants in
            let isRaw: (PhotoProjectionRow) -> Bool = { raw.contains(URL(fileURLWithPath: $0.filename).pathExtension.lowercased().isEmpty ? "" : ".\(URL(fileURLWithPath: $0.filename).pathExtension.lowercased())") }
            let isJPEG: (PhotoProjectionRow) -> Bool = { jpeg.contains(".\(URL(fileURLWithPath: $0.filename).pathExtension.lowercased())") }
            switch policy {
            case .raw: return variants.first(where: isRaw)
            case .jpeg: return variants.first(where: isJPEG)
            case .preferred: return variants.first(where: isRaw) ?? variants.first(where: isJPEG) ?? variants.first
            case .all: return variants.first
            }
        }
    }

    private func resolveName(photo: PhotoProjectionRow, options: ExportOptions, counter: Int, sessionName: String) -> String {
        let filename = URL(fileURLWithPath: photo.filename).lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension
        let base = sanitize(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent)
        let session = sanitize(sessionName)
        let date = Date()
        let dateFormat = options.naming.dateFormat ?? "YYYY-MM-DD"
        let dateString = dateFormat
            .replacingOccurrences(of: "YYYY", with: String(Calendar.current.component(.year, from: date)))
            .replacingOccurrences(of: "MM", with: String(format: "%02d", Calendar.current.component(.month, from: date)))
            .replacingOccurrences(of: "DD", with: String(format: "%02d", Calendar.current.component(.day, from: date)))
        // {time} 固定 HH-mm-ss（24h 制）：localizedString(.medium) 在 12h locale
        // 下产出 "3-45-30 PM"（含空格 + AM/PM），与 ExportView 预览的 HH-mm-ss
        // 不符。与 TS 的差异：TS 两端统一 24h 制，此处对齐该语义。
        // 审计 P1：静态 DateFormatter 被 worker 线程（并发导出）与主线程共用
        // 存在数据竞争，改为函数内新建（格式化成本可忽略）。
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        let time = formatter.string(from: date)
        var pattern = options.naming.pattern
        pattern = pattern.replacingOccurrences(of: "{date}", with: dateString)
        pattern = pattern.replacingOccurrences(of: "{time}", with: time)
        pattern = pattern.replacingOccurrences(of: "{counter}", with: String(format: "%04d", counter))
        pattern = pattern.replacingOccurrences(of: "{original}", with: base)
        // Older UI versions exposed {filename}; keep it as a compatibility
        // alias so an existing saved preset never exports a literal token.
        pattern = pattern.replacingOccurrences(of: "{filename}", with: base)
        pattern = pattern.replacingOccurrences(of: "{session}", with: session)
        let targetExt = options.format == .jpeg ? "jpg" : options.format == .tiff ? "tiff" : ext
        return "\(pattern).\(targetExt.isEmpty ? "jpg" : targetExt)"
    }

    private func uniqueName(_ input: String, usedNames: inout Set<String>, destination: URL) -> String {
        let url = URL(fileURLWithPath: input)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        var candidate = input
        var index = 2
        while usedNames.contains(candidate.lowercased()) || FileManager.default.fileExists(atPath: destination.appendingPathComponent(candidate).path) {
            candidate = "\(base)_\(index)\(ext)"
            index += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }

    private func assertDestinationPath(_ url: URL, inside directory: URL) throws {
        let candidate = canonicalPath(url.path)
        let root = canonicalPath(directory.path)
        guard candidate == root || isPathInside(candidate, root) else { throw ExportServiceError.exportPathInvalid }
    }

    private func isPathInside(_ candidate: String, _ directory: String) -> Bool {
        let candidateComponents = URL(fileURLWithPath: candidate).pathComponents
        let directoryComponents = URL(fileURLWithPath: directory).pathComponents
        guard candidateComponents.count > directoryComponents.count else { return false }
        return Array(candidateComponents.prefix(directoryComponents.count)) == directoryComponents
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func sanitize(_ value: String) -> String {
        let replaced = value.replacingOccurrences(of: "[<>:\"/\\\\|?*]", with: "_", options: .regularExpression)
        return URL(fileURLWithPath: replaced).lastPathComponent
    }

    private func freeSpace(at path: String) -> Int {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map(Int.init) ?? -1
    }

    // MARK: - Files and image conversion

    private func copyXMPIfPresent(sourcePath: String, destinationPath: String) throws {
        let source = URL(fileURLWithPath: sourcePath).deletingPathExtension().appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = URL(fileURLWithPath: destinationPath).deletingPathExtension().appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: destination.path) {
            let sourceData = try Data(contentsOf: source)
            let destinationData = try Data(contentsOf: destination)
            if sourceData != destinationData { throw ExportServiceError.xmpConflict }
            return
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func convert(source: String, destination: URL, options: ExportOptions) throws {
#if canImport(ImageIO)
        let decoded: RAWDecodeResult
        do {
            decoded = try RAWDecoder.getPreview(
                path: source,
                maxDimension: options.maxDimension ?? Int.max,
                quality: 1
            )
        } catch {
            throw ExportServiceError.rawConvertUnsupported
        }
        guard let sourceRef = CGImageSourceCreateWithData(decoded.buffer as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil) else {
            throw ExportServiceError.rawConvertUnsupported
        }
        let outputImage = try applyingWatermark(image, watermark: options.watermark)
        let type: CFString = options.format == .jpeg ? "public.jpeg" as CFString : "public.tiff" as CFString
        let properties: [CFString: Any]
        if options.format == .jpeg {
            properties = [kCGImageDestinationLossyCompressionQuality: (options.quality ?? 85) / 100]
        } else {
            let compression: Int
            switch options.tiffCompression ?? .lzw {
            case .none: compression = 1
            case .lzw: compression = 5
            case .deflate: compression = 8
            }
            properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: compression] as CFDictionary]
        }
        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw ExportServiceError.formatUnsupported
        }
        CGImageDestinationAddImage(destinationRef, outputImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else { throw ExportServiceError.formatUnsupported }
#else
        _ = source
        _ = destination
        _ = options
        throw ExportServiceError.formatUnsupported
#endif
    }

#if canImport(ImageIO)
    private func applyingWatermark(_ image: CGImage, watermark: ExportWatermark?) throws -> CGImage {
        guard let watermark else { return image }
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportServiceError.formatUnsupported }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(CGFloat(watermark.opacity))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let font = CGFont("Helvetica" as CFString)
        let size = CGFloat(watermark.fontSize ?? 24)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font?.postScriptName ?? "Helvetica" as CFString, size, nil),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(watermark.content.prefix(256)), attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let margin = CGFloat(max(16, width / 40))
        let x: CGFloat
        let y: CGFloat
        switch watermark.position {
        case .center:
            x = (CGFloat(width) - bounds.width) / 2
            y = (CGFloat(height) - bounds.height) / 2
        case .bottomRight:
            x = CGFloat(width) - bounds.width - margin
            y = margin
        case .bottomLeft:
            x = margin
            y = margin
        }
        context.textPosition = CGPoint(x: max(0, x), y: max(0, y))
        CTLineDraw(line, context)
        return context.makeImage() ?? image
    }
#endif

    private func setCancelled(_ sessionId: String, value: Bool) {
        cancelLock.lock()
        if value { cancelledSessions.insert(sessionId) } else { cancelledSessions.remove(sessionId) }
        cancelLock.unlock()
    }

    private func isCancelled(_ sessionId: String) -> Bool {
        cancelLock.lock()
        let cancelled = cancelledSessions.contains(sessionId)
        cancelLock.unlock()
        return cancelled
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func mdField(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
