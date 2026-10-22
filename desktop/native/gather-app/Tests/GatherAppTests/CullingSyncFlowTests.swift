// CullingViewModel 同步状态机单测：对齐 tests/unit/renderer/c1-sync-controls.test.ts
// 的 8 组门控用例（deriveSyncControls 矩阵）+ syncFlowState 从
// MetadataSyncSummary 推导的优先级（冲突 > 失败 > 写入中 > 已写入 > 终态 > 空）。
//
// Cut 1 / B8.1a：VM 用 CullingAPI / NavigationAPI / MetadataAPI 的类型化替身
// 构造，不再经过旧命令面 适配器；耐久 reload-ack 的
// JSON 解码用例改为类型化 syncStatus 刷新语义（摘要 + ack / 错误可见）。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

/// 参数化用的状态名。
/// SyncFlowState 是 public 枚举（无隐式 Sendable 派生），不能直接进
/// @Test(arguments:)；用私有 Sendable 枚举承载，映射是穷尽 switch，不会静默漏 case。
private enum FlowStateName: String, Sendable {
    case disconnected, conflict, failed, syncing, c1Read, safeToCleanup, synced

    var state: CullingViewModel.SyncFlowState {
        switch self {
        case .disconnected: return .disconnected
        case .conflict: return .conflict
        case .failed: return .failed
        case .syncing: return .syncing
        case .c1Read: return .c1Read
        case .safeToCleanup: return .safeToCleanup
        case .synced: return .synced
        }
    }
}

/// 参数化用例共用的 summary 构造器（file-private：arguments 里可直接调用）。
private func syncSummary(
    pending: Int = 0, writing: Int = 0, written: Int = 0,
    failed: Int = 0, conflict: Int = 0, synced: Int = 0
) -> MetadataSyncSummary {
    b8SyncSummary(
        sessionId: "s1", pending: pending, writing: writing, written: written,
        failed: failed, conflict: conflict, synced: synced
    )
}

/// 类型化五 API 装配（culling/navigation/metadata/jobs/quality 全部替身；
/// 本文件不断言任何命令名）。
@MainActor
private func makeCullingStack(
    sessionId: String = "s1"
) -> (CullingViewModel, B8CullingAPIStub, B8NavigationAPIStub) {
    let culling = B8CullingAPIStub()
    let navigation = B8NavigationAPIStub()
    let viewModel = CullingViewModel(
        sessionId: sessionId,
        culling: culling,
        navigation: navigation,
        metadata: B6bMetadataAPIStub(),
        jobs: B5bJobAPIStub(),
        quality: B5bQualityAPIStub(),
        captureOne: CaptureOneBridge()
    )
    return (viewModel, culling, navigation)
}

@Suite("CullingSyncFlow deriveControls（对齐 c1-sync-controls.test.ts）", .serialized)
struct CullingSyncFlowTests {
    private typealias Controls = CullingViewModel.SyncFlowControls

