// desktop/native/gather-core/Tests/GatherCoreTests/Services/TriageWritebackServiceTests.swift
// P1 / E：triage 写回的 apply/undo 直测——rating 只写空值、关键词并集、
// 私有命名空间信号、撤销还原并清空信号。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherDelivery
@testable import GatherApplication

private final class TriageXMP: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: MetadataWriteAttributes] = [:]

    func seed(_ path: String, _ attributes: MetadataWriteAttributes) {
        lock.lock(); defer { lock.unlock() }
        storage[path] = attributes
    }
    func attributes(_ path: String) -> MetadataWriteAttributes {
        lock.lock(); defer { lock.unlock() }
        return storage[path] ?? MetadataWriteAttributes()
    }
    func readKeywords(photoPath: String) async throws -> [String] { attributes(photoPath).keywords ?? [] }
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes { attributes(photoPath) }
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        write(photoPath: photoPath, attributes: attributes)
    }
    private func write(photoPath: String, attributes: MetadataWriteAttributes) {
        lock.lock(); defer { lock.unlock() }
        var current = storage[photoPath] ?? MetadataWriteAttributes()
        if let rating = attributes.rating { current.rating = rating }
        if let keywords = attributes.keywords { current.keywords = keywords }
        if let signal = attributes.triageSignal {
            current.triageSignal = signal.isEmpty ? nil : signal
        }
        storage[photoPath] = current
    }
    func removeKeywords(_ path: String, _ removed: [String]) {
        lock.lock(); defer { lock.unlock() }
        var current = storage[path] ?? MetadataWriteAttributes()
        let drop = Set(removed.map(KeywordNormalizer.fold))
        current.keywords = (current.keywords ?? []).filter {
            !drop.contains(KeywordNormalizer.fold($0))
        }
        storage[path] = current
    }

    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { false }
    func removeFile(_ path: String) async throws {}
}

private final class TriageMutations: MetadataMutationPort, @unchecked Sendable {
    private let lock = NSLock()
    var onKeywordDelta: (([String], [String]) -> Void)?
    private var queued: [(photoId: String, values: [String: JSONValue])] = []
    func drain() -> [(photoId: String, values: [String: JSONValue])] {
        lock.lock(); defer { lock.unlock() }
        let result = queued; queued.removeAll(); return result
    }
    func queuePhotoValues(
        sessionId: String, photoId: String, values: [String: JSONValue],
        source: MetadataMutationSource, schedule: Bool
    ) throws -> MetadataMutationResult {
        lock.lock(); defer { lock.unlock() }
        queued.append((photoId, values))
        return MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [.rating], revision: 1, status: "pending")
    }
    func queueKeywordDelta(
        sessionId: String, photoId: String, added: [String], removed: [String],
        owned: [String: Set<MetadataMutationSource>], existingKeywords: [String]?
    ) async throws -> MetadataMutationResult? {
        onKeywordDelta?(added, removed)
        return MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [.keywords],
            revision: 1, status: "pending")
    }
}

@Suite("triage 写回")
struct TriageWritebackServiceTests {
    @Test("apply 写 rating/关键词/私有信号；undo 全部还原并清空信号")
    func applyThenUndo() async throws {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-triage-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(atPath: dir) } catch {}
        }
        let sessionId = "s-1", photoId = "p-1"
        try insertSession(db, sessionId)
        let path = (dir as NSString).appendingPathComponent("a.CR3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: path))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: path)
        let cache = MetadataCacheRepo(connection: db)
        try cache.upsert(photoId: photoId, sessionId: sessionId, data: MetadataCacheInput(rating: 0))

        let xmp = TriageXMP()
        xmp.seed(path, MetadataWriteAttributes(keywords: ["old"]))
        let mutations = TriageMutations()
        mutations.onKeywordDelta = { _, removed in
            xmp.removeKeywords(path, removed)
        }
        let metadata = MetadataService(
            metadataCacheRepo: cache, xmp: xmp, photoRepo: PhotoRepo(connection: db),
            transactions: db, mutations: mutations,
            flushPending: { _ in
                for entry in mutations.drain() {
                    let attributes = try MetadataWriteAttributes(jsonValue: .object(entry.values))
                    try await xmp.writeAttributes(photoPath: path, attributes: attributes)
                }
                return WritebackResult(
                    totalAffected: 1, written: 1, failed: 0, skipped: 0,
                    errors: [], failedItems: [], report: "")
            })
        let settings = SettingsService(repo: SettingsRepo(connection: db))
        let batches = MetadataApplyBatchStore(settings: settings)
        let service = TriageWritebackService(xmp: xmp, metadata: metadata, batches: batches)

        let applied = await service.apply(
            [TriageWritebackDecision(
                photoId: photoId, rating: 3, keyword: "Gather|AI|Keep", namespaceValue: "keep")],
            batchId: "b1", now: "2026-10-27T00:00:00Z")
        #expect(applied.written == [photoId])
        #expect(applied.failed.isEmpty)
        let after = xmp.attributes(path)
        #expect(after.rating == 3)
        #expect(after.keywords == ["old", "Gather|AI|Keep"])
        #expect(after.triageSignal == "keep")
        let batch = try #require(batches.get(id: "b1"))
        #expect(batch.snapshots.first?.beforeRating == 0)
        #expect(batch.snapshots.first?.beforeKeywords == ["old"])

        let undone = try await service.undo(batchId: "b1")
        #expect(undone.written == [photoId])
        let restored = xmp.attributes(path)
        #expect(restored.rating == 0)
        #expect(restored.keywords == ["old"])
        #expect(restored.triageSignal == nil, "撤销必须清空私有信号")
        #expect(try batches.get(id: "b1")?.undone == true)
    }
}
