// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataTemplatePreview.swift
// P1 / B2：模板预览的汇总层（纯函数；IO 由调用方注入 current/disk 快照）。
//
// 与 MetadataTemplatePlanner 的分工：
//   planner  → 单张的逐字段动作（write/clear/unchanged/conflict）
//   本文件   → 多张汇总成面板要显示的数字与明细（"将写 N 张 / M 个字段 / K 处冲突"）
import Foundation
import GatherProtocol

public struct MetadataTemplatePreview: Equatable, Sendable {
    public var templateId: String
    public var templateName: String
    public var totalPhotos: Int
    /// 至少有一个 write/clear 的照片数。
    public var changedPhotos: Int
    /// 会写盘的字段总数（write + clear）。
    public var changedFields: Int
    /// 冲突字段总数（按"字段×照片"计）。
    public var conflictFields: Int
    public var impacts: [MetadataPhotoImpact]

    public init(templateId: String, templateName: String, totalPhotos: Int,
                changedPhotos: Int, changedFields: Int, conflictFields: Int,
                impacts: [MetadataPhotoImpact]) {
        self.templateId = templateId
        self.templateName = templateName
        self.totalPhotos = totalPhotos
        self.changedPhotos = changedPhotos
        self.changedFields = changedFields
        self.conflictFields = conflictFields
        self.impacts = impacts
    }

    /// 没有任何可写动作：UI 用它与"全是冲突"区分（前者禁用按钮，后者提示冲突）。
    public var isEmpty: Bool { changedFields == 0 && conflictFields == 0 }
}

public enum MetadataTemplatePreviewBuilder {
    /// photos 的 current 来自缓存投影，disk 来自盘上读取（nil = 读不到/无侧车）。
    public static func build(
        template: MetadataTemplate,
        photos: [(photoId: String, current: DescriptiveMetadata, disk: DescriptiveMetadata?)],
        policy: MetadataConflictPolicy = .keepExternal
    ) -> MetadataTemplatePreview {
        let impacts = photos.map { photo in
            MetadataTemplatePlanner.plan(
                template: template.fields,
                photoId: photo.photoId,
                current: photo.current,
                disk: photo.disk,
                policy: policy
            )
        }
        return MetadataTemplatePreview(
            templateId: template.id,
            templateName: template.name,
            totalPhotos: photos.count,
            changedPhotos: impacts.filter(\.changed).count,
            changedFields: impacts.reduce(0) { $0 + $1.writeCount + $1.clearCount },
            conflictFields: impacts.reduce(0) { $0 + $1.conflictCount },
            impacts: impacts
        )
    }
}
