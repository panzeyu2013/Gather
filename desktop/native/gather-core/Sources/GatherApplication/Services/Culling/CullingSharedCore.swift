// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingSharedCore.swift
// 挑片域**跨簇共享的两个端口**（#6 拆分 S2）。
//
// 为什么需要：决策侧（Commands/Queries）与交付侧（Delivery）都要读这两样东西——
// photo_metadata_cache（rating/label 真相源）与 deliveries 行（同步状态）。
// 把它们收进一个无状态结构体后，两个服务共享同一份引用，而缓存（sessionLookup /
// sessionUpdate / pageTotal）**不在这里**：那三个只服务决策侧，若被值拷贝会导致
// 「写路径失效只作用一半」。
//
// struct + 两个 Sendable 协议字段 → 编译器自动合成 Sendable，不占 @unchecked 预算。
import Foundation
import GatherProtocol
import GatherPersistence

public struct CullingSharedCore: Sendable {
    /// rating/label 的唯一真相源（写回计划与状态投影都从这里取值）。
    let metadataCache: any MetadataRepository
    /// 交付行只读（同步徽标、镜像回读 base/backup）。
    let deliveryRows: any DeliveryRowReading

    public init(metadataCache: any MetadataRepository, deliveryRows: any DeliveryRowReading) {
        self.metadataCache = metadataCache
        self.deliveryRows = deliveryRows
    }

    /// 同步态的唯一读模型是 deliveries（写回执行器直接维护）。
    /// 手动 rating/label 的旧 outbox 行不再读取：交付行尚未出现时返回调用方给出的
    /// 默认值（updateState 对共享元数据传 .pending，表达"已入队、尚未落交付"）。
    func currentSyncStatus(
        xmpPath: String,
        fallback: MetadataSyncStatus
    ) throws -> MetadataSyncStatus {
        if let row = try deliveryRows.getItem(xmpPath: xmpPath), let status = row.typedStatus {
            return CullingSharedRules.syncStatus(from: status)
        }
        return fallback
    }
}
