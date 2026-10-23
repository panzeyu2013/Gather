// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryCleanupFlow.swift
// WP2b：cleanup / finalize 的逐交付编排（自 DeliveryCoordinator.swift 抽出）。
//
// 每个交付独立三段（不可回滚的文件阶段用 intent 前滚）：
//   prepare(prepared) → DeliveryFilePhase（verify → restore/remove → verify）
//   → advance(fileDone) → DeliveryDBPhase（删除 + intent.finish 同一事务）
// finalize 例外（P1-1）：文件阶段只 verify，不删备份；DB 段返回 deleted/alreadyGone
// （事务已提交）之后才调用 DeliveryFilePhase.removeFinalizeBackup 清理备份。
// 单交付失败不拖垮整批；文件/DB 失败保留 intent，下次 replay() 重试。
//
// 本文件只做控制流与结果映射：状态迁移走 DeliveryStateWriter，文件阶段走
// DeliveryFilePhase，DB 段走 DeliveryDBPhase；错误码/计数与迁移前逐字一致。
// 拆分（WP5，纯移动）：cleanup → DeliveryCleanupFlow+Cleanup.swift；
// finalize + 备份清理 → DeliveryCleanupFlow+Finalize.swift；本文件留结构、存储属性
// 与两段流程共用的错误映射。
// 跨文件访问级：DBPhaseAction / code(for:action:) / cause(of:) / failure 由 private
// 放宽为 internal（struct 本身 internal，公共 API 不变）。

import Foundation
import GatherPersistence

struct DeliveryCleanupFlow: Sendable {
    let deliveryRepo: DeliveryRepo
    let writer: DeliveryStateWriter
    let intents: DeliveryIntentStore
    let summaryQuery: DeliverySummaryQuery
    let filePhase: DeliveryFilePhase
    let dbPhase: DeliveryDBPhase
    let resolvePhotoPath: DeliveryPhotoPathResolver
    let emitStateChanged: @Sendable (String) -> Void

    // MARK: - 错误映射

    enum DBPhaseAction {
        case cleanup
        case finalize
    }

    func code(for error: DeliveryDBPhaseError, action: DBPhaseAction) -> String {
        switch (action, error) {
        case (.cleanup, .database): return "XMP_CLEANUP_DB_FAILED"
        case (.cleanup, .finish): return "XMP_CLEANUP_FINISH_FAILED"
        case (.finalize, .database): return "XMP_FINALIZE_DB_FAILED"
        case (.finalize, .finish): return "XMP_FINALIZE_FINISH_FAILED"
        }
    }

    func cause(of error: DeliveryDBPhaseError) -> Error {
        switch error {
        case .database(let cause), .finish(let cause): return cause
        }
    }

    static func failure(_ code: String, _ xmpPath: String, _ error: Error) -> String {
        "\(code): \(xmpPath) reason=\(String(describing: error))"
    }
}
