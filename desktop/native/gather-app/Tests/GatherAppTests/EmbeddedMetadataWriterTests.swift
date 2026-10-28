// desktop/native/gather-app/Tests/GatherAppTests/EmbeddedMetadataWriterTests.swift
// JPEG 内嵌写盘：IIM/IRB 编解码、XMP+IIM 双写、清空、回读校验、头部备份还原。
//
// 夹具在测试内用 ImageIO 生成，不依赖仓库二进制文件。

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GatherApplication
import GatherProtocol
@testable import GatherHost

private func embeddedFixtureJPEG(iptc: [String: Any]? = nil) throws -> Data {
    let width = 48
    let height = 32
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    for y in 0..<height {
        for x in 0..<width {
            context.setFillColor(
                red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                blue: 0.4, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if let iptc { properties[kCGImagePropertyIPTCDictionary] = iptc }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    let finalized = CGImageDestinationFinalize(destination)
    #expect(finalized)
    return data as Data
}

@Suite("JPEG 内嵌元数据写入")
struct EmbeddedMetadataWriterTests {

    // MARK: IIM / IRB 编解码

    @Test("IIM 编解码往返：多值数据集顺序稳定")
    func iimRoundTrip() throws {
        let iim = IPTCIIM(datasets: [
            IIMDataset(key: .caption, value: Data("标题".utf8)),
            IIMDataset(key: .keywords, value: Data("wedding".utf8)),
            IIMDataset(key: .keywords, value: Data("probe".utf8)),
        ])
        let encoded = try iim.encoded()
        let decoded = try IPTCIIM.parse(encoded)
        #expect(decoded == iim)
        #expect(decoded.values(for: .keywords) == ["wedding", "probe"])
    }

    @Test("IIM 替换：有值写入、空数组删除、非 ASCII 自动补 UTF-8 标志")
    func iimReplacing() throws {
        let base = IPTCIIM(datasets: [IIMDataset(key: .caption, value: Data("old".utf8))])
        let updated = try base.replacing([.caption: ["新标题"], .city: ["上海"]])
        #expect(updated.values(for: .caption) == ["新标题"])
        #expect(updated.values(for: .city) == ["上海"])
        #expect(updated.datasets.contains { $0.key == .codedCharacterSet })
        let cleared = try updated.replacing([.caption: [], .city: []])
        #expect(cleared.values(for: .caption).isEmpty)
        #expect(cleared.values(for: .city).isEmpty)
    }

    @Test("IRB 编解码往返：非 0x0404 资源逐字节保留")
    func irbRoundTrip() throws {
        let items = [
            PhotoshopIRB(resourceID: 0x0404, name: Data(), data: Data([0x1C, 0x02, 0x78, 0x00, 0x02, 0x41, 0x42])),
            PhotoshopIRB(resourceID: 0x0425, name: Data("x".utf8), data: Data([0x01, 0x02, 0x03])),
        ]
        let encoded = PhotoshopIRBList.encode(items)
        let decoded = try PhotoshopIRBList.parse(encoded)
        #expect(decoded == items)
    }

    // MARK: 端到端

    @Test("端到端：写 caption/creator/city + 清空旧 IPTC，scan 哈希不变")
    func writesAndClearsDescriptive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-embedded-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("IMG_0001.jpg").path
        let original = try embeddedFixtureJPEG(iptc: [
            "Caption/Abstract": "旧标题",
            "City": "Shanghai",
            "Keywords": ["old"],
        ])
        try original.write(to: URL(fileURLWithPath: path))

        let before = try JPEGDocument(data: original)
        var descriptive = DescriptiveMetadata()
        descriptive.set(.text("新标题"), for: .caption)
        descriptive.set(.text(""), for: .city)  // 清空
        descriptive.set(.list(["wedding"]), for: .creator)
        let attributes = MetadataWriteAttributes(
            keywords: ["wedding", "probe"],
            descriptive: descriptive)

        let report = try await JPEGMetadataWriter.write(photoPath: path, attributes: attributes)
        #expect(report.touchedIIM)
        #expect(FileManager.default.fileExists(atPath: report.headerBackupPath))
        #expect(report.scanDigest == before.scanDigest)

        let after = try JPEGDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(after.scanDigest == before.scanDigest, "scan 必须逐字节不变")
        let parsed = try await ImageIOExifProvider().parse(filePath: path, isJpeg: true)
        let attributesReadBack = try #require(parsed.flatMap(MetadataService.embeddedAttributesFromParse))
        #expect(attributesReadBack.descriptive?.caption == "新标题")
        #expect(attributesReadBack.descriptive?.city == nil, "清空必须连 IIM 一起删")
        #expect(attributesReadBack.descriptive?.creator == ["wedding"])
        #expect(attributesReadBack.keywords == ["wedding", "probe"])

        let iimValues = try #require(after.photoshopIRB).flatMap {
            try? PhotoshopIRBList.parse($0)
        }?.first(where: { $0.resourceID == PhotoshopIRB.iptcNAA }).flatMap {
            try? IPTCIIM.parse($0.data)
        }
        #expect(iimValues?.values(for: .caption) == ["新标题"])
        #expect(iimValues?.values(for: .keywords) == ["wedding", "probe"])
    }

    @Test("头部备份可还原：restore 后元数据回到原值、像素不变")
    func restoresHeaderBackup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-embedded-restore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("IMG_0002.jpg").path
        let original = try embeddedFixtureJPEG(iptc: ["Caption/Abstract": "原始标题"])
        try original.write(to: URL(fileURLWithPath: path))
        let originalDocument = try JPEGDocument(data: original)

        var descriptive = DescriptiveMetadata()
        descriptive.set(.text("写入后标题"), for: .caption)
        let report = try await JPEGMetadataWriter.write(
            photoPath: path,
            attributes: MetadataWriteAttributes(descriptive: descriptive))

        let afterWrite = try await ImageIOExifProvider().parse(filePath: path, isJpeg: true)
        #expect(afterWrite.flatMap(MetadataService.embeddedAttributesFromParse)?
            .descriptive?.caption == "写入后标题")

        try JPEGMetadataWriter.restore(photoPath: path, headerBackupPath: report.headerBackupPath)
        let restored = try JPEGDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(restored.scanDigest == originalDocument.scanDigest)
        let restoredAttributes = try await ImageIOExifProvider().parse(filePath: path, isJpeg: true)
        #expect(restoredAttributes.flatMap(MetadataService.embeddedAttributesFromParse)?
            .descriptive?.caption == "原始标题")
    }

    @Test("IIM 映射：location→2:27、intellectualGenre→2:4、scene→2:202")
    func descriptiveFieldMapsToIIM() throws {
        #expect(IPTCIIMMapping.key(for: .location) == IIMKey(record: 2, dataset: 27))
        #expect(IPTCIIMMapping.key(for: .intellectualGenre) == IIMKey(record: 2, dataset: 4))
        #expect(IPTCIIMMapping.key(for: .scene) == IIMKey(record: 2, dataset: 202))
        // XMP 独有字段不编造 dataset 号（否则会写坏别人的 IIM）。
        #expect(IPTCIIMMapping.key(for: .usageTerms) == nil)
    }

    @Test("清空 location / intellectualGenre：IIM 2:27 与 2:4 必须一起消失，回读为 nil")
    func clearsLocationAndGenre() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-embedded-clear-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("IMG_0004.jpg").path
        let original = try embeddedFixtureJPEG(iptc: [
            "ContentLocationName": "外滩",
            "ObjectAttributeReference": "纪实",
        ])
        try original.write(to: URL(fileURLWithPath: path))

        // 夹具必须真的把这两个字段写进 IIM，否则本用例测不到「删 dataset」。
        let seedDocument = try JPEGDocument(data: original)
        let seedIRB = try #require(seedDocument.photoshopIRB)
        let seedResources = try PhotoshopIRBList.parse(seedIRB)
        let seedPayload = try #require(seedResources.first { $0.resourceID == PhotoshopIRB.iptcNAA }?.data)
        let seedIIM = try IPTCIIM.parse(seedPayload)
        #expect(seedIIM.values(for: .contentLocationName) == ["外滩"])
        #expect(seedIIM.values(for: .objectAttributeReference) == ["纪实"])

        var descriptive = DescriptiveMetadata()
        descriptive.set(.text(""), for: .location)
        descriptive.set(.text(""), for: .intellectualGenre)
        _ = try await JPEGMetadataWriter.write(
            photoPath: path, attributes: MetadataWriteAttributes(descriptive: descriptive))

        let after = try JPEGDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let afterIRB = try #require(after.photoshopIRB)
        let afterResources = try PhotoshopIRBList.parse(afterIRB)
        let afterPayload = try #require(afterResources.first { $0.resourceID == PhotoshopIRB.iptcNAA }?.data)
        let afterIIM = try IPTCIIM.parse(afterPayload)
        #expect(afterIIM.values(for: .contentLocationName).isEmpty, "清空必须删掉 2:27")
        #expect(afterIIM.values(for: .objectAttributeReference).isEmpty, "清空必须删掉 2:4")

        let readBack = try await ImageIOExifProvider().parse(filePath: path, isJpeg: true)
        let attributes = readBack.flatMap(MetadataService.embeddedAttributesFromParse)
        #expect(attributes?.descriptive?.location == nil, "读侧不得回退到旧 IIM")
        #expect(attributes?.descriptive?.intellectualGenre == nil)
    }

    @Test("空属性集拒绝写入（不制造空 XMP 段）")
    func rejectsEmptyAttributes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-embedded-empty-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("IMG_0003.jpg").path
        try embeddedFixtureJPEG().write(to: URL(fileURLWithPath: path))
        await #expect(throws: JPEGMetadataWriterError.self) {
            _ = try await JPEGMetadataWriter.write(
                photoPath: path, attributes: MetadataWriteAttributes())
        }
    }
}
