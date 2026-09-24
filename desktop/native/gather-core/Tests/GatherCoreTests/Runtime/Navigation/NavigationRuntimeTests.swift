// Tests/GatherCoreTests/Runtime/Navigation/NavigationRuntimeTests.swift
// W2d 小步②：NavigationRuntime actor 测试。
// - 主路径用真实 SQLiteNavigationStore + 迁移库（makeMigratedStoreDatabase），覆盖
//   list / split / merge / analyze 的行为与 NAV_* 错误码、抛出顺序、持久化副作用。
// - 取消断言严格限时（TaskGroup + 5s 看门狗），不做无界轮询。
import Foundation
import Testing
@testable import GatherCore

@Suite("NavigationRuntime (W2d-2)")
struct NavigationRuntimeTests {

    // MARK: - 基座

    private struct Harness {
        let runtime: NavigationRuntime
        let store: SQLiteNavigationStore
        let database: SQLiteDatabase
        let path: String
    }

    private func makeHarness(label: String = "navigation-runtime") async throws -> Harness {
        let (database, path) = try await makeMigratedStoreDatabase(label: label)
        try await database.run("""
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """)
        let store = SQLiteNavigationStore(database: database)
        return Harness(runtime: NavigationRuntime(store: store), store: store, database: database, path: path)
    }

    @discardableResult
    private func insertPhoto(
        _ database: SQLiteDatabase,
        id: String,
        filename: String,
        capturedAt: String,
        directory: String = "/photos"
    ) async throws -> String {
        try await database.run("""
            INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
            VALUES (?, 's1', ?, ?, 'ready', ?, ?)
        """, [.text(id), .text("\(directory)/\(filename)"), .text(filename), .text(capturedAt), .text(capturedAt)])
        return id
    }

    private func insertGroup(
        _ store: SQLiteNavigationStore,
        id: String,
        type: String,
        photoIds: [String],
        source: String = "manual"
    ) async throws {
        try await store.insertGroup(sessionId: "s1", group: NavigationGroupInsert(
            id: id,
            groupType: type,
            photoIdsJSON: NavigationAssembler.photoIdsJSON(photoIds),
            leadPhotoId: nil,
            explanation: "\(type)-\(source)",
            source: source,
            fingerprint: ""
        ))
    }

    /// 返回 NavigationError.description；成功返回 nil，其他错误返回 UNEXPECTED 前缀。
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

    private func insertFourPhotos(_ database: SQLiteDatabase) async throws {
        try await insertPhoto(database, id: "p1", filename: "IMG_0001.jpg", capturedAt: Self.t0)
        try await insertPhoto(database, id: "p2", filename: "IMG_0002.jpg", capturedAt: Self.t1)
        try await insertPhoto(database, id: "p3", filename: "IMG_0003.jpg", capturedAt: Self.t2)
        try await insertPhoto(database, id: "p4", filename: "IMG_0004.jpg", capturedAt: Self.t3)
    }

    // MARK: - list

    @Test("list：过滤 <2 张、回填拍摄时间、空会话为空")
    func listFiltersSingletonsAndFillsCapturedBounds() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertFourPhotos(harness.database)
        try await insertGroup(harness.store, id: "g-full", type: "burst", photoIds: ["p1", "p2", "p3"])
        try await insertGroup(harness.store, id: "g-single", type: "scene", photoIds: ["p4"])

        let groups = try await harness.runtime.list(sessionId: "s1")
        #expect(groups.map(\.id) == ["g-full"], "1 张的组被过滤")
        #expect(groups[0].photoIds == ["p1", "p2", "p3"])
        #expect(groups[0].startAt == Self.t0)
        #expect(groups[0].endAt == Self.t2)
        #expect(groups[0].source == .manual)
        #expect(groups[0].explanation == "burst-manual")

