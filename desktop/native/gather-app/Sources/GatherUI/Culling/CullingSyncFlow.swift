// desktop/native/gather-app/Sources/GatherUI/Culling/CullingSyncFlow.swift
// 同步状态机（#6 S1c：从 CullingViewModel 里提到顶层）。
//
// deriveControls 是纯函数：给定同步摘要 + 权限位，回答能不能加载/确认/清理。
// 它是挑片页唯一的同步决策点，提出后可脱离 VM 单测（CullingSyncFlowTests 已在用）。
import Foundation
import GatherProtocol

public enum SyncFlowState: Equatable {
    case disconnected
    case conflict
    case failed
    case syncing
    case c1Read
    case safeToCleanup
    case synced
}

/// 纯函数版按钮可用性矩阵：对齐 TS deriveSyncControls({ syncState, hasWritten, acked })
/// （tests/unit/renderer/c1-sync-controls.test.ts 的 8 组门控用例）。
/// internal：CullingViewModelTests 直测。
struct SyncFlowControls: Equatable {
    let canLoadMetadata: Bool
    let canConfirmSync: Bool
    let canCleanup: Bool
}

enum CullingSyncFlow {
    static func deriveControls(
        syncState: SyncFlowState,
        hasWritten: Bool,
        acked: Bool
    ) -> SyncFlowControls {
        switch syncState {
        case .syncing, .c1Read, .safeToCleanup:
            // syncing：可重载（无需 ack）；c1Read/safeToCleanup 同左。
            let canLoad = true
            let canConfirm: Bool
            switch syncState {
            case .safeToCleanup: canConfirm = true
            case .c1Read: canConfirm = acked && hasWritten
            default: canConfirm = false
            }
            return SyncFlowControls(
                canLoadMetadata: canLoad,
                canConfirmSync: canConfirm,
                canCleanup: syncState == .safeToCleanup
            )
        case .disconnected, .conflict, .failed, .synced:
            // 保守：全部禁用。
            return SyncFlowControls(canLoadMetadata: false, canConfirmSync: false, canCleanup: false)
        }
    }
}