    // 原 8 条用例：syncing / c1Read 未 ack / c1Read+ack+written /
    // c1Read+ack 无写入 / safeToCleanup / synced / failed / conflict /
    // disconnected（failed、conflict 原为一条 for 循环，展开为两条 case）。
    @Test("deriveControls 门控矩阵", arguments: [
        (FlowStateName.syncing, true, false,
         Controls(canLoadMetadata: true, canConfirmSync: false, canCleanup: false),
         "syncing：仅可重载"),
        (FlowStateName.c1Read, true, false,
         Controls(canLoadMetadata: true, canConfirmSync: false, canCleanup: false),
         "c1Read 未 ack：仅可重载"),
        (FlowStateName.c1Read, true, true,
         Controls(canLoadMetadata: true, canConfirmSync: true, canCleanup: false),
         "c1Read + ack + 已写入：重载/确认可用，清理禁用"),
        (FlowStateName.c1Read, false, true,
         Controls(canLoadMetadata: true, canConfirmSync: false, canCleanup: false),
         "c1Read + ack 但无写入行：确认保持禁用"),
        (FlowStateName.safeToCleanup, false, true,
         Controls(canLoadMetadata: true, canConfirmSync: true, canCleanup: true),
         "safeToCleanup：三者全可用"),
        (FlowStateName.synced, false, true,
         Controls(canLoadMetadata: false, canConfirmSync: false, canCleanup: false),
         "synced：全部禁用"),
        (FlowStateName.failed, true, true,
         Controls(canLoadMetadata: false, canConfirmSync: false, canCleanup: false),
         "failed：全部禁用"),
        (FlowStateName.conflict, true, true,
         Controls(canLoadMetadata: false, canConfirmSync: false, canCleanup: false),
         "conflict：全部禁用"),
        (FlowStateName.disconnected, false, false,
         Controls(canLoadMetadata: false, canConfirmSync: false, canCleanup: false),
         "disconnected（未知/未加载）：保守全禁用"),
    ])
    private func deriveControlsMatrix(
        stateName: FlowStateName,
        hasWritten: Bool,
        acked: Bool,
        expected: Controls,
        label: String
    ) {
        let c = CullingViewModel.CullingSyncFlow.deriveControls(
            syncState: stateName.state, hasWritten: hasWritten, acked: acked)
        #expect(c == expected, Comment(rawValue: label))
    }
}

@Suite("CullingViewModel syncFlowState 推导", .serialized)
@MainActor
struct CullingSyncFlowStateTests {
    // 原 7 条用例：无状态 / 冲突优先 / 失败优先 / 写入中 / 已写入 / 全部终态 / 空行。
    @Test("syncFlowState 优先级矩阵", arguments: [
        (nil as MetadataSyncSummary?, FlowStateName.disconnected, "无状态 → disconnected"),
        (syncSummary(writing: 3, failed: 1, conflict: 2), FlowStateName.conflict, "冲突优先于失败/写入"),
        (syncSummary(writing: 1, failed: 2), FlowStateName.failed, "失败优先于写入"),
        (syncSummary(pending: 5, writing: 3), FlowStateName.syncing, "写入中（pending/writing）→ syncing"),
        (syncSummary(written: 4), FlowStateName.c1Read, "已写入 → c1Read"),
        (syncSummary(synced: 10), FlowStateName.safeToCleanup, "全部终态（synced>0）→ safeToCleanup"),
        (syncSummary(), FlowStateName.synced, "空行 → synced"),
    ])
    private func syncFlowStateMatrix(summary: MetadataSyncSummary?, expected: FlowStateName, label: String) {
        let (vm, _, _) = makeCullingStack()
        if let summary { vm.applySyncSummaryForTesting(summary) }
        #expect(vm.syncFlowState() == expected.state, Comment(rawValue: label))
    }
}

@Suite("CullingViewModel 类型化 API 流程", .serialized)
@MainActor
struct CullingTypedAPIFlowTests {
    @Test("page/history/syncStatus：查询参数与摘要/ack 投影正确")
    func pageHistoryAndSyncStatusThroughTypedAPI() async {
        let (vm, culling, navigation) = makeCullingStack()
        culling.pageResult = b8CullingPage([b8CullingAsset("p1"), b8CullingAsset("p2", revision: 2)])
        culling.summaryResult = CullingSummary(
            totalGroups: 1, totalPhotos: 2, kept: 1, rejected: 0, pending: 1, rated: 1, labeled: 0
        )
        culling.groupsResult = [b8CullingGroup()]
        culling.syncStatusResult = CullingSyncStatus(
            summary: syncSummary(written: 3),
            reloadAckedAt: "2026-09-01T10:00:00.000Z"
        )

        await vm.load()

        #expect(culling.pageQueries.count == 1)
        #expect(culling.pageQueries.first?.sessionId == "s1")
        #expect(culling.pageQueries.first?.scope == .all)
        #expect(culling.pageQueries.first?.limit == 500)
        #expect(culling.historyQueries.first?.limit == 500)
        #expect(navigation.listCalls == ["s1"])
        #expect(vm.page?.assets.map(\.photo.id) == ["p1", "p2"])
        #expect(vm.summary?.totalPhotos == 2)
        #expect(vm.syncStatus?.written == 3)
        #expect(vm.reloadAcked)
        #expect(vm.canLoadMetadata)
        #expect(vm.canConfirmSync)
        #expect(!vm.canCleanup)
    }

