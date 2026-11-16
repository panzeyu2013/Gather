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
    /// 本次**显式清空**的联系人成员（DescriptiveContact.members 的 key）。
    /// contact 结构里 nil 成员既可能是"清空"也可能是"不触碰"，只有列在这里的
    /// 才算清空——JPEG 内嵌残留的判定依赖这条信号。
    public let clearedContactMembers: [String]?

    /// 与模板 apply 同值：一次内联编辑不会超过整批模板套用的规模。
    public static let maxPhotoIds = 2_000
    /// 单字段文本上限（与输入校验的 4096 保持一致）。
    public static let maxFieldLength = 4_096

    public init(
        photoIds: [String],
        fields: DescriptiveMetadata,
        policy: MetadataConflictPolicy = .overwrite,
        clearedContactMembers: [String]? = nil
    ) throws {
        let values = try APIValidation.nonEmpty(
            photoIds, field: "photoIds", maxCount: Self.maxPhotoIds)
        guard !fields.isEmpty else {
            throw GatherError.invalidParameter(field: "fields", reason: "must set at least one field")
        }
        try Self.validate(fields)
        if let clearedContactMembers {
            let known = Set(DescriptiveContact.members.map(\.key))
            if let unknown = clearedContactMembers.first(where: { !known.contains($0) }) {
                throw GatherError.invalidParameter(
                    field: "clearedContactMembers", reason: "unknown member: \(unknown)")
            }
        }
        self.photoIds = values
        self.fields = fields
        self.policy = policy
        self.clearedContactMembers = clearedContactMembers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            photoIds: try container.decode([String].self, forKey: .photoIds),
            fields: try container.decode(DescriptiveMetadata.self, forKey: .fields),
            policy: try container.decodeIfPresent(MetadataConflictPolicy.self, forKey: .policy)
                ?? .overwrite,
            clearedContactMembers: try container.decodeIfPresent(
                [String].self, forKey: .clearedContactMembers)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case photoIds, fields, policy, clearedContactMembers
    }

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

// MARK: - Wave5（batch5）：位置 / 拍摄时间

/// 盘上当前的 GPS 坐标与拍摄时间（编辑器初值；只读快照）。
public struct MetadataGeoDateSnapshot: Codable, Equatable, Sendable {
    public var latitude: Double?
    public var longitude: Double?
    /// exif:DateTimeOriginal 原文（读到什么给什么；UI 负责归一化展示）。
    public var dateTaken: String?

    public init(latitude: Double? = nil, longitude: Double? = nil, dateTaken: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.dateTaken = dateTaken
    }
}

/// 直接编辑 GPS 坐标与拍摄时间（**sidecar 通道**）。
///
/// 三态（与描述性字段同口径）：
/// - latitude/longitude 为 nil = 不动；两者必须同时给（只有一个坐标不是合法资产）；
/// - dateTaken 为 nil = 不动；空串 = 清空该字段；其余必须是可解析的时间（写入前
///   归一化成 "yyyy-MM-dd'T'HH:mm:ss"，即 XMP exif:DateTimeOriginal 的形态）。
/// - 三项全 nil 视为无动作，显式失败（避免 UI 误以为保存成功）。
///
/// 清空**坐标**本波不支持：MetadataWriteAttributes.latitude/longitude 是 Double?（nil 只能
/// 表达"不触碰"），要表达"删除 GPS"需要额外信号；留待下一波（回执已列）。
public struct MetadataGeoDateInput: Decodable, Sendable, Equatable {
    public let photoIds: [String]
    public let latitude: Double?
    public let longitude: Double?
    /// 已归一化的拍摄时间：nil = 不动；"" = 清空；其余 "yyyy-MM-dd'T'HH:mm:ss"。
    public let dateTaken: String?
    /// 冲突策略。坐标/时间走交付层的指纹冲突检测，本字段目前只随输入保留
    /// （描述性字段的 keepExternal/overwrite 语义在 applyDescriptive 路径上）。
    public let policy: MetadataConflictPolicy

    public static let maxPhotoIds = 2_000

