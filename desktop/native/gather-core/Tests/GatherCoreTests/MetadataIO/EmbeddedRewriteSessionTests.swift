// desktop/native/gather-core/Tests/GatherCoreTests/MetadataIO/EmbeddedRewriteSessionTests.swift
// P1 下一波 §3.2：内嵌写回"一次打开、顺序遍历"会话的验收测试。
//
// 钉死的四件事：
// 1) 读放大：一次写回的总读取字节 ≤ 2.1 × 文件大小（旧路径是 6–8 倍）；
// 2) 字节保真：扫描段 SHA 不变、除 XMP/APP13 外的段逐字节相等；
// 3) 属性三态往返：rating/label/keywords/descriptive/triageSignal + 清空；
// 4) 崩溃安全：替换前任一校验/注入失败 → 原文件一个字节都没动、临时文件被删。
//
// 夹具在测试内生成（不依赖仓库二进制）：小 JPEG + 尾部填充构造 12MB 合成文件
// （尾部字节是合法 JPEG 的一部分，扫描段因此可以有任意大小）。

import Foundation
import os
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GatherApplication
import GatherDelivery
import GatherPersistence
import GatherProtocol
import GatherTestSupport
@testable import GatherMetadataIO

// MARK: - 夹具

private func sessionFixtureJPEG(iptc: [String: Any]? = nil) throws -> Data {
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
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// 小 JPEG + 尾部填充 = 指定大小的合成文件（scan 段足够大，用来量读放大）。
private func paddedJPEG(bytes: Int, iptc: [String: Any]? = nil) throws -> Data {
    let base = try sessionFixtureJPEG(iptc: iptc)
    #expect(base.count < bytes)
    var padded = base
    padded.append(Data(repeating: 0x5A, count: bytes - base.count))
    return padded
}

private func makeSessionDirectory(_ tag: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-session-" + tag + "-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeFixture(_ data: Data, name: String, in directory: URL) throws -> String {
    let path = directory.appendingPathComponent(name).path
    try data.write(to: URL(fileURLWithPath: path))
    return path
}

/// 构造一个 APP13（Photoshop IRB）段。
private func makeSessionAPP13(_ resources: [(UInt16, Data)]) -> Data {
    var payload = Data("Photoshop 3.0\0".utf8)
    for (id, data) in resources {
        payload.append(contentsOf: [0x38, 0x42, 0x49, 0x4D])  // 8BIM
        payload.append(UInt8((id >> 8) & 0xFF))
        payload.append(UInt8(id & 0xFF))
        payload.append(0)  // Pascal 名长度 0
        payload.append(0)  // 奇数补齐
        let size = data.count
        payload.append(contentsOf: [
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ])
        payload.append(data)
        if size % 2 == 1 { payload.append(0) }
    }
    var segment = Data([0xFF, 0xED])
    let length = payload.count + 2
    segment.append(UInt8((length >> 8) & 0xFF))
    segment.append(UInt8(length & 0xFF))
    segment.append(payload)
    return segment
}

/// 构造一个 XMP APP1 段（测试里手工播种 lr:hierarchicalSubject 之类写侧不产出的字段）。
private func makeXMPAPP1(_ packet: String) -> Data {
    let payload = JPEGSegment.xmpIdentifier + Data(packet.utf8)
    var segment = Data([0xFF, 0xE1])
    let length = payload.count + 2
    segment.append(UInt8((length >> 8) & 0xFF))
    segment.append(UInt8(length & 0xFF))
    segment.append(payload)
    return segment
}

/// 把 APP1 插到 SOI 之后（读侧取第一个 XMP 段，所以必须排在原有段之前）。
private func injectSessionAPP1(_ segment: Data, into data: Data) -> Data {
    var out = Data([0xFF, 0xD8])
    out.append(segment)
    out.append(data.dropFirst(2))
    return out
}

/// 把 segment 插到第一个 APP13 之后（没有 APP13 时插到 SOI 之后）。
private func injectSessionAPP13(_ segment: Data, into data: Data) throws -> Data {
    let bytes = [UInt8](data)
    var index = 2
    while index + 3 < bytes.count {
        guard bytes[index] == 0xFF else { break }
        let marker = bytes[index + 1]
        if marker == 0xDA { break }
        let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
        let end = index + 2 + length
        if marker == 0xED {
            var out = Data(bytes[0..<end])
            out.append(segment)
            out.append(contentsOf: bytes[end...])
            return out
        }
        index = end
    }
    var out = Data(bytes[0..<2])
    out.append(segment)
    out.append(contentsOf: bytes[2...])
    return out
}

/// 线程安全的读字节累加器（hooks 是 @Sendable）。
private final class ReadCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

    func add(_ count: Int) {
        lock.withLock { $0 += count }
    }

    var value: Int {
        lock.withLock { $0 }
    }
}

/// 注入型错误（模拟校验/替换前失败）。
private struct InjectedFailure: Error {}

private func writeFailurePaths(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.contains(".gather-embedded-") }
}

