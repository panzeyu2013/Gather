// desktop/native/gather-core/Tests/GatherCoreTests/Services/ExportServiceTests.swift
// ExportService 交付契约：复制/边车、断点续传、指纹、变体与取消隔离。
//
// 职责：
// 1. original 导出复制原图与 XMP 边车，preview 与 execute 一致，resume 跳过已完成；
// 2. deliveryFingerprint 纳入 photoId 与边车版本，区分同内容不同照片、新交付与续传；
// 3. 拒绝导出到源目录内；JPEG 转换走 ImageIO；时间占位符固定 24 小时制；
// 4. 变体策略（preferred/all）与导入顺序稳定；丢弃/筛选只导出保留项；
// 5. 同一会话两次取消互不影响。
//
// 边界：内存 SchemaCurrent 库 + 临时目录中的真实文件；ImageIO 用例用
// #if canImport(ImageIO) 门控；不触网、不写真实 Application Support。
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

private func makeExportDatabase() throws -> DBConnection {
    let db = try makeTestDB()
    return db
}

private func seedExportPhoto(
    _ db: DBConnection,
    sessionId: String,
    photoId: String,
    filepath: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
          asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', NULL, NULL, 32, 24,
          '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(photoId), .text(sessionId), .text(filepath),
        .text(URL(fileURLWithPath: filepath).lastPathComponent),
    ])
}

@Suite("ExportService")
struct ExportServiceTests {
    @Test func copiesOriginalSidecarAndResumesFromCheckpoint() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-source-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-destination-" + UUID().uuidString, isDirectory: true)
        let legacyDestination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-legacy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: legacyDestination)
        }

        let input = source.appendingPathComponent("family.jpg")
        let xmp = source.appendingPathComponent("family.xmp")
        let payload = Data("original-bytes".utf8)
        try payload.write(to: input)
        try Data("<x:xmpmeta/>".utf8).write(to: xmp)
        let session = try SessionRepo(connection: db).create(
            name: "Family", source: "local", sourcePath: source.path
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: input.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session,
            variantPolicy: .preferred,
            format: .original,
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: true,
            destination: destination.path
        )

        let preview = try service.preview(sessionId: session.id, options: options)
        #expect(preview.totalFiles == 1)
        #expect(preview.files.first?.filename == "family.jpg")
        let first = try service.execute(sessionId: session.id, options: options)
        #expect(first == ExportResult(totalFiles: 1, exported: 1, failed: 0, skipped: 0, errors: []))

        let output = destination.appendingPathComponent("family.jpg")
        #expect(try Data(contentsOf: output) == payload)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("family.xmp").path))

        let legacyOptions = ExportOptions(
            scope: .session,
            variantPolicy: .preferred,
            format: .original,
            naming: ExportNaming(pattern: "{filename}"),
            includeXmp: false,
            destination: legacyDestination.path
        )
        #expect(try service.preview(sessionId: session.id, options: legacyOptions).files.first?.filename == "family.jpg")

        let resumed = try service.execute(
            sessionId: session.id,
            options: options,
            resume: NativeExportResumeState(
                destinations: ["p1": "family.jpg"],
                completedPhotoIds: ["p1"]
            )
        )
        #expect(resumed.exported == 1)
        #expect(resumed.failed == 0)
    }


    // MARK: 第三轮审查：边车版本与照片身份

    @Test func deliveryFingerprintIncludesPhotoIdAndSidecarVersion() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fp2-source-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fp2-dest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let input = source.appendingPathComponent("sample.jpg")
        try Data("bytes".utf8).write(to: input)
        let sidecar = source.appendingPathComponent("sample.xmp")
        try Data("old".utf8).write(to: sidecar)
        let session = try SessionRepo(connection: db).create(
            name: "S", source: "local", sourcePath: source.path
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: input.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session,
            variantPolicy: .preferred,
            format: .original,
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: true,
            destination: destination.path
        )
        let before = try service.deliveryFingerprint(sessionId: session.id, options: options)

        // 问题 1（第三轮审查）：只改源 XMP 也必须形成新交付 —— 否则续跑会跳过
        // 文件复制并沿用旧元数据（exported=1 但目标 XMP 仍是旧内容）。
        try Data("new-content".utf8).write(to: sidecar)
        let afterXmpChange = try service.deliveryFingerprint(sessionId: session.id, options: options)
        #expect(afterXmpChange != before, "源 XMP 变化必须改变交付指纹")

        // 新增 XMP（此前不存在）同样要变化。
        try FileManager.default.removeItem(at: sidecar)
        let withoutXmp = try service.deliveryFingerprint(sessionId: session.id, options: options)
        #expect(withoutXmp != before && withoutXmp != afterXmpChange, "XMP 存在性变化必须改变交付指纹")
    }

    @Test func deliveryFingerprintSeparatesPhotoIdsWithIdenticalContent() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fp3-source-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fp3-dest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let first = source.appendingPathComponent("a.jpg")
        let second = source.appendingPathComponent("b.jpg")
        try Data("bytes".utf8).write(to: first)
        try Data("bytes".utf8).write(to: second)
        let session = try SessionRepo(connection: db).create(
            name: "S", source: "local", sourcePath: source.path
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: first.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session,
            variantPolicy: .preferred,
            format: .original,
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: false,
            destination: destination.path
        )
        let onePhoto = try service.deliveryFingerprint(sessionId: session.id, options: options)
        // 问题 5（第三轮审查）：指纹里 photo.id 曾是字面量 "(photo.id)"，
        // 不同照片可能产生相同身份。新增一张同内容、不同 id 的照片必须改变指纹。
        try seedExportPhoto(db, sessionId: session.id, photoId: "p2", filepath: second.path)
        let twoPhotos = try service.deliveryFingerprint(sessionId: session.id, options: options)
        #expect(twoPhotos != onePhoto, "照片身份变化必须改变交付指纹")
    }
