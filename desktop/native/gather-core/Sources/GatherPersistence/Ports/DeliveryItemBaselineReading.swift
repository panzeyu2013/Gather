// desktop/native/gather-core/Sources/GatherPersistence/Ports/DeliveryItemBaselineReading.swift
// 交付写回镜像的**只读**子集（R2 FaceKwService 收窄，2026-11-18 Wave 4）。
//
// 为什么单独切：FaceKw 的写回镜像只用到 DeliveryRepository 的 2 个读方法
// （listItems(sessionId:module:) 1 处 + itemBaseline 1 处，见
// FaceKwService+Writeback.swift 的 mirrorWritebackOutcome），构造点却要接收整个
// 交付仓储（含写入、清理、租约等方法，是 FaceKwService 19 参数/10 端口之一）。
// 按消费者切一个窄端口，既让依赖图更诚实，也让测试替身不必伪造宽仓储。
//
// 方法签名与 DeliveryRepository / 它的 extension 默认实现同名且逐字一致：
// 实现只有 DeliveryRepo 一处，经 extension conformance 绑定（零成本）。
import GatherProtocol

public protocol DeliveryItemBaselineReading: Sendable {
    /// 按会话 + 模块读交付项（写回镜像只取本模块、本次执行的行）。
    func listItems(sessionId: String, module: DeliveryModule?) throws -> [DeliveryItemRow]
    /// 按 xmpPath 读交付行上的写回基线；行不存在或读失败 → 空基线（不抛错）。
    /// 口径与 DeliveryRepository.itemBaseline 逐字一致，不另起一套实现。
    func itemBaseline(xmpPath: String) -> DeliveryBaselineRow
}