// MARK: - 测试

@Suite("内嵌写回会话（一次读）")
struct EmbeddedRewriteSessionTests {

    @Test("12MB 合成 JPEG：一次写回总读取 ≤ 2.1×，扫描段 SHA 不变")
    func rewriteReadsAtMostTwiceFileSize() async throws {
        let directory = try makeSessionDirectory("budget")
        defer { removeQuietly(directory) }
        let fileSize = 12 * 1024 * 1024
        let original = try paddedJPEG(bytes: fileSize, iptc: ["Keywords": ["old"], "City": "Shanghai"])
        let path = try writeFixture(original, name: "IMG_0001.jpg", in: directory)
        let before = try JPEGDocument(data: original)

        let counter = ReadCounter()
        let hooks = EmbeddedJPEGSessionHooks(onReadBytes: { counter.add($0) })
        let session = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: hooks))
        let snapshotBytes = counter.value
        #expect(snapshotBytes == fileSize, "快照必须只顺序读一遍（逐块读满文件）")
        #expect(session.headerByteCount < 64 * 1024, "夹具头部应当很小")
        #expect(session.fingerprintBefore == (try await MetadataFingerprint.contentFingerprint(path)),
                "写前指纹必须与 MetadataFingerprint 同格式同值")

        let report = try await session.commit(MetadataWriteAttributes(
            keywords: ["k1", "k2"], rating: 4, label: "Green",
            descriptive: DescriptiveMetadata(caption: "新标题")))
        let totalBytes = counter.value
        let after = try JPEGDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))

        #expect(Double(totalBytes) <= 2.1 * Double(fileSize),
                "总读取 \(totalBytes) 超过 2.1×(\(fileSize))")
        #expect(after.scanDigest == before.scanDigest, "扫描段必须逐字节不变")
        #expect(report.scanDigest == before.scanDigest)
        #expect(report.bytesBefore == Int64(fileSize))
        #expect(report.bytesAfter == Int64(after.scanOffset) + Int64(after.scan.count))
        #expect(report.fingerprintAfter == (try await MetadataFingerprint.contentFingerprint(path)),
                "写后指纹必须与整文件指纹一致（增量算出的 SHA 不得漂移）")
        #expect(try writeFailurePaths(in: directory).isEmpty, "成功路径不得留下临时文件")
    }

    @Test("除 XMP/APP13 外的段逐字节相等（段表结构不变）")
    func keepsNonEditedSegmentsByteIdentical() async throws {
        let directory = try makeSessionDirectory("segments")
        defer { removeQuietly(directory) }
        let original = try sessionFixtureJPEG(iptc: ["Keywords": ["a"], "City": "Shanghai"])
        let path = try writeFixture(original, name: "IMG_0002.jpg", in: directory)
        let before = try JPEGDocument(data: original)

        let session = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 64 * 1024, hooks: .init()))
        _ = try await session.commit(MetadataWriteAttributes(keywords: ["b"], rating: 2))

        let after = try JPEGDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let beforeOthers = before.segments.filter { !$0.isXMP && !$0.isPhotoshop }
        let afterOthers = after.segments.filter { !$0.isXMP && !$0.isPhotoshop }
        #expect(beforeOthers == afterOthers)
        #expect(after.scan.count == before.scan.count)
    }

    @Test("属性三态往返：写入 → 读回一致；清空 → 读回空；triage 信号可清除")
    func attributesRoundTrip() async throws {
        let directory = try makeSessionDirectory("roundtrip")
        defer { removeQuietly(directory) }
        let original = try sessionFixtureJPEG(iptc: ["Keywords": ["old"], "City": "Shanghai"])
        let path = try writeFixture(original, name: "IMG_0003.jpg", in: directory)

        var descriptive = DescriptiveMetadata()
        descriptive.set(.text("标题"), for: .title)
        descriptive.set(.text("说明"), for: .caption)
        descriptive.set(.list(["作者A"]), for: .creator)
        descriptive.set(.text("北京"), for: .city)
        descriptive.contactInfo = DescriptiveContact(email: "a@example.com", url: "https://example.com")
        let written = MetadataWriteAttributes(
            keywords: ["婚礼", "probe"], rating: 5, label: "Red",
            descriptive: descriptive, triageSignal: "keep")

        let writer = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        let report = try await writer.commit(written)
        #expect(report.touchedIIM, "有 descriptive 变更就必须写 APP13")

        let reader = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        #expect(reader.attributes.keywords == ["婚礼", "probe"])
        #expect(reader.attributes.rating == 5)
        #expect(reader.attributes.label == "Red")
        #expect(reader.attributes.triageSignal == "keep")
        #expect(reader.attributes.descriptive?.title == "标题")
        #expect(reader.attributes.descriptive?.caption == "说明")
        #expect(reader.attributes.descriptive?.creator == ["作者A"])
        #expect(reader.attributes.descriptive?.city == "北京")
        #expect(reader.attributes.descriptive?.contactInfo?.email == "a@example.com")
        #expect(reader.attributes.descriptive?.contactInfo?.url == "https://example.com")

        // 清空：关键词空数组、描述性字段留空、triage 信号空串。
        var cleared = DescriptiveMetadata()
        cleared.set(.text(""), for: .title)
        cleared.set(.text(""), for: .city)
        let clearer = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        _ = try await clearer.commit(MetadataWriteAttributes(
            keywords: [], descriptive: cleared, triageSignal: ""))
        let afterClear = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        #expect(afterClear.attributes.keywords == nil)
        #expect(afterClear.attributes.triageSignal == nil)
        #expect(afterClear.attributes.descriptive?.title == nil)
        #expect(afterClear.attributes.descriptive?.city == nil)
        // 没被清空的字段必须保留（三态：nil = 不触碰）。
        #expect(afterClear.attributes.descriptive?.caption == "说明")
        #expect(afterClear.attributes.descriptive?.creator == ["作者A"])
    }

    @Test("多个 APP13：写 IIM 时合并全部资源，非 0x0404 资源逐字节保留")
    func preservesMultipleAPP13Resources() async throws {
        let directory = try makeSessionDirectory("app13")
        defer { removeQuietly(directory) }
        let base = try sessionFixtureJPEG(iptc: ["Keywords": ["old"]])
        let extra = makeSessionAPP13([
            (0x0425, Data(repeating: 0xAA, count: 32)),
            (0x0409, Data([0x01, 0x02, 0x03])),
        ])
        let original = try injectSessionAPP13(extra, into: base)
        let path = try writeFixture(original, name: "IMG_0004.jpg", in: directory)
        let before = try JPEGDocument(data: original)
        #expect(before.photoshopIRBPayloads.count == 2, "夹具必须有两个 APP13")

        let session = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        var descriptive = DescriptiveMetadata()
        descriptive.set(.text("新标题"), for: .caption)
        _ = try await session.commit(MetadataWriteAttributes(
            keywords: ["old"], descriptive: descriptive))

        let after = try JPEGDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
        var resources: [PhotoshopIRB] = []
        for payload in after.photoshopIRBPayloads {
            resources.append(contentsOf: try PhotoshopIRBList.parse(payload))
        }
        #expect(resources.contains { $0.resourceID == PhotoshopIRB.iptcNAA })
        #expect(resources.contains { $0.resourceID == 0x0425 })
        #expect(resources.contains { $0.resourceID == 0x0409 })
        // ImageIO 自己会写一个 0x0425（Caption digest，16 字节），所以按"注入的资源还在"断言。
        let nonIIM = resources.filter { $0.resourceID != PhotoshopIRB.iptcNAA }
        #expect(nonIIM.contains { $0.resourceID == 0x0425 && $0.data == Data(repeating: 0xAA, count: 32) })
        #expect(nonIIM.contains { $0.resourceID == 0x0409 && $0.data == Data([0x01, 0x02, 0x03]) })
        #expect(nonIIM.count == 3, "ImageIO 的 16 字节 0x0425 + 注入的 0x0425 + 0x0409 之外的资源不得丢失或新增")
        let iimResource = resources.first { $0.resourceID == PhotoshopIRB.iptcNAA }
        let iim = iimResource.flatMap { resource in
            doOrNil { try IPTCIIM.parse(resource.data) }
        }
        #expect(iim?.values(for: .caption) == ["新标题"])
    }

    @Test("替换前失败：原文件一个字节不变，临时文件被删")
    func failureBeforeInstallLeavesOriginalUntouched() async throws {
        let directory = try makeSessionDirectory("crash-install")
        defer { removeQuietly(directory) }
        let original = try sessionFixtureJPEG(iptc: ["Keywords": ["old"]])
        let path = try writeFixture(original, name: "IMG_0005.jpg", in: directory)

        let hooks = EmbeddedJPEGSessionHooks(beforeInstall: { throw InjectedFailure() })
        let session = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: hooks))
        await #expect(throws: InjectedFailure.self) {
            _ = try await session.commit(MetadataWriteAttributes(keywords: ["new"], rating: 3))
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original,
                "替换前失败绝不能改原文件")
        #expect(try writeFailurePaths(in: directory).isEmpty, "失败必须删掉临时文件")
    }

    @Test("校验阶段失败：原文件不变、临时文件被删（无回滚路径）")
    func failureDuringVerificationLeavesOriginalUntouched() async throws {
        let directory = try makeSessionDirectory("crash-verify")
        defer { removeQuietly(directory) }
        let original = try sessionFixtureJPEG()
        let path = try writeFixture(original, name: "IMG_0006.jpg", in: directory)

        let hooks = EmbeddedJPEGSessionHooks(beforeVerification: { throw InjectedFailure() })
        let session = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: hooks))
        await #expect(throws: InjectedFailure.self) {
            _ = try await session.commit(MetadataWriteAttributes(keywords: ["new"]))
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        #expect(try writeFailurePaths(in: directory).isEmpty)
    }

    @Test("头部备份：与旧路径同名形态、内容等于原头部、可被 restore 用")
    func headerBackupMatchesOriginalHeader() async throws {
        let directory = try makeSessionDirectory("backup")
        defer { removeQuietly(directory) }
        let original = try sessionFixtureJPEG(iptc: ["Keywords": ["old"]])
        let path = try writeFixture(original, name: "IMG_0007.jpg", in: directory)
        let before = try JPEGDocument(data: original)

        let session = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        let backupPath = try await session.writeHeaderBackup()
        #expect(backupPath.contains(".gather-header-"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath))
            == original.prefix(Int(before.scanOffset)))
        // 幂等：重复调用返回同一路径（不会堆孤儿备份）。
        #expect(try await session.writeHeaderBackup() == backupPath)

        let report = try await session.commit(MetadataWriteAttributes(keywords: ["new"]))
        #expect(report.headerBackupPath == backupPath)
        // restore 只回滚头部：scan 取当前文件的。
        try JPEGMetadataWriter.restore(photoPath: path, headerBackupPath: backupPath)
        let restored = try JPEGDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(restored.xmpPacket == before.xmpPacket)
        #expect(restored.scanDigest == before.scanDigest)
    }

    @Test("lr:hierarchicalSubject：会话把它交给 W3（不混进 dc:subject）")
    func sessionExposesHierarchicalKeywords() throws {
        let directory = try makeSessionDirectory("hierarchical")
        defer { removeQuietly(directory) }
        let packet = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:dc="http://purl.org/dc/elements/1.1/"
                xmlns:lr="http://ns.adobe.com/lightroom/1.0/">
              <dc:subject><rdf:Bag><rdf:li>叶子</rdf:li></rdf:Bag></dc:subject>
              <lr:hierarchicalSubject><rdf:Bag>
                <rdf:li>人物|新娘</rdf:li><rdf:li>地点|上海</rdf:li>
              </rdf:Bag></lr:hierarchicalSubject>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        let original = try injectSessionAPP1(makeXMPAPP1(packet), into: sessionFixtureJPEG())
        let path = try writeFixture(original, name: "IMG_0012.jpg", in: directory)
        let session = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        #expect(session.hierarchicalKeywords == ["人物|新娘", "地点|上海"])
        #expect(Set(session.attributes.keywords ?? []) == Set(["人物|新娘", "地点|上海", "叶子"]))
    }

    @Test("会话不可重入：commit 之后再次 commit / 备份都显式失败")
    func sessionIsSingleUse() async throws {
        let directory = try makeSessionDirectory("single-use")
        defer { removeQuietly(directory) }
        let original = try sessionFixtureJPEG()
        let path = try writeFixture(original, name: "IMG_0008.jpg", in: directory)
        let session = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        _ = try await session.commit(MetadataWriteAttributes(keywords: ["a"]))
        await #expect(throws: EmbeddedSessionError.self) {
            _ = try await session.commit(MetadataWriteAttributes(keywords: ["b"]))
        }
        await #expect(throws: EmbeddedSessionError.self) {
            _ = try await session.writeHeaderBackup()
        }
        await session.abort()
    }

    @Test("工厂：非 JPEG / 已有 sidecar / 开关关闭 → nil（回退旧路径）")
    func factoryFallsBackWhenNotEligible() async throws {
        let directory = try makeSessionDirectory("factory")
        defer { removeQuietly(directory) }
        let original = try sessionFixtureJPEG()
        let path = try writeFixture(original, name: "IMG_0009.jpg", in: directory)
        let rawPath = directory.appendingPathComponent("IMG_0009.dng").path
        try Data([0x00]).write(to: URL(fileURLWithPath: rawPath))

        let factory = EmbeddedJPEGSessionFactory(isEmbeddedTarget: { _ in true })
        #expect(try await factory.open(photoPath: path) != nil)
        #expect(try await factory.open(photoPath: rawPath) == nil, "非 JPEG 不得走快路径")
        #expect(try await factory.open(photoPath: directory.appendingPathComponent("missing.jpg").path) == nil)
        #expect(try await factory.open(photoPath: path) != nil)

        // 出现 .xmp 后必须回退（旧路径的读取会叠加 sidecar 覆盖）。
        try Data("<?xml version=\"1.0\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\"/></rdf:RDF></x:xmpmeta>".utf8)
            .write(to: URL(fileURLWithPath: SidecarXMPProvider.resolveSidecarPath(path)))
        #expect(try await factory.open(photoPath: path) == nil, "有 sidecar 时必须回退旧路径")

        let disabled = EmbeddedJPEGSessionFactory(isEmbeddedTarget: { _ in true }, isEnabled: { false })
        let other = try writeFixture(original, name: "IMG_0010.jpg", in: directory)
        #expect(try await disabled.open(photoPath: other) == nil, "embedded_fast_path=0 不得走快路径")
    }

    @Test("端到端：WritebackService 走会话快路径（写入成功、指纹/备份/属性一致）")
    func writebackServiceUsesSessionPath() async throws {
        let db = try makeTestDB()
        let directory = try makeSessionDirectory("service")
        defer {
            removeQuietly(directory)
            db.close()
        }
        let sessionId = "s-embedded-session"
        try insertSession(db, sessionId)
        let fileSize = 5 * 1024 * 1024
        let original = try paddedJPEG(
            bytes: fileSize, iptc: ["Keywords": ["old"], "City": "Shanghai"])
        let path = try writeFixture(original, name: "IMG_0100.jpg", in: directory)
        try insertPhoto(db, id: "p-embedded-1", sessionId: sessionId, filepath: path)
        let sidecar = SidecarXMPProvider.resolveSidecarPath(path)
        #expect(!FileManager.default.fileExists(atPath: sidecar), "夹具不应带 sidecar")

        // 生产同构：写目标由 router 解析；工厂只在 embedded 目标上接管。
        let router = MetadataWriteRouter(modeProvider: { "auto" })
        let target = MetadataTargetResolver(
            path: { router.target(for: $0).writePath },
            kind: { router.target(for: $0).kind })
        let counter = ReadCounter()
        let factory = EmbeddedJPEGSessionFactory(
            isEmbeddedTarget: { router.target(for: $0).kind == .embedded },
            hooks: EmbeddedJPEGSessionHooks(onReadBytes: { counter.add($0) }))
        let service = WritebackService(
            deliveryRepo: DeliveryRepo(connection: db),
            xmp: router,
            photoRepo: PhotoRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            connection: db,
            assetResolver: nil,
            fileLock: XMPFileLock(),
            target: target,
            rewriteSessions: factory)

        let preview = try await service.preview(
            sessionId: sessionId, module: "similarity",
            keywordAdditions: ["p-embedded-1": ["hero", "婚礼"]])
        let result = try await service.execute(
            sessionId: sessionId, module: "similarity", items: preview.items)
        #expect(result.failed == 0, "写回不得失败：\(result.errors)")
        #expect(result.written == 1)
        #expect(Double(counter.value) <= 2.1 * Double(fileSize),
                "服务层一次写回的总读取 \(counter.value) 超过 2.1×(\(fileSize))")
        #expect(!FileManager.default.fileExists(atPath: sidecar), "内嵌写回不得创建 sidecar")

        let after = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        #expect(after.attributes.keywords == ["old", "hero", "婚礼"],
                "关键词按盘上现状合并（不得丢外部词）")

        let row = try #require(try DeliveryRepo(connection: db).get(path))
        #expect(row.baseFingerprint == (try await MetadataFingerprint.contentFingerprint(path)),
                "base_fingerprint 必须用会话带回的写后指纹（不重读整文件）")
        #expect(row.backupPath.contains(".gather-header-"), "内嵌备份名形态不变")
        #expect(FileManager.default.fileExists(atPath: row.backupPath))
        #expect(row.baseValues["keywords"]?.arrayValue == ["old", "hero", "婚礼"],
                "base_values 用本项已持有的合并属性（第 8 次读已删）")
    }

    @Test("非内嵌目标判定为 nil：isEmbeddedTarget=false 全程回退")
    func factoryRespectsTargetKind() async throws {
        let directory = try makeSessionDirectory("factory-kind")
        defer { removeQuietly(directory) }
        let original = try sessionFixtureJPEG()
        let path = try writeFixture(original, name: "IMG_0011.jpg", in: directory)
        let factory = EmbeddedJPEGSessionFactory(isEmbeddedTarget: { _ in false })
        #expect(try await factory.open(photoPath: path) == nil)
    }
}

// MARK: - 测试内助手

private func removeQuietly(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        // 临时目录清理失败不影响断言（App 的临时目录会被系统回收）。
    }
}

private func doOrNil<T>(_ body: () throws -> T) -> T? {
    do {
        return try body()
    } catch {
        return nil
    }
}
