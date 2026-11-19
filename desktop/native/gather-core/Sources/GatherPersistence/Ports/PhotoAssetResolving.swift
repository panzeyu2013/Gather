// desktop/native/gather-core/Sources/GatherPersistence/Ports/PhotoAssetResolving.swift
// M14c（Wave 5）：PhotoAssetResolver 的窄端口（方法面 2 个：resolve / resolveMany）。
//
// 为什么端口定义在 Persistence（provider 侧）：GatherApplication 的 MetadataService /
// PhotoMetadataProjector / MetadataAttributeWriter / MetadataKeywordWriter 只需要
// 「按会话解析照片真实路径 + xmp 路径」这一窄能力；GatherDelivery 的 WritebackService /
// MetadataMutationService 也只需要同一能力。端口放 Persistence 让 **Application 与
// Delivery 都能只依赖窄面**（Delivery 不能 import Application，消费方侧声明会挡住它）。
//
// 语义与 PhotoAssetResolver 同名方法一致：单照片解析在「照片不属于会话 / 资产模式迁移
// 不完整」时抛错；批量解析对未知照片与迁移不完整行直接缺席。实现只有 PhotoAssetResolver
// 一处（同模块 extension conformance，见 Database/Repositories/PhotoAssetResolver.swift，零成本）。

/// PhotoAssetResolver 的窄端口。
public protocol PhotoAssetResolving: Sendable {
    /// 单照片解析（照片不属于会话 / 资产模式迁移不完整时抛 PhotoAssetResolverError）。
    func resolve(sessionId: String, photoId: String) throws -> ResolvedPhotoAsset

    /// 批量解析：一次 IN 查询替代每照片 5 路 JOIN；未知照片或迁移不完整的行缺席。
    func resolveMany(sessionId: String, photoIds: [String]) throws -> [String: ResolvedPhotoAsset]
}

/// 实现已满足该窄端口全部要求（纯 conformance，无行为改动）。
extension PhotoAssetResolver: PhotoAssetResolving {}
