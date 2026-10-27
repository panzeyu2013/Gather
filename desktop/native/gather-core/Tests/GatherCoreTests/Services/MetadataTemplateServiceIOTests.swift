// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataTemplateServiceIOTests.swift
// P1 / B2：模板 apply/undo 的 IO 编排直测（交付队列 → 回读校验 → 缓存投影 → 批次回滚）。
//
// 用内存 SQLite + 记录型 XMP/mutation 替身，证明：
// 1) apply 不直接写 XMPProvider，而是先入队（可审计/可备份的单一写路径）；
// 2) undo 把"原本不存在"的字段清空（完整回滚，不是只还原有值字段）；
// 3) 冲突策略 keepExternal 时外部改动不被覆盖，但同批其它字段仍写入。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherDelivery
@testable import GatherApplication

/// 记录写入的 XMP 替身：模拟执行器的"按字段合并"语义。
private final class TemplateIOXMP: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: MetadataWriteAttributes] = [:]
    private(set) var writeCount = 0

    func seed(_ path: String, _ attributes: MetadataWriteAttributes) {
        lock.lock(); defer { lock.unlock() }
        storage[path] = attributes
    }

    func attributes(_ path: String) -> MetadataWriteAttributes {
        lock.lock(); defer { lock.unlock() }
        return storage[path] ?? MetadataWriteAttributes()
    }

    func readKeywords(photoPath: String) async throws -> [String] { [] }
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes { attributes(photoPath) }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        write(photoPath: photoPath, attributes: attributes)
    }

    /// 同步临界区（Swift 6 禁止在 async 上下文直接 lock/unlock）。
    private func write(photoPath: String, attributes: MetadataWriteAttributes) {
        lock.lock(); defer { lock.unlock() }
        writeCount += 1
        var current = storage[photoPath] ?? MetadataWriteAttributes()
        if let descriptive = attributes.descriptive {
            var merged = (current.descriptive ?? DescriptiveMetadata()).applying(descriptive)
            if attributes.replaceContact == true {
                merged.set(.contact(descriptive.contactInfo ?? DescriptiveContact()),
                           for: .contactInfo)
            }
            // 真实补丁器把"空值"落成"元素不存在"，读回为 nil；替身必须同语义。
            for field in descriptive.explicitlySetFields
            where merged.value(for: field)?.isEmptyValue ?? false {
                merged.set(nil, for: field)
            }
            current.descriptive = merged
        }
        if let rating = attributes.rating { current.rating = rating }
        if let label = attributes.label { current.label = label }
        if let keywords = attributes.keywords { current.keywords = keywords }
        storage[photoPath] = current
    }

    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { false }
    func removeFile(_ path: String) async throws {}
}

/// 记录入队的 mutation 端口（apply 必须经过它）。
private final class TemplateIOMutations: MetadataMutationPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var queued: [(photoId: String, values: [String: JSONValue])] = []

    func drain() -> [(photoId: String, values: [String: JSONValue])] {
        lock.lock(); defer { lock.unlock() }
        let result = queued
        queued.removeAll()
        return result
    }

    func queuePhotoValues(
        sessionId: String, photoId: String, values: [String: JSONValue],
        source: MetadataMutationSource, schedule: Bool
    ) throws -> MetadataMutationResult {
        lock.lock(); defer { lock.unlock() }
        queued.append((photoId, values))
        return MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [.descriptive],
            revision: 1, status: "pending")
    }

    func queueKeywordDelta(
        sessionId: String, photoId: String, added: [String], removed: [String],
        owned: [String: Set<MetadataMutationSource>], existingKeywords: [String]?
    ) async throws -> MetadataMutationResult? {
        throw PortIOError.unsupported
    }

    enum PortIOError: Error { case unsupported }
}

@Suite("模板套用 IO")
struct MetadataTemplateServiceIOTests {
    private struct Fixture {
        let db: DBConnection
        let dir: String
        let photoId: String
        let sessionId: String
        let photoPath: String
        let xmp: TemplateIOXMP
        let mutations: TemplateIOMutations
        let templates: MetadataTemplateStore
        let batches: MetadataApplyBatchStore
        let service: MetadataTemplateService
        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func makeFixture() throws -> Fixture {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-template-io-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sessionId = "s-\(UUID().uuidString)"
        let photoId = "p-\(UUID().uuidString)"
        try insertSession(db, sessionId)
        let photoPath = (dir as NSString).appendingPathComponent("photo.cr3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: photoPath))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: photoPath)

        let xmp = TemplateIOXMP()
        let mutations = TemplateIOMutations()
        let paths = [photoId: photoPath]
        let metadata = MetadataService(
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            xmp: xmp,
            photoRepo: PhotoRepo(connection: db),
            transactions: db,
            mutations: mutations,
            flushPending: { _ in
                var failed: [WritebackItem] = []
                for entry in mutations.drain() {
                    guard let path = paths[entry.photoId] else { continue }
                    do {
                        let attributes = try MetadataWriteAttributes(
                            jsonValue: .object(entry.values))
                        try await xmp.writeAttributes(photoPath: path, attributes: attributes)
                    } catch {
                        failed.append(WritebackItem(
                            photoId: entry.photoId, photoPath: path, sessionId: "",
                            module: "metadata", keywords: [], xmpPath: TSPath.xmpSidecarPath(path),
                            backupPath: "", xmpStatus: "failed",
                            errorMessage: String(describing: error),
                            attemptCount: 1, lastAttemptAt: ""))
                    }
                }
                return WritebackResult(
                    totalAffected: paths.count, written: paths.count - failed.count,
                    failed: failed.count, skipped: 0, errors: failed.map(\.errorMessage),
                    failedItems: failed, report: "")
            }
        )
        let settings = SettingsService(repo: SettingsRepo(connection: db))
        let templates = MetadataTemplateStore(settings: settings)
        let batches = MetadataApplyBatchStore(settings: settings)
        let service = MetadataTemplateService(
            templates: templates, batches: batches, metadata: metadata, xmp: xmp)
        return Fixture(
            db: db, dir: dir, photoId: photoId, sessionId: sessionId, photoPath: photoPath,
            xmp: xmp, mutations: mutations, templates: templates, batches: batches, service: service)
    }

    @Test("apply：经队列写入并回读校验；undo 还原旧值且清空原本不存在的字段")
    func applyThenUndoRestoresExactly() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let cache = MetadataCacheRepo(connection: fx.db)
        try cache.upsert(photoId: fx.photoId, sessionId: fx.sessionId, data: MetadataCacheInput(
            descriptive: DescriptiveMetadata(title: "旧标题", caption: "旧说明", city: "上海")))
        fx.xmp.seed(fx.photoPath, MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(title: "旧标题", caption: "旧说明", city: "上海")))

