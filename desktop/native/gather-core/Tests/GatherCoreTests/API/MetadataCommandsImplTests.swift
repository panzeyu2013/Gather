// Tests/GatherCoreTests/API/MetadataCommandsImplTests.swift
// R5：metadata 域命令实现直测（批次 B5）。
// 覆盖旧路由分支语义：get 的 photoIds 非空门控与 XMP 提取、set / batch_set 的
// confirmed 门控与落库（含 updates 非空消息逐字）、conflicts 读取冲突、
// resolve_conflict（XMP_CHOICE_MISSING / use_remote 裁决）、orphans 列出、
// resolve_orphan（keep 删除孤儿行 / 未知路径 XMP_ORPHAN_NOT_FOUND）。
import Foundation
import Testing
@testable import GatherCore

// MARK: - 替身（metadata 变更端口）

private actor MetadataCommandsFakeMutations: MetadataMutationPort {
    struct Recorded: Sendable, Equatable {
        let sessionId: String
        let photoId: String
        let source: MetadataMutationSource
    }

    private(set) var recorded: [Recorded] = []

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) async throws -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending")
    }

    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        recorded.append(Recorded(sessionId: sessionId, photoId: photoId, source: source))
        return MetadataMutationResult(
            photoId: photoId,
            xmpPath: "/sidecars/\(photoId).xmp",
            dirtyFields: [.rating, .label, .keywords],
            revision: recorded.count,
            status: "pending"
        )
    }
}

// MARK: - 基座

private struct MetadataCommandsHarness {
    let impl: MetadataCommandsImpl
    let db: SQLiteDatabase
    let metadata: SQLiteMetadataStore
    let outbox: SQLiteWritebackStore
    let provider: FakeFSXMPProvider
    let mutations: MetadataCommandsFakeMutations
    let dir: String
    let storePath: String

    func cleanup() {
        try? FileManager.default.removeItem(atPath: dir)
        removeStoreFiles(storePath)
    }
}

private func makeHarness() async throws -> MetadataCommandsHarness {
    let storePath = storeTempPath("metadata-commands")
    let db = try await makeMigratedStore(path: storePath)
    try await insertSession(db, "s1")
    let metadata = SQLiteMetadataStore(database: db)
    let provider = FakeFSXMPProvider()
    let mutations = MetadataCommandsFakeMutations()
    let service = MetadataService(
        metadataStore: metadata,
        xmp: provider,
        database: db,
        mutations: mutations,
        photoStore: SQLitePhotoStore(database: db)
    )
    let sync = MetadataSyncRuntime(
        writebackStore: SQLiteWritebackStore(database: db),
        xmp: provider,
        sessionStore: SQLiteSessionStore(database: db),
        getNumber: { _, defaultValue in defaultValue },
        skipReloadAck: false
    )
    return MetadataCommandsHarness(
        impl: MetadataCommandsImpl(metadata: service, sync: sync),
        db: db,
        metadata: metadata,
        outbox: SQLiteWritebackStore(database: db),
        provider: provider,
        mutations: mutations,
        dir: storeTempDir("metadata-commands-files"),
        storePath: storePath
    )
}

/// 造一条 conflict 状态的 outbox 行：sidecar 现值为 remoteRating，基线为 {}。
@discardableResult
private func seedConflict(
    _ harness: MetadataCommandsHarness,
    name: String = "conflict.cr3",
    remoteRating: Double = 3
) async throws -> String {
    let photoPath = harness.dir + "/" + name
    let xmpPath = photoPath + ".xmp"
    try await harness.provider.writeAttributes(
        photoPath: photoPath, attributes: MetadataWriteAttributes(rating: remoteRating))
    _ = try await harness.outbox.mergeOutboxPatch(
        xmpPath: xmpPath,
        sessionId: "s1",
        photoPath: photoPath,
        patch: .object(["rating": .number(5)]),
        dirtyFields: ["rating"]
    )
    try await harness.outbox.markOutboxStatus(
        xmpPath: xmpPath, status: "conflict", errorMessage: "")
    return xmpPath
}

/// 造一条孤儿行：outbox 有行但会话关联已删除（orphanOutbox 判定）。
private func seedOrphan(
    _ harness: MetadataCommandsHarness,
    name: String = "orphan.cr3"
) async throws -> (photoPath: String, xmpPath: String) {
    let photoPath = harness.dir + "/" + name
    let xmpPath = photoPath + ".xmp"
    _ = try await harness.outbox.mergeOutboxPatch(
        xmpPath: xmpPath,
        sessionId: "s1",
        photoPath: photoPath,
        patch: .object(["rating": .number(1)]),
        dirtyFields: ["rating"]
    )
    _ = try await harness.db.run(
        "DELETE FROM metadata_outbox_sessions WHERE xmp_path = ?", [.text(xmpPath)])
    return (photoPath, xmpPath)
}

