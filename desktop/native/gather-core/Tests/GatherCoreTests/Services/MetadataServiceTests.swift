// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataServiceTests.swift
// MetadataService 缓存/陈旧键/损坏侧车守卫的直测（用真实文件 + 计数 ExifProvider 做独立 oracle）。
//
// 覆盖此前 0 覆盖的两条数据安全契约：
// 1) 缓存陈旧键判据是 **且**：源文件大小相同但侧车 mtime 变化必须重新提取；
//    若判据退化为或，外部对侧车的修改永远不会被重新读取。
// 2) 损坏侧车（readAttributes 返回空但侧车文件存在）不得用空值覆盖有效缓存。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherDomain

/// 计数 EXIF provider：调用次数即"是否重新提取"的独立证据。
private final class CountingExif: ExifProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func callCount() -> Int { lock.lock(); defer { lock.unlock() }; return calls }

    /// 同步锁临界区辅助（Swift 6：async 上下文不得直接 lock/unlock）。
    private func incrementCalls() {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
    }

    func parse(filePath: String, isJpeg: Bool) async throws -> MetadataParseSegments? {
        incrementCalls()
        return MetadataParseSegments(
            ifd0: .object(["Make": .string("GatherCam"), "Model": .string("X-T5"), "ImageWidth": .number(100)]),
            exif: .object(["DateTimeOriginal": .string("2024:05:01 10:20:30"), "ISO": .number(200)]),
            gps: .object(["latitude": .number(1.5)])
        )
    }
}

/// 可切换属性/存在性的 XMP 替身（比真实实现更严格：不存在任何"静默返回旧值"的兜底）。
private final class SwitchableXMP: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var attributes = MetadataWriteAttributes()
    private var sidecarExists = true

    func setAttributes(_ value: MetadataWriteAttributes) { lock.lock(); attributes = value; lock.unlock() }
    func setSidecarExists(_ value: Bool) { lock.lock(); sidecarExists = value; lock.unlock() }

    /// 同步锁临界区辅助（Swift 6：async 上下文不得直接 lock/unlock）。
    private func attributesSnapshot() -> MetadataWriteAttributes {
        lock.lock()
        defer { lock.unlock() }
        return attributes
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        attributesSnapshot().keywords ?? []
    }
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        attributesSnapshot()
    }
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}
    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return sidecarExists }
    func removeFile(_ path: String) async throws {}
}

private struct NoopMutations: MetadataMutationPort {
    func queuePhotoValues(
        sessionId: String, photoId: String, values: [String: JSONValue],
        source: MetadataMutationSource, schedule: Bool
    ) throws -> MetadataMutationResult {
        MetadataMutationResult(photoId: photoId, xmpPath: photoId + ".xmp", dirtyFields: [], revision: 1, status: "pending")
    }
    func queueMutation(
        sessionId: String, photoId: String, patch: MetadataPatch, source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        MetadataMutationResult(photoId: photoId, xmpPath: photoId + ".xmp", dirtyFields: [], revision: 1, status: "pending")
    }
}

struct MetadataServiceTests {
    private struct Fixture {
        let db: DBConnection
        let dir: String
        let photoId: String
        let photoPath: String
        let exif: CountingExif
        let xmp: SwitchableXMP
        let service: MetadataService

        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func makeFixture() throws -> Fixture {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-metadata-service-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sessionId = "s-\(UUID().uuidString)"
        try insertSession(db, sessionId)
        let photoId = "p-\(UUID().uuidString)"
        let photoPath = dir + "/photo.cr3"
        try Data("raw-bytes".utf8).write(to: URL(fileURLWithPath: photoPath))
        // 侧车真实存在：陈旧键包含侧车 mtime，这是"外部改了 XMP"的唯一廉价信号。
        try Data("sidecar".utf8).write(to: URL(fileURLWithPath: TSPath.xmpSidecarPath(photoPath)))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: photoPath)
        let exif = CountingExif()
        let xmp = SwitchableXMP()
        let service = MetadataService(
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            xmp: xmp,
            connection: db,
            mutations: NoopMutations(),
            assetResolver: nil,
            exif: exif,
            dimensions: nil,
            embeddedReader: nil
        )
        return Fixture(db: db, dir: dir, photoId: photoId, photoPath: photoPath, exif: exif, xmp: xmp, service: service)
    }

