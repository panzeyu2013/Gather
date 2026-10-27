// desktop/native/gather-core/Sources/GatherProtocol/Protocol/DescriptiveMetadata.swift
// P1 / IPTC：描述性元数据（IPTC Core + IPTC Extension）的纯值契约与 XMP 字段表。
//
// 设计边界：
// - 本文件只描述"字段是什么、写到哪个命名空间、用哪种 RDF 形状"，不含任何 XML。
//   XMP 的实际读写由宿主（gather-app/SidecarXMPProvider）按本表驱动。
// - 字段三态必须可区分：nil = 不触碰；空串/空数组 = 显式清空；有值 = 写入。
//   模板批量应用与冲突检测都依赖这一区分。
// - 覆盖：IPTC Core 22 项（含 Contact Info 结构）+ IPTC Extension 10 项。
//   未纳入：ArtworkOrObject 结构数组、Accessibility 字段，留 P2。

import Foundation

/// XMP 值形状：决定补丁器如何序列化、读取器如何收集。
public enum XMPValueShape: String, Codable, CaseIterable, Sendable {
    case text      // <photoshop:City>北京</photoshop:City>
    case alt       // rdf:Alt / rdf:li xml:lang="x-default"
    case bag       // rdf:Bag
    case seq       // rdf:Seq
    case structure // Iptc4xmpCore:CreatorContactInfo 内嵌 rdf:Description
}

/// IPTC 字段的逻辑键（与 XMP 属性名解耦：caption -> dc:description）。
public enum DescriptiveField: String, Codable, CaseIterable, Sendable {
    // IPTC Core
    case title, caption, creator, creatorJobTitle, credit, source
    case copyrightNotice, usageTerms, webStatement, headline, captionWriter, jobIdentifier
    case subjectCode, scene, intellectualGenre, location
    case city, state, country, countryCode, dateCreated, contactInfo
    // IPTC Extension
    case personInImage, event, organisationInImage, sublocation, worldRegion, provinceState
    case modelReleaseStatus, propertyReleaseStatus, digitalSourceType, additionalModelInfo
}

/// XMP 命名空间与属性映射。
public struct XMPFieldDescriptor: Equatable, Sendable {
    public let field: DescriptiveField
    public let prefix: String
    public let namespace: String
    /// 限定名（含前缀），如 dc:title。
    public let qname: String
    public let shape: XMPValueShape

    public init(_ field: DescriptiveField, _ prefix: String, _ namespace: String, _ name: String, _ shape: XMPValueShape) {
        self.field = field
        self.prefix = prefix
        self.namespace = namespace
        self.qname = prefix + ":" + name
        self.shape = shape
    }

    public var isList: Bool { shape == .bag || shape == .seq }
}

public enum XMPNamespaces {
    public static let dc = "http://purl.org/dc/elements/1.1/"
    public static let xmp = "http://ns.adobe.com/xap/1.0/"
    public static let xmpRights = "http://ns.adobe.com/xap/1.0/rights/"
    public static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
    public static let iptcCore = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
    public static let iptcExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
    public static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    /// P1 / E：triage 可移植信号的私有命名空间（与 TriageWritebackPlanner 同源）。
    public static let gatherTriage = "https://gather.app/ns/triage/1.0/"
}

/// Iptc4xmpCore:CreatorContactInfo 的 8 个成员。
public struct DescriptiveContact: Codable, Equatable, Sendable {
    public var city: String?
    public var country: String?
    public var address: String?
    public var postalCode: String?
    public var region: String?
    public var email: String?
    public var telephone: String?
    public var url: String?

    public init(
        city: String? = nil, country: String? = nil, address: String? = nil,
        postalCode: String? = nil, region: String? = nil, email: String? = nil,
        telephone: String? = nil, url: String? = nil
    ) {
        self.city = city
        self.country = country
        self.address = address
        self.postalCode = postalCode
        self.region = region
        self.email = email
        self.telephone = telephone
        self.url = url
    }

