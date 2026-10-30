// desktop/native/gather-app/Sources/GatherUI/Culling/CullingGroupDecision.swift
// P1-8：相似组决策的“真实影响面”。
//
// 旧实现用当前页已加载的组员数展示“相似组 · N 张”，但服务端按完整组执行；
// 组跨页时会把屏幕外成员一起淘汰，且没有二次确认。这里先取完整组，生成
// 影响面快照，再交给统一确认弹窗。
import Foundation

struct CullingGroupDecisionPlan: Equatable, Identifiable {
    let groupId: String
    let keepPhotoIds: [String]
    let totalCount: Int
    let visibleCount: Int
    let sampleRejectedNames: [String]

    var id: String {
        groupId + ":" + keepPhotoIds.sorted().joined(separator: ",")
    }
}
