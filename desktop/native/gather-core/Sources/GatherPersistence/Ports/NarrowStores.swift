// desktop/native/gather-core/Sources/GatherPersistence/Ports/NarrowStores.swift
// R8：Delivery 层的窄读/窄写端口（接口隔离）。
//
// 背景：GatherDelivery 与 GatherPersistence 同属基础设施层，编排器直接持有
// 具体 Repo 是允许的（见 ADR-032）；但**只读协作者**不应看见整张 Repo API：
// - DeliveryMirrorWriter 只读一条交付行 → DeliveryReadStore
// - WritebackService 只读会话照片投影 → PhotoReadStore
// - WritebackService 只回写缓存三字段 → MetadataCacheStore
//
// 具体 Repo 在组合根构造；端口只描述调用点真正用到的语义。
//
// 为什么不复用 PhotoRepository / MetadataRepository（R8 复审结论）：
// 那两个是面向 Application 的**宽**端口（PhotoRepository 约 6 方法、MetadataRepository
// 约 10 方法，含写路径）。让只读协作者依赖宽端口，等于把它们能调的写方法重新暴露出来，
// 与本文件的接口隔离目标相反；这里的方法签名与宽端口同名是有意的“子集声明”，
// 不是重复实现（实现只有 PhotoRepo/MetadataCacheRepo 一处，经 extension conformance 绑定）。
import Foundation
import GatherProtocol

/// 交付行只读面（镜像写手只需要读当前行）。
public protocol DeliveryReadStore: Sendable {
    func get(_ xmpPath: String) throws -> DeliveryRow?
}

/// 会话照片投影只读面（写回计划用）。
public protocol PhotoReadStore {
    func getBySessionProjection(sessionId: String) throws -> [PhotoProjectionRow]
}

/// 元数据缓存三字段回写面（写回收敛用）。
public protocol MetadataCacheStore {
    func updateRating(photoId: String, rating: Int64) throws
    func updateLabel(photoId: String, label: String) throws
    func updateKeywords(photoId: String, keywords: [String]) throws
    /// P1 / IPTC：描述性元数据写盘后的投影刷新（完整快照，整列替换）。
    func updateDescriptive(photoId: String, descriptive: DescriptiveMetadata) throws
    /// P0 / A3：增量补丁合并（未触碰字段保留；撤销时整块替换 contact）。
    func mergeDescriptive(
        photoId: String, patch: DescriptiveMetadata, replaceContact: Bool) throws
}

extension DeliveryRepo: DeliveryReadStore {}
extension PhotoRepo: PhotoReadStore {}
extension MetadataCacheRepo: MetadataCacheStore {}
