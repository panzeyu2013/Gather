// desktop/native/gather-core/Tests/GatherCoreTests/Metadata/MetadataFileSystemTests.swift
// MetadataFingerprint（Services/MetadataFingerprint.swift → Metadata/MetadataFileSystem.swift）
// 直测：真实临时文件上的 contentFingerprint / cacheStalenessKey 语义。
// 语义承接：原文件零专用单测，用例按 TS metadata-fingerprint.ts 语义补齐。

import Foundation
import Testing
@testable import GatherCore

struct MetadataFileSystemTests {

    // MARK: - helpers

    private func makeTempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-fingerprint-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - contentFingerprint

    @Test func contentFingerprintMissingFileIsEmptyString() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fingerprint = try await MetadataFingerprint.contentFingerprint("\(dir)/nope.xmp")
        #expect(fingerprint == "", "TS ENOENT → ''")
    }

    @Test func contentFingerprintFormatIsSizeColonMtimeColonSHA256() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/sidecar.xmp"
        try Data("abc".utf8).write(to: URL(fileURLWithPath: path))

        let stat = try #require(tsStat(path))
        let fingerprint = try await MetadataFingerprint.contentFingerprint(path)
        let parts = fingerprint.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        #expect(parts[0] == "\(stat.size)")
        #expect(parts[1] == "\(Int64(stat.mtimeMs.rounded()))")
        // FIPS 180-4 已知向量：sha256("abc")。
        #expect(parts[2] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func contentFingerprintEmptyFileUsesEmptyDigest() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/empty.xmp"
        try Data().write(to: URL(fileURLWithPath: path))
        let fingerprint = try await MetadataFingerprint.contentFingerprint(path)
        #expect(fingerprint.hasPrefix("0:"))
        #expect(fingerprint.hasSuffix("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
    }

    @Test func contentFingerprintChangesWithContentEvenAtSameSize() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let first = "\(dir)/a.xmp"
        let second = "\(dir)/b.xmp"
        try Data("abc".utf8).write(to: URL(fileURLWithPath: first))
        try Data("abd".utf8).write(to: URL(fileURLWithPath: second))

        let firstFingerprint = try await MetadataFingerprint.contentFingerprint(first)
        let secondFingerprint = try await MetadataFingerprint.contentFingerprint(second)
        let firstDigest = firstFingerprint.split(separator: ":").last
        let secondDigest = secondFingerprint.split(separator: ":").last
        #expect(firstDigest != secondDigest, "同尺寸不同内容必须产出不同指纹")
    }

    // MARK: - cacheStalenessKey

    @Test func cacheStalenessKeyMissingPhotoIsNil() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let key = try await MetadataFingerprint.cacheStalenessKey("\(dir)/missing.cr3")
        #expect(key == nil)
    }

    @Test func cacheStalenessKeyWithoutSidecarUsesZeroXMPMtime() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = "\(dir)/photo.cr3"
        try Data("raw".utf8).write(to: URL(fileURLWithPath: photo))
        let stat = try #require(tsStat(photo))

        let key = try #require(try await MetadataFingerprint.cacheStalenessKey(photo))
        #expect(key.size == Int(stat.size))
        #expect(key.value == "\(Int64(stat.mtimeMs.rounded())):0")
    }

    @Test func cacheStalenessKeyIncludesSidecarMtime() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = "\(dir)/photo.jpg"
        try Data("jpeg".utf8).write(to: URL(fileURLWithPath: photo))
        let xmpPath = TSPath.xmpSidecarPath(photo)
        try Data("xmp".utf8).write(to: URL(fileURLWithPath: xmpPath))

        let photoStat = try #require(tsStat(photo))
        let xmpStat = try #require(tsStat(xmpPath))
        let key = try #require(try await MetadataFingerprint.cacheStalenessKey(photo))
        #expect(key.size == Int(photoStat.size))
        #expect(key.value == "\(Int64(photoStat.mtimeMs.rounded())):\(Int64(xmpStat.mtimeMs.rounded()))")
    }
}