    @Test("update：expectedRevision/patch 进类型化输入并 prepend 历史")
    func updateThroughTypedAPI() async throws {
        let (vm, culling, _) = makeCullingStack()
        let asset = b8CullingAsset("p1", revision: 3)
        culling.pageResult = b8CullingPage([asset, b8CullingAsset("p2")])
        // 后台 refresh 快照与写入结果一致，避免 refreshSilently 把刚应用的决策冲掉。
        culling.updateResult = CullingUpdateResult(
            states: [b8CullingState("p1", revision: 4, pickState: .picked)],
            xmpPath: "/shoot/p1.xmp",
            syncStatus: .pending,
            historyOperationId: 9
        )
        await vm.load()
        culling.pageResult = b8CullingPage([
            b8CullingAsset("p1", revision: 4, pickState: .picked),
            b8CullingAsset("p2")
        ])

        await vm.update(asset, patch: CullingUpdatePatch(pickState: .picked))

        #expect(culling.updateInputs.count == 1)
        #expect(culling.updateInputs.first?.photoId == "p1")
        #expect(culling.updateInputs.first?.expectedRevision == 3)
        #expect(culling.updateInputs.first?.patch.pickState == .picked)
        #expect(vm.undoOperation?.id == 9)
        #expect(vm.undoOperation?.entries.first?.before.pickState == .unreviewed)
        #expect(vm.undoOperation?.entries.first?.after.pickState == .picked)
    }

    @Test("undo：applyHistory 带 direction=undo 与 historyOperationId")
    func undoThroughTypedAPI() async throws {
        let (vm, culling, _) = makeCullingStack()
        let entry = CullingHistoryEntry(
            photoId: "p1",
            before: CullingStateSnapshot(pickState: .unreviewed, rating: 0, colorLabel: .none),
            after: CullingStateSnapshot(pickState: .picked, rating: 0, colorLabel: .none),
            expectedRevision: 1,
            fields: [.pickState]
        )
        culling.pageResult = b8CullingPage([b8CullingAsset("p1", revision: 2, pickState: .picked)])
        culling.historyResult = [
            CullingHistoryOperation(
                id: 7, sessionId: "s1", entries: [entry], undone: false,
                createdAt: "2026-01-01T00:00:00.000Z"
            )
        ]
        culling.applyHistoryResults = [
            CullingUpdateResult(
                states: [b8CullingState("p1", revision: 3)],
                xmpPath: "/shoot/p1.xmp",
                syncStatus: .pending,
                historyOperationId: 7
            )
        ]
        await vm.load()

        await vm.undo()

        #expect(culling.applyHistoryInputs.count == 1)
        #expect(culling.applyHistoryInputs.first?.direction == .undo)
        #expect(culling.applyHistoryInputs.first?.historyOperationId == 7)
        #expect(culling.applyHistoryInputs.first?.entries.first?.photoId == "p1")
        #expect(culling.applyHistoryInputs.first?.entries.first?.patch.pickState == .unreviewed)
        #expect(vm.history.first?.undone == true)
        #expect(vm.undoOperation == nil)
        #expect(vm.redoOperation?.id == 7)
    }