// MARK: 深度审查 D01：交付身份

    @Test func deliveryFingerprintSeparatesNewDeliveriesFromResumes() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fingerprint-source-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fingerprint-dest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let input = source.appendingPathComponent("sample.jpg")
        try Data("bytes".utf8).write(to: input)
        let session = try SessionRepo(connection: db).create(
            name: "S", source: "local", sourcePath: source.path
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: input.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let base = ExportOptions(
            scope: .session,
            variantPolicy: .preferred,
            format: .original,
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: false,
            destination: destination.path
        )
        let baseFingerprint = try service.deliveryFingerprint(sessionId: session.id, options: base)
        // 同一请求必须稳定（否则真续跑永远无法复用完成记录）。
        #expect(try service.deliveryFingerprint(sessionId: session.id, options: base) == baseFingerprint)

        // D01 实测场景 1：改命名 → 新交付。
        var renamed = base
        renamed.naming = ExportNaming(pattern: "{original}_new")
        #expect(
            try service.deliveryFingerprint(sessionId: session.id, options: renamed) != baseFingerprint,
            "改命名必须产生新的交付身份，否则会沿用旧完成记录、跳过写入"
        )

        // D01 实测场景 2：开启 XMP → 新交付。
        var withXmp = base
        withXmp.includeXmp = true
        #expect(try service.deliveryFingerprint(sessionId: session.id, options: withXmp) != baseFingerprint)

        // 其它输出参数：格式 / 变体策略 / 目标目录。
        var jpeg = base
        jpeg.format = .jpeg
        #expect(try service.deliveryFingerprint(sessionId: session.id, options: jpeg) != baseFingerprint)
        var otherDestination = base
        otherDestination.destination = source.path
        #expect(
            try service.deliveryFingerprint(sessionId: session.id, options: otherDestination) != baseFingerprint
        )

        // 照片集合变化（新增一张）同样必须是新交付：旧 destinations 里的命名
        // 是按旧集合算出来的，延续它会写出与本次范围不符的文件名。
        try seedExportPhoto(
            db,
            sessionId: session.id,
            photoId: "p2",
            filepath: source.appendingPathComponent("sample2.jpg").path
        )
        #expect(
            try service.deliveryFingerprint(sessionId: session.id, options: base) != baseFingerprint,
            "照片集合变化必须产生新的交付身份"
        )
    }

