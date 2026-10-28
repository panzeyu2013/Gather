// desktop/native/gather-app/Tests/GatherAppTests/DeliveryFilePortTests.swift
// 交付文件端口的删除守卫：只允许元数据载体与受控备份，绝不删照片原片。

import Foundation
import Testing
import GatherDelivery
import GatherProtocol
@testable import GatherHost

@Suite("交付文件端口（删除守卫）")
struct DeliveryFilePortTests {
    private func makeTempFile(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-port-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("受控备份名可以删除（finalize 依赖）")
    func removesControlledBackups() async throws {
        let port = XMPDeliveryFilePort(SidecarXMPProvider())
        for name in ["a.xmp.gather-backup-123", "IMG_1.JPG.gather-header-abc"] {
            let path = try makeTempFile(name)
            defer { try? FileManager.default.removeItem(atPath: path) }
            try await port.removeFile(path)
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test("照片原片绝不允许通过该端口删除")
    func refusesPhotoFile() async throws {
        let path = try makeTempFile("IMG_1.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let port = XMPDeliveryFilePort(SidecarXMPProvider())
        var didThrow = false
        do {
            try await port.removeFile(path)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("sidecar 仍可删除")
    func removesSidecar() async throws {
        let path = try makeTempFile("IMG_1.xmp")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let port = XMPDeliveryFilePort(SidecarXMPProvider())
        try await port.removeFile(path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
