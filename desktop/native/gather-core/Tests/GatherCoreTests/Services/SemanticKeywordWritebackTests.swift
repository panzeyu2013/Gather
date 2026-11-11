// desktop/native/gather-core/Tests/GatherCoreTests/Services/SemanticKeywordWritebackTests.swift
// Wave4a / task-39（E2）：场景标签写回的**批级撤销**回归测试。
//
// 覆盖：apply 返回本批实际写到的 photoIds → 用这批 id 撤销只清本批 →
// 再次 apply 能恢复（apply→undo→apply 闭环），而不是清整个会话的 AI 场景子树。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherDelivery
@testable import GatherApplication

/// 内存 XMP：关键词按照片路径存；写/删都由 flush 闭包驱动。
private final class SemanticKeywordXMP: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [String]] = [:]

    func seed(_ path: String, _ keywords: [String]) {
        lock.lock(); defer { lock.unlock() }
        storage[path] = keywords
    }

    func keywords(_ path: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage[path] ?? []
    }

    func readKeywords(photoPath: String) async throws -> [String] { keywords(photoPath) }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        MetadataWriteAttributes(keywords: keywords(photoPath))
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        guard let keywords = attributes.keywords else { return }
        lock.withLock { storage[photoPath] = keywords }
    }

    func applyDelta(photoPath: String, added: [String], removed: [String]) {
        lock.lock(); defer { lock.unlock() }
        var current = storage[photoPath] ?? []
        let drop = Set(removed.map(KeywordNormalizer.fold))
        current = current.filter { !drop.contains(KeywordNormalizer.fold($0)) }
        current.append(contentsOf: added)
        storage[photoPath] = current
    }

    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { false }
    func removeFile(_ path: String) async throws {}
}

/// 记录 keyword delta，flush 时一次性落到假 XMP（与真实交付链同路径：queue → flush → 回读）。
private final class SemanticKeywordMutations: MetadataMutationPort, @unchecked Sendable {
    struct Entry {
        let photoId: String
        let added: [String]
        let removed: [String]
    }

    private let lock = NSLock()
    private var queue: [Entry] = []

    func drain() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let entries = queue
        queue.removeAll()
        return entries
    }

    func flushQueuedMetadata(sessionId: String) async throws {}

    func queuePhotoValues(
        sessionId: String, photoId: String, values: [String: JSONValue],
        source: MetadataMutationSource, schedule: Bool
    ) throws -> MetadataMutationResult {
        throw GatherError.invalidParameter(field: "values", reason: "unused")
    }

    func queueKeywordDelta(
        sessionId: String, photoId: String, added: [String], removed: [String],
        owned: [String: Set<MetadataMutationSource>], existingKeywords: [String]?
    ) async throws -> MetadataMutationResult? {
        return lock.withLock {
            queue.append(Entry(photoId: photoId, added: added, removed: removed))
            return MetadataMutationResult(
                photoId: photoId, xmpPath: "", dirtyFields: [.keywords],
                revision: 1, status: "pending")
        }
    }
}

@Suite("场景标签写回批级撤销")
struct SemanticKeywordWritebackTests {
    private func labelsJSON(_ labels: [(String, Double)]) -> String {
        let objects = labels.map { label, confidence in
            "{\"label\":\"\(label)\",\"confidence\":\(confidence)}"
        }
        return "[" + objects.joined(separator: ",") + "]"
    }

