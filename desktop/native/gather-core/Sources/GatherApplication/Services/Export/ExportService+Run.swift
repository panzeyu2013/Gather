// desktop/native/gather-core/Sources/GatherApplication/Services/Export/ExportService+Run.swift
// P1-4 收口：ExportService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：执行（安装回滚凭据、原图复制、ImageIO 转码、sidecar 覆盖、取消登记、进度回调）。
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

        /// 写 sidecar 前留底：目标 sidecar 已存在才复制。
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
        resume: NativeExportResumeState? = nil,
        /// 每张「本次交付可用」的产物（含续跑跳过但文件仍在的）回调：
        /// 调用方（整套交付）据此生成联系表/画廊/manifest，避免另建一份计划。
        onWritten: ((_ photoId: String, _ url: URL) -> Void)? = nil
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
        // D09：执行消费与预览**同一份** buildPlan（命名/重名/sidecar 判定唯一实现）。
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
                onWritten?(plan.photo.id, plan.url)
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.name, bytesWritten: 0, status: "done"))
                continue
            }

            // D1（深审）：安装回滚凭据 —— 覆盖既有文件前先留底，后续任一步失败
            // 都把旧照片/旧 sidecar 恢复回来（旧实现按 created 无条件删除目标，
            // 会把用户此前的交付删掉）。
            var installToken: FileInstallToken?
            do {
                try assertDestinationPath(plan.url, canonicalRoot: canonicalDestination)
                // Wave2：子目录规则要求逐文件建目录（旧实现只建顶层 destination）。
                let outputDirectory = plan.url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true)
                if options.format == .original {
                    installToken = try installFile(from: URL(fileURLWithPath: plan.photo.filepath), to: plan.url)
                } else {
                    // 临时文件放在最终目录内（同卷 + 同目录原子替换），名字用裸文件名。
                    let temporary = outputDirectory.appendingPathComponent(
                        ".\(plan.fileName).gather-export-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
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
                // 整套产物（照片 + sidecar）都写成了才丢弃备份：完成检查点也在此之后写入。
                installToken?.commit()
                exported += 1
                completed += 1
                onWritten?(plan.photo.id, plan.url)
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
                // Wave2：图片水印的校验失败是 GatherError（EXPORT_PARAMS_INVALID +
                // field/reason）——取码上屏（UI 会翻译），不要退化成 NSError 的英文散文。
                let message: String
                if let gather = error as? GatherError {
                    message = gather.code.rawValue
                } else if error is ExportServiceError {
                    message = String(describing: error)
                } else {
                    message = (error as NSError).localizedDescription
                }
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
            // 问题 1（第三轮审查）验收：XMP 更新必须形成**新交付** —— 目标 sidecar 内容
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
        // P0-5 / Wave1：输出锐化在**最终输出像素**上做（缩图之后），只改灰度过渡、
        // 不改尺寸；没有锐化参数时原样返回（旧路径逐字节不变）。
        let sharpened = try applyingOutputSharpening(image, sharpening: options.sharpening)
        // 色彩空间转换与文字水印共用一次目标空间重绘；两者都没要求时原样返回。
        let outputImage = try rendering(
            sharpened, colorSpace: options.colorSpace, watermark: options.watermark)
        let type: CFString = options.format == .jpeg ? "public.jpeg" as CFString : "public.tiff" as CFString
        var properties: [CFString: Any]
        if options.format == .jpeg {
            properties = [kCGImageDestinationLossyCompressionQuality: (options.quality ?? 85) / 100]
        } else {
            let compression: Int
            switch options.tiffCompression ?? .lzw {
            case .none: compression = 1
            case .lzw: compression = 5
            case .deflate: compression = 8
            }
            var tiff: [CFString: Any] = [kCGImagePropertyTIFFCompression: compression]
            // TIFF 的 DPI 真相在 TIFF 段（印前工具多读 XResolution/ResolutionUnit），
            // 顶层 kCGImagePropertyDPI* 下面也写一份，兼容按顶层读的消费者。
            if let dpi = options.dpi {
                tiff[kCGImagePropertyTIFFXResolution] = dpi
                tiff[kCGImagePropertyTIFFYResolution] = dpi
                tiff[kCGImagePropertyTIFFResolutionUnit] = 2
            }
            properties = [kCGImagePropertyTIFFDictionary: tiff as CFDictionary]
        }
        if let dpi = options.dpi {
            // P0-5：JPEG 的 JFIF density 与 TIFF 顶层分辨率都认这两个键。
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw ExportServiceError.formatUnsupported
        }
        // 交付保真：转码输出必须带上原片的 EXIF/GPS/TIFF/IPTC 与 XMP，
        // 否则客户拿到的成片没有版权、拍摄信息与关键词（旧实现全丢）。
        let metadata = sourceMetadata(for: source)
        // TIFF 段必须**嵌套合并**：顶层 merging 会把刚搬过来的 Make/Model/Artist
        // 整个压成只剩 Compression。
        var transferable = transferableProperties(from: source)
        var extra = properties
        if let newTIFF = extra[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let oldTIFF = transferable[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            transferable[kCGImagePropertyTIFFDictionary] = oldTIFF.merging(newTIFF) { _, new in new }
            extra.removeValue(forKey: kCGImagePropertyTIFFDictionary)
        }
        var mergedProperties = transferable.merging(extra, uniquingKeysWith: { _, new in new })
        // 像素已按 EXIF 方向摆正（kCGImageSourceCreateThumbnailWithTransform），
        // 输出必须声明 upright；否则整份 XMP 拷贝会把源 Orientation 带过去，
        // 成片在 PS/LR/C1 里被二次旋转。
        mergedProperties[kCGImagePropertyOrientation] = 1
        if let metadata {
            CGImageDestinationAddImageAndMetadata(
                destinationRef, outputImage, metadata, mergedProperties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destinationRef, outputImage, mergedProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destinationRef) else { throw ExportServiceError.formatUnsupported }
#else
        _ = source
        _ = destination
        _ = options
        throw ExportServiceError.formatUnsupported
#endif
    }

#if canImport(ImageIO)
    /// 可搬运的 EXIF/TIFF/GPS/IPTC 子集：**不含** 像素尺寸、Orientation、缩略图与压缩参数
    /// （输出已按方向归一化、尺寸可能被 maxDimension 改过，照搬会双重旋转/尺寸失真）。
    private func transferableProperties(from path: String) -> [CFString: Any] {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }
        var result: [CFString: Any] = [:]
        let exifKeys: [CFString] = [
            kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
            kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake,
            kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureTime,
            kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFocalLength,
            kCGImagePropertyExifFocalLenIn35mmFilm,
        ]
        if let exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var kept: [CFString: Any] = [:]
            for key in exifKeys where exif[key] != nil { kept[key] = exif[key] }
            if !kept.isEmpty { result[kCGImagePropertyExifDictionary] = kept }
        }
        let tiffKeys: [CFString] = [
            kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel,
            kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright,
            kCGImagePropertyTIFFImageDescription,
        ]
        if let tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var kept: [CFString: Any] = [:]
            for key in tiffKeys where tiff[key] != nil { kept[key] = tiff[key] }
            if !kept.isEmpty { result[kCGImagePropertyTIFFDictionary] = kept }
        }
        if let gps = original[kCGImagePropertyGPSDictionary] {
            result[kCGImagePropertyGPSDictionary] = gps
        }
        if let iptc = original[kCGImagePropertyIPTCDictionary] {
            result[kCGImagePropertyIPTCDictionary] = iptc
        }
        return result
        #else
        return [:]
        #endif
    }

    /// 读取原片的元数据（只取可跨格式搬运的段；缩略图/私有段不复制）。
    private func sourceMetadata(for path: String) -> CGImageMetadata? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else {
            return nil
        }
        guard let mutable = CGImageMetadataCreateMutableCopy(metadata) else { return nil }
        // 方向与像素尺寸属于"已被像素侧处理过"的字段：拷贝过去会造成双重旋转
        // 或尺寸与实际输出不符。
        for path in [
            "tiff:Orientation", "exif:Orientation",
            "tiff:ImageWidth", "tiff:ImageLength",
            "exif:PixelXDimension", "exif:PixelYDimension",
        ] {
            CGImageMetadataRemoveTagWithPath(mutable, nil, path as CFString)
        }
        return mutable
        #else
        return nil
        #endif
    }

    /// 输出重绘：把图渲染进目标色彩空间，可选叠加文字水印（P0-5 / Wave1）。
    ///
    /// - 色彩空间与水印都没要求：**原样返回**（既有路径不变，不做无谓重编码）。
    /// - colorSpace 非 nil：重绘进目标 profile，JPEG/TIFF 因此携带对应 ICC。
    /// - 水印沿用旧实现的文字排版/位置/透明度语义；未指定目标空间时沿用原片
    ///   空间（旧实现固定 DeviceRGB，会把带 profile 的原片降级成"未校色"）。
    private func rendering(
        _ image: CGImage,
        colorSpace: ExportColorSpace?,
        watermark: ExportWatermark?
    ) throws -> CGImage {
        guard colorSpace != nil || watermark != nil else { return image }
        let width = image.width
        let height = image.height
        let targetSpace = resolvedColorSpace(colorSpace, fallback: image)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: targetSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportServiceError.formatUnsupported }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let watermark else { return context.makeImage() ?? image }
        switch watermark.type {
        case .text:
            drawTextWatermark(watermark, in: context, width: width, height: height)
        case .image:
            try drawImageWatermark(watermark, in: context, width: width, height: height)
        }
        return context.makeImage() ?? image
    }

    /// 文字水印（P0-5 / Wave1 的既有版式）：白色文字 + 透明度 + 三种位置。
    private func drawTextWatermark(
        _ watermark: ExportWatermark,
        in context: CGContext,
        width: Int,
        height: Int
    ) {
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
    }

    /// 图片水印合成（Wave2）：logo PNG 渲染进目标色彩空间画面。
    ///
    /// - 尺寸：目标宽 = 输出宽度 × imageScale（默认 0.2），**只缩小不放大**
    ///（logo 比目标小时保持原始像素，避免放大发虚）。
    /// - 位置：center 居中；bottomRight/bottomLeft 距边缘 = 输出宽度 × imageMargin
    ///（默认 0.02）。
    /// - 透明度：context 全局 alpha = watermark.opacity（对图像绘制同样生效）。
    private func drawImageWatermark(
        _ watermark: ExportWatermark,
        in context: CGContext,
        width: Int,
        height: Int
    ) throws {
        let path = watermark.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let logo = WatermarkLogoCache.image(for: path) else {
            // validate 已保证文件可解码；走到这里说明执行期文件被移走/损坏：
            // 明确失败而不是静默少一个水印（水印是交付承诺的一部分）。
            throw GatherError(
                code: .EXPORT_PARAMS_INVALID,
                params: ["field": "watermark.imagePath", "reason": "unreadableAtRender"])
        }
        let scale = min(max(watermark.imageScale ?? 0.2, 0.02), 1)
        let marginRatio = min(max(watermark.imageMargin ?? 0.02, 0), 0.25)
        let targetWidth = CGFloat(width) * CGFloat(scale)
        let drawScale = min(1, targetWidth / CGFloat(max(logo.width, 1)))
        let logoWidth = max(1, (CGFloat(logo.width) * drawScale).rounded())
        let logoHeight = max(1, (CGFloat(logo.height) * drawScale).rounded())
        let margin = (CGFloat(width) * CGFloat(marginRatio)).rounded()
        let x: CGFloat
        switch watermark.position {
        case .center:
            x = (CGFloat(width) - logoWidth) / 2
        case .bottomRight:
            x = CGFloat(width) - logoWidth - margin
        case .bottomLeft:
            x = margin
        }
        // 显式双坐标换算（避免混用两套 y 方向）：
        // - topDownY 是**视觉**坐标（0 = 画面顶边，向下为正）；
        // - CGContext 的绘制坐标是左下原点、向上为正，等价于 cgY = height - topDownY - logoHeight。
        // 这样 bottom-* 一定贴视觉底边（topDownY = height - logoH - margin），
        // 居中两套坐标等价，也不会再出现"y 基准是顶还是底"的歧义。
        let topDownY: CGFloat
        switch watermark.position {
        case .center:
            topDownY = (CGFloat(height) - logoHeight) / 2
        case .bottomRight, .bottomLeft:
            topDownY = CGFloat(height) - logoHeight - margin
        }
        let cgY = CGFloat(height) - topDownY - logoHeight
        context.saveGState()
        context.setAlpha(CGFloat(watermark.opacity))
        context.interpolationQuality = .high
        context.draw(logo, in: CGRect(
            x: x.rounded(), y: cgY.rounded(), width: logoWidth, height: logoHeight))
        context.restoreGState()
    }

    /// 目标色彩空间：显式指定优先，否则沿用原片 profile（缺失时 DeviceRGB）。
    private func resolvedColorSpace(_ colorSpace: ExportColorSpace?, fallback image: CGImage) -> CGColorSpace {
        switch colorSpace {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        case .adobeRGB1998: return CGColorSpace(name: CGColorSpace.adobeRGB1998) ?? CGColorSpaceCreateDeviceRGB()
        case nil: return image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        }
    }

    /// 输出锐化（unsharp mask，P0-5 / Wave1）：out = orig + intensity × (orig − blur)。
    ///
    /// 模糊用可分离盒式平均近似高斯：不引入 GPU/CoreImage 依赖、结果确定，
    /// 单测能在任意机器复现；半径按输出像素解释（UI 0.5-3）。只处理 RGB：
    /// 尺寸与 alpha 不变，非不透明像素仍满足 premultiplied 约束。
    /// 没有锐化参数 / 强度为 0 时原样返回（既有路径字节不变）。
    private func applyingOutputSharpening(
        _ image: CGImage,
        sharpening: ExportSharpening?
    ) throws -> CGImage {
        guard let sharpening, sharpening.intensity > 0 else { return image }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }
        // 缓冲必须是 RGB 空间（下面按 RGBA 8-bit 解释内存）；灰度/CMYK 源退 DeviceRGB。
        let bufferSpace = image.colorSpace?.model == .rgb
            ? (image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
            : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        do {
            // 先渲进缓冲；context 在代码块结束时释放，之后才能安全改写数组内存。
            guard let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: bufferSpace, bitmapInfo: bitmapInfo
            ) else { throw ExportServiceError.formatUnsupported }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let radius = max(1, Int(sharpening.radius.rounded()))
        let blurred = Self.boxBlurRGBA(pixels, width: width, height: height, radius: radius)
        let amount = min(max(sharpening.intensity, 0), 2)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            for channel in 0..<3 {
                let original = Double(pixels[index + channel])
                let smooth = Double(blurred[index + channel])
                var value = Int((original + amount * (original - smooth)).rounded())
                value = min(max(value, 0), 255)
                // premultiplied 约束：半透明像素的通道不得大于 alpha。
                if alpha < 255 { value = min(value, alpha) }
                pixels[index + channel] = UInt8(value)
            }
        }
        do {
            guard let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: bufferSpace, bitmapInfo: bitmapInfo
            ), let output = context.makeImage() else {
                throw ExportServiceError.formatUnsupported
            }
            return output
        }
    }

    /// 可分离盒式模糊（水平 + 垂直各一遍）近似高斯，RGBA 8-bit，边缘按夹取处理。
    /// 滑动窗口使单遍复杂度 O(像素)，半径按输出像素解释。
    private static func boxBlurRGBA(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) -> [UInt8] {
        guard radius > 0, width > 0, height > 0 else { return pixels }
        let window = radius * 2 + 1
        var horizontal = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<height {
            let row = y * width * 4
            var sums = [Int](repeating: 0, count: 4)
            for offset in -radius...radius {
                let x = min(max(offset, 0), width - 1)
                let p = row + x * 4
                for channel in 0..<4 { sums[channel] += Int(pixels[p + channel]) }
            }
            for x in 0..<width {
                let p = row + x * 4
                for channel in 0..<4 { horizontal[p + channel] = UInt8(sums[channel] / window) }
                let removeX = min(max(x - radius, 0), width - 1)
                let addX = min(max(x + radius + 1, 0), width - 1)
                for channel in 0..<4 {
                    sums[channel] += Int(pixels[row + addX * 4 + channel])
                        - Int(pixels[row + removeX * 4 + channel])
                }
            }
        }
        var output = [UInt8](repeating: 0, count: pixels.count)
        for x in 0..<width {
            let column = x * 4
            var sums = [Int](repeating: 0, count: 4)
            for offset in -radius...radius {
                let y = min(max(offset, 0), height - 1)
                let p = y * width * 4 + column
                for channel in 0..<4 { sums[channel] += Int(horizontal[p + channel]) }
            }
            for y in 0..<height {
                let p = y * width * 4 + column
                for channel in 0..<4 { output[p + channel] = UInt8(sums[channel] / window) }
                let removeY = min(max(y - radius, 0), height - 1)
                let addY = min(max(y + radius + 1, 0), height - 1)
                let remove = removeY * width * 4 + column
                let add = addY * width * 4 + column
                for channel in 0..<4 {
                    sums[channel] += Int(horizontal[add + channel]) - Int(horizontal[remove + channel])
                }
            }
        }
        return output
    }
