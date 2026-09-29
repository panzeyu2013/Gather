// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataParallelBatchTests.swift
// 并发批处理回归：batchAsync 的 body 由多个 worker 并发调用，捕获的可变集合必须
// 串行写入。修复前 getMetadata / WritebackService.execute 的并发 append 实测会
// SIGSEGV（_swift_release_dealloc / Array.append）或静默丢项；本套件锁定
// 「每个输入都必须出现在结果里」这一可观测不变量。
import Foundation
import Testing
@testable import GatherCore

private struct ParallelExif: ExifProvider {
    func parse(filePath: String, isJpeg: Bool) async throws -> MetadataParseSegments? {
        MetadataParseSegments(
            ifd0: .object(["Make": .string("M"), "Model": .string("X"), "ImageWidth": .number(10)]),
            exif: .object(["DateTimeOriginal": .string("2024:01:01 00:00:00"), "ISO": .number(100)]),
            gps: .object(["latitude": .number(1.0)])
        )
    }
}

private struct ParallelXMP: XMPProvider {
    func readKeywords(photoPath: String) async throws -> [String] { [] }
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes { MetadataWriteAttributes() }
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}
    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { false }
    func removeFile(_ path: String) async throws {}
}

private struct ParallelMutations: MetadataMutationPort {
    func queuePhotoValues(sessionId: String, photoId: String, values: [String: JSONValue], source: MetadataMutationSource, schedule: Bool) throws -> MetadataMutationResult {
        MetadataMutationResult(photoId: photoId, xmpPath: photoId + ".xmp", dirtyFields: [.rating], revision: 1, status: "pending")
    }
    func queueMutation(sessionId: String, photoId: String, patch: MetadataPatch, source: MetadataMutationSource) async throws -> MetadataMutationResult {
        MetadataMutationResult(photoId: photoId, xmpPath: photoId + ".xmp", dirtyFields: [], revision: 1, status: "pending")
    }
}

private struct ParallelSync: MetadataSyncPort {
    func waitForIdle(xmpPath: String, timeoutMs: Int) async throws {}
    func flushSession(sessionId: String) async throws -> MetadataSyncSummary {
        MetadataSyncSummary(sessionId: sessionId, pending: 0, writing: 0, written: 0, failed: 0, conflict: 0, synced: 0, items: [])
    }
    func confirmSync(sessionId: String, sourceModule: String) throws -> MetadataSyncSummary {
        MetadataSyncSummary(sessionId: sessionId, pending: 0, writing: 0, written: 0, failed: 0, conflict: 0, synced: 0, items: [])
    }
    func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult {
        CleanupResult(deletedCount: 0, errors: [])
    }
}

@Suite("MetadataParallelBatch")
struct MetadataParallelBatchTests {
    private func makeDB(photos: Int) throws -> (DBConnection, String, [String]) {
        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        let sessionId = "s-" + UUID().uuidString
        _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)")
            .run([.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        var ids: [String] = []
        for i in 0..<photos {
            let id = "p\(i)-\(UUID().uuidString)"
            ids.append(id)
            let path = "/tmp/gather-parallel-probe/\(id).cr3"
            _ = try db.prepare("INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)")
                .run([.text(id), .text(sessionId), .text(path), .text(id + ".cr3"), .text(nowISOString()), .text(nowISOString())])
        }
        return (db, sessionId, ids)
    }

    private func service(_ db: DBConnection) -> MetadataService {
        MetadataService(
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            xmp: ParallelXMP(),
            connection: db,
            mutations: ParallelMutations(),
            assetResolver: nil,
            exif: ParallelExif(),
            dimensions: nil,
            embeddedReader: nil
        )
    }

    @Test("getMetadata：96 张并发提取，每张都必须出现在结果里（不崩溃/不丢行）")
    func getMetadataCollectsEveryPhoto() async throws {
        let (db, _, ids) = try makeDB(photos: 96)
        let result = try await service(db).getMetadata(photoIds: ids)
        #expect(result.count == ids.count)
        #expect(Set(result.keys) == Set(ids))
    }

    @Test("batchSet：96 项并发分组，成功计数与输入逐项对应")
    func batchSetCountsEveryUpdate() async throws {
        let (db, _, ids) = try makeDB(photos: 96)
        let updates = ids.map { (photoId: $0, tags: MetadataTags(rating: 3)) }
        let result = try await service(db).batchSet(updates: updates)
        #expect(result.success == ids.count)
        #expect(result.failed == 0)
        #expect(result.errors.isEmpty)
    }

    @Test("WritebackService.execute：64 项 Phase 1 并发入队不丢项（totalAffected 守恒）")
    func writebackExecutePreparesEveryItem() async throws {
        let (db, sessionId, ids) = try makeDB(photos: 64)
        let service = WritebackService(
            writebackRepo: WritebackRepo(connection: db),
            xmp: ParallelXMP(),
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            metadataSync: ParallelSync(),
            metadataMutations: ParallelMutations(),
            outboxRepo: nil,
            keywordOrigins: nil,
            assetResolver: nil
        )
        var additions: [String: [String]] = [:]
        for id in ids { additions[id] = ["kw"] }
        let preview = try await service.preview(sessionId: sessionId, module: "similarity", keywordAdditions: additions)
        #expect(preview.totalCount == ids.count)
        let result = try await service.execute(sessionId: sessionId, module: "similarity", items: preview.items)
        // Phase 1 全部入队；ParallelSync 的空 summary 使 Phase 2 逐项判失败 → 计数守恒。
        #expect(result.totalAffected == ids.count)
        #expect(result.written + result.failed + result.skipped == ids.count)
    }
}