    @Test("apply 返回本批 appliedPhotoIds；undo 只清本批；再次 apply 恢复（E2）")
    func applyUndoApply() async throws {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-semantic-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(atPath: dir) } catch {} }

        let sessionId = "s-1"
        try insertSession(db, sessionId)
        let pathA = (dir as NSString).appendingPathComponent("a.CR3")
        let pathB = (dir as NSString).appendingPathComponent("b.CR3")
        for path in [pathA, pathB] {
            try Data("raw".utf8).write(to: URL(fileURLWithPath: path))
        }
        try insertPhoto(db, id: "p1", sessionId: sessionId, filepath: pathA)
        try insertPhoto(db, id: "p2", sessionId: sessionId, filepath: pathB)

        let cache = MetadataCacheRepo(connection: db)
        try cache.upsert(photoId: "p1", sessionId: sessionId, data: MetadataCacheInput(rating: 0))
        try cache.upsert(photoId: "p2", sessionId: sessionId, data: MetadataCacheInput(rating: 0))

        let semantics = PhotoSemanticsRepo(connection: db)
        for (photoId, label) in [("p1", "beach"), ("p2", "wedding")] {
            try semantics.upsert([PhotoSemanticsInsert(
                photoId: photoId, sessionId: sessionId,
                labelsJson: labelsJSON([(label, 0.9)]),
                feature: nil, featureDim: 0,
                modelVersion: "test", computedAt: "2026-01-01T00:00:00Z")])
        }

        let xmp = SemanticKeywordXMP()
        let mutations = SemanticKeywordMutations()
        let paths = ["p1": pathA, "p2": pathB]
        let photoRepo = PhotoRepo(connection: db)
        let metadata = MetadataService(
            metadataCacheRepo: cache, xmp: xmp, photoRepo: photoRepo, transactions: db,
            mutations: mutations,
            flushPending: { _ in
                let entries = mutations.drain()
                for entry in entries {
                    guard let path = paths[entry.photoId] else { continue }
                    xmp.applyDelta(photoPath: path, added: entry.added, removed: entry.removed)
                }
                return WritebackResult(
                    totalAffected: entries.count, written: entries.count, failed: 0,
                    skipped: 0, errors: [], failedItems: [], report: "")
            })
        let keywords = KeywordRepo(connection: db)
        let indexSync = KeywordIndexSync(index: keywords, metadata: cache)
        let service = SemanticKeywordService(
            semantics: semantics, metadata: metadata, keywords: keywords,
            indexSync: indexSync, photoRepo: photoRepo)

        // ① 写回：本批覆盖两张照片，结果必须回传本批 photoIds。
        let first = try await service.apply(SemanticKeywordApplyInput(sessionId: sessionId))
        #expect(first.appliedPhotos == 2)
        #expect(first.keywordsAdded == 2)
        #expect(first.appliedPhotoIds.sorted() == ["p1", "p2"], "写回结果必须带本批照片 id")
        let planAfterWrite = try service.plan(SemanticKeywordPlanInput(sessionId: sessionId))
        #expect(planAfterWrite.totalAdditions == 0, "写完再预览应为幂等 0")

        // ② 只撤销本批中的 p1（模拟 UI 收到 appliedPhotoIds 后回传）：
        //    p2 的关键词必须保留，不能把整个会话的场景子树清空。
        let undo = try await service.apply(SemanticKeywordApplyInput(
            sessionId: sessionId, photoIds: ["p1"], remove: true))
        #expect(undo.appliedPhotos == 1)
        #expect(undo.appliedPhotoIds == ["p1"])
        #expect(undo.keywordsRemoved == 1)
        #expect(try keywords.photoKeywordPaths(photoId: "p2") == ["AI|场景|wedding"])
        #expect(try keywords.photoKeywordPaths(photoId: "p1").isEmpty)
        let planAfterUndo = try service.plan(SemanticKeywordPlanInput(sessionId: sessionId))
        #expect(planAfterUndo.totalAdditions == 1, "只有 p1 需要重写")
        let pendingForP1 = planAfterUndo.items.filter { $0.photoId == "p1" && !$0.alreadyPresent }
        #expect(pendingForP1.count == 1)

        // ③ 再写回 p1：闭环恢复。
        let second = try await service.apply(SemanticKeywordApplyInput(
            sessionId: sessionId, photoIds: ["p1"]))
        #expect(second.keywordsAdded == 1)
        #expect(second.appliedPhotoIds == ["p1"])
        #expect(try keywords.photoKeywordPaths(photoId: "p1") == ["AI|场景|beach"])
        let planFinal = try service.plan(SemanticKeywordPlanInput(sessionId: sessionId))
        #expect(planFinal.totalAdditions == 0)
    }
}
