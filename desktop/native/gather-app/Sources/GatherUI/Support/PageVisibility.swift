// desktop/native/gather-app/Sources/GatherUI/Support/PageVisibility.swift
// WP4d：7 个会话页 ViewModel 的页面生命周期契约。
//
// 为什么需要：7 个 VM 各自实现了 setVisible/shutdown，但默认值与幂等语义
// 不统一（Control 默认 false，Culling 默认 isActive=true，Gallery/Similarity/
// Face/Export/Duplicates 默认 true），此前靠构造后立即 setPageVisible 纠正。
// 契约只约束"状态 + 默认值 + 幂等 + 关闭终态"，**不**统一各页轮询细节
// （R4）：Culling 画质轮询 / Gallery 索引轮询 / Control 兜底轮询 /
// Similarity 两路轮询各自保留，业务与文案不变。
//
// 契约：
// 1. 默认不可见：VM 构造后可见性状态为 false，不启动轮询、不发起首载；
// 2. setVisible 幂等：重复 true / 重复 false 不重复启动或停止副作用；
// 3. true = 启动/恢复（各页自己的语义），false = 停轮询/取消在途；
// 4. shutdown 是终态：之后 setVisible 一律 no-op；
// 5. 路由唯一：页面级只由当前挂载页 onAppear/onDisappear 经
//    SessionWorkspace.setPageVisible(page, visible) 调用；离开会话/关闭由
//    SessionWorkspace.setVisible(false) 全量扇出。View 不直接改状态。
import Foundation

@MainActor
public protocol PageVisibility: AnyObject {
    /// 页面可见性唯一入口。实现须满足上述契约（默认 false + 幂等 + 终态）。
    func setVisible(_ visible: Bool)
}

extension PageVisibility {
    /// 幂等迁移：值真的变化才返回 true，调用方据此决定是否执行启停副作用。
    ///
    /// 统一放在协议扩展里，避免 7 个 VM 各写一份比较逻辑后再次漂移；
    /// shutdown 终态守卫仍由各 VM 在调用前判断（关闭后不迁移状态）。
    func transitionVisibility(_ state: inout Bool, to visible: Bool) -> Bool {
        guard state != visible else { return false }
        state = visible
        return true
    }
}
