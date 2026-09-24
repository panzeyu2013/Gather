// Tests/GatherCoreTests/API/NavigationCommandsImplTests.swift
// R5：navigation 域命令实现直测（批次 B3）。
// 覆盖旧路由分支语义：analyze 缺省值（2 / 1800 / false）与落库回读、list 过滤
// 单张组、split 顺序切分、merge 组数重校验；错误路径 NAV_BURST_GAP_INVALID /
// NAV_GROUP_NOT_FOUND / NAV_SPLIT_OUT_OF_GROUP / NAV_MERGE_MIN_TWO。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/NavigationCommandsImpl (R5)")
struct NavigationCommandsImplTests {
    private struct Harness {
        let impl: NavigationCommandsImpl
        let db: SQLiteDatabase
        let store: SQLiteNavigationStore
        let path: String
    }

    private func makeHarness() async throws -> Harness {
        let path = storeTempPath("navigation-commands")
        let db = try await makeMigratedStore(path: path)
        try await insertSession(db, "s1")
        let store = SQLiteNavigationStore(database: db)
        return Harness(
            impl: NavigationCommandsImpl(navigation: NavigationRuntime(store: store)),
            db: db, store: store, path: path
        )
    }

    private func insertPhoto(_ db: SQLiteDatabase, id: String, capturedAt: String) async throws {
        let name = "\(id).jpg"
        _ = try await db.run("""
            INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
            VALUES (?, 's1', ?, ?, 'ready', ?, ?)
            """, [
                .text(id), .text("/photos/\(name)"), .text(name),
                .text(capturedAt), .text(capturedAt),
            ])
    }

    private func insertGroup(
        _ store: SQLiteNavigationStore, id: String, type: String, photoIds: [String]
    ) async throws {
        try await store.insertGroup(sessionId: "s1", group: NavigationGroupInsert(
            id: id,
            groupType: type,
            photoIdsJSON: NavigationAssembler.photoIdsJSON(photoIds),
            leadPhotoId: nil,
            explanation: "manual",
            source: "manual",
            fingerprint: ""
        ))
    }

    /// 返回 NavigationError 的错误码；成功返回 nil，其他错误返回 UNEXPECTED 前缀。
    private func errorCode(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch let error as NavigationError {
            return error.description
        } catch {
            return "UNEXPECTED:\(error)"
        }
    }

    private static let t0 = "2026-01-01T00:00:00.000Z"
    private static let t1 = "2026-01-01T00:00:01.000Z"
    private static let t2 = "2026-01-01T00:00:02.000Z"
    private static let t3 = "2026-01-01T00:00:03.000Z"
    private static let t4 = "2026-01-01T01:00:00.000Z"

    @Test("analyze applies the default gaps and persists groups")
    func analyzeUsesDefaults() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertPhoto(harness.db, id: "p1", capturedAt: Self.t0)
        try await insertPhoto(harness.db, id: "p2", capturedAt: Self.t1)
        try await insertPhoto(harness.db, id: "p3", capturedAt: Self.t2)
        try await insertPhoto(harness.db, id: "p4", capturedAt: Self.t4)

        let groups = try await harness.impl.analyze(NavigationAnalyzeParams(sessionId: "s1"))

