// desktop/native/gather-core/Sources/GatherCore/Runtime/Export/ExportRuntime.swift
// W2d-4 步骤②b：ExportRuntime actor —— Services/ExportService.swift 的运行时编排下沉。
//
// 范围与边界：
// - 只新增本文件：编排放进 actor，纯逻辑继续逐字调用 Runtime/Export/ExportAssembler。
//   旧服务在本步骤保持可用（不接线、不改 Services/ 与路由），步骤③切换后再删除。
// - 门禁：本文件不出现 SQL 文本与 SQLiteDatabase；报告行由注入的
//   ExportReportSource 提供（SQL 留在 Store/宿主实现侧）。actor 内无锁（取消集合是
//   actor 隔离状态，不使用 NSLock）。
// - 文件 IO、图像转码、XMP 存在性检查全部走接缝：ExportFileSystem /
//   ExportImageConverter / XMPProvider?，测试可注入内存实现。
//
// 与旧实现的有意差异（行为等价性说明）：
// 1. 取消：旧实现用 NSLock + Set 轮询式检查；actor 化后取消集合为隔离状态。文件操作
//    均为 await 点，取消消息在检查点之间自然送达，不做轮询、不做无界等待。
// 2. 续作状态改为 Sendable 值类型 ExportResumeState + 独立 @Sendable 回调；旧
//    NativeExportResumeState 携带闭包，无法安全跨越 actor 边界。
// 3. 命名冲突消解：ExportAssembler.uniqueName 的 nameExists 是同步闭包，而接缝是
//    async 的，故规划阶段先取一次目标目录条目快照（lowercased），再以快照判定。
//    等价于旧 FileManager.fileExists 在大小写不敏感卷上的行为；大小写敏感卷上比旧
//    实现更保守（旧实现可能因大小写不同而放行同名文件）。最终占用仍由 usedNames 兜底。
// 4. 转码临时文件：旧实现用 defer 兜底删除；async 上下文不允许 defer 中 await，改为
//    成功/失败两条路径显式删除（均 try? 忽略失败，语义相同）。
// 5. XMP 侧车比较：旧实现 Data(contentsOf:) 抛错；接缝 readData 返回可选值，读不到按
//    内容不等 -> EXPORT_XMP_CONFLICT 处理。
// 6. ExportExecuteParams.confirmed 不在本 actor 校验：与旧 ExportService.execute 一致，
//    确认门禁属于命令层职责。

import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import CoreText
#endif

// MARK: - 文件系统接缝

/// 导出 IO 接缝。生产实现为 DiskExportFileSystem；测试注入内存实现。
/// 变更类操作全部 async：actor 在每次文件操作处让出执行权，取消无需轮询即可送达。
public protocol ExportFileSystem: Sendable {
    /// 旧 FileManager.fileExists(atPath:)。
    func exists(_ path: String) async -> Bool
    /// 旧 (try? attributesOfItem[.size]) ?? 0：读不到返回 0。
    func fileSize(_ path: String) async -> Int
    /// 旧 createDirectory(at:withIntermediateDirectories:true)。
    func createDirectory(_ path: String) async throws
    /// 旧 copyItem(at:to:)。
    func copyItem(from sourcePath: String, to destinationPath: String) async throws
    /// 旧 removeItem(at:)。
    func removeItem(_ path: String) async throws
    /// 旧 Data(contentsOf:)；文件缺失返回 nil。
    func readData(_ path: String) async throws -> Data?
    /// 目录内条目名（不递归），用于命名冲突消解快照。
    func names(inDirectory path: String) async throws -> Set<String>
    /// 旧 freeSpace(at:)：向上回溯到存在的父目录，读不到返回 -1。
    func availableCapacity(at path: String) async -> Int
}

/// 生产实现：直接落盘（逐字对齐旧 ExportService 的 FileManager 调用）。
public struct DiskExportFileSystem: ExportFileSystem {
    public init() {}

    public func exists(_ path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func fileSize(_ path: String) async -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)
            .map { Int($0.int64Value) } ?? 0
    }

    public func createDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
    }

    public func copyItem(from sourcePath: String, to destinationPath: String) async throws {
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: sourcePath),
            to: URL(fileURLWithPath: destinationPath)
        )
    }

    public func removeItem(_ path: String) async throws {
        try FileManager.default.removeItem(atPath: path)
    }

    public func readData(_ path: String) async throws -> Data? {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func names(inDirectory path: String) async throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: path))
    }

    public func availableCapacity(at path: String) async -> Int {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map(Int.init) ?? -1
    }
}

