// desktop/native/gather-app/Tests/GatherAppTests/GatherAppDelegateTests.swift
// 深链导入与导入完成通知的契约。
//
// 职责：
// 1. gather://import?file=… 过滤非图片、去重、保留大小写扩展名、丢弃不存在路径；
// 2. Finder 传入文件 URL 直接接受，目录展开为图片文件；
// 3. AppImport.importFiles 成功后 post importCompleted，userInfo 携带
//    sessionId / addedCount / failedCount。
//
// 边界：临时目录 + 真实 1×1 JPEG 驱动启动后共用的导入路径；不跑 AppKit 事件
// 循环、不触网、不写真实 Application Support（内存 SchemaCurrent 库）。
import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GatherUI
@testable import GatherHost
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
import GatherTestSupport

// 本套件读写进程级 NotificationCenter / 真实 DB，导入完成通知跨用例会互串；
// 串行执行保证断言看到的是本用例的 session。
@Suite("GatherAppDelegate", .serialized)
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

        let db = try makeTestDB()
        let composition = AppComposition.make(db: db)

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

        // Cut 3 / 3b-1：导入实现已迁到 AppImport（本测试仍覆盖启动后的菜单/
        // deep-link 共用的导入路径与通知契约）。
        let services = AppServices.live(composition: composition)
        await AppImport.importFiles(
            [good.path, broken.path],
            sessionAPI: services.session,
            l10n: L10n(language: .zhCN)
        )

        let userInfo = try #require(box.userInfo)
        let sessionId = try #require(userInfo[GatherAppImportUserInfoKey.sessionId] as? String)
        #expect(!sessionId.isEmpty)
        #expect(userInfo[GatherAppImportUserInfoKey.addedCount] as? Int == 1)
        #expect(userInfo[GatherAppImportUserInfoKey.failedCount] as? Int == 1)
    }

    /// Cut 4 / 4b-3：C1 默认建库名走 `l10n.format`（原 String(format: l(...))）；
    /// en 界面出译文，非 C1 来源回退「导入照片」。
    @Test func captureOneDefaultNameFollowsInjectedL10n() {
        #expect(AppImport.defaultImportName(source: "capture-one", l10n: L10n(language: .zhCN))
            .hasPrefix("C1 导入 "))
        #expect(AppImport.defaultImportName(source: "capture-one", l10n: L10n(language: .en))
            .hasPrefix("C1 Import "))
        #expect(AppImport.defaultImportName(source: "local", l10n: L10n(language: .en)) == "Import Photos")
        #expect(AppImport.defaultImportName(source: "local", l10n: L10n(language: .zhCN)) == "导入照片")
    }

    /// P1-1：目录导入必须建出带 sourcePath 的目录工作区，否则之后无法重扫/摄取。
    @Test func importDirectoryCreatesWorkspaceWithSourcePath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-import-dir-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try makeJPEG(at: directory.appendingPathComponent("one.jpg"))

        let db = try makeTestDB()
        let composition = AppComposition.make(db: db)
        let services = AppServices.live(composition: composition)

        await AppImport.importFiles(
            [directory.path],
            sessionAPI: services.session,
            l10n: L10n(language: .zhCN)
        )

        let sessions = try await services.session.list()
        let session = try #require(sessions.first)
        #expect(ScanPath.canonical(session.sourcePath) == ScanPath.canonical(directory.path),
                "目录导入必须落 sourcePath；空串会让摄取/重扫永久失败")
    }

    /// P1-1：多文件导入保持 path-scope（source_path 为空），根只能由用户显式设置。
    @Test func importMultipleFilesStaysPathScope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-import-files-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeJPEG(at: directory.appendingPathComponent("one.jpg"))
        let second = try makeJPEG(at: directory.appendingPathComponent("two.jpg"))

        let db = try makeTestDB()
        let composition = AppComposition.make(db: db)
        let services = AppServices.live(composition: composition)

        await AppImport.importFiles(
            [first.path, second.path],
            sessionAPI: services.session,
            l10n: L10n(language: .zhCN)
        )

        let sessions = try await services.session.list()
        let session = try #require(sessions.first)
        #expect(session.sourcePath.isEmpty,
                "公共父目录不得落成工作区根（历史 P0）；根由用户显式设置")
    }

    /// P1-2：建库失败必须 post importFailed，而不是只写日志。
    @Test func importFailurePostsVisibleNotification() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-import-failed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("one.jpg")
        try Data("jpeg-fixture".utf8).write(to: photo)

        let stub = B8SessionAPIStub() // create 默认抛 INVALID_PARAM，模拟建库失败
        final class Box: @unchecked Sendable {
            var error: CommandError?
            var retryFiles: [String]?
        }
        let box = Box()
        let token = NotificationCenter.default.addObserver(
            forName: GatherAppNotification.importFailed,
            object: nil,
            queue: nil
        ) { notification in
            box.error = notification.object as? CommandError
            box.retryFiles = notification.userInfo?[GatherAppImportUserInfoKey.retryFiles] as? [String]
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await AppImport.importFiles(
            [photo.path],
            sessionAPI: stub,
            l10n: L10n(language: .zhCN)
        )

        let error = try #require(box.error)
        #expect(error.code == GatherErrorCode.INVALID_PARAM.rawValue)
        #expect(box.retryFiles == [ScanPath.canonical(photo.path)])
    }

    // MARK: - Wave5 batch7（A2/R5）：C1 导入统一入口

    /// C1 文件统一入口：capture-one 来源标 + 「Capture One 文件」来源标签 +
    /// 判断数据按导入路径集合调度落库（三个 C1 入口共用同一份语义）。
    @Test func captureOneImportEntryMarksSourceAndSchedulesJudgements() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-c1-entry-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = try makeJPEG(at: directory.appendingPathComponent("frame.jpg"))
        let importPaths = normalizeImportFilepaths([photo.path])
        #expect(!importPaths.isEmpty)

        let db = try makeTestDB()
        let services = AppServices.live(composition: AppComposition.make(db: db))

        final class Box: @unchecked Sendable {
            var scheduled: [(sessionId: String, judgements: [C1VariantJudgement])] = []
            var completed: [AnyHashable: Any]?
        }
        let box = Box()
        let token = NotificationCenter.default.addObserver(
            forName: GatherAppNotification.importCompleted, object: nil, queue: nil
        ) { notification in
            box.completed = notification.userInfo
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let judgement = C1VariantJudgement(
            photoPath: importPaths[0], rating: 4, colorTag: 1, pick: true, keywords: ["beach"])
        let coordinator = C1ImportCoordinator(
            snapshotProvider: {
                C1SelectionSnapshot(paths: importPaths, judgements: [judgement])
            },
            fallbackPathProvider: { [] },
            scheduleApply: { sessionId, judgements in
                box.scheduled.append((sessionId, judgements))
            })

        // 生产调用链先 capturePaths（读快照 + 按路径集合暂存判断），再导入。
        _ = try await coordinator.capturePaths(expectedPaths: importPaths)
        await AppImport.importCaptureOneFiles(
            importPaths,
            sessionAPI: services.session,
            coordinator: coordinator,
            l10n: L10n(language: .zhCN)
        )

        let sessions = try await services.session.list()
        #expect(!sessions.isEmpty)
        // 判断数据按导入路径调度一次（真实落库由 scheduler 注入，跳过 DB 等待）。
        #expect(box.scheduled.count == 1)
        let scheduled = try #require(box.scheduled.first)
        #expect(scheduled.judgements.map(\.photoPath) == importPaths)
        // 来源标签统一「Capture One 文件」（失败提示/Toast 用同一 key）。
        let completed = try #require(box.completed)
        #expect(completed[GatherAppImportUserInfoKey.sourceLabel] as? String == "Capture One 文件")
    }

    /// 普通本地导入不触发 C1 判断通道（source=local、无判断调度）。
    @Test func localImportDoesNotTouchC1Judgements() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-local-entry-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = try makeJPEG(at: directory.appendingPathComponent("local.jpg"))

        let db = try makeTestDB()
        let services = AppServices.live(composition: AppComposition.make(db: db))

        final class Box: @unchecked Sendable {
            var c1ErrorPosted = false
            var completed: [AnyHashable: Any]?
        }
        let box = Box()
        let errorToken = NotificationCenter.default.addObserver(
            forName: GatherAppNotification.captureOneError, object: nil, queue: nil
        ) { _ in box.c1ErrorPosted = true }
        let doneToken = NotificationCenter.default.addObserver(
            forName: GatherAppNotification.importCompleted, object: nil, queue: nil
        ) { notification in box.completed = notification.userInfo }
        defer {
            NotificationCenter.default.removeObserver(errorToken)
            NotificationCenter.default.removeObserver(doneToken)
        }

        await AppImport.importFiles(
            [photo.path], sessionAPI: services.session, l10n: L10n(language: .zhCN))

        let sessions = try await services.session.list()
        #expect(!sessions.isEmpty)
        // 普通导入不读 C1 快照，也不产生 C1 判断/C1 错误提示。
        #expect(!box.c1ErrorPosted)
        let completed = try #require(box.completed)
        #expect((completed[GatherAppImportUserInfoKey.sourceLabel] as? String)?.isEmpty != false)
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