    public init(
        photoIds: [String],
        latitude: Double? = nil,
        longitude: Double? = nil,
        dateTaken: String? = nil,
        policy: MetadataConflictPolicy = .overwrite
    ) throws {
        let ids = try APIValidation.nonEmpty(
            photoIds, field: "photoIds", maxCount: Self.maxPhotoIds)
        switch (latitude, longitude) {
        case (nil, nil):
            break
        case (let lat?, let lon?):
            guard lat.isFinite, (-90.0...90.0).contains(lat) else {
                throw GatherError.invalidParameter(
                    field: "latitude", reason: "must be within -90...90")
            }
            guard lon.isFinite, (-180.0...180.0).contains(lon) else {
                throw GatherError.invalidParameter(
                    field: "longitude", reason: "must be within -180...180")
            }
        default:
            throw GatherError.invalidParameter(
                field: "latitude/longitude", reason: "must be provided together")
        }
        var normalizedDate: String?
        if let raw = dateTaken {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                normalizedDate = "" // 显式清空
            } else {
                guard let normalized = Self.normalizedDateTime(trimmed) else {
                    throw GatherError.invalidParameter(
                        field: "dateTaken",
                        reason: "must be ISO-8601 (yyyy-MM-dd'T'HH:mm:ss) or EXIF (yyyy:MM:dd HH:mm:ss)")
                }
                normalizedDate = normalized
            }
        }
        guard latitude != nil || normalizedDate != nil else {
            throw GatherError.invalidParameter(
                field: "latitude/longitude/dateTaken",
                reason: "must set at least one of latitude+longitude or dateTaken")
        }
        self.photoIds = ids
        self.latitude = latitude
        self.longitude = longitude
        self.dateTaken = normalizedDate
        self.policy = policy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            photoIds: try container.decode([String].self, forKey: .photoIds),
            latitude: try container.decodeIfPresent(Double.self, forKey: .latitude),
            longitude: try container.decodeIfPresent(Double.self, forKey: .longitude),
            dateTaken: try container.decodeIfPresent(String.self, forKey: .dateTaken),
            policy: try container.decodeIfPresent(MetadataConflictPolicy.self, forKey: .policy)
                ?? .overwrite)
    }

    private enum CodingKeys: String, CodingKey {
        case photoIds, latitude, longitude, dateTaken, policy
    }

    /// 时间归一化：可解析返回 "yyyy-MM-dd'T'HH:mm:ss"，否则 nil。
    ///
    /// 接受：
    /// - XMP/EXIF 常见形态 "yyyy:MM:dd HH:mm:ss"（相机/ImageIO 读回的就是它）；
    /// - "yyyy-MM-dd HH:mm:ss" 与 "yyyy-MM-dd'T'HH:mm:ss"；
    /// - 带时区/毫秒的 ISO-8601（"…Z"/"…+08:00"/"….123Z"）：先换算到 UTC 再输出；
    /// - 只有日期 "yyyy-MM-dd" → 00:00:00。
    ///
    /// 取舍：EXIF 的 DateTimeOriginal **没有时区**（本地时间里没有 zone 的类型）；带时区
    /// 的输入换算成 UTC 后丢区（XMP 里无法表达原始偏移），因此跨时区往返会差出偏移。
    /// 这是与 C1/Lightroom 一致的模型（它们同样只存无区本地时间）。
    public static func normalizedDateTime(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.timeZone = TimeZone(identifier: "UTC")
        output.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        // 1) 带时区/毫秒的 ISO-8601（换算到 UTC）。
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return output.string(from: date) }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return output.string(from: date) }

        // 2) 无时区的本地/EXIF 形态：按同一组年月日时分秒重排（不做时区换算）。
        let wall = DateFormatter()
        wall.locale = Locale(identifier: "en_US_POSIX")
        wall.timeZone = TimeZone.current
        for pattern in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            wall.dateFormat = pattern
            if let date = wall.date(from: text) {
                let wallOutput = DateFormatter()
                wallOutput.locale = Locale(identifier: "en_US_POSIX")
                wallOutput.timeZone = TimeZone.current
                wallOutput.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                return wallOutput.string(from: date)
            }
        }
        // 3) 只有日期：补 00:00:00。
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone.current
        dateOnly.dateFormat = "yyyy-MM-dd"
        if let date = dateOnly.date(from: text) {
            let wallOutput = DateFormatter()
            wallOutput.locale = Locale(identifier: "en_US_POSIX")
            wallOutput.timeZone = TimeZone.current
            wallOutput.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return wallOutput.string(from: date)
        }
        return nil
    }
}