// MARK: - 用例

@Suite("API/MetadataCommandsImpl (R5)")
struct MetadataCommandsImplTests {
    @Test("get rejects an empty photoIds with INVALID_PARAM:photoIds")
    func getRejectsEmptyPhotoIds() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }

        await #expect(throws: MetadataCommandsError.invalidParam("photoIds")) {
            _ = try await harness.impl.get(MetadataGetParams(photoIds: []))
        }
        #expect(String(describing: MetadataCommandsError.invalidParam("photoIds"))
            == "INVALID_PARAM:photoIds")
    }

    @Test("get extracts tags through MetadataService")
    func getExtractsTags() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let filepath = try writeTempFile(in: harness.dir, name: "p1.jpg")
        try await insertPhoto(harness.db, id: "p1", sessionId: "s1", filepath: filepath)
        try await harness.provider.writeAttributes(
            photoPath: filepath,
            attributes: MetadataWriteAttributes(keywords: ["k1", "k2"], rating: 3, label: "Blue"))

        let tags = try await harness.impl.get(MetadataGetParams(photoIds: ["p1"]))

        #expect(tags.count == 1)
        #expect(tags["p1"]?.keywords == ["k1", "k2"])
        #expect(tags["p1"]?.rating == 3)
        #expect(tags["p1"]?.label == "Blue")
    }

    @Test("set requires confirmation with METADATA_SET_CONFIRM_REQUIRED")
    func setRequiresConfirmation() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        try await insertPhoto(harness.db, id: "p1", sessionId: "s1", filepath: "/v/p1.jpg")

        await #expect(throws: MetadataCommandsError.setConfirmRequired) {
            _ = try await harness.impl.set(MetadataSetParams(
                photoId: "p1", tags: MetadataTags(rating: 5), confirmed: false))
        }
        #expect(String(describing: MetadataCommandsError.setConfirmRequired)
            == "METADATA_SET_CONFIRM_REQUIRED")
        #expect(MetadataCommandsError.setConfirmRequired.gatherCode
            == GatherErrorCode.METADATA_SET_CONFIRM_REQUIRED)
        let recorded = await harness.mutations.recorded
        #expect(recorded.isEmpty, "门控失败不应入队")
    }

    @Test("set persists tags and queues a manual mutation when confirmed")
    func setPersistsTags() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        try await insertPhoto(harness.db, id: "p1", sessionId: "s1", filepath: "/v/p1.jpg")

        let merged = try await harness.impl.set(MetadataSetParams(
            photoId: "p1", tags: MetadataTags(rating: 5, label: "Green"), confirmed: true))

        #expect(merged.rating == 5)
        #expect(merged.label == "Green")
        let cached = try await harness.metadata.metadata(photoId: "p1")
        #expect(cached?.rating == 5)
        #expect(cached?.label == "Green")
        let recorded = await harness.mutations.recorded
        #expect(recorded.count == 1)
        #expect(recorded.first?.source == .manual)
    }

    @Test("batchSet requires confirmation and rejects an empty updates array")
    func batchSetGates() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }

        await #expect(throws: MetadataCommandsError.batchSetConfirmRequired) {
            _ = try await harness.impl.batchSet(MetadataBatchSetParams(
                updates: [MetadataBatchUpdate(photoId: "p1", tags: MetadataTags(rating: 1))],
                confirmed: false))
        }
        await #expect(throws: MetadataCommandsError.invalidUpdates) {
            _ = try await harness.impl.batchSet(MetadataBatchSetParams(
                updates: [], confirmed: true))
        }
        #expect(String(describing: MetadataCommandsError.batchSetConfirmRequired)
            == "METADATA_BATCH_SET_CONFIRM_REQUIRED")
        #expect(String(describing: MetadataCommandsError.invalidUpdates)
            == "Invalid updates: must be a non-empty array")
        #expect(MetadataCommandsError.batchSetConfirmRequired.gatherCode
            == GatherErrorCode.METADATA_BATCH_SET_CONFIRM_REQUIRED)
    }

    @Test("batchSet isolates per-item failures")
    func batchSetIsolatesFailures() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        try await insertPhoto(harness.db, id: "p1", sessionId: "s1", filepath: "/v/b1.jpg")
        try await insertPhoto(harness.db, id: "p2", sessionId: "s1", filepath: "/v/b2.jpg")

        let result = try await harness.impl.batchSet(MetadataBatchSetParams(
            updates: [
                MetadataBatchUpdate(photoId: "p1", tags: MetadataTags(rating: 4)),
                // 不支持字段：MetadataService 逐项隔离为失败（确定性错误路径）。
                MetadataBatchUpdate(photoId: "p2", tags: MetadataTags(dateTaken: "2024:01:01")),
            ],
            confirmed: true
        ))

        #expect(result.success == 1)
        #expect(result.failed == 1)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.hasPrefix("p2: ") == true)
    }

    @Test("conflicts lists the seeded outbox conflict")
    func conflictsListsSeeded() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let xmpPath = try await seedConflict(harness)

        let conflicts = try await harness.impl.conflicts(
            MetadataConflictListParams(sessionId: "s1"))

        #expect(conflicts.count == 1)
        #expect(conflicts.first?.xmpPath == xmpPath)
        #expect(conflicts.first?.fields.map(\.field) == [.rating])
        #expect(conflicts.first?.fields.first?.remote == .number(3))
    }

    @Test("resolveConflict requires confirmation and enforces full choices coverage")
    func resolveConflictGates() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let xmpPath = try await seedConflict(harness)

        await #expect(throws: MetadataCommandsError.resolveConflictConfirmRequired) {
            _ = try await harness.impl.resolveConflict(MetadataConflictResolveParams(
                sessionId: "s1", xmpPath: xmpPath, choices: [.rating: .useRemote], confirmed: false))
        }
        #expect(String(describing: MetadataCommandsError.resolveConflictConfirmRequired)
            == "METADATA_RESOLVE_CONFLICT_CONFIRM_REQUIRED")

        do {
            _ = try await harness.impl.resolveConflict(MetadataConflictResolveParams(
                sessionId: "s1", xmpPath: xmpPath, choices: [:], confirmed: true))
            Issue.record("choices 未覆盖全部字段应抛 XMP_CHOICE_MISSING")
        } catch let error as MetadataSyncError {
            #expect(error.description == "XMP_CHOICE_MISSING")
        }
    }

    @Test("resolveConflict applies the remote choice and clears the conflict")
    func resolveConflictAppliesRemoteChoice() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let xmpPath = try await seedConflict(harness)

        let summary = try await harness.impl.resolveConflict(MetadataConflictResolveParams(
            sessionId: "s1", xmpPath: xmpPath, choices: [.rating: .useRemote], confirmed: true))

        #expect(summary.sessionId == "s1")
        #expect(summary.conflict == 0)
        let remaining = try await harness.impl.conflicts(
            MetadataConflictListParams(sessionId: "s1"))
        #expect(remaining.isEmpty)
    }

    @Test("orphans lists orphan rows and resolve_orphan keep removes them")
    func orphansListAndKeepRemoves() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        let (photoPath, xmpPath) = try await seedOrphan(harness)

        let orphans = try await harness.impl.orphans()
        #expect(orphans.count == 1)
        #expect(orphans.first?.xmpPath == xmpPath)
        #expect(orphans.first?.photoPath == photoPath)
        #expect(orphans.first?.status == "pending")

        let remaining = try await harness.impl.resolveOrphan(MetadataOrphanResolveParams(
            xmpPath: xmpPath, action: .keep, confirmed: true))
        #expect(remaining.isEmpty)
        let after = try await harness.impl.orphans()
        #expect(after.isEmpty)
    }

    @Test("resolveOrphan requires confirmation and rejects an unknown path")
    func resolveOrphanGates() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        _ = try await seedOrphan(harness)

        await #expect(throws: MetadataCommandsError.resolveOrphanConfirmRequired) {
            _ = try await harness.impl.resolveOrphan(MetadataOrphanResolveParams(
                xmpPath: "/v/any.xmp", action: .keep, confirmed: false))
        }
        #expect(String(describing: MetadataCommandsError.resolveOrphanConfirmRequired)
            == "METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED")
        #expect(MetadataCommandsError.resolveOrphanConfirmRequired.gatherCode
            == GatherErrorCode.METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED)

        do {
            _ = try await harness.impl.resolveOrphan(MetadataOrphanResolveParams(
                xmpPath: "/v/missing.xmp", action: .keep, confirmed: true))
            Issue.record("未知 xmpPath 应抛 XMP_ORPHAN_NOT_FOUND")
        } catch let error as MetadataSyncError {
            #expect(error.description == "XMP_ORPHAN_NOT_FOUND")
        }
    }
}
