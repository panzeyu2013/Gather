// desktop/native/gather-core/Tests/GatherCoreTests/Services/OutputServiceTests.swift
// 整套交付：多配方逐套导出、联系表、manifest、失败隔离与参数校验。

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

private func makeOutputJPEG(at path: String, width: Int = 24, height: Int = 18) throws {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func seedOutputPhoto(
    _ db: DBConnection, sessionId: String, photoId: String, filepath: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
          asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', NULL, NULL, 24, 18,
          '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(photoId), .text(sessionId), .text(filepath),
        .text(URL(fileURLWithPath: filepath).lastPathComponent),
    ])
}

@Suite("整套交付（OutputService）")
struct OutputServiceTests {
    private func makeFixture() throws -> (DBConnection, String, String, [String]) {
        let db = try makeTestDB()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-src-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let session = try SessionRepo(connection: db).create(
            name: "Output", source: "local", sourcePath: source.path)
        var paths: [String] = []
        for index in 0..<2 {
            let path = source.appendingPathComponent("IMG_\(index).jpg").path
            try makeOutputJPEG(at: path)
            try seedOutputPhoto(db, sessionId: session.id, photoId: "p\(index)", filepath: path)
            paths.append(path)
        }
        return (db, session.id, source.path, paths)
    }

    @Test("两个配方各自成目录 + manifest 可解码")
    func runsTwoRecipes() throws {
        let (db, sessionId, source, _) = try makeFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-run-" + UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: root.path)
        }
        let service = OutputService(exportService: ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            reports: ExportReportRepo(connection: db)))
        let input = OutputRunInput(
            sessionId: sessionId,
            destinationRoot: root.path,
            recipes: [
                OutputRecipe(name: "Web 2048", format: .jpeg, quality: 80, maxDimension: 2048),
                OutputRecipe(name: "Print TIFF", format: .tiff, quality: nil),
            ])
        let summary = try service.run(input: input)
        #expect(summary.recipes.count == 2)
        #expect(summary.totalExported == 4)
        #expect(summary.totalFailed == 0)
        for recipe in summary.recipes {
            #expect(FileManager.default.fileExists(atPath: recipe.destination))
        }
        #expect(FileManager.default.fileExists(atPath: summary.manifestPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: summary.manifestPath))
        let decoded = try JSONDecoder().decode(OutputRunSummary.self, from: data)
        #expect(decoded.runId == summary.runId)
        #expect(decoded.recipes.count == 2)
    }

    @Test("配方勾选联系表：产出 PDF 并写进结果")
    func producesContactSheet() throws {
        let (db, sessionId, source, _) = try makeFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-sheet-" + UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: root.path)
        }
        let service = OutputService(exportService: ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            reports: ExportReportRepo(connection: db)))
        let input = OutputRunInput(
            sessionId: sessionId,
            destinationRoot: root.path,
            recipes: [OutputRecipe(
                name: "Proof", format: .jpeg, quality: 80,
                artifacts: [.photos, .contactSheet])],
            contactSheet: OutputContactSheetOptions(title: "Proof", columns: 2, rows: 2))
        let summary = try service.run(input: input)
        let sheet = try #require(summary.recipes.first?.contactSheetPath)
        #expect(FileManager.default.fileExists(atPath: sheet))
        let document = try #require(CGPDFDocument(URL(fileURLWithPath: sheet) as CFURL))
        #expect(document.numberOfPages == 1)
    }

    @Test("参数校验：空配方 / 相对根目录")
    func validatesInput() throws {
        let db = try makeTestDB()
        let service = OutputService(exportService: ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            reports: ExportReportRepo(connection: db)))
        #expect(throws: OutputServiceError.self) {
            _ = try service.run(input: OutputRunInput(
                sessionId: "s", destinationRoot: "/tmp/x", recipes: []))
        }
        #expect(throws: OutputServiceError.self) {
            _ = try service.run(input: OutputRunInput(
                sessionId: "s", destinationRoot: "relative/path",
                recipes: [OutputRecipe(name: "A")]))
        }
    }

    @Test("配方勾选画廊：产出 index/data.json/thumbs/large/proof")
    func producesGallery() throws {
        let (db, sessionId, source, _) = try makeFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-gallery-" + UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: root.path)
        }
        let service = OutputService(exportService: ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            reports: ExportReportRepo(connection: db)))
        let input = OutputRunInput(
            sessionId: sessionId,
            destinationRoot: root.path,
            recipes: [OutputRecipe(
                name: "Client Gallery", format: .jpeg, quality: 82,
                artifacts: [.photos, .gallery])],
            gallery: OutputGalleryOptions(
                title: "<script>alert(1)</script>Wedding", subtitle: "2026"))
        let summary = try service.run(input: input)
        let indexPath = try #require(summary.recipes.first?.galleryPath)
        #expect(summary.recipes.first?.galleryItems == 2)
        let galleryDir = URL(fileURLWithPath: indexPath).deletingLastPathComponent()
        for name in ["index.html", "gallery.css", "gallery.js", "data.json", "proof.html", "proof.js"] {
            #expect(FileManager.default.fileExists(
                atPath: galleryDir.appendingPathComponent(name).path), "缺少 \(name)")
        }
        #expect(FileManager.default.fileExists(
            atPath: galleryDir.appendingPathComponent("thumbs/0001.jpg").path))
        #expect(FileManager.default.fileExists(
            atPath: galleryDir.appendingPathComponent("large/0001.jpg").path))
        let entries = try JSONDecoder().decode(
            [GalleryEntry].self,
            from: Data(contentsOf: galleryDir.appendingPathComponent("data.json")))
        #expect(entries.count == 2)
        // manifest 成品清单：两张成片 + gallery/index.html。
        let files = try #require(summary.recipes.first?.files)
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.bytes > 0 })
        let html = try String(contentsOf: galleryDir.appendingPathComponent("index.html"), encoding: .utf8)
        // 标题里的 HTML 必须转义（防止客户画廊 XSS）。
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;Wedding"))
        #expect(!html.contains("<script>alert(1)"))
    }

    @Test("目录名清洗：非法字符被去掉，空名回落 output")
    func sanitizesName() {
        #expect(OutputService.sanitize("Web/2048: client") == "Web2048 client")
        #expect(OutputService.sanitize("///") == "output")
        #expect(OutputService.sanitize("../evil") == "evil", "点号必须被剥掉，防目录穿越")
        #expect(OutputService.sanitize("打印") == "打印", "中日韩字符属于字母，应保留")
    }

    // MARK: - 客户校样回传

    @Test("selection.json 解析：只取勾选、去重、保序")
    func parsesClientSelection() throws {
        let json = """
        {"version":1,"title":"Proof","picks":[
          {"id":"a","name":"0001.jpg","pick":true},
          {"id":"b","name":"0002.jpg","pick":false},
          {"id":"a","name":"0001.jpg","pick":true},
          {"id":"c","name":"0003.jpg"}
        ]}
        """
        let ids = try ClientSelectionParser.pickedPhotoIds(from: Data(json.utf8))
        #expect(ids == ["a", "c"], "pick=false 跳过；重复 id 去重保序；缺省 pick 视为勾选")
    }

    @Test("selection.json 非法 JSON 显式报错")
    func rejectsInvalidSelection() {
        #expect(throws: ClientSelectionError.self) {
            _ = try ClientSelectionParser.pickedPhotoIds(from: Data("not json".utf8))
        }
    }
}


