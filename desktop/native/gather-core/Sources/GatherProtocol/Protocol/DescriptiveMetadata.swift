// desktop/native/gather-core/Sources/GatherProtocol/Protocol/DescriptiveMetadata.swift
// P1 / IPTC：描述性元数据（IPTC Core + IPTC Extension）的纯值契约与 XMP 字段表。
//
// 设计边界：
// - 本文件只描述"字段是什么、写到哪个命名空间、用哪种 RDF 形状"，不含任何 XML。
//   XMP 的实际读写由宿主（gather-app/SidecarXMPProvider）按本表驱动。
// - 字段三态必须可区分：nil = 不触碰；空串/空数组 = 显式清空；有值 = 写入。
//   模板批量应用与冲突检测都依赖这一区分。
// - 覆盖：IPTC Core 23 项（含 Contact Info 结构）+ IPTC Extension 13 项 = 36 项。
//   Wave5（batch2）新增交付高频字段：Instructions（Core）、Event Identifier、
//   Model Release Id、Property Release Id（Extension）。
//   未纳入：ArtworkOrObject 结构数组、Accessibility、Image Creator（后者在标准
//   2025.1 里是 plus:ImageCreator 结构值，本波只做文本字段，暂缓；见 40 册 §2）。
// - 受控值表见文件末 IPTCControlledVocabulary（countryCode / scene / subjectCode /
//   digitalSourceType）；modelReleaseStatus / propertyReleaseStatus 的 PLUS 受控值
//   本波未核实，不加表也不校验。

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
    /// Wave5（batch2）：IPTC Core Instructions（IIM 2:40 / photoshop:Instructions）。
    case instructions
    case subjectCode, scene, intellectualGenre, location
    case city, state, country, countryCode, dateCreated, contactInfo
    // IPTC Extension
    case personInImage, event
    /// Wave5（batch2）：IPTC Ext Event Identifier（Iptc4xmpExt:EventId，multi → Bag）。
    case eventIdentifier
    case organisationInImage, sublocation, worldRegion, provinceState
    case modelReleaseStatus
    /// Wave5（batch2）：IPTC Ext Model Release Id（plus:ModelReleaseID，multi → Bag）。
    case modelReleaseID
    case propertyReleaseStatus
    /// Wave5（batch2）：IPTC Ext Property Release Id（plus:PropertyReleaseID，multi → Bag）。
    case propertyReleaseID
    case digitalSourceType, additionalModelInfo
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
    /// Wave5（batch2）：PLUS LDF XMP 命名空间。IPTC 2025.1 技术参考里
    /// Model Release Id / Property Release Id 的 XMP 属性都在 plus:（plus:ModelReleaseID
    /// / plus:PropertyReleaseID），不在 Iptc4xmpExt。
    public static let plus = "http://ns.useplus.org/ldf/xmp/1.0/"
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

    /// 按成员 key（city/country/…）读值；未知 key 返回 nil。
    public func memberValue(_ key: String) -> String? {
        switch key {
        case "city": return city
        case "country": return country
        case "address": return address
        case "postalCode": return postalCode
        case "region": return region
        case "email": return email
        case "telephone": return telephone
        case "url": return url
        default: return nil
        }
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
    /// 全部 36 个字段的映射（顺序 = 写入/模板遍历顺序；面板分组见 MetadataDisplay）。
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
        // Wave5（batch2）：IPTC 2025.1 技术参考 XMPid=photoshop:Instructions（IIM 2:40）。
        .init(.instructions, "photoshop", XMPNamespaces.photoshop, "Instructions", .text),
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
        // Wave5（batch2）：XMPid=Iptc4xmpExt:EventId，datatype string + occurrence multi → Bag。
        .init(.eventIdentifier, "Iptc4xmpExt", XMPNamespaces.iptcExt, "EventId", .bag),
        .init(.organisationInImage, "Iptc4xmpExt", XMPNamespaces.iptcExt, "OrganisationInImageName", .bag),
        .init(.sublocation, "Iptc4xmpExt", XMPNamespaces.iptcExt, "Sublocation", .text),
        .init(.worldRegion, "Iptc4xmpExt", XMPNamespaces.iptcExt, "WorldRegion", .text),
        .init(.provinceState, "Iptc4xmpExt", XMPNamespaces.iptcExt, "ProvinceState", .text),
        .init(.modelReleaseStatus, "Iptc4xmpExt", XMPNamespaces.iptcExt, "ModelReleaseStatus", .text),
        // Wave5（batch2）：标准 2025.1 的 XMPid 是 plus:ModelReleaseID（string + multi → Bag），
        // 与 repo 既有 release **Status** 的 Iptc4xmpExt 命名空间不同（既有 status 的
        // qname 与标准不一致，属存量问题，见回执待裁决项，本波不改存量字段）。
        .init(.modelReleaseID, "plus", XMPNamespaces.plus, "ModelReleaseID", .bag),
        .init(.propertyReleaseStatus, "Iptc4xmpExt", XMPNamespaces.iptcExt, "PropertyReleaseStatus", .text),
        .init(.propertyReleaseID, "plus", XMPNamespaces.plus, "PropertyReleaseID", .bag),
        .init(.digitalSourceType, "Iptc4xmpExt", XMPNamespaces.iptcExt, "DigitalSourceType", .text),
        .init(.additionalModelInfo, "Iptc4xmpExt", XMPNamespaces.iptcExt, "AddlModelInfo", .text),
        // 注记（Wave5 batch2）：上面 4 个新字段尚未进入
        // MetadataAttributes.embeddedDescriptiveFields（该文件不在本波写作用域）。
        // 后果：JPEG 内嵌元数据（无 .xmp sidecar）的写入会在写后校验时读不到这些字段
        // 而失败回滚；RAW / sidecar 路径不受影响。下一批补齐该表 + IPTCIIM 的
        // 2:40（Instructions）映射后，本条注记应删除（详见 40 册 §2 与回执）。
    ]

    static let byField: [DescriptiveField: XMPFieldDescriptor] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.field, $0) }
    )

    /// 按字段查描述符（值形状判断不属于 UI/服务层的知识）。
    static func descriptor(for field: DescriptiveField) -> XMPFieldDescriptor? {
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
    /// Wave5（batch2）：使用说明（禁发令/限制/复现要求）。
    public var instructions: String?
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
    /// Wave5（batch2）：事件标识（可多个）。
    public var eventIdentifier: [String]?
    public var organisationInImage: [String]?
    public var sublocation: String?
    public var worldRegion: String?
    public var provinceState: String?
    public var modelReleaseStatus: String?
    /// Wave5（batch2）：肖像权释放编号（可多个）。
    public var modelReleaseID: [String]?
    public var propertyReleaseStatus: String?
    /// Wave5（batch2）：物权释放编号（可多个）。
    public var propertyReleaseID: [String]?
    public var digitalSourceType: String?
    public var additionalModelInfo: String?

    public init(
        title: String? = nil, caption: String? = nil, creator: [String]? = nil,
        creatorJobTitle: String? = nil, credit: String? = nil, source: String? = nil,
        copyrightNotice: String? = nil, usageTerms: String? = nil, webStatement: String? = nil,
        headline: String? = nil, captionWriter: String? = nil, jobIdentifier: String? = nil,
        instructions: String? = nil,
        subjectCode: [String]? = nil, scene: [String]? = nil, intellectualGenre: String? = nil,
        location: String? = nil, city: String? = nil, state: String? = nil,
        country: String? = nil, countryCode: String? = nil, dateCreated: String? = nil,
        contactInfo: DescriptiveContact? = nil, personInImage: [String]? = nil,
        event: String? = nil, eventIdentifier: [String]? = nil,
        organisationInImage: [String]? = nil,
        sublocation: String? = nil, worldRegion: String? = nil, provinceState: String? = nil,
        modelReleaseStatus: String? = nil, modelReleaseID: [String]? = nil,
        propertyReleaseStatus: String? = nil, propertyReleaseID: [String]? = nil,
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
        self.instructions = instructions
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
        self.eventIdentifier = eventIdentifier
        self.organisationInImage = organisationInImage
        self.sublocation = sublocation
        self.worldRegion = worldRegion
        self.provinceState = provinceState
        self.modelReleaseStatus = modelReleaseStatus
        self.modelReleaseID = modelReleaseID
        self.propertyReleaseStatus = propertyReleaseStatus
        self.propertyReleaseID = propertyReleaseID
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
        case .instructions: return instructions.map(XMPFieldValue.text)
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
        case .eventIdentifier: return eventIdentifier.map(XMPFieldValue.list)
        case .organisationInImage: return organisationInImage.map(XMPFieldValue.list)
        case .sublocation: return sublocation.map(XMPFieldValue.text)
        case .worldRegion: return worldRegion.map(XMPFieldValue.text)
        case .provinceState: return provinceState.map(XMPFieldValue.text)
        case .modelReleaseStatus: return modelReleaseStatus.map(XMPFieldValue.text)
        case .modelReleaseID: return modelReleaseID.map(XMPFieldValue.list)
        case .propertyReleaseStatus: return propertyReleaseStatus.map(XMPFieldValue.text)
        case .propertyReleaseID: return propertyReleaseID.map(XMPFieldValue.list)
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
        case .instructions: instructions = text
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
        case .eventIdentifier: eventIdentifier = list
        case .organisationInImage: organisationInImage = list
        case .sublocation: sublocation = text
        case .worldRegion: worldRegion = text
        case .provinceState: provinceState = text
        case .modelReleaseStatus: modelReleaseStatus = text
        case .modelReleaseID: modelReleaseID = list
        case .propertyReleaseStatus: propertyReleaseStatus = text
        case .propertyReleaseID: propertyReleaseID = list
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

// MARK: - 受控值（Wave5 batch2）

/// IPTC 受控值（controlled vocabulary）：常量表 + 归一化 + 写入前校验。
///
/// 只收**可核实**的四张表（数据来源：IPTC NewsCodes CV 服务与 IPTC Photo Metadata
/// 2025.1 技术参考，2026-11 抓取）：
/// - countryCode：ISO 3166-1 alpha-2 常用集（标准允许 2/3 字母，本表只收 2 字母；
///   三字母代码不在此表，写入会被判为"词表外"，需要时再补）；
/// - scene：IPTC Scene NewsCodes 全部 24 个（6 位数字码，写码不写英文名）；
/// - subjectCode：IPTC Subject Code NewsCodes **顶层 17 类**（8 位数字码）。该词表
///   已被 IPTC 标记为 legacy（改用 Media Topic），本表只做顶层，够目前 UI 用；
/// - digitalSourceType：IPTC Digital Source Type NewsCodes 18 个在用概念，值是
///   **完整 URI**（例如 http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture）。
///
/// 不做表 / 不校验：modelReleaseStatus、propertyReleaseStatus —— 它们的值是PLUS
/// 受控值（dataformat uri），PLUS CV 站点当前返回 500/XSL 错误，无法核实取值集合；
/// 为避免把合法值判成非法（或写错值），本波只保留自由文本，待拿到官方词表再补。
public enum IPTCControlledVocabulary {
    /// 一个受控值选项：value 落盘（与 XMP 里写的字符串完全一致），label 中文展示。
    /// Identifiable 的 id 就是 value：Picker 的 tag 与身份一致，避免重复值。
    public struct Option: Equatable, Sendable, Identifiable {
        public let value: String
        public let label: String
        public var id: String { value }
        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    /// 受控值字段 → 词表；nil = 自由文本字段（不做选择器也不做校验）。
    public static func options(for field: DescriptiveField) -> [Option]? {
        switch field {
        case .countryCode: return countryCodes
        case .scene: return sceneCodes
        case .subjectCode: return subjectCodes
        case .digitalSourceType: return digitalSourceTypes
        default: return nil
        }
    }

    /// 是否受控值字段（UI 决定渲染 Picker 还是 TextField）。
    public static func isControlled(_ field: DescriptiveField) -> Bool {
        options(for: field) != nil
    }

    /// 写入前归一化：countryCode 统一大写（标准要求字母码，手打 "cn" 不应写成小写）；
    /// 其余只 trim。非受控值字段原样返回（保持既有写入行为）。
    public static func normalized(_ raw: String, for field: DescriptiveField) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isControlled(field) else { return trimmed }
        switch field {
        case .countryCode: return trimmed.uppercased()
        default: return trimmed
        }
    }

    /// 校验：非空时必须在词表内（调用方负责先归一化；空串 = 清空，合法）。
    /// 同义词/别名不做映射：Scene/SubjectCode 是数字码、DigitalSourceType 是 CV URI，
    /// 写别名会被外部工具判成非法值。
    public static func isValid(_ raw: String, for field: DescriptiveField) -> Bool {
        guard let table = options(for: field) else { return true }
        let candidate = normalized(raw, for: field)
        guard !candidate.isEmpty else { return true }
        return table.contains { $0.value == candidate }
    }

    // MARK: 表（顺序即 UI 展示顺序）

    /// ISO 3166-1 alpha-2 常用集（按中文名排序，常用国家在前）。
    public static let countryCodes: [Option] = [
        Option(value: "CN", label: "CN 中国"),
        Option(value: "HK", label: "HK 中国香港"),
        Option(value: "MO", label: "MO 中国澳门"),
        Option(value: "TW", label: "TW 中国台湾"),
        Option(value: "JP", label: "JP 日本"),
        Option(value: "KR", label: "KR 韩国"),
        Option(value: "SG", label: "SG 新加坡"),
        Option(value: "MY", label: "MY 马来西亚"),
        Option(value: "TH", label: "TH 泰国"),
        Option(value: "VN", label: "VN 越南"),
        Option(value: "ID", label: "ID 印度尼西亚"),
        Option(value: "PH", label: "PH 菲律宾"),
        Option(value: "IN", label: "IN 印度"),
        Option(value: "PK", label: "PK 巴基斯坦"),
        Option(value: "BD", label: "BD 孟加拉国"),
        Option(value: "LK", label: "LK 斯里兰卡"),
        Option(value: "NP", label: "NP 尼泊尔"),
        Option(value: "MN", label: "MN 蒙古"),
        Option(value: "KZ", label: "KZ 哈萨克斯坦"),
        Option(value: "UZ", label: "UZ 乌兹别克斯坦"),
        Option(value: "AE", label: "AE 阿联酋"),
        Option(value: "SA", label: "SA 沙特阿拉伯"),
        Option(value: "QA", label: "QA 卡塔尔"),
        Option(value: "KW", label: "KW 科威特"),
        Option(value: "BH", label: "BH 巴林"),
        Option(value: "OM", label: "OM 阿曼"),
        Option(value: "IL", label: "IL 以色列"),
        Option(value: "JO", label: "JO 约旦"),
        Option(value: "LB", label: "LB 黎巴嫩"),
        Option(value: "SY", label: "SY 叙利亚"),
        Option(value: "TR", label: "TR 土耳其"),
        Option(value: "IR", label: "IR 伊朗"),
        Option(value: "IQ", label: "IQ 伊拉克"),
        Option(value: "AF", label: "AF 阿富汗"),
        Option(value: "RU", label: "RU 俄罗斯"),
        Option(value: "UA", label: "UA 乌克兰"),
        Option(value: "BY", label: "BY 白俄罗斯"),
        Option(value: "GE", label: "GE 格鲁吉亚"),
        Option(value: "AM", label: "AM 亚美尼亚"),
        Option(value: "AZ", label: "AZ 阿塞拜疆"),
        Option(value: "PL", label: "PL 波兰"),
        Option(value: "CZ", label: "CZ 捷克"),
        Option(value: "SK", label: "SK 斯洛伐克"),
        Option(value: "HU", label: "HU 匈牙利"),
        Option(value: "RO", label: "RO 罗马尼亚"),
        Option(value: "BG", label: "BG 保加利亚"),
        Option(value: "GR", label: "GR 希腊"),
        Option(value: "CY", label: "CY 塞浦路斯"),
        Option(value: "IT", label: "IT 意大利"),
        Option(value: "ES", label: "ES 西班牙"),
        Option(value: "PT", label: "PT 葡萄牙"),
        Option(value: "FR", label: "FR 法国"),
        Option(value: "DE", label: "DE 德国"),
        Option(value: "AT", label: "AT 奥地利"),
        Option(value: "CH", label: "CH 瑞士"),
        Option(value: "NL", label: "NL 荷兰"),
        Option(value: "BE", label: "BE 比利时"),
        Option(value: "LU", label: "LU 卢森堡"),
        Option(value: "DK", label: "DK 丹麦"),
        Option(value: "SE", label: "SE 瑞典"),
        Option(value: "NO", label: "NO 挪威"),
        Option(value: "FI", label: "FI 芬兰"),
        Option(value: "IS", label: "IS 冰岛"),
        Option(value: "IE", label: "IE 爱尔兰"),
        Option(value: "GB", label: "GB 英国"),
        Option(value: "EE", label: "EE 爱沙尼亚"),
        Option(value: "LV", label: "LV 拉脱维亚"),
        Option(value: "LT", label: "LT 立陶宛"),
        Option(value: "SI", label: "SI 斯洛文尼亚"),
        Option(value: "HR", label: "HR 克罗地亚"),
        Option(value: "RS", label: "RS 塞尔维亚"),
        Option(value: "EG", label: "EG 埃及"),
        Option(value: "MA", label: "MA 摩洛哥"),
        Option(value: "TN", label: "TN 突尼斯"),
        Option(value: "DZ", label: "DZ 阿尔及利亚"),
        Option(value: "ZA", label: "ZA 南非"),
        Option(value: "KE", label: "KE 肯尼亚"),
        Option(value: "NG", label: "NG 尼日利亚"),
        Option(value: "TZ", label: "TZ 坦桑尼亚"),
        Option(value: "ET", label: "ET 埃塞俄比亚"),
        Option(value: "GH", label: "GH 加纳"),
        Option(value: "US", label: "US 美国"),
        Option(value: "CA", label: "CA 加拿大"),
        Option(value: "MX", label: "MX 墨西哥"),
        Option(value: "CU", label: "CU 古巴"),
        Option(value: "DO", label: "DO 多米尼加"),
        Option(value: "GT", label: "GT 危地马拉"),
        Option(value: "CR", label: "CR 哥斯达黎加"),
        Option(value: "PA", label: "PA 巴拿马"),
        Option(value: "BR", label: "BR 巴西"),
        Option(value: "AR", label: "AR 阿根廷"),
        Option(value: "CL", label: "CL 智利"),
        Option(value: "PE", label: "PE 秘鲁"),
        Option(value: "CO", label: "CO 哥伦比亚"),
        Option(value: "VE", label: "VE 委内瑞拉"),
        Option(value: "EC", label: "EC 厄瓜多尔"),
        Option(value: "UY", label: "UY 乌拉圭"),
        Option(value: "BO", label: "BO 玻利维亚"),
        Option(value: "PY", label: "PY 巴拉圭"),
        Option(value: "AU", label: "AU 澳大利亚"),
        Option(value: "NZ", label: "NZ 新西兰"),
        Option(value: "FJ", label: "FJ 斐济"),
        Option(value: "PG", label: "PG 巴布亚新几内亚"),
    ]

    /// IPTC Scene NewsCodes（scn:010100…scn:012400）：落盘只写 6 位数字码。
    public static let sceneCodes: [Option] = [
        Option(value: "010100", label: "010100 头像特写"),
        Option(value: "010200", label: "010200 半身"),
        Option(value: "010300", label: "010300 全身"),
        Option(value: "010400", label: "010400 侧面"),
        Option(value: "010500", label: "010500 背面"),
        Option(value: "010600", label: "010600 单人"),
        Option(value: "010700", label: "010700 双人"),
        Option(value: "010800", label: "010800 两人"),
        Option(value: "010900", label: "010900 群像"),
        Option(value: "011000", label: "011000 全景概览"),
        Option(value: "011100", label: "011100 全景"),
        Option(value: "011200", label: "011200 航拍"),
        Option(value: "011300", label: "011300 水下"),
        Option(value: "011400", label: "011400 夜景"),
        Option(value: "011500", label: "011500 卫星影像"),
        Option(value: "011600", label: "011600 外景"),
        Option(value: "011700", label: "011700 内景"),
        Option(value: "011800", label: "011800 特写"),
        Option(value: "011900", label: "011900 动作"),
        Option(value: "012000", label: "012000 表演"),
        Option(value: "012100", label: "012100 摆拍"),
        Option(value: "012200", label: "012200 象征"),
        Option(value: "012300", label: "012300 趣味"),
        Option(value: "012400", label: "012400 电影场景"),
    ]

    /// IPTC Subject Code NewsCodes 顶层 17 类（8 位数字码；该词表 IPTC 已标 legacy）。
    public static let subjectCodes: [Option] = [
        Option(value: "01000000", label: "01000000 艺术、文化与娱乐"),
        Option(value: "02000000", label: "02000000 犯罪、法律与司法"),
        Option(value: "03000000", label: "03000000 灾难与事故"),
        Option(value: "04000000", label: "04000000 经济、商业与金融"),
        Option(value: "05000000", label: "05000000 教育"),
        Option(value: "06000000", label: "06000000 环境议题"),
        Option(value: "07000000", label: "07000000 健康"),
        Option(value: "08000000", label: "08000000 人情味"),
        Option(value: "09000000", label: "09000000 劳动"),
        Option(value: "10000000", label: "10000000 生活方式与休闲"),
        Option(value: "11000000", label: "11000000 政治"),
        Option(value: "12000000", label: "12000000 宗教与信仰"),
        Option(value: "13000000", label: "13000000 科学与技术"),
        Option(value: "14000000", label: "14000000 社会议题"),
        Option(value: "15000000", label: "15000000 体育"),
        Option(value: "16000000", label: "16000000 冲突与战争"),
        Option(value: "17000000", label: "17000000 天气"),
    ]

    /// IPTC Digital Source Type NewsCodes（在用 18 项；值是 CV 概念的完整 URI）。
    public static let digitalSourceTypes: [Option] = [
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture",
               label: "数字拍摄（真实场景）"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/computationalCapture",
               label: "计算拍摄（多帧合成）"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/negativeFilm",
               label: "胶片负片扫描"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/positiveFilm",
               label: "胶片正片扫描"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/print",
               label: "印刷品扫描"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/minorHumanEdits",
               label: "少量人工修图"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/humanEdits",
               label: "人工修图（非生成式）"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/algorithmicallyEnhanced",
               label: "算法增强"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCreation",
               label: "数字创作（人工、非生成式）"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/dataDrivenMedia",
               label: "数据驱动媒体"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia",
               label: "生成式 AI 生成"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/algorithmicMedia",
               label: "纯算法生成"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/screenCapture",
               label: "屏幕截图"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/virtualRecording",
               label: "虚拟事件录制"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/composite",
               label: "多元素合成"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/compositeCapture",
               label: "实拍元素合成"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/compositeSynthetic",
               label: "含生成式 AI 元素合成"),
        Option(value: "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia",
               label: "生成式 AI 编辑合成"),
    ]
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