    /// 变异守卫：缓存命中判据 && 退化为 || 时，源文件大小不变、仅侧车 mtime 变化
    /// 的情况会被误判为命中 —— 外部软件写进侧车的关键词/星级永远读不到。
    @Test("缓存陈旧键：指纹未变命中缓存；仅侧车 mtime 变化必须重新提取")
    func cacheStalenessKeyRequiresBothSizeAndMtime() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        fx.xmp.setAttributes(MetadataWriteAttributes(keywords: ["k1", "k2"], rating: 3, label: "Green"))

        let first = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(fx.exif.callCount() == 1)
        // 独立 oracle：EXIF 段与 XMP 有效属性都必须落到缓存值上（不是只断言"被调用"）。
        #expect(first[fx.photoId]?.iso == 200)
        #expect(first[fx.photoId]?.make == "GatherCam")
        #expect(first[fx.photoId]?.width == 100)
        #expect(first[fx.photoId]?.rating == 3, "侧车 rating 覆盖 EXIF 缺省")
        #expect(first[fx.photoId]?.keywords == ["k1", "k2"])
        #expect(first[fx.photoId]?.label == "Green")

        // 源文件与侧车都没动 → 必须命中缓存，不再调用 exif。
        _ = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(fx.exif.callCount() == 1, "指纹未变时必须命中缓存")

        // 只动侧车 mtime（源文件大小/内容/mtime 全不变）→ 陈旧键变化 → 必须重新提取。
        let future = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes(
            [.modificationDate: future], ofItemAtPath: TSPath.xmpSidecarPath(fx.photoPath))
        _ = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(fx.exif.callCount() == 2, "仅侧车 mtime 变化也必须使缓存失效（判据是且，不是或）")
    }

    /// 变异守卫：损坏侧车守卫取反（或有侧车就早退）时，空读取会用空关键词/0 星
    /// 覆盖缓存里的有效值，直到文件再次变更前一直显示错误值。
    @Test("损坏侧车（文件在但读回空）必须保留缓存里的关键词/星级/色标")
    func corruptSidecarPreservesCachedValues() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        fx.xmp.setAttributes(MetadataWriteAttributes(keywords: ["k1", "k2"], rating: 3, label: "Green"))
        _ = try await fx.service.getMetadata(photoIds: [fx.photoId])

        // 侧车仍存在，但读取返回空（损坏）→ 同时让源文件 mtime 前移，强制走重新提取。
        fx.xmp.setAttributes(MetadataWriteAttributes())
        fx.xmp.setSidecarExists(true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(300)], ofItemAtPath: fx.photoPath)

        let second = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(fx.exif.callCount() == 2, "源文件 mtime 变化必须重新提取（前置条件）")
        #expect(second[fx.photoId]?.keywords == ["k1", "k2"], "损坏侧车不得用空值覆盖有效缓存")
        #expect(second[fx.photoId]?.rating == 3, "损坏侧车不得把星级清零")
        #expect(second[fx.photoId]?.label == "Green", "损坏侧车不得把色标抹掉")
    }

    /// 对照：侧车**不存在**（合法的空初始状态）时不保留旧值 —— 守卫不能被理解成
    /// "永远保留缓存"（那会让真正被外部清空的关键词永远复活）。
    @Test("侧车不存在时不得复活缓存旧值（守卫只针对损坏）")
    func absentSidecarDoesNotResurrectCachedValues() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        fx.xmp.setAttributes(MetadataWriteAttributes(keywords: ["k1"], rating: 3, label: "Green"))
        _ = try await fx.service.getMetadata(photoIds: [fx.photoId])

        fx.xmp.setAttributes(MetadataWriteAttributes())
        fx.xmp.setSidecarExists(false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(600)], ofItemAtPath: fx.photoPath)

        let second = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(second[fx.photoId]?.keywords == nil)
        #expect(second[fx.photoId]?.rating == nil)
        #expect(second[fx.photoId]?.label == nil)
    }
}
