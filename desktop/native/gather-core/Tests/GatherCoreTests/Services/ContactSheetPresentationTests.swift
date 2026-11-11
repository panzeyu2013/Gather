// desktop/native/gather-core/Tests/GatherCoreTests/Services/ContactSheetPresentationTests.swift
// P1 下一波：交付展示模型（CaptionFormatter / ContactSheetFields / 联系表版式 /
// 画廊 data.json v1→v2 / 发布白名单的纯函数）。

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GatherProtocol
@testable import GatherApplication

private func makeSheetJPEG(at path: String, width: Int = 40, height: Int = 30) throws {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.4, green: 0.6, blue: 0.4, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Suite("交付展示（联系表 / 画廊）")
struct ContactSheetPresentationTests {

    private func item(
        rating: Int = 4,
        label: String = "Green",
        pick: PickState = .picked,
        keywords: [String] = ["婚礼", "户内"],
        title: String? = "主图",
        date: String? = "2026-10-29"
    ) -> DeliveryPresentationItem {
        DeliveryPresentationItem(
            photoId: "p1", filePath: "/tmp/p1.jpg", filename: "IMG_0001.jpg",
            title: title, caption: nil, rating: rating, label: label, pick: pick,
            keywords: keywords, captureTime: date, pixelWidth: 6000, pixelHeight: 4000)
    }

    // MARK: - CaptionFormatter

    @Test("默认模板 = 文件名（老配方零变化）")
    func captionDefaultsToFilename() {
        let text = CaptionFormatter.format(
            CaptionFormatter.defaultTemplate, item: item(), fields: .legacy)
        #expect(text == "IMG_0001.jpg")
    }

    @Test("占位符按 fields 生效；未知占位符原样保留")
    func captionPlaceholders() {
        let fields: ContactSheetFields = [.filename, .rating, .label, .keywords, .captureTime]
        let text = CaptionFormatter.format(
            "{filename} · {rating} · {label} · {keywords} · {date} · {nosuch}",
            item: item(), fields: fields)
        #expect(text == "IMG_0001.jpg · ★★★★ · Green · 婚礼, 户内 · 2026-10-29 · {nosuch}")
    }

    @Test("fields 关闭时对应占位符渲染为空")
    func captionFieldsGate() {
        let text = CaptionFormatter.format(
            "{filename}-{rating}-{label}", item: item(), fields: [.filename])
        #expect(text == "IMG_0001.jpg--")
    }

    @Test("模板全空时回落到文件名（不留空白 caption）")
    func captionEmptyFallsBack() {
        let text = CaptionFormatter.format("", item: item(), fields: .legacy)
        #expect(text == "IMG_0001.jpg")
    }

    // MARK: - 字段与版式

    @Test("ContactSheetFields 编解码往返 + legacy 只含文件名")
    func fieldsCodable() throws {
        let fields: ContactSheetFields = [.filename, .rating, .keywords]
        let data = try JSONEncoder().encode(fields)
        #expect(try JSONDecoder().decode(ContactSheetFields.self, from: data) == fields)
        #expect(ContactSheetFields.legacy == [.filename])
        #expect(ContactSheetFields.legacy.needsBadgeRow == false)
        #expect(ContactSheetFields.legacy.needsKeywordRow == false)
    }

    @Test("caption 区高度：默认 18，星/色标 30，加关键词 42")
    func resolvedCaptionHeight() {
        #expect(ContactSheetOptions().resolvedCaptionHeight == 18)
        #expect(ContactSheetOptions(fields: [.filename, .rating]).resolvedCaptionHeight == 30)
        #expect(ContactSheetOptions(fields: [.filename, .label, .pick]).captionRows == 2)
        #expect(ContactSheetOptions(fields: [.filename, .keywords]).resolvedCaptionHeight == 30)
        #expect(ContactSheetOptions(fields: [.filename, .rating, .keywords])
            .resolvedCaptionHeight == 42)
    }

    // MARK: - 展示模型

    @Test("星级串固定 5 格；None/空白色标折成 nil")
    func presentationHelpers() {
        #expect(item(rating: 0).ratingStars == "☆☆☆☆☆")
        #expect(item(rating: 3).ratingStars == "★★★☆☆")
        #expect(item(label: "None").effectiveLabel == nil)
        #expect(item(label: " ").effectiveLabel == nil)
        #expect(item(label: "Red").effectiveLabel == "Red")
        #expect(item().hasMetadata)
        #expect(DeliveryPresentationItem(photoId: "p", filename: "a.jpg").hasMetadata == false)
    }

    @Test("C1 色标表：8 色有 hex，None 没有")
    func colorPalette() {
        #expect(ColorLabelPalette.hex(for: "Red") == "#d92e2e")
        #expect(ColorLabelPalette.rgb(for: "none") == nil)
        #expect(ColorLabelPalette.hex(for: "Rainbow") == nil)
        #expect(ColorLabelPalette.rgb(for: "Blue") != nil)
    }

    @Test("ContactSheetItem 保留 path/caption 兼容入口")
    func itemCompat() {
        let legacy = ContactSheetItem(path: "/tmp/a/IMG_9.jpg", caption: "IMG_9.jpg")
        #expect(legacy.path == "/tmp/a/IMG_9.jpg")
        #expect(legacy.caption == "IMG_9.jpg")
        #expect(legacy.presentation.filename == "IMG_9.jpg")

        let modern = ContactSheetItem(presentation: item())
        #expect(modern.caption == "IMG_0001.jpg", "缺省 caption = 文件名")
        #expect(modern.path == "/tmp/p1.jpg")
    }

    // MARK: - 渲染

    @Test("带元数据的联系表：照常出页，且多行 caption 不压图")
    func rendersWithMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-sheet-meta-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var items: [ContactSheetItem] = []
        for index in 0..<3 {
            let path = directory.appendingPathComponent("IMG_\(index).jpg").path
            try makeSheetJPEG(at: path)
            var presentation = item()
            presentation.photoId = "p\(index)"
            presentation.filePath = path
            presentation.filename = "IMG_\(index).jpg"
            items.append(ContactSheetItem(
                presentation: presentation,
                caption: CaptionFormatter.format(
                    "{filename} {rating}", item: presentation,
                    fields: [.filename, .rating])))
        }
        let output = directory.appendingPathComponent("sheet.pdf")
        let result = try ContactSheetRenderer.render(
            items: items,
            options: ContactSheetOptions(
                columns: 2, rows: 2, fields: [.filename, .rating, .label, .pick, .keywords]),
            to: output)
        #expect(result.pages == 1)
        #expect(result.failedImages == 0)
        #expect(result.bytes > 1000)
        let document = try #require(CGPDFDocument(URL(fileURLWithPath: output.path) as CFURL))
        #expect(document.numberOfPages == 1)
    }

    @Test("默认 fields：版式与升级前一致（captionHeight 仍 18）")
    func defaultLayoutUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-sheet-default-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("IMG_0.jpg").path
        try makeSheetJPEG(at: path)
        let output = directory.appendingPathComponent("sheet.pdf")
        let result = try ContactSheetRenderer.render(
            items: [ContactSheetItem(path: path, caption: "IMG_0.jpg")],
            options: ContactSheetOptions(columns: 1, rows: 1), to: output)
        #expect(result.pages == 1)
        #expect(ContactSheetOptions().fields == .legacy)
    }

    // MARK: - data.json v1/v2

    @Test("data.json v1（顶层数组）仍可解；v2 对象往返")
    func galleryDataFileCompatibility() throws {
        let v1 = Data("""
        [{"id":"p1","name":"a.jpg","caption":"","thumb":"thumbs/0001.jpg",
          "large":"large/0001.jpg","width":2,"height":3}]
        """.utf8)
        let decodedV1 = try GalleryDataFile.load(v1)
        #expect(decodedV1.version == 1)
        #expect(decodedV1.items.count == 1)
        #expect(decodedV1.items[0].rating == nil, "v1 没有元数据字段")

        let entry = GalleryEntry(
            id: "p1", name: "a.jpg", caption: "主图",
            thumb: "thumbs/0001.jpg", large: "large/0001.jpg",
            width: 6000, height: 4000,
            title: "封面", rating: 4, label: "Green", pick: .picked,
            keywords: ["婚礼"], captureTime: "2026-10-29", triage: "keep")
        let v2 = try JSONEncoder().encode(
            GalleryDataFile(version: GalleryDataFile.currentVersion, items: [entry]))
        let text = try #require(String(data: v2, encoding: .utf8))
        #expect(text.contains("\"version\":2"))
        let roundTrip = try GalleryDataFile.load(v2)
        #expect(roundTrip.version == 2)
        #expect(roundTrip.items == [entry])
    }

    // MARK: - 发布白名单

    @Test("严格白名单：thumbs/画廊入口/联系表通过，manifest/成片被排除")
    func allowlistExcludesOriginals() {
        #expect(WebDAVPublisher.isShareArtifact("thumbs/0001.jpg", allowDownload: true))
        #expect(WebDAVPublisher.isShareArtifact("gallery/thumbs/0001.jpg", allowDownload: true))
        #expect(WebDAVPublisher.isShareArtifact("gallery/index.html", allowDownload: false))
        #expect(WebDAVPublisher.isShareArtifact("gallery/data.json", allowDownload: false))
        #expect(WebDAVPublisher.isShareArtifact("gallery/proof.html", allowDownload: false))
        #expect(WebDAVPublisher.isShareArtifact("contact-sheet-20261030-101010.pdf", allowDownload: false))
        #expect(WebDAVPublisher.isShareArtifact("manifest-abc.json", allowDownload: false) == false,
                "Wave4b：manifest-* 含本机路径/审计信息，永不进分享产物")
        #expect(WebDAVPublisher.isShareArtifact("share.json", allowDownload: false))
        // 成片与无关键产物不上传
        #expect(WebDAVPublisher.isShareArtifact("Web 2048/IMG_0001.jpg", allowDownload: true) == false)
        #expect(WebDAVPublisher.isShareArtifact("notes.txt", allowDownload: false) == false)
        // allowDownload=false 时大图也不上传
        #expect(WebDAVPublisher.isShareArtifact("gallery/large/0001.jpg", allowDownload: true))
        #expect(WebDAVPublisher.isShareArtifact("gallery/large/0001.jpg", allowDownload: false) == false)
    }

    @Test("requiresDownload：thumbs 之外的所有图片都需要下载权限")
    func requiresDownload() {
        #expect(WebDAVPublisher.requiresDownload("thumbs/0001.jpg") == false)
        #expect(WebDAVPublisher.requiresDownload("gallery/thumbs/0001.jpg") == false)
        #expect(WebDAVPublisher.requiresDownload("gallery/large/0001.jpg"))
        #expect(WebDAVPublisher.requiresDownload("Web 2048/IMG_0001.jpg"))
        #expect(WebDAVPublisher.requiresDownload("gallery/index.html") == false)
    }

    @Test("share.json：带 allowDownload / expiresAt / itemCount")
    func shareManifest() throws {
        let share = OutputShareOptions(
            allowDownload: false, expiresAt: "2026-11-30T00:00:00Z",
            remoteSubfolder: "client/wedding")
        let data = WebDAVPublisher.shareManifestJSON(
            share: share, itemCount: 12, createdAt: "2026-10-30T00:00:00Z")
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"allowDownload\" : false"))
        #expect(text.contains("2026-11-30T00:00:00Z"))
        #expect(text.contains("\"itemCount\" : 12"))
    }

    // MARK: - 画廊产物（v2 HTML/JSON）

    @Test("画廊产物：data.json v2 + index 叠星条/色标 + proof 有星级与评论")
    func galleryArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-gallery-v2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("IMG_0001.jpg").path
        try makeSheetJPEG(at: source)
        var presentation = item()
        presentation.photoId = "p1"
        presentation.filePath = source
        presentation.filename = "IMG_0001.jpg"
        let result = try GalleryBuilder.build(
            items: [GalleryItem(presentation: presentation)],
            options: GalleryOptions(title: "婚礼", fields: [.rating, .label, .pick]),
            destination: directory.appendingPathComponent("gallery"))
        #expect(result.itemCount == 1)
        #expect(result.skipped == 0)

        let dataFile = try GalleryDataFile.load(Data(contentsOf: URL(
            fileURLWithPath: directory.appendingPathComponent("gallery/data.json").path)))
        #expect(dataFile.version == 2)
        #expect(dataFile.items.first?.rating == 4)
        #expect(dataFile.items.first?.label == "Green")
        #expect(dataFile.items.first?.pick == .picked)

        let index = try String(
            contentsOf: directory.appendingPathComponent("gallery/index.html"),
            encoding: .utf8)
        #expect(index.contains("data-rating=\"4\""))
        #expect(index.contains("data-label=\"Green\""))
        #expect(index.contains("data-thumb=\"thumbs/0001.jpg\""), "灯箱大图缺失时回退缩略图")
        #expect(index.contains("class=\"badge\""))

        let proof = try String(
            contentsOf: directory.appendingPathComponent("gallery/proof.html"),
            encoding: .utf8)
        #expect(proof.contains("class=\"star\""), "校样页必须有星级按钮")
        #expect(proof.contains("<select class=\"label\""), "校样页必须有色标下拉")
        #expect(proof.contains("<textarea class=\"comment\""), "校样页必须有评论框")

        let proofJS = try String(
            contentsOf: directory.appendingPathComponent("gallery/proof.js"),
            encoding: .utf8)
        #expect(proofJS.contains("gather-proof-v2"))
        #expect(proofJS.contains("version: 2"))
        #expect(proofJS.contains("LEGACY_KEY"), "v1 勾选要能迁移")
    }

    @Test("proof 页 fail-closed / 到期只读守卫（Wave4a-C1/C2）")
    func proofPageFailClosedGuards() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-gallery-guards-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("IMG_0001.jpg").path
        try makeSheetJPEG(at: source)
        var presentation = item()
        presentation.photoId = "p1"
        presentation.filePath = source
        presentation.filename = "IMG_0001.jpg"
        _ = try GalleryBuilder.build(
            items: [GalleryItem(presentation: presentation)],
            options: GalleryOptions(title: "婚礼", fields: [.rating, .label, .pick]),
            destination: directory.appendingPathComponent("gallery"))

        let proofHTML = try String(
            contentsOf: directory.appendingPathComponent("gallery/proof.html"),
            encoding: .utf8)
        #expect(proofHTML.contains("gate-pending"), "初始内容必须默认不可见（拿到配置再放行）")

        let proofJS = try String(
            contentsOf: directory.appendingPathComponent("gallery/proof.js"),
            encoding: .utf8)
        // C2：到期后 submit early return + 下载按钮 disable。
        #expect(proofJS.contains("var expired = false;"))
        #expect(proofJS.contains("if (expired || shareLoadFailed) { return; }"))
        #expect(proofJS.contains("expiredDownload.disabled = true;"))
        // C1：http(s) 拿不到 share.json 时保持门槛关闭；file:// 本地预览保留旧回退。
        #expect(proofJS.contains("var shareLoadFailed = false;"))
        #expect(proofJS.contains("function handleShareUnavailable()"))
        #expect(proofJS.contains("shareLoadFailed = true;"))
        #expect(proofJS.contains("window.location.protocol === 'file:'"))
    }
}
