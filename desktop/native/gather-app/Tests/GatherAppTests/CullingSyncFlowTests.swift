// CullingViewModel 同步状态机单测：对齐 tests/unit/renderer/c1-sync-controls.test.ts
// 的 8 组门控用例（deriveSyncControls 矩阵）+ syncFlowState 从
// MetadataSyncSummary 推导的优先级（冲突 > 失败 > 写入中 > 已写入 > 终态 > 空）。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

@Suite("CullingSyncFlow deriveControls（对齐 c1-sync-controls.test.ts）")
struct CullingSyncFlowTests {
    private typealias State = CullingViewModel.SyncFlowState
    private typealias Controls = CullingViewModel.SyncFlowControls

    @Test("syncing：仅可重载")
    func syncingOnlyLoad() {
        let c = CullingViewModel.CullingSyncFlow.deriveControls(
            syncState: .syncing, hasWritten: true, acked: false)
        #expect(c == Controls(canLoadMetadata: true, canConfirmSync: false, canCleanup: false))
    }

    @Test("c1Read 未 ack：仅可重载")
    func c1ReadWithoutAck() {
        let c = CullingViewModel.CullingSyncFlow.deriveControls(
            syncState: .c1Read, hasWritten: true, acked: false)
        #expect(c == Controls(canLoadMetadata: true, canConfirmSync: false, canCleanup: false))
    }

    @Test("c1Read + ack + 已写入：重载/确认可用，清理禁用")
    func c1ReadAckedWithWritten() {
        let c = CullingViewModel.CullingSyncFlow.deriveControls(
            syncState: .c1Read, hasWritten: true, acked: true)
        #expect(c == Controls(canLoadMetadata: true, canConfirmSync: true, canCleanup: false))
    }

    @Test("c1Read + ack 但无写入行：确认保持禁用")
    func c1ReadAckedNoWritten() {
        let c = CullingViewModel.CullingSyncFlow.deriveControls(
            syncState: .c1Read, hasWritten: false, acked: true)
        #expect(c == Controls(canLoadMetadata: true, canConfirmSync: false, canCleanup: false))
    }

    @Test("safeToCleanup：三者全可用")
    func safeToCleanupAllEnabled() {
        let c = CullingViewModel.CullingSyncFlow.deriveControls(
            syncState: .safeToCleanup, hasWritten: false, acked: true)
        #expect(c == Controls(canLoadMetadata: true, canConfirmSync: true, canCleanup: true))
    }

    @Test("synced：全部禁用")
    func syncedAllDisabled() {
        let c = CullingViewModel.CullingSyncFlow.deriveControls(
            syncState: .synced, hasWritten: false, acked: true)
        #expect(c == Controls(canLoadMetadata: false, canConfirmSync: false, canCleanup: false))
    }

    @Test("failed/conflict：全部禁用")
    func failedConflictAllDisabled() {
        for state: State in [.failed, .conflict] {
            let c = CullingViewModel.CullingSyncFlow.deriveControls(
                syncState: state, hasWritten: true, acked: true)
            #expect(c == Controls(canLoadMetadata: false, canConfirmSync: false, canCleanup: false))
        }
    }

    @Test("disconnected（未知/未加载）：保守全禁用")
    func disconnectedAllDisabled() {
        let c = CullingViewModel.CullingSyncFlow.deriveControls(
            syncState: .disconnected, hasWritten: false, acked: false)
        #expect(c == Controls(canLoadMetadata: false, canConfirmSync: false, canCleanup: false))
    }
}

@Suite("CullingViewModel syncFlowState 推导")
@MainActor
struct CullingSyncFlowStateTests {
    private func summary(
        pending: Int = 0, writing: Int = 0, written: Int = 0,
        failed: Int = 0, conflict: Int = 0, synced: Int = 0
    ) -> MetadataSyncSummary {
        MetadataSyncSummary(
            sessionId: "s1", pending: pending, writing: writing, written: written,
            failed: failed, conflict: conflict, synced: synced, items: [])
    }

    private func makeViewModel() -> CullingViewModel {
        CullingViewModel(
            sessionId: "s1",
            commands: .testEmpty()
        )
    }

    @Test("无状态 → disconnected")
    func nilSummaryDisconnected() {
        let vm = makeViewModel()
        #expect(vm.syncFlowState() == .disconnected)
    }

    @Test("冲突优先于失败/写入")
    func conflictWins() {
        let vm = makeViewModel()
        vm.applySyncSummaryForTesting(summary(writing: 3, failed: 1, conflict: 2))
        #expect(vm.syncFlowState() == .conflict)
    }

    @Test("失败优先于写入")
    func failedOverSyncing() {
        let vm = makeViewModel()
        vm.applySyncSummaryForTesting(summary(writing: 1, failed: 2))
        #expect(vm.syncFlowState() == .failed)
    }

    @Test("写入中（pending/writing）→ syncing")
    func writingIsSyncing() {
        let vm = makeViewModel()
        vm.applySyncSummaryForTesting(summary(pending: 5, writing: 3))
        #expect(vm.syncFlowState() == .syncing)
    }

    @Test("已写入 → c1Read")
    func writtenIsC1Read() {
        let vm = makeViewModel()
        vm.applySyncSummaryForTesting(summary(written: 4))
        #expect(vm.syncFlowState() == .c1Read)
    }

    @Test("全部终态（synced>0）→ safeToCleanup")
    func syncedIsSafeToCleanup() {
        let vm = makeViewModel()
        vm.applySyncSummaryForTesting(summary(synced: 10))
        #expect(vm.syncFlowState() == .safeToCleanup)
    }

    @Test("空行 → synced")
    func emptySummarySynced() {
        let vm = makeViewModel()
        vm.applySyncSummaryForTesting(summary())
        #expect(vm.syncFlowState() == .synced)
    }
}
