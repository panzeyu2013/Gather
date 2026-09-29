import Foundation
import Testing
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif
@testable import GatherCore

private func makeExportDatabase() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    return db
}

private func seedExportPhoto(
    _ db: DBConnection,
    sessionId: String,
    photoId: String,
    filepath: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
          result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', '{}', '{}', NULL, NULL, 32, 24,
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
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
          result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', '{}', '{}', ?, NULL, 32, 24,
          '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(photoId), .text(sessionId), .text("/shoot/" + filename),
        .text(filename), .text(assetId),
    ])
}
