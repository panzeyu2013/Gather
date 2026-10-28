// desktop/native/gather-app/Tests/GatherAppTests/MetadataWriteRouterTests.swift
// 写目标策略与路由：JPEG 内嵌 / sidecar / RAW 的选择，以及 backup→write→restore 闭环。

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GatherApplication
import GatherProtocol
@testable import GatherHost

private func routerFixtureJPEG() throws -> Data {
    let width = 32
    let height = 24
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    let finalized = CGImageDestinationFinalize(destination)
    #expect(finalized)
    return data as Data
}

private func makeRouterDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-router-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

@Suite("元数据写目标路由")
struct MetadataWriteRouterTests {

    @Test("策略表：非 JPEG/已有 sidecar/模式")
    func policyTable() {
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.CR3", mode: "embedded", sidecarExists: false, isJPEG: false) == .sidecar)
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.jpg", mode: "embedded", sidecarExists: true, isJPEG: true) == .sidecar)
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.jpg", mode: "embedded", sidecarExists: false, isJPEG: true) == .embedded)
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.JPG", mode: "auto", sidecarExists: false, isJPEG: true) == .embedded)
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.jpg", mode: "sidecar", sidecarExists: false, isJPEG: true) == .sidecar)
        #expect(MetadataTargetPolicy.resolve(
            photoPath: "/a.jpg", mode: "unknown", sidecarExists: false, isJPEG: true) == .sidecar)
    }

    @Test("独立 JPEG + embedded：写进 JPEG，不创建 .xmp")
    func writesEmbeddedWithoutSidecar() async throws {
        let dir = try makeRouterDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("IMG_0001.jpg")
        try routerFixtureJPEG().write(to: URL(fileURLWithPath: path))
        let router = MetadataWriteRouter(modeProvider: { "embedded" })
        #expect(router.target(for: path).kind == .embedded)

        var descriptive = DescriptiveMetadata()
        descriptive.set(.text("内嵌标题"), for: .caption)
        try await router.writeAttributes(
            photoPath: path, attributes: MetadataWriteAttributes(descriptive: descriptive))

        let sidecarPath = SidecarXMPProvider.resolveSidecarPath(path)
        #expect(!FileManager.default.fileExists(atPath: sidecarPath), "内嵌模式不得创建 sidecar")
        let attributes = try await router.readAttributes(photoPath: path)
        #expect(attributes.descriptive?.caption == "内嵌标题")
    }

    @Test("已有 .xmp：即使模式为 embedded 也写 sidecar（一份真相）")
    func sidecarWinsWhenPresent() async throws {
        let dir = try makeRouterDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("IMG_0002.jpg")
        try routerFixtureJPEG().write(to: URL(fileURLWithPath: path))
        let sidecarPath = SidecarXMPProvider.resolveSidecarPath(path)
        try Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\"/></rdf:RDF></x:xmpmeta>".utf8)
            .write(to: URL(fileURLWithPath: sidecarPath))

        let router = MetadataWriteRouter(modeProvider: { "embedded" })
        #expect(router.target(for: path).kind == .sidecar)
        var descriptive = DescriptiveMetadata()
        descriptive.set(.text("sidecar 标题"), for: .caption)
        try await router.writeAttributes(
            photoPath: path, attributes: MetadataWriteAttributes(descriptive: descriptive))
        let sidecarAttributes = try await SidecarXMPProvider().readAttributes(photoPath: path)
        #expect(sidecarAttributes.descriptive?.caption == "sidecar 标题")
    }

    @Test("RAW 永远走 sidecar")
    func rawAlwaysSidecar() async throws {
        let dir = try makeRouterDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("IMG_0003.CR3")
        try Data([0x00]).write(to: URL(fileURLWithPath: path))
        let router = MetadataWriteRouter(modeProvider: { "auto" })
        #expect(router.target(for: path).kind == .sidecar)
    }

    @Test("embedded backup → write → restore：元数据回到原值")
    func backupWriteRestore() async throws {
        let dir = try makeRouterDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("IMG_0004.jpg")
        try routerFixtureJPEG().write(to: URL(fileURLWithPath: path))
        let router = MetadataWriteRouter(modeProvider: { "embedded" })

        var descriptive = DescriptiveMetadata()
        descriptive.set(.text("写入值"), for: .caption)
        let backup = try await router.backup(photoPath: path)
        #expect(!backup.isEmpty)
        try await router.writeAttributes(
            photoPath: path, attributes: MetadataWriteAttributes(descriptive: descriptive))
        let written = try await router.readAttributes(photoPath: path)
        #expect(written.descriptive?.caption == "写入值")

        try await router.restore(photoPath: path, backupPath: backup)
        let restored = try await router.readAttributes(photoPath: path)
        #expect(restored.descriptive?.caption == nil)
    }


    @Test("RAW 兄弟存在时 JPEG 跟随 sidecar，避免两个真相源")
    func rawSiblingForcesSidecar() throws {
        let dir = try makeRouterDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jpegPath = dir + "/IMG_0001.JPG"
        try routerFixtureJPEG().write(to: URL(fileURLWithPath: jpegPath))
        // 同 basename 的 RAW 兄弟。
        try Data("raw".utf8).write(to: URL(fileURLWithPath: dir + "/IMG_0001.CR3"))
        let router = MetadataWriteRouter(modeProvider: { "auto" })
        let target = router.target(for: jpegPath)
        #expect(target.kind == .sidecar, "有 RAW 兄弟时不能写内嵌")
        #expect(target.writePath.hasSuffix(".xmp"))
    }
}
