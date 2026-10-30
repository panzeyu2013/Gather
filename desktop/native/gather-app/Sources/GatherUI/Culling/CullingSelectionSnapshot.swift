// desktop/native/gather-app/Sources/GatherUI/Culling/CullingSelectionSnapshot.swift
// P1-7：服务端 selection 快照 + 跨页批量确认计划。
import Foundation
import GatherProtocol

struct CullingSelectionSnapshot: Equatable {
    let scope: CullingScope
    let filters: CullingFilters?
    let groupId: String?
    let idsHash: String
    let count: Int
    let truncated: Bool
}

/// 跨页批量的影响面快照。
///
/// `snapshot` 非 nil = ⌘A 的服务端范围（执行时服务端重算 + hash 校验；
/// nil = 用户手动跨页选择，按显式 id 分块提交）。两条路都必须先确认再执行。
struct CullingCrossPageBatchPlan: Identifiable {
    let id = UUID().uuidString
    let patch: CullingUpdatePatch
    let snapshot: CullingSelectionSnapshot?
    let photoIds: [String]
    let visiblePhotoIds: [String]

    var totalCount: Int { photoIds.count }
    var visibleCount: Int { visiblePhotoIds.count }
}
