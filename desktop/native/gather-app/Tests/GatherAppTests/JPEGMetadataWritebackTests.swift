// desktop/native/gather-app/Tests/GatherAppTests/JPEGMetadataWritebackTests.swift
// P1 回归：JPEG 的"盘上值"= 内嵌 IPTC/XMP + sidecar。
//
// 两件事必须同时成立：
// 1) 写后回读/缓存投影走 diskAttributes：只改 caption 不得清掉内嵌 title；
// 2) sidecar 无法清空 JPEG 内嵌字段：显式失败（JPEG_EMBEDDED_CLEAR_UNSUPPORTED），
//    缓存保留盘上真实值，用户不会误以为清空成功。
//
// 用真实 JPEG（ImageIO 写入 IPTC）+ 真实 SidecarXMPProvider + 真实交付执行器，
// 不 mock 任何写盘/解析环节。

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherDelivery
@testable import GatherApplication
@testable import GatherHost

private func makeTempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-jpeg-metadata-" + UUID().uuidString, isDirectory: true).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// 真实 JPEG：IPTC title/caption/copyright + XMP contact/webStatement 写进 APP1
/// （Bridge/C1 的形态）。
private func writeJPEG(
    at path: String,
    title: String,
    caption: String,
    copyright: String,
    contactCity: String = "上海",
    contactEmail: String = "a@b.c",
    webStatement: String = "https://example.com/license"
) throws {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NSError(domain: "JPEGMetadataWritebackTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建 JPEG destination"])
    }
    let context = CGContext(
        data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    let image = try #require(context?.makeImage())
    let properties: [CFString: Any] = [
        kCGImagePropertyIPTCDictionary: [
            kCGImagePropertyIPTCObjectName: title,
            kCGImagePropertyIPTCCaptionAbstract: caption,
            kCGImagePropertyIPTCCopyrightNotice: copyright,
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "GatherCam",
            kCGImagePropertyTIFFModel: "X-T5",
        ],
    ]
    let metadata = CGImageMetadataCreateMutable()
    #expect(CGImageMetadataRegisterNamespaceForPrefix(
        metadata,
        "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/" as CFString,
        "Iptc4xmpCore" as CFString, nil))
    #expect(CGImageMetadataSetValueWithPath(
        metadata, nil, "Iptc4xmpCore:CreatorContactInfo" as CFString,
        [
            "Iptc4xmpCore:CiAdrCity": contactCity,
            "Iptc4xmpCore:CiEmailWork": contactEmail,
        ] as CFDictionary))
    #expect(CGImageMetadataSetValueWithPath(
        metadata, nil, "xmpRights:WebStatement" as CFString, webStatement as CFString))
    CGImageDestinationAddImageAndMetadata(
        destination, image, metadata, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination), "测试 JPEG 必须真的写成文件")
}

private struct JPEGWritebackFixture {
    let db: DBConnection
    let sessionId: String
    let tempRoot: String
    let cache: MetadataCacheRepo
    let metadata: MetadataService
    let xmp: SidecarXMPProvider

    init() throws {
        let db = try makeTestDB()
        let sessionId = "s-jpeg-metadata"
        try insertSession(db, sessionId)
        let root = try makeTempDir()
        let photoRepo = PhotoRepo(connection: db)
        let cache = MetadataCacheRepo(connection: db)
        let deliveryRepo = DeliveryRepo(connection: db)
        let resolver = PhotoAssetResolver(connection: db)
        let xmp = SidecarXMPProvider()
        let mutations = MetadataMutationService(
            deliveryRepo: deliveryRepo, xmp: xmp, assetResolver: resolver)
        let writeback = WritebackService(
            deliveryRepo: deliveryRepo, xmp: xmp, photoRepo: photoRepo,
            metadataCacheRepo: cache, connection: db, assetResolver: resolver,
            fileLock: XMPFileLock())
        let metadata = MetadataService(
            metadataCacheRepo: cache, xmp: xmp, photoRepo: photoRepo,
            transactions: db, mutations: mutations,
            flushPending: { sessionId in
                try await writeback.executePending(sessionId: sessionId, module: "metadata")
            },
            assetResolver: resolver, exif: ImageIOExifProvider(),
            dimensions: ImageIODimensionsProvider())

        self.db = db
        self.sessionId = sessionId
        self.tempRoot = root
        self.cache = cache
        self.metadata = metadata
        self.xmp = xmp
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: tempRoot)
        db.close()
    }

    @discardableResult
    func addPhoto(id: String, name: String, title: String, caption: String,
                  copyright: String) throws -> String {
        let path = (tempRoot as NSString).appendingPathComponent(name)
        try writeJPEG(at: path, title: title, caption: caption, copyright: copyright)
        try insertPhoto(db, id: id, sessionId: sessionId, filepath: path)
        return path
    }
}