// MARK: - 图像转码接缝

/// 转码接缝：生产实现为 SystemExportImageConverter（ImageIO），测试可注入内存实现。
public protocol ExportImageConverter: Sendable {
    func convert(sourcePath: String, destinationPath: String, options: ExportOptions) async throws
}

/// 生产实现：逐字移植旧 ExportService.convert + applyingWatermark。
public struct SystemExportImageConverter: ExportImageConverter {
    public init() {}

    public func convert(sourcePath: String, destinationPath: String, options: ExportOptions) async throws {
#if canImport(ImageIO)
        let decoded: RAWDecodeResult
        do {
            decoded = try RAWDecoder.getPreview(
                path: sourcePath,
                maxDimension: options.maxDimension ?? Int.max,
                quality: 1
            )
        } catch {
            throw ExportError.rawConvertUnsupported
        }
        guard let sourceRef = CGImageSourceCreateWithData(decoded.buffer as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil) else {
            throw ExportError.rawConvertUnsupported
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
        let destination = URL(fileURLWithPath: destinationPath)
        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw ExportError.formatUnsupported
        }
        CGImageDestinationAddImage(destinationRef, outputImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else { throw ExportError.formatUnsupported }
#else
        _ = sourcePath
        _ = destinationPath
        _ = options
        throw ExportError.formatUnsupported
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
        ) else { throw ExportError.formatUnsupported }
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
}

// MARK: - 报告数据源接缝

/// 报告行数据源：把旧 ExportService.generateReport 里的 SQL 留在实现侧，
/// actor 只接收 SQLiteRow 值。gather-app 侧用 SQLiteDatabase 实现本协议。
public protocol ExportReportSource: Sendable {
    func sessionSummaryRows(sessionId: String) async throws -> [SQLiteRow]
    func personRows(sessionId: String) async throws -> [SQLiteRow]
    func keywordRows(sessionId: String) async throws -> [SQLiteRow]
    func cullingDecisionRows(sessionId: String) async throws -> [SQLiteRow]
}

// MARK: - 续作状态（Sendable 值类型）

/// 旧 NativeExportResumeState 的可跨 actor 值版本：断点续作只携带值，
/// 回调以独立的 @Sendable 参数传入 execute。
public struct ExportResumeState: Sendable, Equatable {
    public var destinations: [String: String]
    public var completedPhotoIds: Set<String>

