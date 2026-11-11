// desktop/native/gather-core/Tests/GatherCoreTests/MetadataIO/MetadataAttributesTests.swift
// Wave5（batch2）收口：JPEG 内嵌读表（MetadataAttributes.embeddedDescriptiveFields）
// 必须收录 task-12 新增的 4 个 IPTC 字段，否则默认 auto 的 JPEG 内嵌写入会在
// 写后校验时读不到字段而失败回滚。
//
// 两层用例：
// 1. 纯映射（合成 MetadataParseSegments）：XMP 文本/Bag 读回、IIM 2:40 回退、
//    "XMP 显式清空阻断 IIM 复活"、标量按单元素列表读；
// 2. 真实 JPEG 往返：JPEGMetadataWriter.write → ImageIO 读回 → 四字段齐全，
//    且 IIM 只出现 instructions（2:40），其余字段不编造 dataset。
import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GatherAnalysis
import GatherProtocol
@testable import GatherMetadataIO

/// 夹具在测试内用 ImageIO 生成，不依赖仓库二进制文件。
private func wave5FixtureJPEG() throws -> Data {
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
    CGImageDestinationAddImage(destination, image, nil)
    let finalized = CGImageDestinationFinalize(destination)
    #expect(finalized)
    return data as Data
}

@Suite("内嵌描述性元数据映射（Wave5 字段）")
struct MetadataAttributesTests {

    @Test("XMP 分段读回：instructions 文本 + eventIdentifier/releaseID Bag")
    func embeddedReadsWave5Fields() throws {
        let parsed = MetadataParseSegments(
            xmp: .object([
                "Instructions": .string("禁发至 2026-12-01"),
                "EventId": .array([.string("urn:event:acme-2026")]),
                "ModelReleaseID": .array([.string("MR-0001"), .string("MR-0002")]),
                "PropertyReleaseID": .array([.string("PR-0001")]),
            ]),
            xmpPresentKeys: ["Instructions", "EventId", "ModelReleaseID", "PropertyReleaseID"])
        let descriptive = try #require(
            MetadataAttributes.embeddedAttributesFromParse(parsed)?.descriptive)
        #expect(descriptive.instructions == "禁发至 2026-12-01")
        #expect(descriptive.eventIdentifier == ["urn:event:acme-2026"])
        #expect(descriptive.modelReleaseID == ["MR-0001", "MR-0002"])
        #expect(descriptive.propertyReleaseID == ["PR-0001"])
    }

    @Test("IIM 回退：Instructions 读 2:40（ImageIO 键名 SpecialInstructions）")
    func instructionsFallsBackToIIM() throws {
        let parsed = MetadataParseSegments(
            iptc: .object(["SpecialInstructions": .string("仅限一次使用")]))
        let descriptive = try #require(
            MetadataAttributes.embeddedAttributesFromParse(parsed)?.descriptive)
        #expect(descriptive.instructions == "仅限一次使用", "Bridge/C1 只写 IIM 的旧文件也要能读")
    }

    @Test("XMP 显式清空阻断 IIM 复活：空 Instructions 不得回退到 2:40 旧值")
    func explicitEmptyXMPBlocksIIMFallback() throws {
        let parsed = MetadataParseSegments(
            xmp: .object(["Instructions": .string("")]),
            dc: .object(["title": .string("标题")]),
            iptc: .object(["SpecialInstructions": .string("旧禁发令")]),
            xmpPresentKeys: ["Instructions"])
        let descriptive = try #require(
            MetadataAttributes.embeddedAttributesFromParse(parsed)?.descriptive)
        #expect(descriptive.title == "标题", "夹具必须让 descriptive 非空（否则返回 nil）")
        #expect(descriptive.instructions == nil, "清空后旧 IIM 不得把字段复活")
    }

    @Test("列表字段标量形态：外部只写一个值时按单元素列表读回")
    func scalarBecomesSingleItemList() throws {
        let parsed = MetadataParseSegments(
            xmp: .object(["ModelReleaseID": .string("MR-9")]),
            xmpPresentKeys: ["ModelReleaseID"])
        let descriptive = try #require(
            MetadataAttributes.embeddedAttributesFromParse(parsed)?.descriptive)
        #expect(descriptive.modelReleaseID == ["MR-9"])
    }

    @Test("JPEG 内嵌往返：四字段写完 ImageIO 读得回（写后校验不会回滚）")
    func embeddedJPEGRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-wave5-embedded-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("IMG_WAVE5.jpg").path
        try wave5FixtureJPEG().write(to: URL(fileURLWithPath: path))

        var descriptive = DescriptiveMetadata()
        descriptive.set(.text("禁发至 2026-12-01"), for: .instructions)
        descriptive.set(.list(["urn:event:acme-2026"]), for: .eventIdentifier)
        descriptive.set(.list(["MR-0001", "MR-0002"]), for: .modelReleaseID)
        descriptive.set(.list(["PR-0001"]), for: .propertyReleaseID)
        // write 内部会按 ImageIO 回读做逐字段校验；读不到字段会抛错并回滚。
        _ = try await JPEGMetadataWriter.write(
            photoPath: path, attributes: MetadataWriteAttributes(descriptive: descriptive))

        let parsed = try await ImageIOExifProvider().parse(filePath: path, isJpeg: true)
        let readBack = try #require(
            parsed.flatMap(MetadataAttributes.embeddedAttributesFromParse)?.descriptive)
        #expect(readBack.instructions == "禁发至 2026-12-01")
        #expect(readBack.eventIdentifier == ["urn:event:acme-2026"])
        #expect(readBack.modelReleaseID == ["MR-0001", "MR-0002"])
        #expect(readBack.propertyReleaseID == ["PR-0001"])

        // IIM 侧只有 instructions（2:40）；其余三个字段没有 dataset，不得被编造。
        let after = try JPEGDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let resources = after.photoshopIRB.flatMap { try? PhotoshopIRBList.parse($0) }
        let iim = resources?
            .first(where: { $0.resourceID == PhotoshopIRB.iptcNAA })
            .flatMap { try? IPTCIIM.parse($0.data) }
        #expect(iim?.values(for: .specialInstructions) == ["禁发至 2026-12-01"])
        #expect(iim?.values(for: .byline).isEmpty == true, "未写其它字段")
    }
}