@Suite("JPEG 元数据写后回读")
struct JPEGMetadataWritebackTests {
    @Test("只改 caption：写后缓存仍保留 JPEG 内嵌 title/copyright")
    func editingCaptionKeepsEmbeddedTitle() async throws {
        let fx = try JPEGWritebackFixture()
        defer { fx.cleanup() }
        try fx.addPhoto(
            id: "p-jpeg", name: "IMG_100.JPG",
            title: "内嵌标题", caption: "内嵌说明", copyright: "© 2026 Gather")

        let outcome = try await fx.metadata.applyMetadataAttributes(
            [("p-jpeg", MetadataWriteAttributes(
                descriptive: DescriptiveMetadata(caption: "sidecar 新说明")))],
            source: .manual)
        #expect(outcome.failed.isEmpty, "只改 caption 不应失败：\(outcome.failed)")
        #expect(outcome.written == ["p-jpeg"])
        #expect(outcome.uncertain.isEmpty)

        let cached = try #require(try fx.cache.get("p-jpeg")?.descriptive)
        #expect(cached.caption == "sidecar 新说明")
        #expect(cached.title == "内嵌标题", "JPEG 内嵌 title 不得被 sidecar 快照清出缓存")
        #expect(cached.copyrightNotice == "© 2026 Gather",
                "JPEG 内嵌 copyright 不得被 sidecar 快照清出缓存")

