// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingSharedRules.swift
// 挑片域的**纯规则**（#6 拆分 S1：从 CullingService 的 Queries/Delivery 扩展里提出）。
//
// 为什么单独成类型：这三个符号被决策侧（Queries/Commands）与交付侧（Delivery）同时使用，
// 但它们是纯函数/常量——没有状态、没有 IO、没有依赖。抽成 enum 之后两边都能直接引用，
// 不必让交付侧为了一个色标解析去依赖整个决策服务。
//
// 全是 static，天然 Sendable；不进 @unchecked 预算。
import Foundation
import GatherProtocol
import GatherDelivery
import GatherPersistence

enum CullingSharedRules {
    /// TS: COLOR_LABELS —— 合法的八个色标（none 表示未设置）。
    static let colorLabels: Set<CaptureOneColorLabel> = [
        .none, .red, .orange, .yellow, .green, .blue, .pink, .purple,
    ]

    /// 合法色标解析：nil / 未知 / 非法值一律归 .none（唯一真相源里可能有历史脏值）。
    static func colorLabel(_ raw: String?) -> CaptureOneColorLabel {
        guard let raw, let parsed = CaptureOneColorLabel(rawValue: raw),
              colorLabels.contains(parsed) else { return .none }
        return parsed
    }

    /// 交付行 → 旧 MetadataSyncStatus 投影（culling 徽标/更新结果用）。
    static func syncStatus(from status: DeliveryStatus) -> MetadataSyncStatus {
        switch status {
        case .pending: .pending
        case .writing: .writing
        case .written: .written
        case .synced: .synced
        case .failed: .failed
        case .conflict: .conflict
        case .cleaned: .cleaned
        }
    }
}