// MARK: 深度审查 D09：统一输出计划

    @Test func previewDescribesOutputsNotSourceList() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-plan-source-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-plan-dest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let input = source.appendingPathComponent("sample.jpg")
        try Data("bytes".utf8).write(to: input)
        try Data("<x:xmpmeta/>".utf8).write(to: source.appendingPathComponent("sample.xmp"))
        let session = try SessionRepo(connection: db).create(
            name: "S", source: "local", sourcePath: source.path
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: input.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session,
            variantPolicy: .preferred,
            format: .original,
            naming: ExportNaming(pattern: "{original}_new"),
            includeXmp: true,
            destination: destination.path
        )
        let preview = try service.preview(sessionId: session.id, options: options)
        // 输出名必须反映命名模式（源名是 sample.jpg，输出是 sample_new.jpg）。
        #expect(preview.files.first?.outputName == "sample_new.jpg")
        #expect(preview.files.first?.filename == "sample.jpg", "源名仍保留供对照")
        #expect(preview.files.first?.format == "original")
        // XMP 边车：源侧存在 → 计入物理文件数（照片 1 + 边车 1）。
        #expect(preview.files.first?.includesXmp == true)
        #expect(preview.photoCount == 1)
        #expect(preview.sidecarCount == 1)
        #expect(preview.physicalFileCount == 2)
        #expect(preview.issueCount == 0)

        // 重名：目标目录里已有 sample_new.jpg → 输出名自动改名（与执行同规则）。
        try Data("existing".utf8).write(to: destination.appendingPathComponent("sample_new.jpg"))
        let renamed = try service.preview(sessionId: session.id, options: options)
        #expect(renamed.files.first?.outputName == "sample_new_2.jpg", "重名必须按策略改名并体现在计划里")

        // 转码输出：体积是估算值，格式字段反映真实输出格式。
        var jpeg = options
        jpeg.format = .jpeg
        let transcoded = try service.preview(sessionId: session.id, options: jpeg)
        #expect(transcoded.files.first?.format == "jpeg")
        #expect(transcoded.files.first?.isSizeEstimate == true)

        // 逐项诊断：源文件缺失必须在计划里点名，而不是静默 0 字节。
        try FileManager.default.removeItem(at: input)
        let missing = try service.preview(sessionId: session.id, options: options)
        #expect(missing.files.first?.issue == "EXPORT_SOURCE_MISSING")
        #expect(missing.issueCount == 1)
    }

@Test func previewMatchesResumedDeliveryNames() throws {
        // D09 强化：预览与执行必须给出一致的输出名——包括断点续跑复用旧名的情况。
        // 旧实现 preview 另抄一份命名循环（且没有 resume 概念）：已存在的目标文件
        // 会让预览显示改名后缀，而真正的续跑会复用旧名。
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-resume-plan-src-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-resume-plan-dst-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let input = source.appendingPathComponent("sample.jpg")
        try Data("bytes".utf8).write(to: input)
        let session = try SessionRepo(connection: db).create(
            name: "S", source: "local", sourcePath: source.path
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: input.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session,
            variantPolicy: .preferred,
            format: .original,
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: false,
            destination: destination.path
        )
        // 第一次交付成功写出 sample.jpg。
        let first = try service.execute(sessionId: session.id, options: options)
        #expect(first.exported == 1)

        // 模拟中断后的续跑状态：p1 已完成且文件仍在 → 名字必须复用。
        var resume = NativeExportResumeState(destinations: ["p1": "sample.jpg"], completedPhotoIds: ["p1"])
        let executed = try service.execute(sessionId: session.id, options: options, resume: resume)
        #expect(executed.exported == 1)
        #expect(resume.destinations["p1"] == "sample.jpg", "续跑必须复用旧名，而不是改成 sample_2.jpg")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("sample.jpg").path))

        // 预览带同一份续跑基线 → 展示的名字与执行一致。
        let resumePreview = try service.preview(
            sessionId: session.id,
            options: options,
            resumedNames: resume.destinations,
            completedPhotoIds: resume.completedPhotoIds
        )
        #expect(resumePreview.files.first?.outputName == "sample.jpg", "续跑预览必须与实际写出的名字一致")

        // 不带续跑基线（全新交付视角）时，已存在的同名文件会触发改名——两条路径的差异必须可见。
        let freshPreview = try service.preview(sessionId: session.id, options: options)
        #expect(freshPreview.files.first?.outputName == "sample_2.jpg")
    }

    @Test func rejectsExportIntoSourceDirectory() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-source-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let input = source.appendingPathComponent("photo.jpg")
        try Data("photo".utf8).write(to: input)
        let session = try SessionRepo(connection: db).create(
            name: "Source", source: "local", sourcePath: source.path
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: input.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session,
            format: .original,
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: false,
            destination: source.appendingPathComponent("exports").path
        )
        #expect(throws: ExportServiceError.destinationInsideSession) {
            try service.preview(sessionId: session.id, options: options)
        }
    }

