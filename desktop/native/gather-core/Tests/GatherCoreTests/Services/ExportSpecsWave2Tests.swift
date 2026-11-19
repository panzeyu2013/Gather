// desktop/native/gather-core/Tests/GatherCoreTests/Services/ExportSpecsWave2Tests.swift
// Wave2（task-16）：导出规格补齐 —— 图片水印 / 子目录规则 / 配方级联系表画廊参数。
//
// 覆盖：
// - 图片水印：logo 合成尺寸（按输出宽度比例，只缩小不放大）、右下/居中位置、
//   透明度叠加、超大 logo 降采样；非法 logo/版式参数给出 EXPORT_PARAMS_INVALID；
// - 子目录规则：token（{yyyy}/{MM}/{dd}/{client}/{event}/{orig}）展开、
//   执行时创建多级目录、未知 token/绝对路径/路径穿越/空段被拒；
// - OutputRecipe 新旧 JSON：subdirectory/contactSheet(margin)/gallery/图片水印字段
//   往返，旧 JSON（无新键）仍可解码。
//
// 边界：内存库 + 临时目录真实文件；ImageIO 用例用 canImport(ImageIO) 门控；
// 不触网、不写真实 Application Support。
import Foundation
import Testing
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication

private func seedWave2Photo(
    _ db: DBConnection, sessionId: String, photoId: String, filepath: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
          asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', NULL, NULL, 8, 8,
          '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(photoId), .text(sessionId), .text(filepath),
        .text(URL(fileURLWithPath: filepath).lastPathComponent),
    ])
}

#if canImport(ImageIO)
private func makeSolidImage(
    width: Int, height: Int,
    red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1
) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

/// 把 CGImage 渲成 RGBA 缓冲，供像素采样/包围盒统计。
///
/// 坐标系约定：CGImage/CGBitmapContext 的**内存第 0 行是图像顶行**（自上而下），
/// 而 CGContext 的绘制坐标是左下原点。采样辅助（redBoundingBox/pixel）统一把
/// 内存行换算成「自底向上」的 y，避免两套 y 方向在断言里混用。
private func rgbaBuffer(of image: CGImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw Wave2TestError.contextFailed }
    // 整图绘制后内存行序与 CGImage 一致（第 0 行 = 顶行）。
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height)
}

/// 红色 logo 的包围盒：y 统一为**自底向上**（与 CGContext 绘制坐标同向，
/// bottomRight 的 minY 就是距底边距）。
private func redBoundingBox(
    pixels: [UInt8], width: Int, height: Int
) -> (minX: Int, maxX: Int, minY: Int, maxY: Int, count: Int) {
    var minX = width, maxX = -1, minY = height, maxY = -1, count = 0
    for row in 0..<height {
        let y = height - 1 - row  // 内存 row0 = 顶行 → 自底向上的 y
        for x in 0..<width {
            let index = (row * width + x) * 4
            // 红色 logo：R 明显高于 G/B（灰度背景 128 不满足）。
            if pixels[index] > 150, Int(pixels[index + 1]) < 100, Int(pixels[index + 2]) < 100 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1
            }
        }
    }
    return (minX, maxX, minY, maxY, count)
}

/// 取某一像素的 RGB；y 为自底向上坐标（内部换算成内存行）。
private func pixel(
    _ pixels: [UInt8], width: Int, height: Int, x: Int, y: Int
) -> (r: Int, g: Int, b: Int) {
    let row = height - 1 - y
    let index = (row * width + x) * 4
    return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
}

private enum Wave2TestError: Error { case contextFailed }
#endif

@Suite("Wave2 导出规格（图片水印/子目录/配方参数）")
struct ExportSpecsWave2Tests {
    private func makeFixture(
        fileCount: Int = 1
    ) throws -> (db: DBConnection, sessionId: String, source: URL, destination: URL, files: [URL]) {
        let db = try makeTestDB()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-wave2-src-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-wave2-dst-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let session = try SessionRepo(connection: db).create(
            name: "Wave2", source: "local", sourcePath: source.path)
        var files: [URL] = []
        for index in 0..<fileCount {
            let url = source.appendingPathComponent("IMG_\(index).jpg")
            try Data("wave2-bytes-\(index)".utf8).write(to: url)
            try seedWave2Photo(
                db, sessionId: session.id, photoId: "p\(index)", filepath: url.path)
            files.append(url)
        }
        return (db, session.id, source, destination, files)
    }

