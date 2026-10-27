// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataTemplatePlanner.swift
// P1 / B2：元数据模板批量应用的纯计划层（preview 的唯一实现）。
//
// 语义（与 Product 决策一致）：
// - 模板字段 nil = 不触碰；空值 = 清空；有值 = 写入；
// - 盘上现值与缓存现值不一致 = 外部改过 → conflict（默认不覆盖）；
// - 计划是纯函数：不做 IO、不写库，confirm 阶段才落盘并记录批次。
import Foundation
import GatherProtocol

/// 单个字段的计划动作。
public enum MetadataFieldAction: String, Codable, Equatable, Sendable {
    case write
    case clear
    /// 模板未设置该字段（不计入 impacts）
    case skip
    /// 目标值与现值相同，无需写盘
    case unchanged
    /// 盘上被外部改过，按策略不覆盖
    case conflict
}

public struct MetadataFieldImpact: Equatable, Sendable {
    public var field: DescriptiveField
    public var action: MetadataFieldAction
    public var current: XMPFieldValue?
    public var template: XMPFieldValue?
    public var disk: XMPFieldValue?

    public init(field: DescriptiveField, action: MetadataFieldAction, current: XMPFieldValue?, template: XMPFieldValue?, disk: XMPFieldValue?) {
        self.field = field
        self.action = action
        self.current = current
        self.template = template
        self.disk = disk
    }
}

public struct MetadataPhotoImpact: Equatable, Sendable {
    public var photoId: String
    public var fields: [MetadataFieldImpact]

    public init(photoId: String, fields: [MetadataFieldImpact]) {
        self.photoId = photoId
        self.fields = fields
    }

    public var writeCount: Int { fields.filter { $0.action == .write }.count }
    public var clearCount: Int { fields.filter { $0.action == .clear }.count }
    public var conflictCount: Int { fields.filter { $0.action == .conflict }.count }
    /// 有任何 write/clear 即为"会改动"。
    public var changed: Bool { writeCount + clearCount > 0 }
}

public enum MetadataTemplatePlanner {

    /// 单张照片的计划：逐字段比较"模板 / 缓存 / 盘上"。
    public static func plan(
        template: DescriptiveMetadata,
        photoId: String,
        current: DescriptiveMetadata,
        disk: DescriptiveMetadata?,
        policy: MetadataConflictPolicy = .keepExternal
    ) -> MetadataPhotoImpact {
        var impacts: [MetadataFieldImpact] = []
        for field in template.explicitlySetFields {
            let templateValue = template.value(for: field)
            let currentValue = current.value(for: field)
            let diskValue = disk?.value(for: field)

            // 外部改过：只有"读过盘且缓存有该字段"时才能判定。
            // - disk == nil：没侧车/读不到，未知，不得当冲突；
            // - current == nil：缓存没有该字段（未扫描），不能证明外部改过。
            let externallyModified = disk != nil && diskValue != currentValue
                && currentValue != nil
            let target = normalized(templateValue)
            let isClear = target == nil

            // 判定基线必须取"盘上真实值"：缓存只是投影，外部可能已经改过。
            let baseline = normalized(diskValue ?? currentValue)
            let action: MetadataFieldAction
            // 清空同样是破坏性动作：外部改过且 keepExternal 时必须冲突，
            // 否则模板的"勾选留空"会无提示删掉外部新值。
            if externallyModified, policy == .keepExternal {
                action = .conflict
            } else if isClear {
                action = baseline == nil ? .unchanged : .clear
            } else if baseline == target {
                action = .unchanged
            } else {
                action = .write
            }
            impacts.append(MetadataFieldImpact(
                field: field, action: action,
                current: currentValue, template: templateValue, disk: diskValue
            ))
        }
        return MetadataPhotoImpact(photoId: photoId, fields: impacts)
    }

    /// 批量计划 + 汇总（面板"将写入 N 张 / M 个字段 / K 处冲突"的数据源）。
    public static func planBatch(
        template: DescriptiveMetadata,
        photos: [(photoId: String, current: DescriptiveMetadata, disk: DescriptiveMetadata?)],
        policy: MetadataConflictPolicy = .keepExternal
    ) -> [MetadataPhotoImpact] {
        photos.map { photo in
            plan(template: template, photoId: photo.photoId, current: photo.current, disk: photo.disk, policy: policy)
        }
    }

    /// 空值与 nil 等价（清空语义），其余原样。
    private static func normalized(_ value: XMPFieldValue?) -> XMPFieldValue? {
        guard let value, !value.isEmptyValue else { return nil }
        return value
    }
}
