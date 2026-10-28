// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/MetadataInlineInputs.swift
// P0 / B2：单张/少量照片的"直接编辑描述性元数据"输入。
//
// 与模板的分工：
// - 模板 = 可复用的字段集合（settings 持久化），preview → apply；
// - 内联 = 用户在当前照片上改的那几个字段，直接 apply（批次 templateId="inline"），
//   undo 复用同一套 MetadataApplyBatchStore。
import Foundation

public struct MetadataInlineApplyInput: Decodable, Sendable, Equatable {
    public let photoIds: [String]
    /// 三态：nil 不触碰 / 空值清空 / 有值写入。
    public let fields: DescriptiveMetadata
    /// 内联编辑默认覆盖（用户看着当前值改）；调用方可显式传 keepExternal。
    public let policy: MetadataConflictPolicy

    /// 与模板 apply 同值：一次内联编辑不会超过整批模板套用的规模。
    public static let maxPhotoIds = 2_000
    /// 单字段文本上限（与输入校验的 4096 保持一致）。
    public static let maxFieldLength = 4_096

    public init(
        photoIds: [String],
        fields: DescriptiveMetadata,
        policy: MetadataConflictPolicy = .overwrite
    ) throws {
        let values = try APIValidation.nonEmpty(
            photoIds, field: "photoIds", maxCount: Self.maxPhotoIds)
        guard !fields.isEmpty else {
            throw GatherError.invalidParameter(field: "fields", reason: "must set at least one field")
        }
        try Self.validate(fields)
        self.photoIds = values
        self.fields = fields
        self.policy = policy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            photoIds: try container.decode([String].self, forKey: .photoIds),
            fields: try container.decode(DescriptiveMetadata.self, forKey: .fields),
            policy: try container.decodeIfPresent(MetadataConflictPolicy.self, forKey: .policy)
                ?? .overwrite
        )
    }

    private enum CodingKeys: String, CodingKey { case photoIds, fields, policy }

    /// 逐字段长度/数量上限：超长描述会写进 XMP，不能无限大。
    private static func validate(_ fields: DescriptiveMetadata) throws {
        for field in DescriptiveField.allCases {
            switch fields.value(for: field) {
            case .text(let value):
                try check(value.count, field: field)
            case .list(let values):
                guard values.count <= 100 else {
                    throw GatherError.invalidParameter(
                        field: "fields.\(field.rawValue)",
                        reason: "must have at most 100 items")
                }
                for value in values { try check(value.count, field: field) }
            case .contact(let contact):
                let members = [
                    contact.city, contact.country, contact.address, contact.postalCode,
                    contact.region, contact.email, contact.telephone, contact.url,
                ]
                for value in members.compactMap({ $0 }) {
                    try check(value.count, field: field)
                }
            case .none:
                break
            }
        }
    }

    private static func check(_ length: Int, field: DescriptiveField) throws {
        guard length <= maxFieldLength else {
            throw GatherError.invalidParameter(
                field: "fields.\(field.rawValue)",
                reason: "length must be at most \(maxFieldLength)")
        }
    }
}
