// Tests/GatherCoreTests/Store/DuplicateStoreTests.swift
// R1：DuplicateStore 测试（校验列/视觉 hash 落库、精确分组、分组重建、决议与状态重算）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/DuplicateStore (R1)")
struct DuplicateStoreTests {
    private func makeStore() async throws -> (SQLiteDuplicateStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "duplicate")
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        return (SQLiteDuplicateStore(database: database), database, path)
    }

    private func insertPhoto(
        _ database: SQLiteDatabase,
        id: String,
        checksum: String = "",
        status: String = "ready",
        sessionId: String = "s1"
    ) async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(sessionId), .text("/v/\(id).jpg"), .text("\(id).jpg"), .text(checksum), .text(status)]
        )
    }

    @Test func writeScanResultsUpdatesChecksumsAndVisualHashes() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1")
        try await insertPhoto(database, id: "p2")

        try await store.writeScanResults(
            sessionId: "s1",
            checksums: [
                DuplicateChecksumUpdate(photoId: "p1", checksum: "aaa", fileSize: 100, fileMtimeMs: 1_700_000_000_000),
                DuplicateChecksumUpdate(photoId: "p2", checksum: "aaa", fileSize: 100, fileMtimeMs: 1_700_000_000_001),
            ],
            visualHashes: [
                DuplicateHashUpsert(photoId: "p1", hashHex: "ff00", fileSize: 100, fileMtimeMs: 1_700_000_000_000),
                DuplicateHashUpsert(photoId: "p2", hashHex: "00ff", fileSize: 100, fileMtimeMs: 1_700_000_000_001),
            ]
        )

        let photos = try await store.photos(sessionId: "s1")
        #expect(photos.map(\.checksum) == ["aaa", "aaa"])
        #expect(photos[0].checksumFileSize == 100)
        #expect(photos[0].checksumFileMtimeMs == 1_700_000_000_000)

        // 同 (session, photo) 再写入 → UPSERT 覆盖。
        try await store.writeScanResults(
            sessionId: "s1",
            checksums: [],
            visualHashes: [DuplicateHashUpsert(photoId: "p1", hashHex: "1234", fileSize: 200, fileMtimeMs: 5)]
        )
        let hashes = try await store.visualHashes(sessionId: "s1")
        #expect(hashes.count == 2)
        let p1 = try #require(hashes.first { $0.photoId == "p1" })
        #expect(p1.hashHex == "1234")
        #expect(p1.fileSize == 200)
        #expect(p1.fileMtimeMs == 5)
    }

    @Test func exactDuplicateGroupsAndClusteringInput() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        for (id, checksum) in [("p1", "same"), ("p2", "same"), ("p3", "same"), ("p4", "other"), ("p5", "")] {
            try await insertPhoto(database, id: id, checksum: checksum)
        }

        let groups = try await store.exactDuplicateGroups(sessionId: "s1")
        #expect(groups.count == 1, "仅 >1 成员的 checksum 成组；空 checksum 排除")
        #expect(groups[0].checksum == "same")
        #expect(groups[0].photoIds == ["p1", "p2", "p3"])

        try await database.run(
            """
            INSERT INTO similarity_hashes (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
            VALUES ('s1', 'p2', 'bb', 10, 20), ('s1', 'p1', 'aa', 10, 20)
            """
        )
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s2', 'S2', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        try await insertPhoto(database, id: "x1", sessionId: "s2")
        try await database.run(
            "INSERT INTO similarity_hashes (session_id, photo_id, hash_hex, file_size, file_mtime_ms) VALUES ('s2', 'x1', 'cc', 1, 1)"
        )

        let pairs = try await store.hashesForClustering(sessionId: "s1")
        #expect(pairs.map(\.photoId) == ["p1", "p2"], "OTHER session 的 hash 不参与，按 photo_id 排序")
        #expect(pairs.map(\.hashHex) == ["aa", "bb"])
    }

    @Test func rebuildGroupsIsIdempotentAndResetsRemoved() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        for id in ["p1", "p2", "p3"] {
            try await insertPhoto(database, id: id, checksum: "same")
        }
        let fileInfo = [
            "p1": DuplicateFileInfo(size: 100, mtimeISO: "2026-01-01T00:00:00.000Z"),
            "p2": DuplicateFileInfo(size: 200, mtimeISO: "2026-02-01T00:00:00.000Z"),
        ]

        let first = try await store.rebuildGroups(
            sessionId: "s1",
            exact: [DuplicateExactGroupInput(checksum: "same", photoIds: ["p1", "p2"])],
            visual: [DuplicateVisualGroupInput(hashHex: "ab", photoIds: ["p2", "p3"])],
            fileInfo: fileInfo,
            createdAt: "2026-01-01T00:00:00.000Z"
        )
        #expect(first.exact.count == 1)
        #expect(first.visual.count == 1)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM duplicate_groups") == 2)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM duplicate_group_members") == 4)

        // 决议移除 p2 后再次扫描：removed 复位为 ready，旧组整体替换（id 变化、无残留）。
        try await store.rebuildGroups(
            sessionId: "s1",
            exact: [DuplicateExactGroupInput(checksum: "same", photoIds: ["p1", "p2"])],
            visual: [DuplicateVisualGroupInput(hashHex: "ab", photoIds: ["p2", "p3"])],
            fileInfo: fileInfo,
            createdAt: "2026-01-01T00:00:00.000Z"
        )
        let second = try await store.groups(sessionId: "s1")
        #expect(second.count == 2)
        #expect(second.map(\.groupType) == ["exact", "visual"])
        #expect(second.allSatisfy { $0.memberCount == 2 })
        #expect(second.allSatisfy { $0.resolution == nil })
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM duplicate_group_members") == 4)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM photos WHERE status = 'removed'") == 0)
    }

    @Test func groupsAndMembersReadBackWithFileInfo() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        for id in ["p1", "p2"] {
            try await insertPhoto(database, id: id, checksum: "same")
        }
        let ids = try await store.rebuildGroups(
            sessionId: "s1",
            exact: [DuplicateExactGroupInput(checksum: "same", photoIds: ["p1", "p2"])],
            visual: [],
            fileInfo: ["p1": DuplicateFileInfo(size: 111, mtimeISO: "2026-01-01T00:00:00.000Z")],
            createdAt: "2026-01-01T00:00:00.000Z"
        )

        let groups = try await store.groups(sessionId: "s1")
        #expect(groups.count == 1)
        #expect(groups[0].id == ids.exact[0])
        #expect(groups[0].checksum == "same")
        #expect(groups[0].hashHex == nil)
        #expect(groups[0].memberCount == 2)
        #expect(groups[0].createdAt == "2026-01-01T00:00:00.000Z")

        let members = try await store.members(groupIds: [groups[0].id])
        let list = try #require(members[groups[0].id])
        #expect(list.count == 2)
        #expect(list.map(\.photoId) == ["p1", "p2"])
        #expect(list.allSatisfy { $0.isKept })
        #expect(list[0].fileSize == 111)
        #expect(list[0].fileMtime == "2026-01-01T00:00:00.000Z")
        #expect(list[1].fileSize == nil, "无 stat 信息的成员 file_size 为 NULL")
        #expect(try await store.members(groupId: groups[0].id).count == 2)
        #expect(try await store.members(groupIds: []).isEmpty)
    }

    @Test func applyResolutionAndResolveMemberRecomputeStatuses() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        for id in ["p1", "p2"] {
            try await insertPhoto(database, id: id, checksum: "same")
        }
        _ = try await store.rebuildGroups(
            sessionId: "s1",
            exact: [DuplicateExactGroupInput(checksum: "same", photoIds: ["p1", "p2"])],
            visual: [],
            fileInfo: [:],
            createdAt: "2026-01-01T00:00:00.000Z"
        )
        let group = try await store.groups(sessionId: "s1")[0]
        let members = try await store.members(groupId: group.id)
        let keptId = members[0].id

        try await store.applyResolution(groupId: group.id, resolution: "keep_one", keptMemberIds: [keptId])
        #expect(try await store.groups(sessionId: "s1")[0].resolution == "keep_one")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM photos WHERE status = 'removed'") == 1)
        let after = try await database.queryOne("SELECT status FROM photos WHERE id = 'p2'")
        #expect(after?.text("status") == "removed", "被移除成员的照片状态 → removed")

        // 单成员恢复保留 → 状态回到 ready。
        let removedMember = try #require(members.first { $0.id != keptId })
        let photoId = try await store.resolveMember(memberId: removedMember.id, isKept: true)
        #expect(photoId == "p2")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM photos WHERE status = 'removed'") == 0)

        // 不存在的成员/组。
        await #expect(throws: DuplicateStoreError.memberNotFound(999)) {
            _ = try await store.resolveMember(memberId: 999, isKept: true)
        }
        await #expect(throws: DuplicateStoreError.groupNotFound(999)) {
            try await store.applyResolution(groupId: 999, resolution: "keep_all", keptMemberIds: [])
        }
    }
}