    /// 结构成员表（读取器按 qname 收集，写入器按 qname 序列化）。
    public static let members: [(key: String, qname: String)] = [
        ("city", "Iptc4xmpCore:CiAdrCity"),
        ("country", "Iptc4xmpCore:CiAdrCtry"),
        ("address", "Iptc4xmpCore:CiAdrExtadr"),
        ("postalCode", "Iptc4xmpCore:CiAdrPcode"),
        ("region", "Iptc4xmpCore:CiAdrRegion"),
        ("email", "Iptc4xmpCore:CiEmailWork"),
        ("telephone", "Iptc4xmpCore:CiTelWork"),
        ("url", "Iptc4xmpCore:CiUrlWork"),
    ]

    public var isEmpty: Bool {
        city == nil && country == nil && address == nil && postalCode == nil
            && region == nil && email == nil && telephone == nil && url == nil
    }

    /// 成员级合并：只覆盖 other 中非 nil 的成员。
    /// 模板里的部分联系方式不得把盘上未填的成员整块删掉。
    public func merging(_ other: DescriptiveContact) -> DescriptiveContact {
        var result = self
        if let value = other.city { result.city = value }
        if let value = other.country { result.country = value }
        if let value = other.address { result.address = value }
        if let value = other.postalCode { result.postalCode = value }
        if let value = other.region { result.region = value }
        if let value = other.email { result.email = value }
        if let value = other.telephone { result.telephone = value }
        if let value = other.url { result.url = value }
        return result
    }
}

public extension XMPFieldDescriptor {
    /// 全部 32 个字段的映射，顺序即 UI 展示顺序。
    static let all: [XMPFieldDescriptor] = [
        .init(.title, "dc", XMPNamespaces.dc, "title", .alt),
        .init(.caption, "dc", XMPNamespaces.dc, "description", .alt),
        .init(.creator, "dc", XMPNamespaces.dc, "creator", .seq),
        .init(.creatorJobTitle, "photoshop", XMPNamespaces.photoshop, "AuthorsPosition", .text),
        .init(.credit, "photoshop", XMPNamespaces.photoshop, "Credit", .text),
        .init(.source, "photoshop", XMPNamespaces.photoshop, "Source", .text),
        .init(.copyrightNotice, "dc", XMPNamespaces.dc, "rights", .alt),
        .init(.usageTerms, "xmpRights", XMPNamespaces.xmpRights, "UsageTerms", .alt),
        .init(.webStatement, "xmpRights", XMPNamespaces.xmpRights, "WebStatement", .text),
        .init(.headline, "photoshop", XMPNamespaces.photoshop, "Headline", .text),
        .init(.captionWriter, "photoshop", XMPNamespaces.photoshop, "CaptionWriter", .text),
        .init(.jobIdentifier, "photoshop", XMPNamespaces.photoshop, "TransmissionReference", .text),
        .init(.subjectCode, "Iptc4xmpCore", XMPNamespaces.iptcCore, "SubjectCode", .bag),
        .init(.scene, "Iptc4xmpCore", XMPNamespaces.iptcCore, "Scene", .bag),
        .init(.intellectualGenre, "Iptc4xmpCore", XMPNamespaces.iptcCore, "IntellectualGenre", .text),
        .init(.location, "Iptc4xmpCore", XMPNamespaces.iptcCore, "Location", .text),
        .init(.city, "photoshop", XMPNamespaces.photoshop, "City", .text),
        .init(.state, "photoshop", XMPNamespaces.photoshop, "State", .text),
        .init(.country, "photoshop", XMPNamespaces.photoshop, "Country", .text),
        .init(.countryCode, "Iptc4xmpCore", XMPNamespaces.iptcCore, "CountryCode", .text),
        .init(.dateCreated, "photoshop", XMPNamespaces.photoshop, "DateCreated", .text),
        .init(.contactInfo, "Iptc4xmpCore", XMPNamespaces.iptcCore, "CreatorContactInfo", .structure),
        .init(.personInImage, "Iptc4xmpExt", XMPNamespaces.iptcExt, "PersonInImage", .bag),
        .init(.event, "Iptc4xmpExt", XMPNamespaces.iptcExt, "Event", .alt),
        .init(.organisationInImage, "Iptc4xmpExt", XMPNamespaces.iptcExt, "OrganisationInImageName", .bag),
        .init(.sublocation, "Iptc4xmpExt", XMPNamespaces.iptcExt, "Sublocation", .text),
        .init(.worldRegion, "Iptc4xmpExt", XMPNamespaces.iptcExt, "WorldRegion", .text),
        .init(.provinceState, "Iptc4xmpExt", XMPNamespaces.iptcExt, "ProvinceState", .text),
        .init(.modelReleaseStatus, "Iptc4xmpExt", XMPNamespaces.iptcExt, "ModelReleaseStatus", .text),
        .init(.propertyReleaseStatus, "Iptc4xmpExt", XMPNamespaces.iptcExt, "PropertyReleaseStatus", .text),
        .init(.digitalSourceType, "Iptc4xmpExt", XMPNamespaces.iptcExt, "DigitalSourceType", .text),
        .init(.additionalModelInfo, "Iptc4xmpExt", XMPNamespaces.iptcExt, "AddlModelInfo", .text),
    ]