    @Test("batchUpdate/decideGroup：选中集与保留集进类型化输入")
    func batchAndDecideThroughTypedAPI() async throws {
        let (vm, culling, _) = makeCullingStack()
        culling.pageResult = b8CullingPage([
            b8CullingAsset("p1"), b8CullingAsset("p2"), b8CullingAsset("p3")
        ])
        culling.batchUpdateResults = [
            CullingUpdateResult(
                states: [b8CullingState("p1", revision: 2, pickState: .rejected),
                         b8CullingState("p2", revision: 2, pickState: .rejected)],
                xmpPath: "/shoot/p1.xmp",
                syncStatus: .pending,
                historyOperationId: 11
            )
        ]
        await vm.load()
        vm.toggleSelection("p1")
        vm.toggleSelection("p2")
        culling.pageResult = b8CullingPage([
            b8CullingAsset("p1", revision: 2, pickState: .rejected),
            b8CullingAsset("p2", revision: 2, pickState: .rejected),
            b8CullingAsset("p3")
        ])

        await vm.batchUpdate(patch: CullingUpdatePatch(pickState: .rejected))

        #expect(culling.batchUpdateInputs.count == 1)
        #expect(culling.batchUpdateInputs.first?.photoIds == ["p1", "p2"])
        #expect(culling.batchUpdateInputs.first?.patch.pickState == .rejected)
        #expect(vm.undoOperation?.id == 11)

        let group = b8CullingGroup(groupId: "g1", photoIds: ["p1", "p2"])
        await vm.decideSimilarityGroup(group, keepPhotoIds: ["p1"], shouldAdvance: false)
        #expect(culling.decideGroupInputs.count == 1)
        #expect(culling.decideGroupInputs.first?.groupId == "g1")
        #expect(culling.decideGroupInputs.first?.keepPhotoIds == ["p1"])
    }
}

/// 耐久 reload-ack 的类型化契约：syncStatus 直接携带摘要 + ack，不再经过
/// JSONValue 解码；失败必须可见（不得静默保持旧状态）。
@Suite("CullingViewModel syncStatus 刷新（类型化 ack）", .serialized)
@MainActor
struct CullingSyncStatusRefreshTests {
    @Test("摘要字段与 reloadAckedAt 一并应用")
    func refreshAppliesSummaryAndAck() async {
        let (vm, culling, _) = makeCullingStack()
        culling.syncStatusResult = CullingSyncStatus(
            summary: syncSummary(pending: 1, written: 2, conflict: 1, synced: 3),
            reloadAckedAt: "2026-09-01T10:00:00.000Z"
        )

        await vm.refreshSyncStatus()

        #expect(vm.syncStatus == syncSummary(pending: 1, written: 2, conflict: 1, synced: 3))
        #expect(vm.reloadAcked)
        #expect(culling.syncStatusCalls == ["s1"])
        #expect(culling.summaryCalls == ["s1"])
    }

    @Test("ack 缺失 → reloadAcked 保持 false，确认同步保持禁用")
    func refreshWithoutAckKeepsConfirmDisabled() async {
        let (vm, culling, _) = makeCullingStack()
        culling.syncStatusResult = CullingSyncStatus(
            summary: syncSummary(written: 2),
            reloadAckedAt: nil
        )

        await vm.refreshSyncStatus()

        #expect(!vm.reloadAcked)
        #expect(vm.syncStatus?.written == 2)
        #expect(vm.canLoadMetadata)
        #expect(!vm.canConfirmSync)
    }

    @Test("syncStatus 失败 → 可见 lastSyncError，不伪造已确认")
    func refreshErrorSurfaces() async {
        let (vm, culling, _) = makeCullingStack()
        culling.syncStatusError = GatherError(code: .CULLING_REVISION_CONFLICT)

        await vm.refreshSyncStatus()

        #expect(vm.syncStatus == nil)
        #expect(!vm.reloadAcked)
        // Cut 4 / 4a-3b-1：只存错误载体（码），文案在渲染期本地化。
        #expect(vm.lastSyncError?.code == "CULLING_REVISION_CONFLICT")
        #expect(!vm.canLoadMetadata)
    }
}
