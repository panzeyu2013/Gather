import Foundation
import Testing
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif
@testable import GatherCore

private func makeTempPhotoStore() async throws -> any PhotoStore {
    let (database, _) = try await makeMigratedStoreDatabase(label: "photos")
    return SQLitePhotoStore(database: database)
}


private struct ExportTestEnv {
    let db: DBConnection
    let photoStore: any PhotoStore
}

private func makeExportDatabase() async throws -> ExportTestEnv {
    // 临时文件库：ExportService 的 photoStore 需与旧连接同库读取照片行。
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-export-\(UUID().uuidString).sqlite").path
    let db = try DBConnection(path: path)
    try MigrationRunner().migrate(db)
    let store = try SQLitePhotoStore(database: try SQLiteDatabase(path: path))
    return ExportTestEnv(db: db, photoStore: store)
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
    @Test func copiesOriginalSidecarAndResumesFromCheckpoint() async throws {
        let env = try await makeExportDatabase()
        let db = env.db
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
            photoStore: env.photoStore,
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

        let preview = try await service.preview(sessionId: session.id, options: options)
        #expect(preview.totalFiles == 1)
        #expect(preview.files.first?.filename == "family.jpg")
        let first = try await service.execute(sessionId: session.id, options: options)
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
        #expect(try await service.preview(sessionId: session.id, options: legacyOptions).files.first?.filename == "family.jpg")

        let resumed = try await service.execute(
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

    @Test func rejectsExportIntoSourceDirectory() async throws {
        let env = try await makeExportDatabase()
        let db = env.db
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
            photoStore: env.photoStore,
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
        await #expect(throws: ExportServiceError.destinationInsideSession) {
            try await service.preview(sessionId: session.id, options: options)
        }
    }

#if canImport(ImageIO)
    @Test func convertsJpegThroughImageIO() async throws {
        let env = try await makeExportDatabase()
        let db = env.db
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
            photoStore: env.photoStore,
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
        let result = try await service.execute(sessionId: session.id, options: options)
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
    @Test func timePlaceholderUsesFixed24HourFormat() async throws {
        let env = try await makeExportDatabase()
        let db = env.db
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
            photoStore: env.photoStore,
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

        let result = try await service.execute(sessionId: session.id, options: options)
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
}