    public init(destinations: [String: String] = [:], completedPhotoIds: Set<String> = []) {
        self.destinations = destinations
        self.completedPhotoIds = completedPhotoIds
    }
}

// MARK: - ExportRuntime

/// 导出运行时：预览、文件规划、断点续作、原图复制/转码编排与报告生成。
public actor ExportRuntime {
    /// 依赖集合（装配期注入；actor 只读）。
    public struct Dependencies: Sendable {
        public let photoStore: any PhotoStore
        public let sessionStore: any SessionStore
        public let reportSource: any ExportReportSource
        public let fileSystem: any ExportFileSystem
        public let imageConverter: any ExportImageConverter
        public let xmpProvider: (any XMPProvider)?
        public let dateProvider: @Sendable () -> Date
        public let temporaryFileName: @Sendable (String) -> String

        public init(
            photoStore: any PhotoStore,
            sessionStore: any SessionStore,
            reportSource: any ExportReportSource,
            fileSystem: any ExportFileSystem,
            imageConverter: any ExportImageConverter = SystemExportImageConverter(),
            xmpProvider: (any XMPProvider)? = nil,
            dateProvider: @escaping @Sendable () -> Date = { Date() },
            temporaryFileName: @escaping @Sendable (String) -> String = { planName in
                ".\(planName).gather-export-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
            }
        ) {
            self.photoStore = photoStore
            self.sessionStore = sessionStore
            self.reportSource = reportSource
            self.fileSystem = fileSystem
            self.imageConverter = imageConverter
            self.xmpProvider = xmpProvider
            self.dateProvider = dateProvider
            self.temporaryFileName = temporaryFileName
        }
    }

    private let deps: Dependencies
    /// 取消会话集合：actor 隔离状态，替代旧 NSLock + Set。
    private var cancelledSessions: Set<String> = []

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    // MARK: - 取消

    /// 标记会话取消。运行中的 execute 在下一个文件检查点生效（不轮询、不阻塞）。
    public func cancel(_ sessionId: String) async throws {
        cancelledSessions.insert(sessionId)
    }

    // MARK: - 预览

    /// 旧 ExportService.preview(sessionId:options:)。
    public func preview(_ params: ExportPreviewParams) async throws -> ExportPreview {
        try ExportAssembler.validate(params.options)
        try await assertDestinationOutsideSource(sessionId: params.sessionId, destination: params.options.destination)

        let photos = try await filteredPhotos(sessionId: params.sessionId, options: params.options)
        var files: [ExportPreviewFile] = []
        files.reserveCapacity(photos.count)
        for photo in photos {
            let size = await deps.fileSystem.fileSize(photo.filepath)
            files.append(ExportPreviewFile(photoId: photo.id, filename: photo.filename, fileSize: size))
        }
        let total = files.reduce(0) { $0 + $1.fileSize }
        let freeSpace = await deps.fileSystem.availableCapacity(at: params.options.destination)
        return ExportPreview(
            totalFiles: files.count,
            totalSizeBytes: total,
            freeSpaceBytes: freeSpace,
            files: files
        )
    }

    // MARK: - 执行

    /// 旧 ExportService.execute(sessionId:options:onProgress:resume:)。
    /// 回调已改为 @Sendable，检查点续作状态为 Sendable 值类型。
    public func execute(
        _ params: ExportExecuteParams,
        resume: ExportResumeState? = nil,
        onProgress: (@Sendable (NativeExportProgress) -> Void)? = nil,
        onPlanned: (@Sendable (String, String) -> Void)? = nil,
        onPlanReady: (@Sendable () -> Void)? = nil,
        onCompleted: (@Sendable (String) -> Void)? = nil
    ) async throws -> ExportResult {
        let sessionId = params.sessionId
        let options = params.options
        try ExportAssembler.validate(options)
        try await assertDestinationOutsideSource(sessionId: sessionId, destination: options.destination)
        cancelledSessions.remove(sessionId)

        let photos = try await filteredPhotos(sessionId: sessionId, options: options)
        let sessionName = try await deps.sessionStore.get(id: sessionId)?.name ?? sessionId
        let destination = URL(fileURLWithPath: options.destination).standardizedFileURL
        try await deps.fileSystem.createDirectory(destination.path)

        var state = resume ?? ExportResumeState()
        var usedNames = Set<String>()
        var destinationNames = Set<String>()
        if let names = try? await deps.fileSystem.names(inDirectory: destination.path) {
            destinationNames = Set(names.map { $0.lowercased() })
        }
        var plans: [(photo: PhotoProjection, name: String, url: URL)] = []
        plans.reserveCapacity(photos.count)

        for (index, photo) in photos.enumerated() {
            var name = state.destinations[photo.id]
            if let existing = name {
                let existingPath = destination.appendingPathComponent(existing).path
                let fileExists = await deps.fileSystem.exists(existingPath)
                let resumable = state.completedPhotoIds.contains(photo.id) && fileExists
                if !resumable && fileExists { name = nil }
            }
            if let resolvedName = name {
                usedNames.insert(resolvedName.lowercased())
                name = resolvedName
            } else {
                let resolved = ExportAssembler.resolveName(
                    filename: photo.filename,
                    options: options,
                    counter: (options.naming.counterStart ?? 1) + index,
                    sessionName: sessionName,
                    date: deps.dateProvider()
                )
                let unique = ExportAssembler.uniqueName(resolved, usedNames: &usedNames) { candidate in
                    destinationNames.contains(candidate.lowercased())
                }
                state.destinations[photo.id] = unique
                onPlanned?(photo.id, unique)
                name = unique
            }
            guard let plannedName = name else { continue }
            plans.append((photo, plannedName, destination.appendingPathComponent(plannedName)))
        }
        onPlanReady?()

        var exported = 0
        var failed = 0
        var skipped = 0
        var completed = 0
        var errors: [String] = []

        for plan in plans {
            if cancelledSessions.contains(sessionId) {
                skipped += 1
                continue
            }
            if state.completedPhotoIds.contains(plan.photo.id),
               await deps.fileSystem.exists(plan.url.path) {
                exported += 1
                completed += 1
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.name, bytesWritten: 0, status: "done"))
                continue
            }

            var created = false
            do {
                try ExportAssembler.assertDestinationPath(plan.url, inside: destination)
                if options.format == .original {
                    try await deps.fileSystem.copyItem(from: plan.photo.filepath, to: plan.url.path)
                    created = true
                } else {
                    let temporaryPath = destination
                        .appendingPathComponent(deps.temporaryFileName(plan.name)).path
                    do {
                        try await deps.imageConverter.convert(
                            sourcePath: plan.photo.filepath,
                            destinationPath: temporaryPath,
                            options: options
                        )
                        try await deps.fileSystem.copyItem(from: temporaryPath, to: plan.url.path)
                        created = true
                    } catch {
                        try? await deps.fileSystem.removeItem(temporaryPath)
                        throw error
                    }
                    try? await deps.fileSystem.removeItem(temporaryPath)
                }
                if options.includeXmp {
                    try await copyXMPIfPresent(sourcePath: plan.photo.filepath, destinationPath: plan.url.path)
                }
                let bytes = await deps.fileSystem.fileSize(plan.url.path)
                exported += 1
                completed += 1
                state.completedPhotoIds.insert(plan.photo.id)
                onCompleted?(plan.photo.id)
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.name, bytesWritten: bytes, status: "done"))
            } catch ExportError.cancelled {
                skipped += 1
            } catch {
                if created { try? await deps.fileSystem.removeItem(plan.url.path) }
                let message = error is ExportError ? String(describing: error) : (error as NSError).localizedDescription
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

    // MARK: - 报告

    /// 旧 ExportService.generateReport(sessionId:reportType:format:)。
    public func report(_ params: ExportReportParams) async throws -> ReportData {
        let requested = params.format == "md" ? ReportFormat.md : ReportFormat.csv
        switch params.reportType {
        case "session_summary":
            let rows = try await deps.reportSource.sessionSummaryRows(sessionId: params.sessionId)
            return ExportAssembler.sessionSummary(rows: rows, format: requested)

        case "person":
            let rows = try await deps.reportSource.personRows(sessionId: params.sessionId)
            return ExportAssembler.personReport(rows: rows)

        case "keyword":
            let bindingRows = try await deps.reportSource.keywordRows(sessionId: params.sessionId)
            let cullingRows = try await deps.reportSource.cullingDecisionRows(sessionId: params.sessionId)
            return ExportAssembler.keywordReport(
                keywords: ExportAssembler.keywords(bindingRows: bindingRows, cullingRows: cullingRows)
            )

        default:
            return ExportAssembler.emptyReport(format: requested)
        }
    }

    // MARK: - 私有：校验与查询（纯逻辑见 ExportAssembler）

    private func assertDestinationOutsideSource(sessionId: String, destination: String) async throws {
        guard let session = try await deps.sessionStore.get(id: sessionId) else {
            throw ExportError.sessionNotFound
        }
        guard !session.sourcePath.isEmpty else { return }
        let dest = ExportAssembler.canonicalPath(destination)
        let source = ExportAssembler.canonicalPath(session.sourcePath)
        if dest == source || ExportAssembler.isPathInside(dest, source) {
            throw ExportError.destinationInsideSession
        }
    }

    private func filteredPhotos(sessionId: String, options: ExportOptions) async throws -> [PhotoProjection] {
        let photos = try await deps.photoStore.getBySessionProjection(sessionId: sessionId)
        let scoped = try ExportAssembler.scopedPhotos(photos, scope: options.scope)
        let policy = options.variantPolicy ?? .preferred
        return ExportAssembler.selectVariants(scoped, policy: policy)
    }

    // MARK: - 私有：XMP 侧车

    private func copyXMPIfPresent(sourcePath: String, destinationPath: String) async throws {
        let source = URL(fileURLWithPath: sourcePath).deletingPathExtension().appendingPathExtension("xmp").path
        let destination = URL(fileURLWithPath: destinationPath).deletingPathExtension().appendingPathExtension("xmp").path
        let sourceExists: Bool
        if let xmp = deps.xmpProvider {
            sourceExists = xmp.fileExists(source)
        } else {
            sourceExists = await deps.fileSystem.exists(source)
        }
        guard sourceExists else { return }
        if await deps.fileSystem.exists(destination) {
            let sourceData = try await deps.fileSystem.readData(source)
            let destinationData = try await deps.fileSystem.readData(destination)
            if sourceData != destinationData { throw ExportError.xmpConflict }
            return
        }
        try await deps.fileSystem.copyItem(from: source, to: destination)
    }
}