    private func service(_ db: DBConnection) -> ExportService {
        ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db)
    }

    // MARK: - 子目录规则（token 展开 + 执行期建目录）

    @Test("子目录 token 展开：{client}/{event}/{orig} 逐照片解析")
    func subdirectoryTokensResolve() {
        let subdirectory = ExportSubdirectory(
            template: "{client}/{event}/{orig}", client: "ACME", event: "婚礼")
        #expect(subdirectory.resolved(originalFilename: "IMG_1.NEF") == "ACME/婚礼/IMG_1")
        // 空 client/event：该段解析时丢弃，不会留下空目录段。
        let partial = ExportSubdirectory(template: "{client}/{event}/{orig}")
        #expect(partial.resolved(originalFilename: "a.jpg") == "a")
        // 日期 token 用本地日期（与命名 {date} 同源）。
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dated = ExportSubdirectory(template: "{yyyy}/{MM}/{dd}")
        #expect(dated.resolved(originalFilename: "a.jpg")
            == String(format: "%04d/%02d/%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0))
        // token 值里的路径分隔符/穿越被清洗，不能逃出目标根。
        let sanitized = ExportSubdirectory(
            template: "{client}", client: "../evil/name")
        let resolved = sanitized.resolved(originalFilename: "a.jpg") ?? ""
        #expect(!resolved.contains(".."))
        #expect(!resolved.hasPrefix("/"))
    }

    @Test("非法子目录模板被拒：未知 token / 绝对路径 / 路径穿越 / 空段")
    func invalidSubdirectoryTemplatesRejected() {
        let cases: [(String, String)] = [
            ("{client}/{unknown}", "unknownToken"),
            ("/abs/{yyyy}", "absolutePath"),
            ("{client}/../x", "pathTraversal"),
            ("a//b", "emptySegment"),
            ("{client", "unclosedToken"),
        ]
        for (template, expectedReason) in cases {
            let reason = ExportSubdirectory.validationReason(for: template)
            #expect(reason?.hasPrefix(expectedReason) == true, "模板 \(template) 的 reason: \(String(describing: reason))")
        }
        #expect(ExportSubdirectory.validationReason(for: "{yyyy}/{MM}/{dd}") == nil)
        #expect(ExportSubdirectory.validationReason(for: "") == nil)
    }

    @Test("执行时按子目录写盘（多级目录自动创建）")
    func executeCreatesSubdirectories() throws {
        let fixture = try makeFixture(fileCount: 2)
        defer {
            try? FileManager.default.removeItem(at: fixture.source)
            try? FileManager.default.removeItem(at: fixture.destination)
        }
        let options = ExportOptions(
            scope: .session,
            format: .original,
            subdirectory: ExportSubdirectory(
                template: "{client}/{event}", client: "ACME", event: "婚礼"),
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: false,
            destination: fixture.destination.path)
        // 预览与执行同源：outputName 带相对子目录前缀（先预览，避免已存在文件触发
        // 重名唯一化）。
        let preview = try service(fixture.db).preview(
            sessionId: fixture.sessionId, options: options)
        #expect(preview.files.first?.outputName == "ACME/婚礼/IMG_0.jpg")

        let result = try service(fixture.db).execute(
            sessionId: fixture.sessionId, options: options)
        #expect(result.exported == 2)
        for index in 0..<2 {
            let output = fixture.destination
                .appendingPathComponent("ACME/婚礼/IMG_\(index).jpg")
            #expect(FileManager.default.fileExists(atPath: output.path),
                    "子目录成片缺失: \(output.path)")
        }
    }

    @Test("非法子目录规则在执行/预览前被拒（EXPORT_PARAMS_INVALID）")
    func invalidSubdirectoryRejectedByService() throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.source)
            try? FileManager.default.removeItem(at: fixture.destination)
        }
        let options = ExportOptions(
            scope: .session,
            format: .original,
            subdirectory: ExportSubdirectory(template: "../escape"),
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: false,
            destination: fixture.destination.path)
        do {
            _ = try service(fixture.db).preview(
                sessionId: fixture.sessionId, options: options)
            #expect(Bool(false), "非法子目录必须被拒绝")
        } catch let error as GatherError {
            #expect(error.code == .EXPORT_PARAMS_INVALID)
            #expect(error.params["reason"] == "pathTraversal")
        }
    }

    // MARK: - 图片水印

    #if canImport(ImageIO)
    private func makeWatermarkFixture(
        logoWidth: Int, logoHeight: Int, sourceWidth: Int = 400, sourceHeight: Int = 300
    ) throws -> (fixture: (db: DBConnection, sessionId: String, source: URL, destination: URL, files: [URL]), logo: URL) {
        let fixture = try makeFixture()
        let gray = try makeSolidImage(
            width: sourceWidth, height: sourceHeight, red: 0.5, green: 0.5, blue: 0.5)
        let sourceData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            sourceData, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, gray,
            [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (sourceData as Data).write(to: fixture.files[0])

        let logo = fixture.source.appendingPathComponent("logo.png")
        try writePNG(
            try makeSolidImage(width: logoWidth, height: logoHeight, red: 1, green: 0, blue: 0),
            to: logo)
        return (fixture, logo)
    }

    private func watermarkOptions(
        destination: URL,
        logo: URL,
        scale: Double = 0.25,
        margin: Double = 0.02,
        opacity: Double = 1,
        position: ExportWatermarkPosition = .bottomRight
    ) -> ExportOptions {
        ExportOptions(
            scope: .session,
            format: .tiff,
            tiffCompression: .none,
            watermark: ExportWatermark(
                type: .image,
                content: logo.path,
                position: position,
                opacity: opacity,
                imageScale: scale,
                imageMargin: margin),
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: false,
            destination: destination.path)
    }

    private func outputImage(
        _ fixture: (db: DBConnection, sessionId: String, source: URL, destination: URL, files: [URL])
    ) throws -> CGImage {
        let output = fixture.destination.appendingPathComponent("IMG_0.tiff")
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test("图片水印：按输出宽度比例合成（右下 + 边距）")
    func imageWatermarkScalesAndPositions() throws {
        let (fixture, logo) = try makeWatermarkFixture(logoWidth: 800, logoHeight: 200)
        defer {
            try? FileManager.default.removeItem(at: fixture.source)
            try? FileManager.default.removeItem(at: fixture.destination)
        }
        let options = watermarkOptions(
            destination: fixture.destination, logo: logo,
            scale: 0.25, margin: 0.02, position: .bottomRight)
        #expect(try service(fixture.db).execute(
            sessionId: fixture.sessionId, options: options).exported == 1)
        let image = try outputImage(fixture)
        #expect(image.width == 400 && image.height == 300, "水印不得改变成片尺寸")
        let buffer = try rgbaBuffer(of: image)
        let box = redBoundingBox(pixels: buffer.pixels, width: buffer.width, height: buffer.height)
        // 目标宽 = 400 × 0.25 = 100，高按 logo 比例 100×25。
        #expect(box.count > 0, "输出里必须出现 logo 像素")
        #expect(abs((box.maxX - box.minX + 1) - 100) <= 2, "logo 宽度: \(box.maxX - box.minX + 1)")
        #expect(abs((box.maxY - box.minY + 1) - 25) <= 2, "logo 高度: \(box.maxY - box.minY + 1)")
        // 右下：右边缘距画面右侧 = 400 × 0.02 = 8；底部边距 = 8（y 从底部起）。
        #expect(abs(box.maxX - (400 - 8 - 1)) <= 2, "右边缘: \(box.maxX)")
        #expect(abs(box.minY - 8) <= 2, "底边距: \(box.minY)")
    }

    @Test("图片水印：居中位置 + 超大 logo 降采样（不放大）")
    func imageWatermarkCenterAndDownsample() throws {
        let (fixture, logo) = try makeWatermarkFixture(logoWidth: 4000, logoHeight: 1000)
        defer {
            try? FileManager.default.removeItem(at: fixture.source)
            try? FileManager.default.removeItem(at: fixture.destination)
        }
        let options = watermarkOptions(
            destination: fixture.destination, logo: logo,
            scale: 0.1, margin: 0.02, position: .center)
        #expect(try service(fixture.db).execute(
            sessionId: fixture.sessionId, options: options).exported == 1)
        let image = try outputImage(fixture)
        let buffer = try rgbaBuffer(of: image)
        let box = redBoundingBox(pixels: buffer.pixels, width: buffer.width, height: buffer.height)
        // 目标宽 = 400 × 0.1 = 40（4000px 的 logo 解码期降采样到 ≤2048 后再缩到 40）。
        #expect(abs((box.maxX - box.minX + 1) - 40) <= 2, "logo 宽度: \(box.maxX - box.minX + 1)")
        let centerX = (box.minX + box.maxX) / 2
        let centerY = (box.minY + box.maxY) / 2
        #expect(abs(centerX - 200) <= 2, "水平居中: \(centerX)")
        #expect(abs(centerY - 150) <= 2, "垂直居中: \(centerY)")
    }

    @Test("图片水印：logo 比目标小时不放大 + 透明度叠加")
    func imageWatermarkNoUpscaleAndOpacity() throws {
        let (fixture, logo) = try makeWatermarkFixture(logoWidth: 40, logoHeight: 20)
        defer {
            try? FileManager.default.removeItem(at: fixture.source)
            try? FileManager.default.removeItem(at: fixture.destination)
        }
        let options = watermarkOptions(
            destination: fixture.destination, logo: logo,
            scale: 0.5, margin: 0.02, opacity: 0.5, position: .bottomLeft)
        #expect(try service(fixture.db).execute(
            sessionId: fixture.sessionId, options: options).exported == 1)
        let image = try outputImage(fixture)
        let buffer = try rgbaBuffer(of: image)
        let box = redBoundingBox(pixels: buffer.pixels, width: buffer.width, height: buffer.height)
        // 目标宽 200 > logo 40：保持原始 40×20，不放大。
        #expect(abs((box.maxX - box.minX + 1) - 40) <= 1, "不放大: \(box.maxX - box.minX + 1)")
        // 透明度 0.5：灰度 128 背景上叠 50% 红 → R≈191、G/B≈64。
        let center = pixel(
            buffer.pixels, width: buffer.width, height: buffer.height,
            x: (box.minX + box.maxX) / 2, y: (box.minY + box.maxY) / 2)
        #expect(center.r > 150 && center.r < 230, "透明度混合 R: \(center)")
        #expect(center.g > 30 && center.g < 100, "透明度混合 G: \(center)")
        // 左下位置：左边缘 = 400 × 0.02 = 8。
        #expect(abs(box.minX - 8) <= 2, "左边缘: \(box.minX)")
    }

    @Test("图片水印校验：路径缺失/不可解码/版式越界给 EXPORT_PARAMS_INVALID")
    func imageWatermarkValidation() throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.source)
            try? FileManager.default.removeItem(at: fixture.destination)
        }
        let service = service(fixture.db)
        let missing = fixture.source.appendingPathComponent("no-such-logo.png")
        var options = watermarkOptions(
            destination: fixture.destination, logo: missing, scale: 0.25)
        func expectParamError(_ options: ExportOptions, field: String, reason: String) {
            do {
                _ = try service.preview(sessionId: fixture.sessionId, options: options)
                #expect(Bool(false), "必须被拒绝")
            } catch let error as GatherError {
                #expect(error.code == .EXPORT_PARAMS_INVALID)
                #expect(error.params["field"] == field)
                #expect(error.params["reason"] == reason)
            } catch {
                #expect(Bool(false), "错误类型: \(error)")
            }
        }
        expectParamError(options, field: "watermark.imagePath", reason: "missing")

        // 不可解码的"图片"文件。
        let broken = fixture.source.appendingPathComponent("broken.png")
        try Data("not a png".utf8).write(to: broken)
        options = watermarkOptions(destination: fixture.destination, logo: broken)
        expectParamError(options, field: "watermark.imagePath", reason: "notAnImage")

        // 版式参数越界（校验在解码前先查路径，所以给真实 logo）。
        let logo = fixture.source.appendingPathComponent("logo.png")
        try writePNG(
            try makeSolidImage(width: 10, height: 10, red: 1, green: 0, blue: 0), to: logo)
        var badScale = ExportOptions(
            scope: .session, format: .tiff,
            watermark: ExportWatermark(
                type: .image, content: logo.path, position: .center,
                opacity: 1, imageScale: 2, imageMargin: 0.02),
            naming: ExportNaming(pattern: "{original}"), includeXmp: false,
            destination: fixture.destination.path)
        expectParamError(badScale, field: "watermark.imageScale", reason: "outOfRange")
        badScale.watermark?.imageScale = 0.5
        badScale.watermark?.imageMargin = 1
        expectParamError(badScale, field: "watermark.imageMargin", reason: "outOfRange")
    }
    #endif

    // MARK: - OutputRecipe 新旧 JSON

    @Test("OutputRecipe 新字段（子目录/联系表/画廊/图片水印）JSON 往返")
    func recipeNewFieldsRoundTrip() throws {
        let recipe = OutputRecipe(
            id: "r1",
            name: "Wave2 配方",
            format: .tiff,
            quality: nil,
            maxDimension: 6000,
            colorSpace: .adobeRGB1998,
            dpi: 300,
            sharpening: ExportSharpening(radius: 2, intensity: 0.8),
            watermark: ExportWatermark(
                type: .image, content: "/tmp/logo.png", position: .bottomRight,
                opacity: 0.7, imageScale: 0.15, imageMargin: 0.03),
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: true,
            includeMetadata: true,
            destination: "",
            subdirectory: ExportSubdirectory(
                template: "{client}/{yyyy}-{MM}-{dd}", client: "ACME", event: "婚礼"),
            contactSheet: OutputContactSheetOptions(
                title: "Proof", columns: 3, rows: 4, margin: 48,
                fields: [.filename, .rating], captionTemplate: "{filename}"),
            gallery: OutputGalleryOptions(
                title: "Gallery", thumbnailMaxDimension: 640,
                largeMaxDimension: 2560, fields: [.rating, .pick]),
            artifacts: [.photos, .contactSheet, .gallery])
        let data = try JSONEncoder().encode(recipe)
        #expect(try JSONDecoder().decode(OutputRecipe.self, from: data) == recipe)
    }

    @Test("旧配方 JSON（无子目录/联系表/画廊键）仍可解码")
    func legacyRecipeJSONDecodes() throws {
        let legacy = #"{"id":"r1","name":"旧配方","format":"jpeg","quality":85,"naming":{"pattern":"{original}"},"includeXmp":false,"includeMetadata":true,"destination":"","artifacts":["photos"]}"#
        let decoded = try JSONDecoder().decode(OutputRecipe.self, from: Data(legacy.utf8))
        #expect(decoded.subdirectory == nil)
        #expect(decoded.contactSheet == nil)
        #expect(decoded.gallery == nil)
    }

    #if canImport(ImageIO)
    @Test("水印 logo 缓存：path+size+mtime 键与容量上限（Wave4b）")
    func watermarkLogoCacheKeyedAndBounded() throws {
        WatermarkLogoCache.removeAll()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-logo-cache-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            WatermarkLogoCache.removeAll()
            do { try FileManager.default.removeItem(at: root) } catch {
                // 清理失败不影响断言。
            }
        }
        let logo = root.appendingPathComponent("logo.png")
        try writePNG(try makeSolidImage(width: 10, height: 10, red: 1, green: 0, blue: 0), to: logo)
        #expect(WatermarkLogoCache.image(for: logo.path)?.width == 10)
        #expect(WatermarkLogoCache.entryCount == 1)

        // 同路径替换成不同尺寸/时间：键变化 → 重新解码，不能继续用旧图。
        try writePNG(try makeSolidImage(width: 20, height: 6, red: 0, green: 1, blue: 0), to: logo)
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
                ofItemAtPath: logo.path)
        } catch {
            // 设 mtime 失败时尺寸已不同，仍能验证键变化。
        }
        #expect(WatermarkLogoCache.image(for: logo.path)?.width == 20)

        // 容量上限：灌入 12 个不同 logo 后条目数不得超过 maxEntries。
        for index in 0..<12 {
            let path = root.appendingPathComponent("extra-\(index).png")
            // task-45：每轮编码 PNG + 解码（缓存键/上限用例），只把同步图像
            // 创建/解码放进局部 autoreleasepool，让 ImageIO/CGImage 临时对象按轮回收。
            try autoreleasepool {
                try writePNG(try makeSolidImage(width: 2, height: 2, red: 0, green: 0, blue: 1), to: path)
                _ = WatermarkLogoCache.image(for: path.path)
            }
        }
        #expect(WatermarkLogoCache.entryCount <= WatermarkLogoCache.maxEntries)
    }
    #endif
}