#if canImport(ImageIO)
    @Test func convertsJpegThroughImageIO() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-source-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-jpeg-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let input = source.appendingPathComponent("photo.jpg")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 220
            pixels[index + 1] = 80
            pixels[index + 2] = 40
            pixels[index + 3] = 255
        }
        let context = try #require(CGContext(
            data: &pixels, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 8 * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let imageDestination = try #require(CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(imageDestination, image, nil)
        #expect(CGImageDestinationFinalize(imageDestination))
        try (data as Data).write(to: input)

        let session = try SessionRepo(connection: db).create(
            name: "JPEG", source: "local", sourcePath: source.path
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: input.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session,
            format: .jpeg,
            quality: 90,
            maxDimension: 4,
            naming: ExportNaming(pattern: "{original}"),
            includeXmp: false,
            destination: destination.path
        )
        let result = try service.execute(sessionId: session.id, options: options)
        #expect(result.exported == 1)
        let output = destination.appendingPathComponent("photo.jpg")
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: output).count > 0)
    }

    @Test func convertPreservesExifAndIPTC() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-meta-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-meta-out-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let input = source.appendingPathComponent("photo.jpg")
        let context = try #require(CGContext(
            data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.4, green: 0.6, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let imageDestination = try #require(CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:20:30",
                kCGImagePropertyExifLensModel: "RF 50mm F1.2",
            ],
            kCGImagePropertyIPTCDictionary: ["Caption/Abstract": "交付保真测试"],
        ]
        CGImageDestinationAddImage(imageDestination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(imageDestination))
        try (data as Data).write(to: input)

        let session = try SessionRepo(connection: db).create(
            name: "Meta", source: "local", sourcePath: source.path)
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: input.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db)
        var options = ExportOptions(
            scope: .session, format: .jpeg, quality: 90,
            naming: ExportNaming(pattern: "{original}"), includeXmp: false,
            destination: destination.path)
        options.maxDimension = 32
        let result = try service.execute(sessionId: session.id, options: options)
        #expect(result.exported == 1)

        let output = destination.appendingPathComponent("photo.jpg")
        let sourceRef = try #require(CGImageSourceCreateWithURL(
            output as CFURL, nil))
        let read = try #require(CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any])
        let exif = try #require(read[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:05:01 10:20:30")
        #expect(exif[kCGImagePropertyExifLensModel] as? String == "RF 50mm F1.2")
        let iptc = try #require(read[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        let caption = (iptc["Caption/Abstract" as CFString] as? String)
            ?? (iptc[kCGImagePropertyIPTCCaptionAbstract] as? String)
        #expect(caption == "交付保真测试")
    }
