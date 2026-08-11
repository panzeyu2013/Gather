import Foundation
import Testing
@testable import GatherApp

@Suite("GatherAppDelegate")
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
}
