// desktop/native/gather-app/Tests/GatherAppTests/GatherDeepLinkRouteTests.swift
// Wave3 / task-21：gather:// URL scheme 的类型化解析（session / photo / import）。
//
// 覆盖：
// 1. gather://session/<id> 与 gather://photo/<id> 的成功解析与空 id 拒绝；
// 2. gather://import?file=…（旧行为）与 gather://import?session=<id>&file=…（加入已有工作区）；
// 3. gather://import?session=<id>（无文件 = 打开工作区）；
// 4. 未知 scheme/host 的类型化错误码；
// 5. 与旧 GatherDeepLink.importFiles 的兼容（同一过滤规则，不重复实现）。
//
// 边界：只碰临时目录与真实 1 字节文件（解析只做“存在 + 扩展名”校验，不读像素）。
import Foundation
import Testing
@testable import GatherHost

@Suite("gather:// 深链解析")
struct GatherDeepLinkRouteTests {
    private func makeTempDir() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-deeplink-route-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func parsesSessionAndPhotoRoutes() throws {
        #expect(GatherDeepLinkParser.parse(URL(string: "gather://session/session-1")!) ==
            .route(.openSession(sessionId: "session-1")))
        #expect(GatherDeepLinkParser.parse(URL(string: "gather://photo/photo-1")!) ==
            .route(.openPhoto(photoId: "photo-1")))
    }

    @Test func rejectsMissingIdentifiersWithTypedErrors() throws {
        #expect(GatherDeepLinkParser.parse(URL(string: "gather://session/")!) ==
            .invalid(.missingSessionId))
        #expect(GatherDeepLinkParser.parse(URL(string: "gather://photo/")!) ==
            .invalid(.invalidPhotoId))
    }

    @Test func parsesLegacyImportFiles() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("a.jpg")
        try Data("x".utf8).write(to: photo)

        let url = try #require(URL(string:
            "gather://import?file=" + photo.path.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed)!))
        #expect(GatherDeepLinkParser.parse(url) ==
            .route(.importFiles(files: [photo.standardizedFileURL.path])))
    }

    @Test func parsesImportIntoExistingSession() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("b.jpg")
        try Data("x".utf8).write(to: photo)
        let encoded = try #require(photo.path.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed))
        let url = try #require(URL(string: "gather://import?session=session-2&file=" + encoded))

        #expect(GatherDeepLinkParser.parse(url) ==
            .route(.importIntoSession(
                sessionId: "session-2", files: [photo.standardizedFileURL.path])))
    }

    @Test func emptyFileListWithSessionOpensSession() throws {
        #expect(GatherDeepLinkParser.parse(URL(string: "gather://import?session=session-3")!) ==
            .route(.openSession(sessionId: "session-3")))
    }

    @Test func rejectsUnsupportedSchemeAndHost() throws {
        guard case .invalid(let schemeError) = GatherDeepLinkParser.parse(
            URL(string: "https://example.com/session/1")!) else {
            Issue.record("expected invalid scheme")
            return
        }
        #expect(schemeError.code == "DEEPLINK_UNSUPPORTED_SCHEME")

        guard case .invalid(let hostError) = GatherDeepLinkParser.parse(
            URL(string: "gather://unknown/1")!) else {
            Issue.record("expected invalid host")
            return
        }
        #expect(hostError.code == "DEEPLINK_UNKNOWN_HOST")
    }
}
