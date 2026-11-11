// desktop/native/gather-app/Tests/GatherAppTests/CullingViewStateStoreTests.swift
// Wave5 批次 2 / B3：挑片浏览状态存档的纯单元测试。
//
// 覆盖：
// - 编解码往返（含参考槽 / 未知可选字段）；
// - 版本不匹配、损坏 JSON 时 fail-safe 回 nil 并清掉坏键（不崩、不阻塞进页）；
// - 按 sessionId 隔离（两个会话互不覆盖）与"只清当前照片"字段级清理；
// - 保存节流（CullingViewStateSaveThrottle）只保留最新状态、代数过期即丢弃。
//
// 不解码图片、不触盘：UserDefaults 用独立 suite，避免污染真实默认值。
import Foundation
import Testing
@testable import GatherUI

@Suite("B3 挑片浏览状态存档")
@MainActor
struct CullingViewStateStoreTests {
    // MARK: 夹具

    private func makeStore() -> (store: CullingViewStateStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "CullingViewStateStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return (CullingViewStateStore(defaults: defaults), defaults, suiteName)
    }

    private func makeState(
        scope: String = "all",
        filters: CullingViewFilters = CullingViewFilters(),
        sort: String = "import",
        layout: String = "single",
        density: String = "m",
        currentPhotoId: String? = "p1",
        reference: CullingViewReference? = nil,
        similarityGroupId: String? = nil,
        filmstripExpanded: Bool = true,
        inspectorVisible: Bool = true
    ) -> CullingViewState {
        CullingViewState(
            scope: scope,
            filters: filters,
            sort: sort,
            layout: layout,
            density: density,
            currentPhotoId: currentPhotoId,
            reference: reference,
            similarityGroupId: similarityGroupId,
            filmstripExpanded: filmstripExpanded,
            inspectorVisible: inspectorVisible)
    }

    // MARK: 编解码

    @Test("往返：筛选六维 / 参考槽 / 布局面板字段全部保持")
    func roundtripKeepsAllFields() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var filters = CullingViewFilters()
        filters.unreviewedOnly = true
        filters.pickState = "picked"
        filters.rating = 4
        filters.colorLabel = "Green"
        filters.qualityStatus = "analysed"
        filters.metadataConflictOnly = true
        filters.triageVerdicts = ["keep", "review"]
        let reference = CullingViewReference(
            photoId: "p9", filepath: "/shoot/p9.jpg", filename: "p9.jpg")
        let state = makeState(
            scope: "filtered",
            filters: filters,
            sort: "rating_desc",
            layout: "compare2",
            density: "l",
            currentPhotoId: "p42",
            reference: reference,
            similarityGroupId: "g1",
            filmstripExpanded: false,
            inspectorVisible: false)

        store.save(state, sessionId: "s1")
        let loaded = try #require(store.load(sessionId: "s1"))
        #expect(loaded == state)
        #expect(loaded.version == CullingViewState.currentVersion)
    }

    // MARK: 会话隔离

    @Test("按 sessionId 隔离：两个会话各自恢复自己的当前照片")
    func sessionsAreIsolated() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.save(makeState(currentPhotoId: "a1"), sessionId: "session-a")
        store.save(makeState(currentPhotoId: "b9"), sessionId: "session-b")

        #expect(store.load(sessionId: "session-a")?.currentPhotoId == "a1")
        #expect(store.load(sessionId: "session-b")?.currentPhotoId == "b9")
        #expect(store.load(sessionId: "session-c") == nil)
    }

    // MARK: fail-safe

    @Test("版本不匹配：丢弃存档（回 nil）并清键，不猜测迁移")
    func versionMismatchDropsState() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 未来/旧版本存档：等价于跨版本升级后留下的结构。
        let stale = CullingViewState(
            version: 999, scope: "all", sort: "import", layout: "single",
            density: "m", currentPhotoId: "p1")
        defaults.set(
            try JSONEncoder().encode(stale),
            forKey: CullingViewStateStore.key("s1"))

        #expect(store.load(sessionId: "s1") == nil)
        #expect(defaults.data(forKey: CullingViewStateStore.key("s1")) == nil, "坏键必须清掉，避免每次进页重试")
    }

    @Test("损坏 JSON：fail-safe 回 nil 且清键（不崩、不挡进页）")
    func corruptDataDropsState() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("{not-json".utf8), forKey: CullingViewStateStore.key("s1"))
        #expect(store.load(sessionId: "s1") == nil)
        #expect(defaults.data(forKey: CullingViewStateStore.key("s1")) == nil)
    }

    // MARK: 字段级清理

    @Test("只清当前照片：筛选/排序/布局/参考槽保留")
    func clearCurrentPhotoKeepsOtherFields() throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var filters = CullingViewFilters()
        filters.rating = 5
        let reference = CullingViewReference(
            photoId: "p9", filepath: "/shoot/p9.jpg", filename: "p9.jpg")
        store.save(makeState(
            scope: "filtered", filters: filters, sort: "capture_asc",
            layout: "grid", density: "s", currentPhotoId: "gone",
            reference: reference), sessionId: "s1")

        store.clearCurrentPhoto(sessionId: "s1")

        let loaded = try #require(store.load(sessionId: "s1"))
        #expect(loaded.currentPhotoId == nil, "被删照片的 id 必须清掉，避免反复 seek")
        #expect(loaded.scope == "filtered")
        #expect(loaded.filters.rating == 5)
        #expect(loaded.sort == "capture_asc")
        #expect(loaded.layout == "grid")
        #expect(loaded.density == "s")
        #expect(loaded.reference == reference, "参考槽与当前照片无关，不能被一起清掉")
    }

    // MARK: 保存节流

    @Test("节流：只保留最新状态，过期代数取不走")
    func throttleKeepsLatestOnly() throws {
        var throttle = CullingViewStateSaveThrottle()
        let first = makeState(currentPhotoId: "p1")
        let second = makeState(currentPhotoId: "p2")
        let third = makeState(currentPhotoId: "p3")

        let generation1 = throttle.enqueue(first)
        #expect(throttle.hasPending)
        let generation2 = throttle.enqueue(second)
        #expect(throttle.take(expectedGeneration: generation1) == nil, "旧代数的睡眠任务必须丢弃")
        #expect(throttle.take(expectedGeneration: generation2) == second, "最新一拍生效")
        #expect(!throttle.hasPending)

        let generation3 = throttle.enqueue(third)
        #expect(throttle.take(expectedGeneration: generation3) == third)
        #expect(throttle.take() == nil, "重复 take 不重复写盘")
    }

    @Test("flush：无待写状态时 take() 为 nil，幂等")
    func throttleFlushIsIdempotent() throws {
        var throttle = CullingViewStateSaveThrottle()
        #expect(throttle.take() == nil)
        throttle.enqueue(makeState())
        #expect(throttle.take() != nil)
        #expect(throttle.take() == nil)
    }
}