    static let byField: [DescriptiveField: XMPFieldDescriptor] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.field, $0) }
    )

    /// 按字段查描述符（值形状判断不属于 UI/服务层的知识）。
    public static func descriptor(for field: DescriptiveField) -> XMPFieldDescriptor? {
        byField[field]
    }
}

/// 模板批量套用时的冲突处置：默认保留外部改动。
/// 放在 Protocol：API 输入（MetadataTemplatePreviewInput/ApplyInput）要用它。
public enum MetadataConflictPolicy: String, Codable, CaseIterable, Sendable {
    case keepExternal
    case overwrite
}

/// 字段值的通用载体：补丁器/读取器/模板都只认这三种形态。
public enum XMPFieldValue: Equatable, Sendable {
    case text(String)
    case list([String])
    case contact(DescriptiveContact)

    public var isEmptyValue: Bool {
        switch self {
        case .text(let value): return value.isEmpty
        case .list(let values): return values.isEmpty
        case .contact(let value): return value.isEmpty
        }
    }
}

// MARK: - 容器

/// IPTC Core + Extension 的描述性元数据容器。
///
/// 三态语义（模板/批量写回的基石）：
/// - nil 表示不触碰该字段（模板里"未勾选"）；
/// - 空串/空数组表示显式清空（模板里"勾选且留空"）；
/// - 有值表示写入。
public struct DescriptiveMetadata: Codable, Equatable, Sendable {
    // IPTC Core
    public var title: String?
    public var caption: String?
    public var creator: [String]?
    public var creatorJobTitle: String?
    public var credit: String?
    public var source: String?
    public var copyrightNotice: String?
    public var usageTerms: String?
    public var webStatement: String?
    public var headline: String?
    public var captionWriter: String?
    public var jobIdentifier: String?
    public var subjectCode: [String]?
    public var scene: [String]?
    public var intellectualGenre: String?
    public var location: String?
    public var city: String?
    public var state: String?
    public var country: String?
    public var countryCode: String?
    public var dateCreated: String?
    public var contactInfo: DescriptiveContact?
    // IPTC Extension
    public var personInImage: [String]?
    public var event: String?
    public var organisationInImage: [String]?
    public var sublocation: String?
    public var worldRegion: String?
    public var provinceState: String?
    public var modelReleaseStatus: String?
    public var propertyReleaseStatus: String?
    public var digitalSourceType: String?
    public var additionalModelInfo: String?

