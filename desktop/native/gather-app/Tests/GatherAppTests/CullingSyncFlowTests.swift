// CullingViewModel 同步状态机单测：对齐 tests/unit/renderer/c1-sync-controls.test.ts
// 的 8 组门控用例（deriveSyncControls 矩阵）+ syncFlowState 从
// MetadataSyncSummary 推导的优先级（冲突 > 失败 > 写入中 > 已写入 > 终态 > 空）。
//
// 合并说明：两组用例都是「同一函数、仅输入不同」，原先 8 + 7 条声明里逐条重复了
// 同样的调用与断言形状；现各自合并为一条 @Test(arguments:) 参数化用例，
// 每条输入与断言逐字保留在对应的 argument case 上（case 数不变、声明数 15 → 2）。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

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
    MetadataSyncSummary(
        sessionId: "s1", pending: pending, writing: writing, written: written,
        failed: failed, conflict: conflict, synced: synced, items: [])
}

@Suite("CullingSyncFlow deriveControls（对齐 c1-sync-controls.test.ts）")
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

@Suite("CullingViewModel syncFlowState 推导")
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
        let vm = CullingViewModel(sessionId: "s1", router: StubCommandRouter.empty())
        if let summary { vm.applySyncSummaryForTesting(summary) }
        #expect(vm.syncFlowState() == expected.state, Comment(rawValue: label))
    }
}


/// culling.sync_status 的唯一解码入口（CullingViewModel.decodeSyncStatus）：
/// 路由器在摘要对象上附耐久 `reloadAckedAt`（sessions.reload_acked_at）。旧实现
/// 只解 MetadataSyncSummary（未知键被忽略）→ 内存 reloadAcked 冷启动即丢、确认
/// 同步按钮永久禁用；本套件用手写 JSON 响应独立钉住「摘要 + ack」的解码契约。
/// （变异验证：把 ack 解出改回 nil / 去掉空串守卫，本套件即变红。）
@Suite("CullingViewModel.decodeSyncStatus（耐久 reload-ack 解码）")
struct CullingDecodeSyncStatusTests {
    /// 对齐 SessionCommandRouter 的 culling.sync_status 响应形状（摘要 + reloadAckedAt）。
    private func payload(ack: JSONValue) -> JSONValue {
        .object([
            "sessionId": .string("s1"),
            "pending": .number(1), "writing": .number(0), "written": .number(2),
            "failed": .number(0), "conflict": .number(1), "synced": .number(3),
            "items": .array([]),
            "reloadAckedAt": ack,
        ])
    }

    @Test("摘要字段与 reloadAckedAt 一并解出")
    func decodesSummaryAndAck() throws {
        let decoded = try CullingViewModel.decodeSyncStatus(payload(ack: .string("2026-09-01T10:00:00.000Z")))
        #expect(decoded.summary == MetadataSyncSummary(
            sessionId: "s1", pending: 1, writing: 0, written: 2,
            failed: 0, conflict: 1, synced: 3, items: []))
        #expect(decoded.reloadAckedAt == "2026-09-01T10:00:00.000Z")
    }

    @Test("ack 为 null / 空串 / 键缺失 → nil（空串不得当作已确认）")
    func missingAckIsNil() throws {
        #expect(try CullingViewModel.decodeSyncStatus(payload(ack: .null)).reloadAckedAt == nil)
        #expect(try CullingViewModel.decodeSyncStatus(payload(ack: .string(""))).reloadAckedAt == nil)
        let withoutAckKey: JSONValue = .object([
            "sessionId": .string("s1"), "pending": .number(0), "writing": .number(0),
            "written": .number(0), "failed": .number(0), "conflict": .number(0),
            "synced": .number(0), "items": .array([]),
        ])
        #expect(try CullingViewModel.decodeSyncStatus(withoutAckKey).reloadAckedAt == nil)
    }

    @Test("非摘要载荷 → 抛解码错误（不得静默返回空摘要）")
    func malformedPayloadThrows() {
        do {
            _ = try CullingViewModel.decodeSyncStatus(.object(["nope": .number(1)]))
            Issue.record("非摘要载荷应抛错")
        } catch is DecodingError {
            // 预期：JSONDecoder 往返失败。
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }
}