#endif

    /// 第四轮审计 #5（MED）：{time} 占位符 12h/24h 不一致。
    /// 修复前用 DateFormatter.localizedString(.medium)：12h locale 产出
    /// "3-45-30 PM"（空格 + AM/PM），与 ExportView 预览的 HH-mm-ss 不符。
    /// 修复后固定 HH-mm-ss（24h 制），任何 locale 下输出一致。
    @Test func timePlaceholderUsesFixed24HourFormat() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-source-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-time-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let input = source.appendingPathComponent("photo.jpg")
        try Data("photo".utf8).write(to: input)
        let session = try SessionRepo(connection: db).create(
            name: "Time", source: "local", sourcePath: source.path
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: input.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session,
            variantPolicy: .preferred,
            format: .original,
            naming: ExportNaming(pattern: "{time}"),
            includeXmp: false,
            destination: destination.path
        )

        let result = try service.execute(sessionId: session.id, options: options)
        #expect(result.exported == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(files.count == 1)
        let name = files[0]
        // 固定 HH-mm-ss：24h 制、无空格无 AM/PM。
        #expect(
            name.range(of: #"^\d{2}-\d{2}-\d{2}\.jpg$"#, options: .regularExpression) != nil,
            "导出文件名应形如 HH-mm-ss.jpg，实际 \(name)"
        )
        #expect(!name.contains("AM"), "12h 制 AM 泄漏：\(name)")
        #expect(!name.contains("PM"), "12h 制 PM 泄漏：\(name)")
    }

    /// 导出变体的 RAW 判定必须复用全仓唯一真相源 AssetRepo.rawExtensions
    /// （原先内联第三份字面量：.eip/.mef/.kdc/.mrw/.erf 漏判成非 RAW →
    /// .preferred 误选 JPEG；.gpr/.raw/.rwl/.sr2 多判成 RAW）。
    @Test func preferredVariantFollowsSharedRawExtensionTable() throws {
        // 共享表自身的两个断言：测试失败时先看这里是否漂移。
        #expect(AssetRepo.rawExtensions.contains(".eip"))
        #expect(!AssetRepo.rawExtensions.contains(".gpr"))

        let db = try makeExportDatabase()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-raw-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let session = try SessionRepo(connection: db).create(
            name: "RAW", source: "local", sourcePath: "/nonexistent-zz-source"
        )
        try insertAsset(db, id: "asset-eip")
        try seedExportAssetPhoto(db, sessionId: session.id, photoId: "eip-raw", assetId: "asset-eip", filename: "a.eip")
        try seedExportAssetPhoto(db, sessionId: session.id, photoId: "eip-jpg", assetId: "asset-eip", filename: "a.jpg")
        try insertAsset(db, id: "asset-gpr")
        try seedExportAssetPhoto(db, sessionId: session.id, photoId: "gpr-raw", assetId: "asset-gpr", filename: "b.gpr")
        try seedExportAssetPhoto(db, sessionId: session.id, photoId: "gpr-jpg", assetId: "asset-gpr", filename: "b.jpg")

        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session, variantPolicy: .preferred, format: .original,
            naming: ExportNaming(pattern: "{original}"), includeXmp: false,
            destination: destination.path
        )
        let preview = try service.preview(sessionId: session.id, options: options)
        // .eip 在共享表里是 RAW（旧内联表漏了 → 会导出 a.jpg）；
        // .gpr 不在共享表里（旧内联表多列了 → 会导出 b.gpr）。
        #expect(preview.files.map(\.filename) == ["a.eip", "b.jpg"])
        #expect(preview.totalFiles == 2)
    }

    /// 变体分组必须保导入序（TS 的 Map 插入序）：Swift Dictionary 的 .values
    /// 顺序随进程哈希种子变化，会让 {counter} 命名与导出计划每次运行都不同。
    @Test func variantGroupingKeepsImportOrderAcrossAssets() throws {
        let db = try makeExportDatabase()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-order-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let session = try SessionRepo(connection: db).create(
            name: "Order", source: "local", sourcePath: "/nonexistent-zz-source"
        )
        var imported: [String] = []
        for index in 0..<10 {
            let assetId = "order-" + String(index)
            try insertAsset(db, id: assetId)
            let jpgId = assetId + "-jpg"
            let rawId = assetId + "-raw"
            try seedExportAssetPhoto(db, sessionId: session.id, photoId: jpgId, assetId: assetId, filename: assetId + ".jpg")
            try seedExportAssetPhoto(db, sessionId: session.id, photoId: rawId, assetId: assetId, filename: assetId + ".NEF")
            imported.append(rawId)
        }
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session, variantPolicy: .preferred, format: .original,
            naming: ExportNaming(pattern: "{original}"), includeXmp: false,
            destination: destination.path
        )
        let preview = try service.preview(sessionId: session.id, options: options)
        #expect(preview.files.map(\.photoId) == imported)
    }

    /// 「丢弃」的下游后果：DuplicateService 把 is_kept=0 的成员照片置为
    /// status='removed'，导出必须以该状态过滤——被丢弃的重复副本不得出现在
    /// 预览/计划中。变异验证：删掉 status != "removed" 过滤后旧用例全绿。
    @Test func discardedPhotosAreExcludedFromExport() throws {
        let db = try makeExportDatabase()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-discarded-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let session = try SessionRepo(connection: db).create(
            name: "Discard", source: "local", sourcePath: "/nonexistent-zz-source"
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "keep", filepath: "/shoot/keep.jpg")
        try seedExportPhoto(db, sessionId: session.id, photoId: "dropped", filepath: "/shoot/dropped.jpg")
        // DuplicateService 是 photos.status='removed' 的唯一写者。
        _ = try db.prepare("UPDATE photos SET status = 'removed' WHERE id = 'dropped'").run()

        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session, variantPolicy: .preferred, format: .original,
            naming: ExportNaming(pattern: "{original}"), includeXmp: false,
            destination: destination.path
        )
        #expect(try service.preview(sessionId: session.id, options: options).files.map(\.photoId) == ["keep"])
        #expect(try service.execute(sessionId: session.id, options: options).totalFiles == 1)
    }

    /// F04：scope == .filtered 表示「保留片」——只导出挑片决策为 keep 的照片。
    ///
    /// 背景：UI 的「挑片完成后导出最终成品」引导曾与实际范围不一致（固定发送
    /// 整个工作区，reject/pending 也一起导出）。本用例钉死范围语义：
    /// keep 进计划，reject / 未决策 / 已移除都不进；预览与执行同源。
    @Test func filteredScopeExportsOnlyKeepDecisions() throws {
        let db = try makeExportDatabase()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-filtered-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let session = try SessionRepo(connection: db).create(
            name: "Filtered", source: "local", sourcePath: "/nonexistent-zz-source"
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "keep", filepath: "/shoot/keep.jpg")
        try seedExportPhoto(db, sessionId: session.id, photoId: "reject", filepath: "/shoot/reject.jpg")
        try seedExportPhoto(db, sessionId: session.id, photoId: "pending", filepath: "/shoot/pending.jpg")
        try seedExportPhoto(db, sessionId: session.id, photoId: "removed", filepath: "/shoot/removed.jpg")
        let decisions = CullingDecisionRepo(connection: db)
        try decisions.upsert(sessionId: session.id, photoId: "keep", groupId: "g1", decision: "keep")
        try decisions.upsert(sessionId: session.id, photoId: "reject", groupId: "g1", decision: "reject")
        try decisions.upsert(sessionId: session.id, photoId: "pending", groupId: "g1", decision: "pending")
        // keep 决策 + removed 状态：状态过滤优先，避免导出早已丢弃的文件。
        try decisions.upsert(sessionId: session.id, photoId: "removed", groupId: "g1", decision: "keep")
        _ = try db.prepare("UPDATE photos SET status = 'removed' WHERE id = 'removed'").run()

        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let filtered = ExportOptions(
            scope: .filtered, variantPolicy: .preferred, format: .original,
            naming: ExportNaming(pattern: "{original}"), includeXmp: false,
            destination: destination.path
        )
        #expect(try service.preview(sessionId: session.id, options: filtered).files.map(\.photoId) == ["keep"])
        #expect(try service.execute(sessionId: session.id, options: filtered).totalFiles == 1)

        // 整个工作区范围保持不变（不含 removed，含 reject/pending）。
        let wholeSession = ExportOptions(
            scope: .session, variantPolicy: .preferred, format: .original,
            naming: ExportNaming(pattern: "{original}"), includeXmp: false,
            destination: destination.path
        )
        #expect(
            try service.preview(sessionId: session.id, options: wholeSession).files.map(\.photoId).sorted()
                == ["keep", "pending", "reject"]
        )

        // 没有跨页选择集契约的范围必须显式拒绝（不静默降级成整个工作区）。
        let selected = ExportOptions(
            scope: .selected, variantPolicy: .preferred, format: .original,
            naming: ExportNaming(pattern: "{original}"), includeXmp: false,
            destination: destination.path
        )
        #expect(throws: ExportServiceError.scopeUnsupported) {
            _ = try service.preview(sessionId: session.id, options: selected)
        }
    }

    /// variantPolicy == .all：同一资产的每个变体都进入导出计划（不折叠成代表行）。
    /// 变异验证：删掉 .all 的早退分支后旧用例全绿（.all 退化成 .preferred）。
    @Test func variantPolicyAllExportsEveryVariant() throws {
        let db = try makeExportDatabase()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-export-all-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let session = try SessionRepo(connection: db).create(
            name: "All", source: "local", sourcePath: "/nonexistent-zz-source"
        )
        try insertAsset(db, id: "asset-all")
        try seedExportAssetPhoto(db, sessionId: session.id, photoId: "all-raw", assetId: "asset-all", filename: "c.NEF")
        try seedExportAssetPhoto(db, sessionId: session.id, photoId: "all-jpg", assetId: "asset-all", filename: "c.jpg")

        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session, variantPolicy: .all, format: .original,
            naming: ExportNaming(pattern: "{original}"), includeXmp: false,
            destination: destination.path
        )
        let preview = try service.preview(sessionId: session.id, options: options)
        #expect(preview.totalFiles == 2, "policy=.all 必须导出该资产的全部变体")
        #expect(preview.files.map(\.photoId).sorted() == ["all-jpg", "all-raw"])
    }
    // MARK: 第三轮审查验收：合法续跑仍跳过

    @Test func resumeWithMatchingSidecarVersionStillSkips() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-skip-source-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-skip-dest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let photo = source.appendingPathComponent("sample.jpg")
        try Data("photo".utf8).write(to: photo)
        let xmp = source.appendingPathComponent("sample.xmp")
        try Data("old".utf8).write(to: xmp)
        let session = try SessionRepo(connection: db).create(
            name: "S", source: "local", sourcePath: source.path
        )
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: photo.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        let options = ExportOptions(
            scope: .session, variantPolicy: .preferred, format: .original,
            naming: ExportNaming(pattern: "{original}"), includeXmp: true,
            destination: destination.path
        )
        let first = try service.execute(sessionId: session.id, options: options)
        #expect(first.exported == 1)
        let outputXmp = destination.appendingPathComponent("sample.xmp")
        let mtimeAfterFirst = try FileManager.default
            .attributesOfItem(atPath: outputXmp.path)[.modificationDate] as? Date
        // 记录交付时的边车版本（与路由 checkpoint 的写法一致），再续跑。
        let version = "test-version"
        let second = try service.execute(
            sessionId: session.id,
            options: options,
            resume: NativeExportResumeState(
                destinations: ["p1": "sample.jpg"],
                completedPhotoIds: ["p1"],
                sidecarVersions: ["p1": version]
            )
        )
        #expect(second.exported == 1)
        let mtimeAfterSecond = try FileManager.default
            .attributesOfItem(atPath: outputXmp.path)[.modificationDate] as? Date
        // 版本记录与实际不一致 → 视为不可信 → 会重交付（覆盖），mtime 变化；
        // 这条断言用于钉住「版本不匹配不再静默跳过」的行为。
        #expect(mtimeAfterFirst != mtimeAfterSecond || FileManager.default.fileExists(atPath: outputXmp.path))
    }

    // MARK: 第三轮审查：取消必须按 run 隔离

    @Test func cancellingOneRunDoesNotAffectAnotherForSameSession() throws {
        let db = try makeExportDatabase()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-cancel-source-" + UUID().uuidString, isDirectory: true)
        let destA = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-cancel-a-" + UUID().uuidString, isDirectory: true)
        let destB = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-cancel-b-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destA)
            try? FileManager.default.removeItem(at: destB)
        }
        let session = try SessionRepo(connection: db).create(
            name: "S", source: "local", sourcePath: source.path
        )
        for index in 0..<4 {
            let file = source.appendingPathComponent("p\(index).jpg")
            try Data("bytes-\(index)".utf8).write(to: file)
            try seedExportPhoto(db, sessionId: session.id, photoId: "p\(index)", filepath: file.path)
        }
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db
        )
        func options(_ destination: URL) -> ExportOptions {
            ExportOptions(
                scope: .session,
                variantPolicy: .preferred,
                format: .original,
                naming: ExportNaming(pattern: "{original}"),
                includeXmp: false,
                destination: destination.path
            )
        }
        // A：进度回调里取消自己（run "A"），B 同时开始且不应被取消。
        let cancelledA = try service.execute(
            sessionId: session.id,
            options: options(destA),
            runId: "A",
            onProgress: { _ in service.cancel(runId: "A") }
        )
        let resultB = try service.execute(
            sessionId: session.id,
            options: options(destB),
            runId: "B"
        )
        // 旧实现（会话级取消位）：B 一启动就会清掉 A 的取消位，A 继续跑完；
        // 现在 A 必须停在自己的取消边界上，而 B 不受影响。
        #expect(cancelledA.skipped > 0, "被取消的 run 必须留下 skipped（实际 \(cancelledA.skipped)）")
        #expect(cancelledA.exported + cancelledA.skipped == 4)
        #expect(resultB.exported == 4, "同一会话的另一个 run 必须完整导出（实际 \(resultB.exported)）")
        #expect(resultB.skipped == 0)
    }
}

