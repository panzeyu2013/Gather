// Tests/GatherCoreTests/Store/DuplicateStoreQueryTests.swift
// W2c Store 测试：DuplicateStore.groups(ids:) / membersWithPhoto(groupIds:)
// （原 Services/DuplicateService.swift 606-645 行 fetchGroups/fetchMembers 内联 SQL 的 Store 化）。
// 断言重点：JOIN photos 字段齐全、组 = id 序 / 成员 = dgm.id 序、空参数返回 [] / [:]。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/DuplicateStoreQuery (W2c)")
struct DuplicateStoreQueryTests {
    private func makeStore() async throws -> (store: SQLiteDuplicateStore, database: SQLiteDatabase) {
        let database = try await makeMigratedStore(path: storeTempPath("duplicate-query"))
        try await insertSession(database, "s1")
        for id in ["p1", "p2", "p3", "p4", "p5"] {
            try await insertPhoto(database, id: id, sessionId: "s1")
        }
        return (SQLiteDuplicateStore(database: database), database)
    }

    /// 一组精确 + 一组视觉（组 id 由 rebuildGroups 返回，顺序即插入序）。
    private func makeGroups(_ store: SQLiteDuplicateStore) async throws -> (exact: [Int], visual: [Int]) {
        try await store.rebuildGroups(
            sessionId: "s1",
            exact: [DuplicateExactGroupInput(checksum: "sum-a", photoIds: ["p1", "p2"])],
            visual: [DuplicateVisualGroupInput(hashHex: "hash-b", photoIds: ["p3", "p4", "p5"])],
            fileInfo: [:],
            createdAt: "2026-01-01T00:00:00.000Z"
        )
    }

    // MARK: - groups(ids:)

    @Test("groups(ids:)：字段齐全（exact/visual 互斥列 NULL）、按 id 升序")
    func groupsByIdFields() async throws {
        let (store, _) = try await makeStore()
        let ids = try await makeGroups(store)

        #expect(try await store.groups(ids: []).isEmpty)
        #expect(try await store.groups(ids: [999_999]).isEmpty)

        let all = try await store.groups(ids: ids.exact + ids.visual)
        #expect(all.map(\.id) == ids.exact + ids.visual, "ORDER BY id")
        #expect(all.count == 2)

        let exact = try #require(all.first { $0.groupType == "exact" })
        #expect(exact.sessionId == "s1")
        #expect(exact.checksum == "sum-a")
        #expect(exact.hashHex == nil)
        #expect(exact.memberCount == 2)
        #expect(exact.resolution == nil)
        #expect(exact.createdAt == "2026-01-01T00:00:00.000Z")

        let visual = try #require(all.first { $0.groupType == "visual" })
        #expect(visual.checksum == nil)
        #expect(visual.hashHex == "hash-b")
        #expect(visual.memberCount == 3)
    }

    @Test("groups(ids:)：只返回请求的组（子集）")
    func groupsByIdSubset() async throws {
        let (store, _) = try await makeStore()
        let ids = try await makeGroups(store)
        let only = try await store.groups(ids: [ids.visual[0]])
        #expect(only.map(\.id) == ids.visual)
        #expect(only.allSatisfy { $0.groupType == "visual" })
    }

    // MARK: - membersWithPhoto(groupIds:)

    @Test("membersWithPhoto：JOIN photos 的 filepath/filename 齐全、成员按 dgm.id 序")
    func membersWithPhotoJoinFields() async throws {
        let (store, _) = try await makeStore()
        let ids = try await makeGroups(store)

        #expect(try await store.membersWithPhoto(groupIds: []).isEmpty)

        let members = try await store.membersWithPhoto(groupIds: [ids.exact[0]])
        let exactMembers = try #require(members[ids.exact[0]])
        #expect(exactMembers.map(\.photoId) == ["p1", "p2"], "ORDER BY dgm.id")
        let first = try #require(exactMembers.first)
        #expect(first.groupId == ids.exact[0])
        #expect(first.sessionId == "s1")
        #expect(first.filepath == "/tmp/fixtures/p1.jpg")
        #expect(first.filename == "p1.jpg")
        #expect(first.isKept, "重组后成员默认 is_kept=1")
        #expect(first.fileSize == nil, "fileInfo 为空 → NULL")
        #expect(first.fileMtime == nil)
        #expect(first.resolution == nil)
    }

    @Test("membersWithPhoto：多组各归其组，未请求的组不返回（空组不产生键）")
    func membersWithPhotoGrouping() async throws {
        let (store, _) = try await makeStore()
        let ids = try await makeGroups(store)

        let both = try await store.membersWithPhoto(groupIds: ids.exact + ids.visual)
        #expect(both.count == 2)
        #expect(both[ids.exact[0]]?.map(\.photoId) == ["p1", "p2"])
        #expect(both[ids.visual[0]]?.map(\.photoId) == ["p3", "p4", "p5"])
        #expect(both[ids.visual[0]]?.allSatisfy { $0.filepath.hasPrefix("/tmp/fixtures/") } == true)

        let visualOnly = try await store.membersWithPhoto(groupIds: [ids.visual[0]])
        #expect(visualOnly.keys.sorted() == [ids.visual[0]].sorted())
        #expect(visualOnly[ids.exact[0]] == nil, "未请求的组不得出现")
    }
}