        // 缺省 burst 2 / scene 1800：p1-p3 各成一 burst/scene 组；p4 单张被过滤。
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.photoIds == ["p1", "p2", "p3"] })
        #expect(groups.contains { $0.type == .burst })
        #expect(groups.contains { $0.type == .scene })
        #expect(!groups.contains { $0.photoIds.contains("p4") })

        // 第二次调用命中缓存指纹，返回同一批组。
        let cached = try await harness.impl.analyze(NavigationAnalyzeParams(sessionId: "s1"))
        #expect(Set(cached.map(\.id)) == Set(groups.map(\.id)))
    }

    @Test("analyze rejects an invalid burst gap with NAV_BURST_GAP_INVALID")
    func analyzeRejectsInvalidIntervals() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertPhoto(harness.db, id: "p1", capturedAt: Self.t0)

        let code = await errorCode {
            _ = try await harness.impl.analyze(
                NavigationAnalyzeParams(sessionId: "s1", burstGapSeconds: 0))
        }
        #expect(code == "NAV_BURST_GAP_INVALID")
    }

    @Test("list returns only groups with at least two photos")
    func listFiltersSinglePhotoGroups() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertPhoto(harness.db, id: "p1", capturedAt: Self.t0)
        try await insertPhoto(harness.db, id: "p2", capturedAt: Self.t1)
        try await insertPhoto(harness.db, id: "p3", capturedAt: Self.t2)
        try await insertGroup(harness.store, id: "g1", type: "burst", photoIds: ["p1", "p2"])
        try await insertGroup(harness.store, id: "g2", type: "burst", photoIds: ["p3"])

        let groups = try await harness.impl.list(NavigationListParams(sessionId: "s1"))

        #expect(groups.count == 1)
        #expect(groups.first?.id == "g1")
        #expect(groups.first?.photoIds == ["p1", "p2"])
        #expect(groups.first?.startAt == Self.t0)
        #expect(groups.first?.endAt == Self.t1)
    }

    @Test("split cuts before the given photo and reports the tail group")
    func splitCutsBeforePhoto() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertPhoto(harness.db, id: "p1", capturedAt: Self.t0)
        try await insertPhoto(harness.db, id: "p2", capturedAt: Self.t1)
        try await insertPhoto(harness.db, id: "p3", capturedAt: Self.t2)
        try await insertGroup(harness.store, id: "g1", type: "burst", photoIds: ["p1", "p2", "p3"])

        let groups = try await harness.impl.split(NavigationSplitParams(
            sessionId: "s1", groupId: "g1", beforePhotoId: "p2"))

        // 前半段单张被 list 过滤，只剩 [p2, p3]，来源 manual。
        #expect(groups.count == 1)
        #expect(groups.first?.photoIds == ["p2", "p3"])
        #expect(groups.first?.source == .manual)

        let outOfGroup = await errorCode {
            _ = try await harness.impl.split(NavigationSplitParams(
                sessionId: "s1", groupId: groups[0].id, beforePhotoId: "p2"))
        }
        #expect(outOfGroup == "NAV_SPLIT_OUT_OF_GROUP")

        let notFound = await errorCode {
            _ = try await harness.impl.split(NavigationSplitParams(
                sessionId: "s1", groupId: "missing", beforePhotoId: "p2"))
        }
        #expect(notFound == "NAV_GROUP_NOT_FOUND")
    }

    @Test("merge combines groups and rejects a single group id")
    func mergeCombinesAndValidates() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertPhoto(harness.db, id: "p1", capturedAt: Self.t0)
        try await insertPhoto(harness.db, id: "p2", capturedAt: Self.t1)
        try await insertPhoto(harness.db, id: "p3", capturedAt: Self.t2)
        try await insertPhoto(harness.db, id: "p4", capturedAt: Self.t3)
        try await insertGroup(harness.store, id: "g1", type: "burst", photoIds: ["p1", "p2"])
        try await insertGroup(harness.store, id: "g2", type: "burst", photoIds: ["p3", "p4"])

        let merged = try await harness.impl.merge(
            NavigationMergeParams(sessionId: "s1", groupIds: ["g1", "g2"]))

        #expect(merged.count == 1)
        #expect(merged.first?.photoIds == ["p1", "p2", "p3", "p4"])
        #expect(merged.first?.source == .manual)

        let minTwo = await errorCode {
            _ = try await harness.impl.merge(
                NavigationMergeParams(sessionId: "s1", groupIds: ["g1"]))
        }
        #expect(minTwo == "NAV_MERGE_MIN_TWO")
    }
}
