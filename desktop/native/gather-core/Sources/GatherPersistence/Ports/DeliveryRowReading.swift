// desktop/native/gather-core/Sources/GatherPersistence/Ports/DeliveryRowReading.swift
// 交付行的**只读**子集（#6 CullingDecisionService 收窄）。
//
// 为什么单独切：挑片服务只用 DeliveryRepository 的 2 个读方法（getItem / getMany，
// 共 8 处调用），却要在构造点接收整个交付仓储（含写入、清理、租约等方法）。
// 按消费者切一个窄端口，既让依赖图更诚实，也让测试替身不必伪造写方法。
public protocol DeliveryRowReading: Sendable {
    func getItem(xmpPath: String) throws -> DeliveryRow?
    func getMany(xmpPaths: [String]) throws -> [String: DeliveryRow]
}