    public init(
        title: String? = nil, caption: String? = nil, creator: [String]? = nil,
        creatorJobTitle: String? = nil, credit: String? = nil, source: String? = nil,
        copyrightNotice: String? = nil, usageTerms: String? = nil, webStatement: String? = nil,
        headline: String? = nil, captionWriter: String? = nil, jobIdentifier: String? = nil,
        subjectCode: [String]? = nil, scene: [String]? = nil, intellectualGenre: String? = nil,
        location: String? = nil, city: String? = nil, state: String? = nil,
        country: String? = nil, countryCode: String? = nil, dateCreated: String? = nil,
        contactInfo: DescriptiveContact? = nil, personInImage: [String]? = nil,
        event: String? = nil, organisationInImage: [String]? = nil,
        sublocation: String? = nil, worldRegion: String? = nil, provinceState: String? = nil,
        modelReleaseStatus: String? = nil, propertyReleaseStatus: String? = nil,
        digitalSourceType: String? = nil, additionalModelInfo: String? = nil
    ) {
        self.title = title
        self.caption = caption
        self.creator = creator
        self.creatorJobTitle = creatorJobTitle
        self.credit = credit
        self.source = source
        self.copyrightNotice = copyrightNotice
        self.usageTerms = usageTerms
        self.webStatement = webStatement
        self.headline = headline
        self.captionWriter = captionWriter
        self.jobIdentifier = jobIdentifier
        self.subjectCode = subjectCode
        self.scene = scene
        self.intellectualGenre = intellectualGenre
        self.location = location
        self.city = city
        self.state = state
        self.country = country
        self.countryCode = countryCode
        self.dateCreated = dateCreated
        self.contactInfo = contactInfo
        self.personInImage = personInImage
        self.event = event
        self.organisationInImage = organisationInImage
        self.sublocation = sublocation
        self.worldRegion = worldRegion
        self.provinceState = provinceState
        self.modelReleaseStatus = modelReleaseStatus
        self.propertyReleaseStatus = propertyReleaseStatus
        self.digitalSourceType = digitalSourceType
        self.additionalModelInfo = additionalModelInfo
    }

    /// 全部字段为 nil 即"无操作"。
    public var isEmpty: Bool { nonNilFieldCount == 0 }

    /// 有值（非 nil）的字段数；用于 UI「N 个字段已填」。
    public var nonNilFieldCount: Int {
        DescriptiveField.allCases.reduce(0) { count, field in
            count + (value(for: field) == nil ? 0 : 1)
        }
    }

    /// 读字段：nil 表示"该字段未被设置"（与"被清空"区分）。
    public func value(for field: DescriptiveField) -> XMPFieldValue? {
        switch field {
        case .title: return title.map(XMPFieldValue.text)
        case .caption: return caption.map(XMPFieldValue.text)
        case .creator: return creator.map(XMPFieldValue.list)
        case .creatorJobTitle: return creatorJobTitle.map(XMPFieldValue.text)
        case .credit: return credit.map(XMPFieldValue.text)
        case .source: return source.map(XMPFieldValue.text)
        case .copyrightNotice: return copyrightNotice.map(XMPFieldValue.text)
        case .usageTerms: return usageTerms.map(XMPFieldValue.text)
        case .webStatement: return webStatement.map(XMPFieldValue.text)
        case .headline: return headline.map(XMPFieldValue.text)
        case .captionWriter: return captionWriter.map(XMPFieldValue.text)
        case .jobIdentifier: return jobIdentifier.map(XMPFieldValue.text)
        case .subjectCode: return subjectCode.map(XMPFieldValue.list)
        case .scene: return scene.map(XMPFieldValue.list)
        case .intellectualGenre: return intellectualGenre.map(XMPFieldValue.text)
        case .location: return location.map(XMPFieldValue.text)
        case .city: return city.map(XMPFieldValue.text)
        case .state: return state.map(XMPFieldValue.text)
        case .country: return country.map(XMPFieldValue.text)
        case .countryCode: return countryCode.map(XMPFieldValue.text)
        case .dateCreated: return dateCreated.map(XMPFieldValue.text)
        case .contactInfo: return contactInfo.map(XMPFieldValue.contact)
        case .personInImage: return personInImage.map(XMPFieldValue.list)
        case .event: return event.map(XMPFieldValue.text)
        case .organisationInImage: return organisationInImage.map(XMPFieldValue.list)
        case .sublocation: return sublocation.map(XMPFieldValue.text)
        case .worldRegion: return worldRegion.map(XMPFieldValue.text)
        case .provinceState: return provinceState.map(XMPFieldValue.text)
        case .modelReleaseStatus: return modelReleaseStatus.map(XMPFieldValue.text)
        case .propertyReleaseStatus: return propertyReleaseStatus.map(XMPFieldValue.text)
        case .digitalSourceType: return digitalSourceType.map(XMPFieldValue.text)
        case .additionalModelInfo: return additionalModelInfo.map(XMPFieldValue.text)
        }
    }

