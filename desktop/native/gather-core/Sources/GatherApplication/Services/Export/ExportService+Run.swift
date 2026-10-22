// desktop/native/gather-core/Sources/GatherApplication/Services/Export/ExportService+Run.swift
// P1-4 收口：ExportService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：执行（安装回滚凭据、原图复制、ImageIO 转码、边车覆盖、取消登记、进度回调）。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import CoreText
#endif

extension ExportService {

    /// 一次「安装文件」的可回滚凭据（D1）。
    ///
    /// 覆盖既有文件前把旧文件复制到目标目录内的隐藏备份；提交时删除备份，
    /// 回滚时用备份恢复（本次新建的文件则直接删除，不留半套产物）。
    final class FileInstallToken {
        let destination: URL
        private var backup: URL?
        private var sidecarDestination: URL?
        private var sidecarBackup: URL?
        init(destination: URL, backup: URL?, sidecarDestination: URL? = nil, sidecarBackup: URL? = nil) {
            self.destination = destination
            self.backup = backup
            self.sidecarDestination = sidecarDestination
            self.sidecarBackup = sidecarBackup
        }

        /// 已在目标目录留底的旧照片（同目录，保证同卷）。
        var photoBackup: URL? { backup }

        /// 写边车前留底：目标边车已存在才复制。
        func backupSidecar() {
            let sidecar = destination.deletingPathExtension().appendingPathExtension("xmp")
            sidecarDestination = sidecar
            guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
            let backupURL = sidecar.deletingLastPathComponent()
                .appendingPathComponent(".\(sidecar.lastPathComponent).gather-prev-\(UUID().uuidString)")
            try? FileManager.default.removeItem(at: backupURL)
            if (try? FileManager.default.copyItem(at: sidecar, to: backupURL)) != nil {
                sidecarBackup = backupURL
            }
        }

        func commit() {
            if let backup { try? FileManager.default.removeItem(at: backup) }
            if let sidecarBackup { try? FileManager.default.removeItem(at: sidecarBackup) }
            backup = nil
            sidecarBackup = nil
        }

        func rollback() {
            let fm = FileManager.default
            if let backup {
                try? fm.removeItem(at: destination)
                try? fm.moveItem(at: backup, to: destination)
            } else {
                try? fm.removeItem(at: destination)
            }
            backup = nil
            if let sidecarBackup, let sidecarDestination {
                try? fm.removeItem(at: sidecarDestination)
                try? fm.moveItem(at: sidecarBackup, to: sidecarDestination)
            }
            sidecarBackup = nil
        }
    }