        // 盘上 sidecar 只有改动字段；内嵌值仍在（Bridge 仍能读到）。
        let sidecar = try await fx.xmp.readAttributes(
            photoPath: (fx.tempRoot as NSString).appendingPathComponent("IMG_100.JPG"))
        #expect(sidecar.descriptive?.caption == "sidecar 新说明")
        #expect(sidecar.descriptive?.title == nil)
    }

    @Test("清空 JPEG 内嵌字段：显式失败 + uncertain，缓存保留盘上旧值")
    func clearingEmbeddedFieldsFailsClosed() async throws {
        let fx = try JPEGWritebackFixture()
        defer { fx.cleanup() }
        let photoPath = try fx.addPhoto(
            id: "p-jpeg", name: "IMG_101.JPG",
            title: "内嵌标题", caption: "内嵌说明", copyright: "© 2026 Gather")
        // 先有一个真实 sidecar：证明后面确实发生了"sidecar 元素删除"，而不是根本没写。
        try await fx.xmp.writeAttributes(
            photoPath: photoPath,
            attributes: MetadataWriteAttributes(
                descriptive: DescriptiveMetadata(title: "sidecar 旧标题", city: "上海")))

        var cleared = DescriptiveMetadata()
        cleared.clear(.caption)
        cleared.clear(.webStatement)
        cleared.clear(.contactInfo)
        let outcome = try await fx.metadata.applyMetadataAttributes(
            [("p-jpeg", MetadataWriteAttributes(descriptive: cleared))], source: .manual)

        #expect(outcome.written.isEmpty, "清空未生效不得报 written")
        #expect(outcome.uncertain == ["p-jpeg"], "可能已写 sidecar：必须进 uncertain/撤销批次")
        #expect(outcome.undoable == ["p-jpeg"])
        let failure = try #require(outcome.failed.first)
        #expect(failure.message.hasPrefix("JPEG_EMBEDDED_CLEAR_UNSUPPORTED:"),
                "必须给出可操作的明确错误码：\(failure.message)")
        #expect(failure.message.contains("caption"))
        #expect(failure.message.contains("webStatement"),
                "WebStatement 必须映射并纳入清空判定：\(failure.message)")
        #expect(failure.message.contains("contactInfo"),
                "CreatorContactInfo 必须映射并纳入清空判定：\(failure.message)")

        let cached = try #require(try fx.cache.get("p-jpeg")?.descriptive)
        #expect(cached.title == "sidecar 旧标题", "缓存必须反映 sidecar 的最终值")
        #expect(cached.caption == "内嵌说明", "失败时缓存不得丢掉内嵌字段")
        #expect(cached.webStatement == "https://example.com/license")
        #expect(cached.contactInfo?.city == "上海")
        #expect(cached.contactInfo?.email == "a@b.c")

        // sidecar 存在且元素确实被删除了；失败来自内嵌值残留，而不是 sidecar 没写。
        let xmpPath = TSPath.xmpSidecarPath(photoPath)
        #expect(FileManager.default.fileExists(atPath: xmpPath))
        let sidecar = try await fx.xmp.readAttributes(photoPath: photoPath)
        #expect(sidecar.descriptive?.caption == nil)
        #expect(sidecar.descriptive?.webStatement == nil)
        #expect(sidecar.descriptive?.contactInfo == nil)
        #expect(sidecar.descriptive?.title == "sidecar 旧标题", "未清空的 sidecar 字段必须保留")
    }

    @Test("清空联系人单个成员：内嵌仍保留时必须失败（成员级信号）")
    func clearingSingleContactMemberFailsClosed() async throws {
        let fx = try JPEGWritebackFixture()
        defer { fx.cleanup() }
        let photoPath = try fx.addPhoto(
            id: "p-jpeg", name: "IMG_103.JPG",
            title: "内嵌标题", caption: "内嵌说明", copyright: "© 2026 Gather")
        // 先落一份带城市的 sidecar：证明后面确实发生了成员删除，而不是根本没写。
        try await fx.xmp.writeAttributes(
            photoPath: photoPath,
            attributes: MetadataWriteAttributes(
                descriptive: DescriptiveMetadata(city: "上海")))

        // 用户只清空城市，邮箱保留 → contact 结构非空 + replaceContact 整块替换。
        let outcome = try await fx.metadata.applyMetadataAttributes(
            [("p-jpeg", MetadataWriteAttributes(
                descriptive: DescriptiveMetadata(contactInfo: DescriptiveContact(email: "a@b.c")),
                replaceContact: true,
                clearedContactMembers: ["city"]))],
            source: .manual)

        #expect(outcome.written.isEmpty, "成员级清空未生效不得报 written")
        #expect(outcome.uncertain == ["p-jpeg"], "可能已写 sidecar：必须进 uncertain/撤销批次")
        let failure = try #require(outcome.failed.first)
        #expect(failure.message.contains("contactInfo"), "\(failure.message)")
        // sidecar 已无城市（成员被删），盘上仍有（来自内嵌 IPTC）。
        let sidecar = try await fx.xmp.readAttributes(photoPath: photoPath)
        #expect(sidecar.descriptive?.contactInfo?.city == nil)
        let cached = try #require(try fx.cache.get("p-jpeg")?.descriptive)
        #expect(cached.contactInfo?.city == "上海", "缓存保留盘上真值")
    }

    @Test("兄弟刷新：编辑 RAW 时 JPEG 兄弟按自己的盘上值刷新，不丢内嵌 title")
    func siblingRefreshUsesEachPhotosDiskValues() async throws {
        let fx = try JPEGWritebackFixture()
        defer { fx.cleanup() }
        let rawPath = (fx.tempRoot as NSString).appendingPathComponent("IMG_102.CR3")
        try Data("raw-bytes".utf8).write(to: URL(fileURLWithPath: rawPath))
        try insertPhoto(fx.db, id: "p-raw", sessionId: fx.sessionId, filepath: rawPath)
        try fx.addPhoto(
            id: "p-jpeg", name: "IMG_102.JPG",
            title: "内嵌标题", caption: "内嵌说明", copyright: "© 2026 Gather")
        // 让两个变体共享同一个 sidecar：CR3 与 JPG 同 stem（xmpSidecarPath 均落 IMG_102.xmp）。
        #expect(TSPath.normalize(TSPath.xmpSidecarPath(rawPath))
            == TSPath.normalize(TSPath.xmpSidecarPath(
                (fx.tempRoot as NSString).appendingPathComponent("IMG_102.JPG"))))

        // 写前缓存：JPEG 兄弟已有内嵌字段（模拟扫描投影）。
        try fx.cache.upsert(
            photoId: "p-jpeg", sessionId: fx.sessionId,
            data: MetadataCacheInput(descriptive: DescriptiveMetadata(
                title: "内嵌标题", caption: "内嵌说明", copyrightNotice: "© 2026 Gather")))

        let outcome = try await fx.metadata.applyMetadataAttributes(
            [("p-raw", MetadataWriteAttributes(
                descriptive: DescriptiveMetadata(caption: "RAW 新说明")))],
            source: .manual)
        #expect(outcome.failed.isEmpty, "\(outcome.failed)")
        #expect(outcome.written == ["p-raw"])

        let rawCached = try #require(try fx.cache.get("p-raw")?.descriptive)
        #expect(rawCached.caption == "RAW 新说明")
        let jpegCached = try #require(try fx.cache.get("p-jpeg")?.descriptive)
        #expect(jpegCached.caption == "RAW 新说明", "共享 sidecar 的写入要投影到兄弟")
        #expect(jpegCached.title == "内嵌标题",
                "兄弟刷新必须逐张读盘：RAW sidecar 快照不能清掉 JPEG 内嵌 title")
        #expect(jpegCached.copyrightNotice == "© 2026 Gather")
        #expect(jpegCached.webStatement == "https://example.com/license")
        #expect(jpegCached.contactInfo?.city == "上海")
    }
}