#endif

    /// 登记一次执行（返回 runId）。execute 入口调用。
    private func registerRun(sessionId: String, preferredRunId: String?) -> String {
        let runId = preferredRunId ?? UUID().uuidString
        cancelLock.lock()
        sessionRuns[sessionId, default: []].insert(runId)
        // 清掉上一轮的取消位：重试同一 job 时执行器用同一个 runId，
        // 残留标记会让整批「跳过但成功」。
        cancelledRuns.remove(runId)
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

#if canImport(ImageIO)
/// 图片水印 logo 的解码缓存（Wave2）。
///
/// 为什么缓存：一次交付可能合成上千张，每张都从磁盘解码同一个 logo 是纯浪费；
/// 缓存的是「解码期就按最长边 2048 降采样」的 CGImage —— 既给超大 logo 兜底
///（不把 12000px 的 PNG 全量进内存），又保证缩到输出尺寸时画质够用。
/// 锁 + nonisolated(unsafe) 的静态表写法与 GatherAnalysis 的 AFPointProfiles 一致。
private enum WatermarkLogoCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var images: [String: CGImage] = [:]

    /// 读取 logo（最长边 ≤ 2048）；nil = 不可解码。
    static func image(for path: String) -> CGImage? {
        lock.lock()
        if let cached = images[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let decoded = decode(path: path) else { return nil }
        lock.lock()
        images[path] = decoded
        lock.unlock()
        return decoded
    }

    /// 清空缓存（测试隔离用）。
    static func removeAll() {
        lock.lock()
        images.removeAll()
        lock.unlock()
    }

    private static func decode(path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
#endif
