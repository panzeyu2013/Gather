// desktop/native/gather-app/Tests/GatherAppTests/C1StatusCapsuleTests.swift
// Cut 1 / B8.2e：C1 状态胶囊从 字符串命令迁到 CullingAPI 的回归守卫。
//
// 覆盖：
// - refresh(sessionId:) 走 CullingAPI.syncStatus，摘要 + reloadAckedAt 一并应用；
// - 失败静默降级（failedToLoad），恢复后重新生效；
// - 订阅首拉 / 退订归零回收状态（不残留 12s 轮询订阅）；
// - 胶囊渲染（状态文案 / 队列 / 最近同步 / tooltip）与语言切换；
// - Host 只接 CullingAPI，不再持有 router；
// - CullingAPI 注入幂等（单例多宿主只装配一次）。
//
// 用隔离的 C1StatusService 实例而不是 shared：避免与并行套件（LayoutBudget
// 会真正渲染宿主并触发 onAppear）互相污染状态与轮询任务。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

@MainActor
@Suite("C1 status capsule", .serialized)
struct C1StatusCapsuleTests {
    private func makeService(_ api: B8CullingAPIStub) -> C1StatusService {
        let service = C1StatusService()
        service.setCullingAPI(api)
        return service
    }

    private func capsule(_ service: C1StatusService, sessionId: String = "s1") -> C1StatusCapsule {
        C1StatusCapsule(sessionId: sessionId, onOpenSettings: {}, service: service)
    }

    @Test("refresh：摘要与 reloadAckedAt 从 CullingAPI 进入胶囊")
    func refreshMapsSyncStatus() async {
        let api = B8CullingAPIStub()
        api.syncStatusResult = CullingSyncStatus(
            summary: b8SyncSummary(written: 2),
            reloadAckedAt: "2026-09-01T10:00:00.000Z"
        )
        let service = makeService(api)

        await service.refresh(sessionId: "s1")

        #expect(api.syncStatusCalls == ["s1"])
        #expect(service.statuses["s1"]?.syncStatus?.written == 2)
        #expect(service.statuses["s1"]?.reloadedAt == "2026-09-01T10:00:00.000Z")
        #expect(service.statuses["s1"]?.failedToLoad == false)

        let view = capsule(service)
        // 4b-2l：胶囊模型不再读进程全局语言，测试显式传 L10n。
        let zh = L10n(language: .zhCN)
        #expect(view.queue == 2)
        #expect(view.capsule(with: zh).label == "已写入待读取")
        #expect(view.capsule(with: zh).detail == "Gather 已写入，等待 C1 读取")
        #expect(view.syncedAtText != nil)
        #expect(view.tooltip(with: zh).contains("写回队列：2 项"))
        #expect(view.tooltip(with: zh).contains("最近同步："))
    }

    @Test("失败静默降级为状态未知，恢复后重新显示摘要")
    func failureDegradesThenRecovers() async {
        let api = B8CullingAPIStub()
        api.syncStatusError = GatherError(code: .CULLING_REVISION_CONFLICT)
        let service = makeService(api)

        await service.refresh(sessionId: "s1")
        #expect(service.statuses["s1"]?.failedToLoad == true)
        let view = capsule(service)
        let zh = L10n(language: .zhCN)
        #expect(view.capsule(with: zh).label == "状态未知")
        #expect(view.capsule(with: zh).detail == "无法获取同步状态")
        #expect(view.tooltip(with: zh).contains("状态未知：自动重试中"))

        // 恢复：错误清掉后下一次刷新必须清除 failedToLoad 并应用新摘要。
        api.syncStatusError = nil
        api.syncStatusResult = CullingSyncStatus(summary: b8SyncSummary(synced: 1))
        await service.refresh(sessionId: "s1")
        #expect(service.statuses["s1"]?.failedToLoad == false)
        #expect(service.statuses["s1"]?.syncStatus?.synced == 1)
        #expect(view.capsule(with: L10n(language: .zhCN)).label == "已同步可清理")
    }

    @Test("订阅首拉 + 退订归零回收状态")
    func subscribeRefreshesAndUnsubscribeClears() async {
        let api = B8CullingAPIStub()
        api.syncStatusResult = CullingSyncStatus(summary: b8SyncSummary(pending: 1))
        let service = makeService(api)

        service.subscribe(sessionId: "s1")
        #expect(await waitUntilAsync { service.statuses["s1"] != nil })
        #expect(api.syncStatusCalls.contains("s1"))
        #expect(service.statuses["s1"]?.syncStatus?.pending == 1)

        service.unsubscribe(sessionId: "s1")
        #expect(service.statuses["s1"] == nil)
    }

    @Test("胶囊文案跟随界面语言，状态/队列不随语言变化")
    func labelsFollowLanguage() async {
        let api = B8CullingAPIStub()
        api.syncStatusResult = CullingSyncStatus(summary: b8SyncSummary(synced: 1))
        let service = makeService(api)
        await service.refresh(sessionId: "s1")
        let view = capsule(service)

        let zh = view.capsule(with: L10n(language: .zhCN)).label
        let en = view.capsule(with: L10n(language: .en)).label
        #expect(zh == "已同步可清理")
        #expect(en == "Synced, Ready to Clean Up")
        // 队列公式是 pending+writing+written；synced 不计入，语言切换也不改变它。
        #expect(view.queue == 0)
    }

    @Test("async 刷新乱序：迟到的旧响应不得覆盖较新的状态")
    func staleRefreshDoesNotOverwriteNewer() async {
        let api = B8CullingAPIStub()
        api.syncStatusResults = [
            CullingSyncStatus(summary: b8SyncSummary(synced: 1)),
            CullingSyncStatus(summary: b8SyncSummary(synced: 2)),
        ]
        // 第一次调用慢 120ms，第二次立即返回：第二次先落地，第一次迟到。
        api.syncStatusDelays = [.milliseconds(120), .zero]
        let service = makeService(api)

        let first = Task { await service.refresh(sessionId: "s1") }
        try? await Task.sleep(for: .milliseconds(20))
        await service.refresh(sessionId: "s1")
        await first.value

        #expect(api.syncStatusCalls.count == 2)
        #expect(service.statuses["s1"]?.syncStatus?.synced == 2)
    }

    @Test("Host 只持有 CullingAPI，不再有命令面字段")
    func hostHasNoCommandSurface() {
        let host = C1StatusCapsuleHost(
            sessionId: "s1",
            culling: B8CullingAPIStub(),
            onOpenSettings: {},
            service: C1StatusService()
        )
        let labels = Mirror(reflecting: host).children.compactMap(\.label)
        #expect(labels.contains("culling"))
        #expect(!labels.contains("router"))
    }

    @Test("CullingAPI 注入幂等：多宿主共享单例时首个实例生效")
    func injectionIsIdempotent() async {
        let first = B8CullingAPIStub()
        first.syncStatusResult = CullingSyncStatus(summary: b8SyncSummary(synced: 3))
        let second = B8CullingAPIStub()
        let service = C1StatusService()

        service.setCullingAPI(first)
        service.setCullingAPI(second)
        await service.refresh(sessionId: "s1")

        #expect(first.syncStatusCalls == ["s1"])
        #expect(second.syncStatusCalls.isEmpty)
        #expect(service.statuses["s1"]?.syncStatus?.synced == 3)
    }
}