        let injected = try await harness.runtime.list(sessionId: "s1", capturedAt: ["p1": "A", "p3": "B"])
        #expect(injected[0].startAt == "A", "capturedAt 注入时不再查询拍摄行")
        #expect(injected[0].endAt == "B")
        #expect(try await harness.runtime.list(sessionId: "s2").isEmpty)
    }

    // MARK: - split

    @Test("split 越界 / 目标照片不在组内 → NAV_SPLIT_OUT_OF_GROUP，且无写副作用")
    func splitOutOfBoundsRaisesSplitOutOfGroup() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertFourPhotos(harness.database)
        try await insertGroup(harness.store, id: "g1", type: "burst", photoIds: ["p1", "p2", "p3", "p4"])

        let atZero = await errorCode { try await harness.runtime.split(sessionId: "s1", groupId: "g1", atIndex: 0) }
        #expect(atZero == "NAV_SPLIT_OUT_OF_GROUP")
        let atCount = await errorCode { try await harness.runtime.split(sessionId: "s1", groupId: "g1", atIndex: 4) }
        #expect(atCount == "NAV_SPLIT_OUT_OF_GROUP")
        let beforeUnknown = await errorCode {
            try await harness.runtime.split(sessionId: "s1", groupId: "g1", beforePhotoId: "px")
        }
        #expect(beforeUnknown == "NAV_SPLIT_OUT_OF_GROUP", "beforePhotoId 不在组内 → 越界")

        let missing = await errorCode { try await harness.runtime.split(sessionId: "s1", groupId: "nope", atIndex: 9) }
        #expect(missing == "NAV_GROUP_NOT_FOUND", "组不存在先于越界判定")

        let remaining = try await harness.runtime.list(sessionId: "s1")
        #expect(remaining.count == 1 && remaining[0].photoIds == ["p1", "p2", "p3", "p4"], "越界不产生写副作用")
    }

    @Test("split 成功：两个 manual 组、并集不变、lead 重算")
    func splitAtValidIndexProducesTwoManualGroups() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertFourPhotos(harness.database)
        try await insertGroup(harness.store, id: "g1", type: "burst", photoIds: ["p1", "p2", "p3", "p4"])

        let groups = try await harness.runtime.split(sessionId: "s1", groupId: "g1", atIndex: 2)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.source == .manual && $0.type == .burst })
        #expect(Set(groups.flatMap { $0.photoIds }) == ["p1", "p2", "p3", "p4"], "并集不变")
        #expect(groups.allSatisfy { $0.id != "g1" }, "旧组被替换")
        #expect(groups.allSatisfy { $0.leadPhotoId != nil && $0.explanation == "NAV_RECOMMEND_ORDER" })
        #expect(try await harness.store.groups(sessionId: "s1").count == 2)
    }

    // MARK: - merge

    @Test("merge 去重后 <2 组 → NAV_MERGE_MIN_TWO")
    func mergeLessThanTwoRaisesMergeMinTwo() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }

        let empty = await errorCode { try await harness.runtime.merge(sessionId: "s1", groupIds: []) }
        #expect(empty == "NAV_MERGE_MIN_TWO")
        let one = await errorCode { try await harness.runtime.merge(sessionId: "s1", groupIds: ["a"]) }
        #expect(one == "NAV_MERGE_MIN_TWO")
        let duplicated = await errorCode { try await harness.runtime.merge(sessionId: "s1", groupIds: ["a", "a"]) }
        #expect(duplicated == "NAV_MERGE_MIN_TWO", "同 id 去重后只有一组")
    }

    @Test("merge 类型不匹配 → NAV_MERGE_TYPE_MISMATCH；缺组先于类型判定")
    func mergeTypeMismatchAndMissingGroup() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertFourPhotos(harness.database)
        try await insertGroup(harness.store, id: "gb", type: "burst", photoIds: ["p1", "p2"])
        try await insertGroup(harness.store, id: "gs", type: "scene", photoIds: ["p3", "p4"])

        let mismatch = await errorCode { try await harness.runtime.merge(sessionId: "s1", groupIds: ["gb", "gs"]) }
        #expect(mismatch == "NAV_MERGE_TYPE_MISMATCH")
        let missing = await errorCode { try await harness.runtime.merge(sessionId: "s1", groupIds: ["gb", "nope"]) }
        #expect(missing == "NAV_GROUP_NOT_FOUND", "存在性先于类型判定")
        #expect(try await harness.store.groups(sessionId: "s1").count == 2, "失败不产生写副作用")
    }

    @Test("merge 成功：按拍摄行顺序合并、旧组删除、source=manual")
    func mergeSortsByCaptureOrder() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertFourPhotos(harness.database)
        try await insertGroup(harness.store, id: "gb1", type: "burst", photoIds: ["p1", "p3"])
        try await insertGroup(harness.store, id: "gb2", type: "burst", photoIds: ["p2", "p4"])

        let groups = try await harness.runtime.merge(sessionId: "s1", groupIds: ["gb2", "gb1"])
        #expect(groups.count == 1)
        #expect(groups[0].photoIds == ["p1", "p2", "p3", "p4"], "按 captureRows 顺序排序")
        #expect(groups[0].source == .manual && groups[0].type == .burst)
        let rows = try await harness.store.groups(sessionId: "s1")
        #expect(rows.count == 1 && !["gb1", "gb2"].contains(rows[0].id))
    }

    // MARK: - analyze

    @Test("analyze：burst/scene 分组落库、缓存命中、空 session 为空")
    func analyzeGroupsPersistsAndCaches() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertPhoto(harness.database, id: "p1", filename: "IMG_0001.jpg", capturedAt: Self.t0)
        try await insertPhoto(harness.database, id: "p2", filename: "IMG_0002.jpg", capturedAt: Self.t1)
        try await insertPhoto(harness.database, id: "p3", filename: "IMG_0003.jpg", capturedAt: Self.t2)

        let first = try await harness.runtime.analyze(sessionId: "s1")
        #expect(first.count == 2, "同一组照片同时构成 burst 与 scene")
        #expect(Set(first.map { $0.type }) == [.burst, .scene])
        #expect(first.allSatisfy { $0.photoIds == ["p1", "p2", "p3"] && $0.source == .automatic })
        #expect(first.allSatisfy { $0.startAt == Self.t0 && $0.endAt == Self.t2 })
        #expect(first.allSatisfy { $0.explanation == "NAV_RECOMMEND_ORDER" && $0.leadPhotoId != nil })
        #expect(try await harness.store.cachedFingerprint(sessionId: "s1") != nil)

        let second = try await harness.runtime.analyze(sessionId: "s1")
        #expect(second.map(\.id) == first.map(\.id), "指纹一致 → 直接返回缓存组")
        #expect(try await harness.store.groups(sessionId: "s1").count == 2, "缓存命中不重复落库")

        let empty = try await harness.runtime.analyze(sessionId: "s2")
        #expect(empty.isEmpty)
    }

    @Test("analyze：dryRun 不落库；gapSeconds 便捷重载落库")
    func analyzeDryRunAndGapConvenience() async throws {
        let harness = try await makeHarness()
        defer { removeStoreFiles(harness.path) }
        try await insertPhoto(harness.database, id: "p1", filename: "IMG_0001.jpg", capturedAt: Self.t0)
        try await insertPhoto(harness.database, id: "p2", filename: "IMG_0002.jpg", capturedAt: Self.t1)

        let dry = try await harness.runtime.analyze(sessionId: "s1", dryRun: true)
        #expect(dry.count == 2)
        #expect(try await harness.store.groups(sessionId: "s1").isEmpty, "dryRun 不落库")

        let burstGapInvalid = await errorCode {
            try await harness.runtime.analyze(sessionId: "s1", burstGapSeconds: 0.01, dryRun: true)
        }
        #expect(burstGapInvalid == "NAV_BURST_GAP_INVALID")
        let sceneGapInvalid = await errorCode {
            try await harness.runtime.analyze(sessionId: "s1", burstGapSeconds: 2, sceneGapSeconds: 1, dryRun: true)
        }
        #expect(sceneGapInvalid == "NAV_SCENE_GAP_INVALID")
        #expect(try await harness.store.groups(sessionId: "s1").isEmpty, "参数非法不落库")

        let persisted = try await harness.runtime.analyze(sessionId: "s1", gapSeconds: 2)
        #expect(persisted.count == 2)
        #expect(try await harness.store.groups(sessionId: "s1").count == 2)
    }

    // MARK: - 取消（限时）

    /// 阻塞 store：captureRows 挂起至取消。
    private struct BlockingNavigationStore: NavigationStore {
        func groups(sessionId: String) async throws -> [NavigationGroupRecord] { [] }
        func manualGroups(sessionId: String) async throws -> [NavigationGroupRecord] { [] }
        func cachedFingerprint(sessionId: String) async throws -> String? { nil }
        func insertGroup(sessionId: String, group: NavigationGroupInsert) async throws {}
        func deleteGroup(sessionId: String, id: String) async throws {}
        func deleteGroups(sessionId: String, ids: [String]) async throws {}
        func deleteAutomaticGroups(sessionId: String) async throws {}
        func replaceAutomaticGroups(sessionId: String, groups: [NavigationGroupInsert], fingerprint: String) async throws {}
        func captureRows(sessionId: String) async throws -> [NavigationCaptureRow] {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return []
        }
    }

    @Test("取消：analyze 传播 CancellationError（5 秒看门狗，无轮询）")
    func analyzeCancellationPropagatesWithinBound() async throws {
        let runtime = NavigationRuntime(store: BlockingNavigationStore())
        let task = Task { try await runtime.analyze(sessionId: "s1", dryRun: true) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let outcome = await withTaskGroup(of: String.self) { group -> String in
            group.addTask {
                do {
                    _ = try await task.value
                    return "completed"
                } catch is CancellationError {
                    return "cancelled"
                } catch {
                    return "error:\(error)"
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return "timeout"
            }
            let first = await group.next() ?? "timeout"
            group.cancelAll()
            return first
        }
        task.cancel()
        #expect(outcome == "cancelled", "取消必须传播且 5 秒内返回，实际 \(outcome)")
    }
}