    /// 把文件安装到目标位置：目标已存在时用临时文件 + 原子替换，并返回回滚凭据。
    private func installFile(from sourceURL: URL, to destinationURL: URL) throws -> FileInstallToken {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: destinationURL.path)
        var backup: URL?
        if existed {
            let backupURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).gather-prev-\(UUID().uuidString)")
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: destinationURL, to: backupURL)
            backup = backupURL
        }
        do {
            if existed {
                let temporary = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(destinationURL.lastPathComponent).gather-replace-\(UUID().uuidString)")
                try fm.copyItem(at: sourceURL, to: temporary)
                defer { try? fm.removeItem(at: temporary) }
                _ = try fm.replaceItemAt(destinationURL, withItemAt: temporary)
            } else {
                try fm.copyItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            if let backup { try? fm.removeItem(at: backup) }
            throw error
        }
        return FileInstallToken(destination: destinationURL, backup: backup)
    }

    func sidecarExists(forSource path: String) -> Bool {
        let sidecar = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("xmp")
        return FileManager.default.fileExists(atPath: sidecar.path)
    }

    public func execute(
        sessionId: String,
        options: ExportOptions,
        runId: String? = nil,
        onProgress: ((NativeExportProgress) -> Void)? = nil,
        resume: NativeExportResumeState? = nil
    ) throws -> ExportResult {
        try validate(options)
        try assertDestinationOutsideSource(sessionId: sessionId, destination: options.destination)
        // 问题 2：每次执行独立取消位；入口不再清任何公共标志。
        // runId 由调用方（任务 id）传入时，取消信号可精确到这一次执行。
        let runId = registerRun(sessionId: sessionId, preferredRunId: runId)
        defer { unregisterRun(sessionId: sessionId, runId: runId) }

        let photos = try filteredPhotos(sessionId: sessionId, options: options)
        let sessionName = try sessionRepo.get(id: sessionId)?.name ?? sessionId
        let destination = URL(fileURLWithPath: options.destination).standardizedFileURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var state = resume ?? NativeExportResumeState()
        // D09：执行消费与预览**同一份** buildPlan（命名/重名/边车判定唯一实现）。
        // 旧实现把命名循环写在 execute 里，preview 另抄一份 → 两处规则可能漂移
        //（预览显示的名字与真正写出的名字不一致）。
        let built = buildPlan(
            photos: photos,
            options: options,
            sessionName: sessionName,
            destination: destination,
            resumedNames: state.destinations,
            completedPhotoIds: state.completedPhotoIds,
            onPlanned: { photoId, name in
                state.destinations[photoId] = name
                state.onPlanned?(photoId, name)
            }
        )
        // 保持原语义：解析出的名字写回续跑状态（检查点据此持久化）。
        for (photoId, name) in built.resolvedNames {
            state.destinations[photoId] = name
        }
        let plans = built.items
        state.onPlanReady?()

        var exported = 0
        var failed = 0
        var skipped = 0
        var completed = 0
        var errors: [String] = []
        // E-3：目标目录的 canonical 路径只解析一次（循环内是同一常量）。
        let canonicalDestination = canonicalPath(destination.path)

        for plan in plans {
            if isCancelled(runId) {
                skipped += 1
                continue
            }
            if state.completedPhotoIds.contains(plan.photo.id),
               FileManager.default.fileExists(atPath: plan.url.path),
               shouldSkipCompleted(plan: plan, options: options, state: state) {
                exported += 1
                completed += 1
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.name, bytesWritten: 0, status: "done"))
                continue
            }

            // D1（深审）：安装回滚凭据 —— 覆盖既有文件前先留底，后续任一步失败
            // 都把旧照片/旧边车恢复回来（旧实现按 created 无条件删除目标，
            // 会把用户此前的交付删掉）。
            var installToken: FileInstallToken?
            do {
                try assertDestinationPath(plan.url, canonicalRoot: canonicalDestination)
                if options.format == .original {
                    installToken = try installFile(from: URL(fileURLWithPath: plan.photo.filepath), to: plan.url)
                } else {
                    let temporary = destination.appendingPathComponent(
                        ".\(plan.name).gather-export-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
                    )
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try convert(source: plan.photo.filepath, destination: temporary, options: options)
                    installToken = try installFile(from: temporary, to: plan.url)
                }
                if options.includeXmp {
                    installToken?.backupSidecar()
                    try copyXMPIfPresent(sourcePath: plan.photo.filepath, destinationPath: plan.url.path)
                }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: plan.url.path)[.size] as? NSNumber)
                    .map { Int($0.int64Value) } ?? 0
                // 整套产物（照片 + 边车）都写成了才丢弃备份：完成检查点也在此之后写入。
                installToken?.commit()
                exported += 1
                completed += 1
                state.completedPhotoIds.insert(plan.photo.id)
                state.onCompleted?(plan.photo.id, sidecarVersion(forSource: plan.photo.filepath))
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.name, bytesWritten: bytes, status: "done"))
            } catch ExportServiceError.cancelled {
                skipped += 1
            } catch {
                // D1：失败 = 本次没有完成；恢复覆盖前的旧文件（本次新建则删除半成品）。
                installToken?.rollback()
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

    // MARK: - Files and image conversion

    private func copyXMPIfPresent(sourcePath: String, destinationPath: String) throws {
        let source = URL(fileURLWithPath: sourcePath).deletingPathExtension().appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = URL(fileURLWithPath: destinationPath).deletingPathExtension().appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: destination.path) {
            let sourceData = try Data(contentsOf: source)
            let destinationData = try Data(contentsOf: destination)
            if sourceData == destinationData { return }
            // 问题 1（第三轮审查）验收：XMP 更新必须形成**新交付** —— 目标边车内容
            // 与源不同时覆盖（原子写），而不是抛冲突或静默跳过。
            try sourceData.write(to: destination, options: .atomic)
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

    /// 登记一次执行（返回 runId）。execute 入口调用。
    private func registerRun(sessionId: String, preferredRunId: String?) -> String {
        let runId = preferredRunId ?? UUID().uuidString
        cancelLock.lock()
        sessionRuns[sessionId, default: []].insert(runId)
        cancelLock.unlock()
        return runId
    }

    private func unregisterRun(sessionId: String, runId: String) {
        cancelLock.lock()
        sessionRuns[sessionId]?.remove(runId)
        if sessionRuns[sessionId]?.isEmpty == true { sessionRuns[sessionId] = nil }
        cancelledRuns.remove(runId)
        cancelLock.unlock()
    }

    private func isCancelled(_ runId: String) -> Bool {
        cancelLock.lock()
        let cancelled = cancelledRuns.contains(runId)
        cancelLock.unlock()
        return cancelled
    }
}