// MARK: - Wave5 batch7（A2/R5）：gather://import?source=capture-one

/// C1 来源深链：不改路由形状（仍 .importFiles），只把导入语义切到 C1
/// （判断快照 + capture-one 来源标 + 去重/命名一致）。
@Suite("Capture One 来源深链（A2/R5）")
@MainActor
struct GatherDeepLinkCaptureOneSourceTests {
    private func makePhoto(_ name: String) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-c1-deeplink-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = directory.appendingPathComponent(name)
        try Data("jpeg-fixture".utf8).write(to: photo)
        return (directory, photo)
    }

    private func importURL(files: [URL], source: String?) throws -> URL {
        var components = URLComponents()
        components.scheme = "gather"
        components.host = "import"
        var items = files.map { URLQueryItem(name: "file", value: $0.path) }
        if let source { items.append(URLQueryItem(name: "source", value: source)) }
        components.queryItems = items
        return try #require(components.url)
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("isCaptureOneSource：大小写/空白容错；local/缺省/非 import URL 不算 C1")
    func recognizesSourceParameter() throws {
        for raw in [
            "gather://import?file=/a.jpg&source=capture-one",
            "gather://import?file=/a.jpg&SOURCE=Capture-One",
            "gather://import?file=/a.jpg&source=%20capture-one%20",
        ] {
            let url = try #require(URL(string: raw))
            #expect(GatherAppDelegate.isCaptureOneSource(url), "应识别 C1 来源：\(raw)")
        }
        for raw in [
            "gather://import?file=/a.jpg&source=local",
            "gather://import?file=/a.jpg",
            "gather://session/s1?source=capture-one",
        ] {
            let url = try #require(URL(string: raw))
            #expect(!GatherAppDelegate.isCaptureOneSource(url), "不应识别 C1 来源：\(raw)")
        }
    }

    @Test("source=capture-one → onCaptureOneFilesImport；普通 URL → onImportFiles")
    func routesCaptureOneSemantics() throws {
        let (directory, photo) = try makePhoto("c1.jpg")
        let (localDirectory, localPhoto) = try makePhoto("local.jpg")
        defer {
            cleanup(directory)
            cleanup(localDirectory)
        }
        final class Box: @unchecked Sendable {
            var c1: [String]?
            var local: [String]?
        }
        let box = Box()
        let delegate = GatherAppDelegate()
        delegate.onImportFiles = { box.local = $0 }
        delegate.onCaptureOneFilesImport = { box.c1 = $0 }

        delegate.handle(try importURL(files: [photo], source: "capture-one"))
        #expect(box.c1 == [photo.standardizedFileURL.path])
        #expect(box.local == nil, "C1 来源不得走通用导入（会丢来源标与判断数据）")

        delegate.handle(try importURL(files: [localPhoto], source: nil))
        #expect(box.local == [localPhoto.standardizedFileURL.path])
    }

    @Test("C1 回调未安装时排队；先装通用回调也不把 C1 导入降级成本地导入")
    func pendingCaptureOneImportIsNotDowngraded() throws {
        let (directory, photo) = try makePhoto("pending.jpg")
        defer { cleanup(directory) }
        let delegate = GatherAppDelegate()
        delegate.handle(try importURL(files: [photo], source: "capture-one"))

        // 只装通用回调：C1 来源 URL 必须继续排队，不能被 onImportFiles 消费。
        var localCalls: [[String]] = []
        delegate.onImportFiles = { localCalls.append($0) }
        #expect(localCalls.isEmpty)

        // 装 C1 回调 → 重放，走 C1 语义。
        var c1Calls: [[String]] = []
        delegate.onCaptureOneFilesImport = { c1Calls.append($0) }
        #expect(c1Calls.count == 1)
        #expect(c1Calls.first == [photo.standardizedFileURL.path])
        #expect(localCalls.isEmpty)
    }
}
