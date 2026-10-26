// desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryBackupPathTests.swift
// P2-12：backup_path 的受控目录/前缀/常规文件校验。

import GatherProtocol
import Foundation
import Testing
@testable import GatherDelivery
@testable import GatherPersistence

struct DeliveryBackupPathTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-backup-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func acceptsSiblingRegularBackupWithExpectedPrefix() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let xmp = directory.appendingPathComponent("IMG_1.xmp").path
        let backup = xmp + ".gather-backup-" + UUID().uuidString.lowercased()
        try "original".write(toFile: backup, atomically: true, encoding: .utf8)

        #expect(try DeliveryBackupPath.validate(xmpPath: xmp, backupPath: backup) == backup)
    }

    @Test func acceptsUppercaseDiskXMPWithLowercaseDatabasePath() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // DB 侧 TSPath 归一化为小写，盘上真实文件是 IMG_1.XMP。
        let xmp = directory.appendingPathComponent("IMG_1.xmp").path
        let backup = directory.appendingPathComponent("IMG_1.XMP.gather-backup-abc").path
        try "original".write(toFile: backup, atomically: true, encoding: .utf8)

        #expect(try DeliveryBackupPath.validate(xmpPath: xmp, backupPath: backup) == backup)
    }

    @Test func rejectsTraversalBeforeNormalization() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let xmp = directory.appendingPathComponent("IMG_1.xmp").path
        let backup = directory.path + "/sub/../IMG_1.xmp.gather-backup-x"

        #expect(throws: DeliveryBackupPathError.traversal(backup)) {
            _ = try DeliveryBackupPath.validate(xmpPath: xmp, backupPath: backup)
        }
    }

    @Test func rejectsDifferentDirectoryAndUnexpectedName() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let xmp = directory.appendingPathComponent("IMG_1.xmp").path
        let sibling = directory.appendingPathComponent("IMG_1.xmp.gather-backup-x").path
        let otherDirectory = directory.appendingPathComponent("elsewhere/IMG_1.xmp.gather-backup-x").path
        let wrongName = directory.appendingPathComponent("other.xmp").path

        #expect(throws: DeliveryBackupPathError.notSibling(otherDirectory)) {
            _ = try DeliveryBackupPath.validate(xmpPath: xmp, backupPath: otherDirectory)
        }
        #expect(throws: DeliveryBackupPathError.unexpectedName(wrongName)) {
            _ = try DeliveryBackupPath.validate(xmpPath: xmp, backupPath: wrongName)
        }
        // 缺备份（ENOENT）不是校验失败：cleanup 仍要报 backupMissing。
        #expect(try DeliveryBackupPath.validate(xmpPath: xmp, backupPath: sibling) == sibling)
    }

    @Test func rejectsSymbolicLinkAndDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let xmp = directory.appendingPathComponent("IMG_1.xmp").path
        let target = directory.appendingPathComponent("target").path
        try "target".write(toFile: target, atomically: true, encoding: .utf8)
        let link = xmp + ".gather-backup-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let dirBackup = xmp + ".gather-backup-dir"
        try FileManager.default.createDirectory(atPath: dirBackup, withIntermediateDirectories: true)

        #expect(throws: DeliveryBackupPathError.symbolicLink(link)) {
            _ = try DeliveryBackupPath.validate(xmpPath: xmp, backupPath: link)
        }
        #expect(throws: DeliveryBackupPathError.notRegularFile(dirBackup)) {
            _ = try DeliveryBackupPath.validate(xmpPath: xmp, backupPath: dirBackup)
        }
    }

    @Test func xmpPathMustBeAbsoluteWithoutTraversal() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("IMG_1.jpg").path

        #expect(throws: DeliveryBackupPathError.self) {
            try DeliveryXMPPath.requireSafeSidecar(xmpPath: "relative/IMG_1.xmp", photoPath: photo)
        }
        let traversal = directory.path + "/sub/../IMG_1.xmp"
        #expect(throws: DeliveryBackupPathError.unsafeXMPPath(traversal)) {
            try DeliveryXMPPath.requireSafeSidecar(xmpPath: traversal, photoPath: photo)
        }
    }

    @Test func xmpPathMustBeSiblingOfPhoto() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("IMG_1.jpg").path
        let elsewhere = directory.appendingPathComponent("other/IMG_1.xmp").path

        #expect(throws: DeliveryBackupPathError.xmpNotSiblingOfPhoto(elsewhere)) {
            try DeliveryXMPPath.requireSafeSidecar(xmpPath: elsewhere, photoPath: photo)
        }
        let sibling = directory.appendingPathComponent("IMG_1.xmp").path
        #expect(throws: Never.self) {
            try DeliveryXMPPath.requireSafeSidecar(xmpPath: sibling, photoPath: photo)
        }
    }
}
