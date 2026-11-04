// desktop/native/gather-core/Sources/GatherPersistence/Ports/CullingDecisionLiteReading.swift
// 决策行的**单方法读端口**（#6 拆分 S4）。
//
// 为什么单独切：写回规划只需要「这张会话里已决策的照片及其决策值」，
// 但它今天要拿整个 CullingService 才能读到。给交付侧一个单方法端口之后，
// 两个服务之间只剩**一条单向边**，而不是 6 个回调。
public protocol CullingDecisionLiteReading {
    /// 会话内已落库的决策行（decision != pending 由调用方过滤）。
    func getDecisions(sessionId: String) throws -> [CullingDecisionLiteRow]
}
