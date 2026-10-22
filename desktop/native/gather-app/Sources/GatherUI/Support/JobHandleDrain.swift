// desktop/native/gather-app/Sources/GatherUI/Support/JobHandleDrain.swift
// Cut 3 / 3b-3：JobHandle 的 fire-and-forget 消费入口。
//
// 3b-2 前该扩展声明在 GatherHost/APIs/AppServices.swift；Dashboard/Gallery
// 视图模型（GatherUI）也用同一入口，拆 target 后上移到 UI。JobHandle 本身是
// GatherProtocol 的类型，扩展不触及任何领域实现。
import GatherProtocol

public extension JobHandle {
    /// Fire-and-forget 入队：消费事件直到终态，让 AsyncStream 的观察者随流释放。
    /// 只用于“UI 另有事件中心订阅、不关心这个 handle”的调用点（Dashboard 建
    /// metadata.scan 等）；需要逐帧进度的调用方应直接消费 handle.events。
    func drain() {
        Task { for await _ in events {} }
    }
}