@Suite("整套交付冲突检测")
struct OutputServiceConflictTests {
    @Test("同名配方 → OUTPUT_RECIPE_CONFLICT，不写盘")
    func rejectsDuplicateDestinations() throws {
        let db = try makeTestDB()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-conflict-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(atPath: root.path) }
        let session = try SessionRepo(connection: db).create(
            name: "Conflict", source: "local", sourcePath: root.path)
        let service = OutputService(exportService: ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            reports: ExportReportRepo(connection: db)))
        let input = OutputRunInput(
            sessionId: session.id, destinationRoot: root.path,
            recipes: [
                OutputRecipe(name: "Same", format: .jpeg, quality: 80),
                OutputRecipe(name: "Same", format: .tiff),
            ])
        #expect(throws: OutputServiceError.self) {
            _ = try service.run(input: input)
        }
    }
}



@Suite("整套交付取消")
struct OutputServiceCancelTests {
    @Test("取消后立即停止：不写 manifest")
    func cancellationStopsBeforeManifest() throws {
        let db = try makeTestDB()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-cancel-src-" + UUID().uuidString, isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-cancel-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: source.path)
            try? FileManager.default.removeItem(atPath: root.path)
        }
        let session = try SessionRepo(connection: db).create(
            name: "Cancel", source: "local", sourcePath: source.path)
        let service = OutputService(exportService: ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            reports: ExportReportRepo(connection: db)))
        let input = OutputRunInput(
            sessionId: session.id, destinationRoot: root.path,
            recipes: [OutputRecipe(name: "Only", format: .jpeg, quality: 80)])
        #expect(throws: CancellationError.self) {
            _ = try service.run(input: input, isCancelled: { true })
        }
        // 取消也要留下「已交付了什么」的记录（partial manifest）。
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let manifestName = try #require(files.first { $0.hasPrefix("manifest-") })
        let summary = try JSONDecoder().decode(
            OutputRunSummary.self,
            from: Data(contentsOf: root.appendingPathComponent(manifestName)))
        #expect(summary.cancelled == true)
        #expect(summary.recipes.isEmpty)
    }

    @Test("断点续跑：已完成照片不重导、不产生 _2 副本")
    func resumeSkipsCompleted() throws {
        let db = try makeTestDB()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-resume-src-" + UUID().uuidString, isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-resume-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: source.path)
            try? FileManager.default.removeItem(atPath: root.path)
        }
        let session = try SessionRepo(connection: db).create(
            name: "Resume", source: "local", sourcePath: source.path)
        var paths: [String] = []
        for index in 0..<2 {
            let path = source.appendingPathComponent("IMG_\(index).jpg").path
            try makeOutputJPEG(at: path)
            try seedOutputPhoto(db, sessionId: session.id, photoId: "p\(index)", filepath: path)
            paths.append(path)
        }
        let service = OutputService(exportService: ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            reports: ExportReportRepo(connection: db)))
        let recipe = OutputRecipe(name: "Resume", format: .jpeg, quality: 80)
        let input = OutputRunInput(
            sessionId: session.id, destinationRoot: root.path, recipes: [recipe])
        var captured: [String: OutputRecipeResume] = [:]
        _ = try service.run(
            input: input,
            onRecipeResume: { recipeId, state in captured[recipeId] = state })
        #expect(captured[recipe.id]?.completedPhotoIds.count == 2)

        // 第二次带 resume：应跳过（不再写新文件），目录里没有 _2 副本。
        let second = try service.run(input: input, resume: captured)
        #expect(second.totalExported == 2)
        let recipeDir = root.appendingPathComponent("Resume")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: recipeDir.path)) ?? []
        #expect(!names.contains { $0.contains("_2") }, "续跑不得产生重名副本")
        #expect(names.filter { $0.hasSuffix(".jpg") }.count == 2)
    }


    @Test("改了配方参数后旧 resume 不得复用")
    func resumeInvalidatedByRecipeChange() throws {
        let db = try makeTestDB()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-resume2-src-" + UUID().uuidString, isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-output-resume2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: source.path)
            try? FileManager.default.removeItem(atPath: root.path)
        }
        let session = try SessionRepo(connection: db).create(
            name: "Resume2", source: "local", sourcePath: source.path)
        for index in 0..<2 {
            let path = source.appendingPathComponent("R_\(index).jpg").path
            try makeOutputJPEG(at: path)
            try seedOutputPhoto(db, sessionId: session.id, photoId: "r\(index)", filepath: path)
        }
        let service = OutputService(exportService: ExportService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            reports: ExportReportRepo(connection: db)))
        let recipe = OutputRecipe(name: "Resume2", format: .jpeg, quality: 80)
        let input = OutputRunInput(
            sessionId: session.id, destinationRoot: root.path, recipes: [recipe])
        var captured: [String: OutputRecipeResume] = [:]
        _ = try service.run(input: input, onRecipeResume: { id, state in captured[id] = state })

        var changed = recipe
        changed.maxDimension = 100
        let changedInput = OutputRunInput(
            sessionId: session.id, destinationRoot: root.path, recipes: [changed])
        let second = try service.run(input: changedInput, resume: captured)
        #expect(second.totalExported == 2)
        // 参数变了 → 不复用旧完成清单：目标目录出现新一套（_2）文件。
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("Resume2").path)) ?? []
        #expect(names.filter { $0.contains("_2") }.count >= 1, "新参数必须真的重导")
    }
}