    /// 写字段：nil = 清空该字段（回到"未设置"）。
    public mutating func set(_ value: XMPFieldValue?, for field: DescriptiveField) {
        let text: String? = {
            switch value {
            case .text(let value): return value
            case .list(let values): return values.first ?? ""
            case .contact, .none: return nil
            }
        }()
        let list: [String]? = {
            switch value {
            case .list(let values): return values
            case .text(let value): return value.isEmpty ? [] : [value]
            case .contact, .none: return nil
            }
        }()
        switch field {
        case .title: title = text
        case .caption: caption = text
        case .creator: creator = list
        case .creatorJobTitle: creatorJobTitle = text
        case .credit: credit = text
        case .source: source = text
        case .copyrightNotice: copyrightNotice = text
        case .usageTerms: usageTerms = text
        case .webStatement: webStatement = text
        case .headline: headline = text
        case .captionWriter: captionWriter = text
        case .jobIdentifier: jobIdentifier = text
        case .subjectCode: subjectCode = list
        case .scene: scene = list
        case .intellectualGenre: intellectualGenre = text
        case .location: location = text
        case .city: city = text
        case .state: state = text
        case .country: country = text
        case .countryCode: countryCode = text
        case .dateCreated: dateCreated = text
        case .contactInfo:
            // 显式清空必须留下"非 nil 的空结构"：nil 表示不触碰，空结构才能
            // 让补丁器删除元素（见 clear(_:)）。
            if case .contact(let contact) = value { contactInfo = contact } else { contactInfo = nil }
        case .personInImage: personInImage = list
        case .event: event = text
        case .organisationInImage: organisationInImage = list
        case .sublocation: sublocation = text
        case .worldRegion: worldRegion = text
        case .provinceState: provinceState = text
        case .modelReleaseStatus: modelReleaseStatus = text
        case .propertyReleaseStatus: propertyReleaseStatus = text
        case .digitalSourceType: digitalSourceType = text
        case .additionalModelInfo: additionalModelInfo = text
        }
    }

    /// 合并：other 的非 nil 字段覆盖 self（模板应用语义）。
    public func applying(_ other: DescriptiveMetadata) -> DescriptiveMetadata {
        var merged = self
        for field in DescriptiveField.allCases {
            guard let value = other.value(for: field) else { continue }
            if field == .contactInfo, case .contact(let incoming) = value {
                // 结构字段：空结构 = 显式清空；否则成员级合并（部分模板不删其它成员）。
                if incoming.isEmpty {
                    merged.contactInfo = DescriptiveContact()
                } else {
                    merged.contactInfo = (merged.contactInfo ?? DescriptiveContact()).merging(incoming)
                }
                continue
            }
            merged.set(value, for: field)
        }
        return merged
    }

    /// 被显式设置的字段（模板预览用）。
    public var explicitlySetFields: [DescriptiveField] {
        DescriptiveField.allCases.filter { value(for: $0) != nil }
    }

    /// 显式清空一个字段：按值形状写入"空值"，保证 value(for:) 非 nil
    /// （写入器据此删除元素；nil 会被理解成"不触碰"）。
    public mutating func clear(_ field: DescriptiveField) {
        let shape = XMPFieldDescriptor.descriptor(for: field)?.shape ?? .text
        switch shape {
        case .structure:
            set(.contact(DescriptiveContact()), for: field)
        case .bag, .seq:
            set(.list([]), for: field)
        case .text, .alt:
            set(.text(""), for: field)
        }
    }
}

// MARK: - JSONValue 往返

public extension JSONValue {
    /// 任意 Encodable -> JSONValue（经 JSONEncoder 一次往返）。
    init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// JSONValue -> 任意 Decodable。
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}
