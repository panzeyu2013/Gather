// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Metadata/WritebackRuntimeTests.swift
// R4：WritebackRuntime 直测由 Tests/.../Services/MetadataSyncCoordinatorTests.swift
// 迁入 Runtime/Metadata/（被测公开类型/签名不变，2 tests / 1 suite 逐字搬迁；
// 用例数不降）。共享替身：FakeFSXMPProvider（仍随 coordinator 直测文件，internal
// 可见）；Store fixture 来自 Support/RepoTestSupport.swift。

import Foundation
import Testing
@testable import GatherCore

// MARK: - WritebackRuntime 直测

/// MetadataMutationPort 替身：无资产解析器环境下按 photoId 查 filepath，
/// 复刻 queuePhotoValues 的 mergePatch 语义（source 注入 + dirty 过滤）。
private struct StubMutationPort: MetadataMutationPort {
    let db: SQLiteDatabase
    let outbox: SQLiteWritebackStore

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) async throws -> MetadataMutationResult {
        let row = try await db.queryOne("SELECT filepath FROM photos WHERE id = ? AND session_id = ?", [.text(photoId), .text(sessionId)])
        let photoPath = row?.text(at: 0) ?? photoId
        let xmpPath = TSPath.xmpSidecarPath(photoPath)
        let dirtyFields = values.keys
            .filter { ["rating", "label", "keywords"].contains($0) }
            .compactMap { MetadataField(rawValue: $0) }
        var patch = values
        patch["source"] = .string(source.rawValue)
        let merged = try await outbox.mergeOutboxPatch(
            xmpPath: xmpPath,
            sessionId: sessionId,
            photoPath: photoPath,
            patch: .object(patch),
            dirtyFields: dirtyFields.map(\.rawValue)
        )
        return MetadataMutationResult(
            photoId: photoId,
            xmpPath: merged.xmpPath,
            dirtyFields: dirtyFields,
            revision: Int(merged.revision),
            status: merged.status
        )
    }

    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        try await queuePhotoValues(
            sessionId: sessionId, photoId: photoId, values: [:], source: source, schedule: false)
    }
}

@Suite(.serialized)
struct WritebackRuntimeTests {
    @Test func previewThenExecuteWritesSidecarAndReportsResult() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-wb-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-writeback-tests-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let sessionId = "s-\(UUID().uuidString)"
        let photoId = "p1"
        let photoPath = "\(dir)/photo.cr3"
        _ = try await db.run("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)", [.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        _ = try await db.run("INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at) VALUES (?, ?, ?, 'photo.cr3', ?, ?)", [.text(photoId), .text(sessionId), .text(photoPath), .text(nowISOString()), .text(nowISOString())])

        let provider = FakeFSXMPProvider()
        let outbox = try SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath))
        let coordinator = MetadataSyncRuntime(
            writebackStore: SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath)),
            xmp: provider,
            sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
            getNumber: { _, defaultValue in defaultValue },
            skipReloadAck: false
        )
        let service = WritebackRuntime(
            writebackStore: SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath)),
            xmp: provider,
            photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
            sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
            metadataSync: coordinator,
            metadataMutations: StubMutationPort(db: db, outbox: outbox),
            metadataStore: nil,
            assetResolver: nil
        )

        let preview = try await service.preview(
            sessionId: sessionId,
            module: "similarity",
            keywordAdditions: [photoId: ["groupA", "portrait"]]
        )
        #expect(preview.totalCount == 1)
        #expect(preview.affectedPhotos == 1)
        #expect(preview.items.first?.keywords == ["groupA", "portrait"])

        let result = try await service.execute(sessionId: sessionId, module: "similarity", items: preview.items)
        #expect(result.written == 1)
        #expect(result.failed == 0)
        #expect(result.errors.isEmpty)

        // 侧车真实写入关键词；outbox 行 written；writeback_items 状态落盘。
        let written = try await provider.readAttributes(photoPath: photoPath)
        #expect(written.keywords == ["groupA", "portrait"])
        #expect(try await outbox.outboxEntry(xmpPath: TSPath.xmpSidecarPath(photoPath))?.status == "written")
        let items = try await service.getItems(sessionId: sessionId, module: "similarity")
        #expect(items.count == 1)
        #expect(items.first?.xmpStatus == "written")

        await coordinator.shutdown()
    }

    /// 另一模块存在未确认写回时，preview 必须被互斥门拦截。
    @Test func previewBlockedByOtherModuleActive() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-wb-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-writeback-tests-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let sessionId = "s-\(UUID().uuidString)"
        let photoId = "p1"
        let photoPath = "\(dir)/photo.cr3"
        _ = try await db.run("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)", [.text(sessionId), .text("t"), .text(nowISOString()), .text(nowISOString())])
        _ = try await db.run("INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at) VALUES (?, ?, ?, 'photo.cr3', ?, ?)", [.text(photoId), .text(sessionId), .text(photoPath), .text(nowISOString()), .text(nowISOString())])

        let outbox = try SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath))
        // face_kw 模块的 written 行（另一模块未确认的工作）。
        _ = try await outbox.mergeOutboxPatch(
            xmpPath: TSPath.xmpSidecarPath(photoPath),
            sessionId: sessionId,
            photoPath: photoPath,
            patch: JSONValue.object([
                "keywords": .array([.string("kw")]),
                "source": .string("face-keyword"),
            ]),
            dirtyFields: ["keywords"]
        )
        try await outbox.markOutboxWritten(
            xmpPath: TSPath.xmpSidecarPath(photoPath),
            revision: 1,
            fingerprint: "fp",
            baseValues: JSONValue.object([:]),
            backupPath: ""
        )

        let provider = FakeFSXMPProvider()
        let coordinator = MetadataSyncRuntime(
            writebackStore: SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath)),
            xmp: provider,
            sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
            getNumber: { _, defaultValue in defaultValue },
            skipReloadAck: false
        )
        let service = WritebackRuntime(
            writebackStore: SQLiteWritebackStore(database: try SQLiteDatabase(path: dbPath)),
            xmp: provider,
            photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
            sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
            metadataSync: coordinator,
            metadataMutations: StubMutationPort(db: db, outbox: outbox),
            metadataStore: nil,
            assetResolver: nil
        )

        do {
            _ = try await service.preview(sessionId: sessionId, module: "similarity")
            Issue.record("expected otherModuleActive")
        } catch let error as WritebackRuntimeError {
            #expect(error == .otherModuleActive)
        }

        await coordinator.shutdown()
    }
}