        _ = try fx.templates.save(MetadataTemplate(
            id: "t1", name: "婚礼", fields: DescriptiveMetadata(
                title: "新标题", caption: "", copyrightNotice: "© 2026"),
            createdAt: "", updatedAt: ""), now: "2026-10-26T00:00:00Z")

        let applied = try await fx.service.apply(
            templateId: "t1", photoIds: [fx.photoId], now: "2026-10-26T00:00:00Z")
        #expect(applied.written == [fx.photoId])
        #expect(applied.failed.isEmpty)
        let after = fx.xmp.attributes(fx.photoPath).descriptive
        #expect(after?.title == "新标题")
        #expect(after?.copyrightNotice == "© 2026")
        #expect(after?.caption == nil, "空值 = 显式清空")
        #expect(after?.city == "上海", "模板没碰的字段必须保留")

        let batch = try #require(fx.batches.latest())
        #expect(Set(batch.snapshots.first?.touchedFields ?? []) == [.title, .copyrightNotice, .caption])

        let undone = try await fx.service.undo(batchId: applied.batchId)
        #expect(undone.written == [fx.photoId])
        let restored = fx.xmp.attributes(fx.photoPath).descriptive
        #expect(restored?.title == "旧标题")
        #expect(restored?.caption == "旧说明")
        #expect(restored?.copyrightNotice == nil, "原本不存在的字段必须清空（完整回滚）")
        #expect(try fx.batches.get(id: applied.batchId)?.undone == true)
    }

    @Test("模板只填 contact 部分成员：成员级合并且写后校验通过（不整块删）")
    func partialContactMerges() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let cache = MetadataCacheRepo(connection: fx.db)
        let existing = DescriptiveContact(city: "上海", telephone: "123")
        try cache.upsert(photoId: fx.photoId, sessionId: fx.sessionId, data: MetadataCacheInput(
            descriptive: DescriptiveMetadata(contactInfo: existing)))
        fx.xmp.seed(fx.photoPath, MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(contactInfo: existing)))
        _ = try fx.templates.save(MetadataTemplate(
            id: "t-contact", name: "联系方式",
            fields: DescriptiveMetadata(contactInfo: DescriptiveContact(email: "a@b.c")),
            createdAt: "", updatedAt: ""), now: "")

        let applied = try await fx.service.apply(
            templateId: "t-contact", photoIds: [fx.photoId], now: "")
        #expect(applied.failed.isEmpty, "成员级合并后写后校验必须通过")
        #expect(applied.written == [fx.photoId])
        let after = fx.xmp.attributes(fx.photoPath).descriptive?.contactInfo
        #expect(after?.city == "上海")
        #expect(after?.telephone == "123")
        #expect(after?.email == "a@b.c")

        let batch = try #require(fx.batches.latest())
        _ = try await fx.service.undo(batchId: batch.id)
        let restored = fx.xmp.attributes(fx.photoPath).descriptive?.contactInfo
        #expect(restored?.city == "上海")
        #expect(restored?.telephone == "123")
        #expect(restored?.email == nil, "撤销必须删除模板新增的 contact 成员")
    }

    @Test("keepExternal：外部改过的字段跳过，同批其它字段仍写入")
    func conflictKeepsExternalValue() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let cache = MetadataCacheRepo(connection: fx.db)
        try cache.upsert(photoId: fx.photoId, sessionId: fx.sessionId, data: MetadataCacheInput(
            descriptive: DescriptiveMetadata(title: "缓存标题", city: "缓存城市")))
        // 盘上 city 被外部改过 → 与缓存不一致。
        fx.xmp.seed(fx.photoPath, MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(title: "缓存标题", city: "外部改过")))
        _ = try fx.templates.save(MetadataTemplate(
            id: "t2", name: "地点", fields: DescriptiveMetadata(title: "模板标题", city: "模板城市"),
            createdAt: "", updatedAt: ""), now: "")

        let applied = try await fx.service.apply(
            templateId: "t2", photoIds: [fx.photoId], now: "")
        #expect(applied.conflicts == [fx.photoId])
        #expect(applied.written == [fx.photoId])
        let after = fx.xmp.attributes(fx.photoPath).descriptive
        #expect(after?.title == "模板标题")
        #expect(after?.city == "外部改过", "keepExternal 绝不覆盖外部改动")
    }
}
