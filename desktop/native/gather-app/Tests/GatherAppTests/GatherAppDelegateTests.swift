import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GatherApp
@testable import GatherCore

@Suite("GatherAppDelegate")
@MainActor
struct GatherAppDelegateTests {
    @Test func deepLinkFiltersFilesAndDeduplicates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-deeplink-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let photo = directory.appendingPathComponent("family photo.jpg")
        let text = directory.appendingPathComponent("notes.txt")
        try Data("jpeg-fixture".utf8).write(to: photo)
        try Data("not-an-image".utf8).write(to: text)

        var components = URLComponents()
        components.scheme = "gather"
        components.host = "import"
        components.queryItems = [
            URLQueryItem(name: "file", value: photo.path),
            URLQueryItem(name: "file", value: photo.path),
            URLQueryItem(name: "file", value: text.path),
            URLQueryItem(name: "file", value: directory.path),
        ]
        let url = try #require(components.url)
        #expect(GatherDeepLink.importFiles(from: url) == [photo.standardizedFileURL.path])
    }

    @Test func finderFileURLIsAcceptedAndDirectoryIsExpanded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-file-url-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.jpg")
        let second = directory.appendingPathComponent("second.nef")
        try Data("1".utf8).write(to: first)
        try Data("2".utf8).write(to: second)

        #expect(GatherDeepLink.importFiles(from: first) == [first.standardizedFileURL.path])
        #expect(Set(GatherDeepLink.importFiles(from: directory)) == Set([
            first.standardizedFileURL.path,
            second.standardizedFileURL.path,
        ]))
    }

    /// 扩展名匹配大小写不敏感（.JPG）；不存在的路径被过滤。
    @Test func deepLinkAcceptsUppercaseExtensionAndDropsMissingPaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-deeplink-case-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let photo = directory.appendingPathComponent("SHOT.JPG")
        let missing = directory.appendingPathComponent("gone.png")
        try Data("jpeg-fixture".utf8).write(to: photo)

        var components = URLComponents()
        components.scheme = "gather"
        components.host = "import"
        components.queryItems = [
            URLQueryItem(name: "file", value: photo.path),
            URLQueryItem(name: "file", value: missing.path),
        ]
        let url = try #require(components.url)
        #expect(GatherDeepLink.importFiles(from: url) == [photo.standardizedFileURL.path])
    }

    /// importFiles 成功建库后 post importCompleted，userInfo 携带
    /// sessionId/failedCount/addedCount（RootView 导航 + Toast 契约）。
    @Test func importFilesPostsImportCompletedWithCounts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-import-completed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let good = try makeJPEG(at: directory.appendingPathComponent("good.jpg"))
        let broken = directory.appendingPathComponent("broken.txt")
        try Data("not-an-image".utf8).write(to: broken)

        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        let settings = try makeTestSettings()
        let router = SessionCommandRouter.makeDefault(
            db: db, settings: settings.snapshot, settingsAPI: settings.api, templates: settings.templates, albums: settings.albums, workspace: settings.workspace, persons: settings.persons, personStore: settings.personStore, faceStore: settings.faceStore, metadataStore: settings.metadataStore, cullingStore: settings.cullingStore, similarityStore: settings.similarityStore)

        final class Box: @unchecked Sendable {
            var userInfo: [AnyHashable: Any]?
        }
        let box = Box()
        let token = NotificationCenter.default.addObserver(
            forName: GatherAppNotification.importCompleted,
            object: nil,
            queue: nil
        ) { notification in
            box.userInfo = notification.userInfo
        }
        defer { NotificationCenter.default.removeObserver(token) }

        GatherApp.importFiles([good.path, broken.path], router: router)

        let userInfo = try #require(box.userInfo)
        let sessionId = try #require(userInfo[GatherAppImportUserInfoKey.sessionId] as? String)
        #expect(!sessionId.isEmpty)
        #expect(userInfo[GatherAppImportUserInfoKey.addedCount] as? Int == 1)
        #expect(userInfo[GatherAppImportUserInfoKey.failedCount] as? Int == 1)
    }

    /// 生成真实可解码的 1x1 JPEG（RAWDecoder.getDimensions 依赖 ImageIO 读头）。
    private func makeJPEG(at url: URL) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError("CGContext failed") }
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else { throw TestError("makeImage failed") }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw TestError("destination failed") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw TestError("finalize failed") }
        try (data as Data).write(to: url)
        return url
    }

    private struct TestError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
