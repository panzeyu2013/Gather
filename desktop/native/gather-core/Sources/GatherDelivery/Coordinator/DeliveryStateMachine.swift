// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryStateMachine.swift
// WP2b：交付状态机的显式迁移表（GatherDelivery 侧的唯一判定入口）。
//
// 背景：迁移前「哪些状态能删 / 能重开 / 能镜像」散落在 Coordinator 的
// 分支（row.typedStatus == .synced、item.status == .written || .failed）
// 与 Persistence 的 SQL 条件里。本文件把「来源态集合 → 目标态」写成显式表：
// - DeliveryStateMachine.Transition：交付级 7 条迁移（含自迁移，服务于幂等重放）；
// - DeliveryStateMachine.ItemTransition：交付项级 4 条迁移；
// - 命名判定：cleanup 候选、新输入重开、镜像目标、confirm 就绪。
//
// 与 Persistence 的关系：DeliveryStatus.canTransition / DeliveryItemStatus.canTransition
// 仍是仓储 CAS 的最后一道校验（SQL 的 status IN (...) 也由它派生）。本表是
// Delivery 编排层的判定来源，两者必须逐边一致——DeliveryStateMachineTests 对
// 全部 (from, to) 组合做双向断言，任何一边新增/删除边都会让测试先红。
//
// 为什么不在本文件直接执行 SQL：状态写入的唯一入口是 DeliveryStateWriter；
// 状态机只回答「能不能」，不碰连接、不写行。

import Foundation
import GatherPersistence

enum DeliveryStateMachine {
    // MARK: - 交付级迁移

    /// 命名迁移。sources 是**显式来源态集合**（含自迁移），target 是唯一目标态。
    enum Transition: String, CaseIterable, Sendable {
        /// 新输入重新打开（revision 由调用方推进）：writing/written/synced/failed/conflict → pending。
        case enqueue
        /// 抢写租约：pending/failed/conflict → writing（writing 自迁移=续租）。
        case claimWriting
        /// 写盘成功：writing → written。
        case writeSucceeded
        /// 会话确认：written → synced。
        case confirm
        /// 写盘失败：pending/writing/failed → failed。
        case failWriting
        /// 外部修改：pending/writing/written/synced/failed/conflict → conflict。
        case markConflict
        /// 清理/审计终态：synced → cleaned（当前 cleanup 是物理删除）。
        case cleanup

        var target: DeliveryStatus {
            switch self {
            case .enqueue: return .pending
            case .claimWriting: return .writing
            case .writeSucceeded: return .written
            case .confirm: return .synced
            case .failWriting: return .failed
            case .markConflict: return .conflict
            case .cleanup: return .cleaned
            }
        }

        var sources: Set<DeliveryStatus> {
            switch self {
            case .enqueue:
                return [.pending, .writing, .written, .synced, .failed, .conflict]
            case .claimWriting:
                return [.writing, .pending, .failed, .conflict]
            case .writeSucceeded:
                return [.written, .writing]
            case .confirm:
                return [.synced, .written]
            case .failWriting:
                return [.failed, .pending, .writing]
            case .markConflict:
                return [.conflict, .pending, .writing, .written, .synced, .failed]
            case .cleanup:
                return [.cleaned, .synced]
            }
        }
    }

    /// 交付级迁移表：target → 允许的来源态（由 Transition 派生，顺序稳定）。
    static let deliveryTable: [DeliveryStatus: Set<DeliveryStatus>] = Dictionary(
        uniqueKeysWithValues: Transition.allCases.map { ($0.target, $0.sources) }
    )

    static func allows(_ from: DeliveryStatus, _ to: DeliveryStatus) -> Bool {
        deliveryTable[to]?.contains(from) ?? false
    }

    static func sources(for target: DeliveryStatus) -> Set<DeliveryStatus> {
        deliveryTable[target] ?? []
    }

    /// 稳定排序的来源态（日志/测试/诊断用；SQL 仍由仓储按枚举派生）。
    static func orderedSources(for target: DeliveryStatus) -> [DeliveryStatus] {
        DeliveryStatus.allCases.filter { allows($0, target) }
    }

    // MARK: - 交付项级迁移

    enum ItemTransition: CaseIterable, Sendable {
        case pending
        case written
        case synced
        case failed

        var target: DeliveryItemStatus {
            switch self {
            case .pending: return .pending
            case .written: return .written
            case .synced: return .synced
            case .failed: return .failed
            }
        }

        var sources: Set<DeliveryItemStatus> {
            switch self {
            case .pending:
                return [.pending, .written, .synced, .failed]
            case .written:
                return [.written, .pending, .failed]
            case .synced:
                return [.synced, .written]
            case .failed:
                return [.failed, .pending, .written]
            }
        }
    }

    static let itemTable: [DeliveryItemStatus: Set<DeliveryItemStatus>] = Dictionary(
        uniqueKeysWithValues: ItemTransition.allCases.map { ($0.target, $0.sources) }
    )

    static func allows(_ from: DeliveryItemStatus, _ to: DeliveryItemStatus) -> Bool {
        itemTable[to]?.contains(from) ?? false
    }

    // MARK: - 命名判定（编排层不再直接比较状态字面量）

    /// cleanup/finalize 候选：只有 synced 可删。
    static func isCleanupCandidate(_ status: DeliveryStatus?) -> Bool {
        status == .synced
    }

    /// confirm 就绪：只有 written 能翻 synced。
    static func isConfirmReady(_ status: DeliveryStatus?) -> Bool {
        status == .written
    }

    /// 新输入应把旧状态重新打开（written/synced/failed/conflict）。
    /// writing 不走这里（仍需租约接管），pending/cleaned 不重开。
    static let reopenSources: Set<DeliveryStatus> = [.written, .synced, .failed, .conflict]

    static func shouldReopenForInput(_ status: DeliveryStatus?) -> Bool {
        guard let status else { return false }
        return reopenSources.contains(status)
    }

    /// cleaned 是审计终态：新输入不能复活，只能新建行。
    static func isTerminalForNewInput(_ status: DeliveryStatus?) -> Bool {
        status == .cleaned
    }

    /// 镜像只接受已执行的结果（written/failed）；pending 表示没执行。
    static func isMirrorableItemStatus(_ status: DeliveryItemStatus?) -> Bool {
        status == .written || status == .failed
    }
}
