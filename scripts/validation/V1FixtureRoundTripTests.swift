// V1 夹具写回/清空往返（验证 harness；只在运行时临时复制进 GatherAppTests）。
//
// 目的：用真实 JPEG 段结构（EXIF/XMP/IPTC/ICC/APP2）验证内嵌写回：
// 写后 scan SHA 不变、非编辑段逐字节不变、XMP+IIM 双读一致、清空后字段消失、
// 成功/失败都不留 .gather-embedded-* 临时文件。
//
// 用法：scripts/validation/run-v1-fixtures.sh [fixtures-dir]
import Foundation
import Testing
import GatherProtocol
@testable import GatherHost

@Suite("V1 夹具往返（验证 harness）")
struct V1FixtureRoundTripTests {
    @Test("100 张夹具：写回 → 双读 → 清空 → scan SHA 不变")
    func fixturesRoundTrip() async throws {
        let directory = try #require(
            ProcessInfo.processInfo.environment["GATHER_VALIDATION_FIXTURES"],
            "GATHER_VALIDATION_FIXTURES 未设置")
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count == 100, "夹具矩阵应为 100 张，实际 \(files.count)")

        var failures: [String] = []
        for file in files {
            do {
                try await checkOne(file)
            } catch {
                failures.append("\(file.lastPathComponent): \(error)")
            }
        }
        #expect(failures.isEmpty, "失败 \(failures.count) 张：\n\(failures.joined(separator: "\n"))")
    }

    private func checkOne(_ source: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-v1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent(source.lastPathComponent).path
        try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: path))
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let before = try JPEGDocument(data: original)

        var descriptive = DescriptiveMetadata()
        descriptive.set(.text("V1 caption"), for: .caption)
        descriptive.set(.text("V1 copyright"), for: .copyrightNotice)
        descriptive.set(.text("V1 title"), for: .title)
        descriptive.set(.text("Shanghai"), for: .city)
        descriptive.set(.text("V1 headline"), for: .headline)
        descriptive.set(.list(["V1 creator"]), for: .creator)
        let attributes = MetadataWriteAttributes(
            keywords: ["v1", "验证"], rating: 4, label: "Green",
            descriptive: descriptive, triageSignal: "keep")

        let isLargeIIM = source.lastPathComponent.hasPrefix("E-large")
        if isLargeIIM {
            // 负向样本：>64KB IIM 拆分不是可移植形态；要求显式失败且原片不变。
            let session = try #require(EmbeddedJPEGSession.open(
                photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
            do {
                _ = try await session.commit(attributes)
                Issue.record("\(source.lastPathComponent): 大 IIM 拆分竟然写成功（需复核是否丢字段）")
            } catch {
                let after = try Data(contentsOf: URL(fileURLWithPath: path))
                #expect(after == original, "\(source.lastPathComponent): 失败后原片字节被改动")
            }
            let leftovers = try failurePaths(in: directory)
            #expect(leftovers.isEmpty, "\(source.lastPathComponent): 失败留下临时文件 \(leftovers)")
            return
        }

        let session = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        let report = try await session.commit(attributes)
        #expect(report.scanDigest == before.scanDigest, "\(source.lastPathComponent): report scan SHA 变了")

        let afterData = try Data(contentsOf: URL(fileURLWithPath: path))
        let after = try JPEGDocument(data: afterData)
        #expect(after.scanDigest == before.scanDigest, "\(source.lastPathComponent): scan SHA 变了")
        #expect(nonEdited(after) == nonEdited(before), "\(source.lastPathComponent): 非 XMP/APP13 段被改动")

        let reader = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        #expect(reader.attributes.rating == 4, "\(source.lastPathComponent): rating 未读回")
        #expect(reader.attributes.label == "Green", "\(source.lastPathComponent): label 未读回")
        #expect(reader.attributes.keywords?.contains("v1") == true, "\(source.lastPathComponent): keywords 未读回")
        #expect(reader.attributes.triageSignal == "keep", "\(source.lastPathComponent): triage 未读回")
        #expect(reader.attributes.descriptive?.caption == "V1 caption", "\(source.lastPathComponent): caption 未读回")
        #expect(reader.attributes.descriptive?.copyrightNotice == "V1 copyright", "\(source.lastPathComponent): copyright 未读回")
        #expect(reader.attributes.descriptive?.city == "Shanghai", "\(source.lastPathComponent): city 未读回")

        var cleared = DescriptiveMetadata()
        cleared.set(.text(""), for: .caption)
        cleared.set(.text(""), for: .copyrightNotice)
        cleared.set(.text(""), for: .title)
        cleared.set(.text(""), for: .city)
        let clearer = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        _ = try await clearer.commit(MetadataWriteAttributes(
            keywords: [], descriptive: cleared, triageSignal: ""))

        let clearedReader = try #require(EmbeddedJPEGSession.open(
            photoPath: path, chunkBytes: 1 << 20, hooks: .init()))
        #expect(clearedReader.attributes.keywords == nil, "\(source.lastPathComponent): 清空后 keywords 复活")
        #expect(clearedReader.attributes.triageSignal == nil, "\(source.lastPathComponent): 清空后 triage 复活")
        #expect(clearedReader.attributes.descriptive?.caption == nil, "\(source.lastPathComponent): 清空后 caption 复活")
        #expect(clearedReader.attributes.descriptive?.copyrightNotice == nil, "\(source.lastPathComponent): 清空后 copyright 复活")
        #expect(clearedReader.attributes.descriptive?.title == nil, "\(source.lastPathComponent): 清空后 title 复活")
        #expect(clearedReader.attributes.descriptive?.city == nil, "\(source.lastPathComponent): 清空后 city 复活")
        #expect(clearedReader.attributes.descriptive?.headline == "V1 headline", "\(source.lastPathComponent): 未清空字段被误删")
        #expect(clearedReader.attributes.descriptive?.creator == ["V1 creator"], "\(source.lastPathComponent): creator 被误删")

        let final = try JPEGDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(final.scanDigest == before.scanDigest, "\(source.lastPathComponent): 清空后 scan SHA 变了")
        let leftovers = try failurePaths(in: directory)
        #expect(leftovers.isEmpty, "\(source.lastPathComponent): 成功路径留下临时文件 \(leftovers)")
    }

    private func nonEdited(_ document: JPEGDocument) -> [JPEGSegment] {
        document.segments.filter { !$0.isXMP && !$0.isPhotoshop }
    }

    private func failurePaths(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".gather-embedded-") }
    }
}