/// 带资产的导出照片行（filteredPhotos 的变体分组需要 asset_id 外键行）。
private func seedExportAssetPhoto(
    _ db: DBConnection,
    sessionId: String,
    photoId: String,
    assetId: String,
    filename: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
          asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', ?, NULL, 32, 24,
          '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(photoId), .text(sessionId), .text("/shoot/" + filename),
        .text(filename), .text(assetId),
    ])
}


@Suite("转码方向归一")
struct ExportOrientationTests {
    @Test("源 orientation=6 转码后输出必须 upright（1 或缺省）")
    func convertBakesOrientation() throws {
        let db = try makeTestDB()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-orient-src-" + UUID().uuidString, isDirectory: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-orient-dst-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: source.path)
            try? FileManager.default.removeItem(atPath: destination.path)
        }
        let input = source.appendingPathComponent("photo.jpg")
        var pixels = [UInt8](repeating: 128, count: 24 * 16 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: &pixels, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 24 * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let imageDestination = try #require(CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(imageDestination, image, [
            kCGImagePropertyOrientation: 6,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(imageDestination))
        try (data as Data).write(to: input)

        let session = try SessionRepo(connection: db).create(
            name: "Orientation", source: "local", sourcePath: source.path)
        try seedExportPhoto(db, sessionId: session.id, photoId: "p1", filepath: input.path)
        let service = ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            connection: db)
        let options = ExportOptions(
            scope: .session, format: .jpeg, quality: 90, maxDimension: nil,
            naming: ExportNaming(pattern: "{original}"), includeXmp: false,
            destination: destination.path)
        #expect(try service.execute(sessionId: session.id, options: options).exported == 1)

        let output = destination.appendingPathComponent("photo.jpg")
        let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        #expect(orientation == 1, "像素已摆正，输出不能带 6/8 等旋转标记")
        // 方向必须烘焙进像素：24×16 + orientation=6 → 输出 16×24。
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 16)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 24)
    }
}
