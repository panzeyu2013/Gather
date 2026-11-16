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
@testable import GatherProtocol

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

// MARK: - Wave5 batch5：gather://rate（脚本写评级/色标/保留）

/// URL scheme 第二层：无 UI 直接写判断。
///
/// 覆盖：合法（单张/多张/去重/大小写/部分字段）、缺参（session/photo/判断字段）、
/// 越界（rating）、未知 label/pick、photo 数量上限。
@Suite("gather://rate 深链解析")
struct GatherDeepLinkRateRouteTests {
    private func result(_ raw: String) throws -> GatherDeepLinkParseResult {
        GatherDeepLinkParser.parse(try #require(URL(string: raw)))
    }

    @Test func parsesSinglePhotoRating() throws {
        #expect(try result("gather://rate?session=s1&photo=p1&rating=3") ==
            .route(.rate(
                sessionId: "s1",
                photoIds: ["p1"],
                patch: GatherAutomationDecisionPatch(rating: 3))))
    }

    @Test func parsesAllFieldsAndDedupesPhotos() throws {
        #expect(try result(
            "gather://rate?session=s1&photo=p1&photo=p2&photo=p1&rating=5&label=Red&pick=keep") ==
            .route(.rate(
                sessionId: "s1",
                photoIds: ["p1", "p2"],
                patch: GatherAutomationDecisionPatch(
                    rating: 5, colorLabel: .red, pickState: .picked))))

        // 只给 pick（拒绝）也是合法补丁；色标名大小写不敏感。
        #expect(try result("gather://rate?session=s1&photo=p1&pick=REJECT") ==
            .route(.rate(
                sessionId: "s1",
                photoIds: ["p1"],
                patch: GatherAutomationDecisionPatch(pickState: .rejected))))

        // 「清除色标」是可表达的：label=none → CaptureOneColorLabel.none。
        #expect(try result("gather://rate?session=s1&photo=p1&label=none") ==
            .route(.rate(
                sessionId: "s1",
                photoIds: ["p1"],
                patch: GatherAutomationDecisionPatch(colorLabel: CaptureOneColorLabel.none))))
    }

    @Test func rejectsMissingParameters() throws {
        // 缺 session / 缺 photo / photo 为空串 → 各自稳定码。
        #expect(try result("gather://rate?photo=p1&rating=3") == .invalid(.missingSessionId))
        #expect(try result("gather://rate?session=&photo=p1&rating=3") == .invalid(.missingSessionId))
        #expect(try result("gather://rate?session=s1&rating=3") == .invalid(.missingPhotoIds))
        #expect(try result("gather://rate?session=s1&photo=&rating=3") == .invalid(.missingPhotoIds))

        // 一个判断字段都没给 = 空写，必须拒绝（不能"看起来成功但什么都没改"）。
        guard case .invalid(let error) = try result("gather://rate?session=s1&photo=p1") else {
            Issue.record("expected invalid decision")
            return
        }
        #expect(error.code == "DEEPLINK_INVALID_DECISION")
    }

    @Test func rejectsOutOfRangeRating() throws {
        guard case .invalid(let error) = try result(
            "gather://rate?session=s1&photo=p1&rating=6") else {
            Issue.record("expected invalid decision")
            return
        }
        #expect(error.code == "DEEPLINK_INVALID_DECISION")
        // 失败原因不吞：说明合法区间，脚本作者能据此修。
        #expect(error.description.contains("0…5"))
    }

    @Test func rejectsUnknownLabelAndPick() throws {
        guard case .invalid(let labelError) = try result(
            "gather://rate?session=s1&photo=p1&label=chartreuse") else {
            Issue.record("expected invalid label")
            return
        }
        #expect(labelError.code == "DEEPLINK_INVALID_DECISION")
        #expect(labelError.description.contains("色标"))

        guard case .invalid(let pickError) = try result(
            "gather://rate?session=s1&photo=p1&pick=maybe") else {
            Issue.record("expected invalid pick")
            return
        }
        #expect(pickError.code == "DEEPLINK_INVALID_DECISION")
        #expect(pickError.description.contains("keep"))
    }

    @Test func rejectsTooManyPhotos() throws {
        let photos = (0...GatherDeepLinkParser.maxRatePhotoIds)
            .map { "photo=p\($0)" }
            .joined(separator: "&")
        #expect(try result("gather://rate?session=s1&\(photos)&rating=1") ==
            .invalid(.tooManyPhotoIds))
    }

    @Test func keepsLegacyRoutesParseable() throws {
        // 新增 rate 不得影响既有 4 条路由的解析结果（回归钉子）。
        #expect(try result("gather://session/s1") == .route(.openSession(sessionId: "s1")))
        #expect(try result("gather://photo/p1") == .route(.openPhoto(photoId: "p1")))
    }
}

// MARK: - Wave5 batch5：AppDelegate 路由分发（无 UI 也可执行）

/// 分发契约：解析成功的 rate 调用 onApplyDecisions；解析失败走 onDeepLinkError；
/// 回调尚未安装时排队，安装后重放（与 import 同口径）。
@Suite("gather://rate 路由分发")
@MainActor
struct GatherDeepLinkRateDispatchTests {
    private func rateURL(_ raw: String) throws -> URL {
        try #require(URL(string: raw))
    }

    @Test func dispatchesRateToHandler() throws {
        final class Box: @unchecked Sendable {
            var sessionId: String?
            var photoIds: [String] = []
            var patch: GatherAutomationDecisionPatch?
        }
        let box = Box()
        let delegate = GatherAppDelegate()
        delegate.onApplyDecisions = { sessionId, photoIds, patch in
            box.sessionId = sessionId
            box.photoIds = photoIds
            box.patch = patch
        }
        delegate.handle(try rateURL(
            "gather://rate?session=s1&photo=p1&photo=p2&rating=4&label=blue&pick=keep"))
        #expect(box.sessionId == "s1")
        #expect(box.photoIds == ["p1", "p2"])
        #expect(box.patch == GatherAutomationDecisionPatch(
            rating: 4, colorLabel: .blue, pickState: .picked))
    }

    @Test func replaysPendingRateWhenHandlerInstalls() throws {
        final class Box: @unchecked Sendable {
            var applied = false
        }
        let box = Box()
        let delegate = GatherAppDelegate()
        // 回调未安装：先排队（不静默丢弃）。
        delegate.handle(try rateURL("gather://rate?session=s1&photo=p1&rating=2"))
        #expect(box.applied == false)
        delegate.onApplyDecisions = { _, _, _ in box.applied = true }
        #expect(box.applied)
    }

    @Test func invalidRateReportsErrorWithoutApplying() throws {
        final class Box: @unchecked Sendable {
            var applied = false
            var error: GatherDeepLinkError?
        }
        let box = Box()
        let delegate = GatherAppDelegate()
        delegate.onApplyDecisions = { _, _, _ in box.applied = true }
        delegate.onDeepLinkError = { box.error = $0 }
        delegate.handle(try rateURL("gather://rate?session=s1&photo=p1&rating=9"))
        #expect(box.applied == false)
        #expect(box.error?.code == "DEEPLINK_INVALID_DECISION")
    }
}
