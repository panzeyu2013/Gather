// desktop/native/gather-core/Sources/GatherProtocol/Protocol/MetadataAttributes.swift
// 元数据属性的**纯函数簇**（#6 S0：从 1,645 行的 MetadataService 里切出的第一刀）。
//
// 为什么先切这块：36 个函数里有 17 个是 static，合计 254 行，全部无 self、无 IO、
// 无事务——搬它们是零风险的等价变换，而且这块是跨 target 的：GatherMetadataIO 的
// 内嵌 JPEG 读路径（MetadataWriteRouter / JPEGMetadataWriter / XMPPacketReader）
// 直接复用它，此前它们只能通过 Application 的 MetadataService 间接取得。
//
// 边界：只放「值 → 值」的映射与合并。任何需要读盘/读库/事务的都不能进这里。
import Foundation

public enum MetadataAttributes {
    /// TS: `{ ...selectedAttributes, ...sidecarAttributes }`（后者按 key 覆盖）。
    ///
    /// **唯一实现**：宿主内的 JPEG 读路径（`MetadataWriteRouter.readEmbedded`）也走这里。
    /// 以前路由里另抄一份，抄的时候漏了 `triageSignal`/`keywordsMode`/`replaceContact`，
    /// 导致"内嵌 + sidecar 合成"会静默丢这三个字段。
    public static func mergeAttributes(
        _ base: MetadataWriteAttributes,
        _ overlay: MetadataWriteAttributes
    ) -> MetadataWriteAttributes {
        MetadataWriteAttributes(
            keywords: overlay.keywords ?? base.keywords,
            rating: overlay.rating ?? base.rating,
            label: overlay.label ?? base.label,
            dateTaken: overlay.dateTaken ?? base.dateTaken,
            latitude: overlay.latitude ?? base.latitude,
            longitude: overlay.longitude ?? base.longitude,
            // P0 / B1：描述性元数据**逐字段**合并（sidecar 覆盖内嵌，内嵌补 sidecar 空缺）。
            // 旧实现整块 overlay：sidecar 只要有一个字段，JPEG 里的其它 IPTC 就全丢。
            descriptive: mergeDescriptive(base.descriptive, overlay.descriptive),
            triageSignal: overlay.triageSignal ?? base.triageSignal,
            keywordsMode: overlay.keywordsMode ?? base.keywordsMode,
            replaceContact: overlay.replaceContact ?? base.replaceContact
        )
    }

    /// 逐字段合并：overlay 的非 nil 字段覆盖 base（nil = 该来源没有该字段）。
    public static func mergeDescriptive(
        _ base: DescriptiveMetadata?,
        _ overlay: DescriptiveMetadata?
    ) -> DescriptiveMetadata? {
        switch (base, overlay) {
        case (nil, nil): return nil
        case (let base?, nil): return base
        case (nil, let overlay?): return overlay
        case (let base?, let overlay?): return base.applying(overlay)
        }
    }

    /// TS: embeddedAttributesFromParse —— 从已解析段派生内嵌可写属性：
    /// - keywords：XMP dc:subject 优先于 IPTC Keywords；
    /// - rating：xmp:Rating ?? IFD0 Rating（数字或数字字符串）；
    /// - label：xmp:Label；
    /// - descriptive：dc / xmp / IPTC-IIM 的字段映射（P0 / B1）。
    ///
    /// 旧实现在"只有 IPTC 关键词"时返回 nil（TS 的 exifr 字符集不可靠）。
    /// ImageIO 实现下不成立：CGImageProperties 会把 IIM 合成为 dc:subject，
    /// 且字符串是原生 Swift String；保留该分支只会把可读文件推给未接线的
    /// EmbeddedXMPReader（等价于丢失描述性元数据）。
    public static func embeddedAttributesFromParse(_ parsed: MetadataParseSegments) -> MetadataWriteAttributes? {
        let xmp = parsed.xmp
        let dc = parsed.dc
        let iptc = parsed.iptc
        let ifd0 = parsed.ifd0
        let rawRating = xmp?["Rating"] ?? ifd0?["Rating"]
        let rating: Double?
        if let number = rawRating?.numberValue {
            rating = number
        } else if let string = rawRating?.stringValue, let parsedNumber = Double(string), parsedNumber.isFinite {
            rating = parsedNumber
        } else {
            rating = nil
        }
        // 关键词同样要做 presence 阻断：外部只清空 XMP 的 dc:subject 时，
        // ImageIO 会把 IIM 旧关键词合成回 dc:subject（实测），不判 presence 会复活旧值。
        let keywords: [String]? = if parsed.xmpPresentKeys.contains("subject") {
            normalizeKeywordList(dc?["subject"])
        } else {
            normalizeKeywordList(dc?["subject"] ?? iptc?["Keywords"])
        }
        let descriptive = descriptiveFromParse(parsed)
        if keywords == nil, rating == nil, xmp?["Label"] == nil, descriptive.isEmpty {
            return nil
        }
        return MetadataWriteAttributes(
            keywords: keywords,
            rating: rating,
            label: xmp?["Label"]?.stringValue,
            descriptive: descriptive.isEmpty ? nil : descriptive
        )
    }

    /// 内嵌描述性元数据映射（键表与 ImageIO 的 IPTC 常量逐字一致）。
    ///
    /// 取值优先级：dc（XMP 原生）→ xmp（其它命名空间的本地名）→ IPTC-IIM
    /// （Bridge/Lightroom 常写的形态）。每个字段独立取第一个非空值。
    ///
    /// P1：改为表驱动——旧实现逐行手写，漏了计划验收明确要求的 `location`；
    /// 新增字段只需加一行表项，并由一组真实 JPEG 映射测试兜住。
    private struct EmbeddedDescriptiveField {
        let field: DescriptiveField
        var dcKeys: [String] = []
        var xmpKeys: [String] = []
        var iimKeys: [String] = []
        var isList = false
    }

    private static let embeddedDescriptiveFields: [EmbeddedDescriptiveField] = [
        .init(field: .title, dcKeys: ["title"], iimKeys: ["ObjectName"]),
        .init(field: .caption, dcKeys: ["description"], iimKeys: ["Caption/Abstract"]),
        .init(field: .creator, dcKeys: ["creator"], iimKeys: ["Byline"], isList: true),
        .init(field: .copyrightNotice, dcKeys: ["rights"], iimKeys: ["CopyrightNotice"]),
        .init(field: .creatorJobTitle, xmpKeys: ["AuthorsPosition"], iimKeys: ["BylineTitle"]),
        .init(field: .credit, xmpKeys: ["Credit"], iimKeys: ["Credit"]),
        .init(field: .source, xmpKeys: ["Source"], iimKeys: ["Source"]),
        .init(field: .headline, xmpKeys: ["Headline"], iimKeys: ["Headline"]),
        .init(field: .captionWriter, xmpKeys: ["CaptionWriter"], iimKeys: ["Writer/Editor"]),
        .init(field: .jobIdentifier, xmpKeys: ["TransmissionReference"],
              iimKeys: ["OriginalTransmissionReference"]),
        // 实测：ImageIO 把 UsageTerms 写在 XMP，IIM 无对应 dataset（2:130 读作 ImageType），
        // 因此不做 IIM 回退——否则清空 XMP 后旧 IIM 会把字段复活。
        .init(field: .usageTerms, xmpKeys: ["UsageTerms"]),
        // IPTC Core 的 WebStatement 只在 XMP 命名空间（xmpRights），没有 IIM 对应。
        .init(field: .webStatement, xmpKeys: ["WebStatement"]),
        .init(field: .city, xmpKeys: ["City"], iimKeys: ["City"]),
        .init(field: .state, xmpKeys: ["State"], iimKeys: ["Province/State"]),
        .init(field: .country, xmpKeys: ["Country"], iimKeys: ["Country/PrimaryLocationName"]),
        .init(field: .countryCode, xmpKeys: ["CountryCode"],
              iimKeys: ["Country/PrimaryLocationCode"]),
        .init(field: .sublocation, xmpKeys: ["Sublocation"], iimKeys: ["SubLocation"]),
        // 计划 B1 验收字段：旧实现漏了这一行。
        .init(field: .location, xmpKeys: ["Location"], iimKeys: ["ContentLocationName"]),
        .init(field: .intellectualGenre, xmpKeys: ["IntellectualGenre"],
              iimKeys: ["ObjectAttributeReference"]),
        .init(field: .subjectCode, xmpKeys: ["SubjectCode"], iimKeys: ["SubjectReference"],
              isList: true),
        .init(field: .dateCreated, xmpKeys: ["DateCreated"], iimKeys: ["DateCreated"]),
        // IIM 2:202（实测 ImageIO 读回键名 Scene）：写侧已映射，清空时删 dataset。
        .init(field: .scene, xmpKeys: ["Scene"], iimKeys: ["Scene"], isList: true),
        .init(field: .event, xmpKeys: ["Event"]),
        .init(field: .personInImage, xmpKeys: ["PersonInImage"], isList: true),
        .init(field: .organisationInImage, xmpKeys: ["OrganisationInImageName"], isList: true),
        .init(field: .worldRegion, xmpKeys: ["WorldRegion"]),
        .init(field: .provinceState, xmpKeys: ["ProvinceState"]),
        .init(field: .modelReleaseStatus, xmpKeys: ["ModelReleaseStatus"]),
        .init(field: .propertyReleaseStatus, xmpKeys: ["PropertyReleaseStatus"]),
        .init(field: .digitalSourceType, xmpKeys: ["DigitalSourceType"]),
        .init(field: .additionalModelInfo, xmpKeys: ["AddlModelInfo"]),
    ]

    static func descriptiveFromParse(_ parsed: MetadataParseSegments) -> DescriptiveMetadata {
        var result = DescriptiveMetadata()
        for spec in embeddedDescriptiveFields {
            // 内嵌 XMP 里存在该键（哪怕值是空）= 用户显式清空过：不得再回退到 IIM，
            // 否则旧 IIM 会把已清空的字段"复活"（写侧已删 dataset，这里兜住外部残留）。
            let blockedByExplicitEmpty = (spec.dcKeys + spec.xmpKeys)
                .contains { parsed.xmpPresentKeys.contains($0) }
            if blockedByExplicitEmpty {
                // 诊断：XMP 键在场但为空 → 忽略非空 IIM 残留（语义不能改，否则清空会
                // 被旧 IIM "复活"）。外部工具混合形态（XMP 空壳 + IIM 有值）因此会被
                // 读成空，这里 debug 留痕，便于排查"盘上有值却显示为空"。
                let iimResidue = spec.isList
                    ? firstList(parsed, keys: spec.iimKeys, isIIM: true) != nil
                    : firstText(parsed, keys: spec.iimKeys, isIIM: true) != nil
                if iimResidue {
                    GatherLogger.log(
                        "embedded XMP present-but-empty masked IPTC-IIM residue for field "
                            + "\(spec.field.rawValue)", level: .debug)
                }
            }
            if spec.isList {
                let list = firstList(parsed, keys: spec.dcKeys, isDC: true)
                    ?? firstList(parsed, keys: spec.xmpKeys, isDC: false)
                    ?? (blockedByExplicitEmpty
                        ? nil
                        : firstList(parsed, keys: spec.iimKeys, isIIM: true))
                if let list { result.set(.list(list), for: spec.field) }
            } else {
                let text = firstText(parsed, keys: spec.dcKeys, isDC: true)
                    ?? firstText(parsed, keys: spec.xmpKeys, isDC: false)
                    ?? (blockedByExplicitEmpty
                        ? nil
                        : firstText(parsed, keys: spec.iimKeys, isIIM: true))
                if let text { result.set(.text(text), for: spec.field) }
            }
        }
        // Iptc4xmpCore:CreatorContactInfo 是结构（ImageIO 返回字典），不能走
        // 上面的单值表；缺映射时 JPEG 清空联系人永远会被判"成功"。
        if let contact = contactFromParse(parsed) {
            result.contactInfo = contact
        }
        return result
    }

    /// 内嵌 IPTC Core 联系人结构（CreatorContactInfo 的成员名去掉前缀）。
    ///
    /// ImageIO 的 CGImageMetadataCopyTags 会把结构成员暴露为字典键
    /// CiAdrCity / CiEmailWork …；成员表与写入端共用 DescriptiveContact.members。
    private static func contactFromParse(_ parsed: MetadataParseSegments) -> DescriptiveContact? {
        guard case .object(let object)? = parsed.xmp?["CreatorContactInfo"] else { return nil }
        var contact = DescriptiveContact()
        for (key, qname) in DescriptiveContact.members {
            let local = qname.split(separator: ":").last.map(String.init) ?? qname
            guard let text = textValue(object[local]), !text.isEmpty else { continue }
            switch key {
            case "city": contact.city = text
            case "country": contact.country = text
            case "address": contact.address = text
            case "postalCode": contact.postalCode = text
            case "region": contact.region = text
            case "email": contact.email = text
            case "telephone": contact.telephone = text
            case "url": contact.url = text
            default: break
            }
        }
        return contact.isEmpty ? nil : contact
    }

    private static func firstText(
        _ parsed: MetadataParseSegments, keys: [String], isDC: Bool = false, isIIM: Bool = false
    ) -> String? {
        let segment = isIIM ? parsed.iptc : (isDC ? parsed.dc : parsed.xmp)
        for key in keys {
            if let text = textValue(segment?[key]), !text.isEmpty { return text }
        }
        return nil
    }

    private static func firstList(
        _ parsed: MetadataParseSegments, keys: [String], isDC: Bool = false, isIIM: Bool = false
    ) -> [String]? {
        let segment = isIIM ? parsed.iptc : (isDC ? parsed.dc : parsed.xmp)
        for key in keys {
            if let list = listValue(segment?[key]), !list.isEmpty { return list }
        }
        return nil
    }

    /// ImageIO 的 rdf:Alt 值是「带 qualifier 的 tag 数组」（如 dc:title 返回 [tag]）：
    /// 标量原样取，数组取首个字符串元素，数字转字符串。
    static func textValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue { return text }
        if let number = value.numberValue {
            return number.rounded() == number ? String(Int(number)) : String(number)
        }
        if let items = value.arrayElements {
            for item in items {
                if let text = textValue(item), !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// 列表型字段：数组取全部字符串；标量视为单元素列表（逗号不拆，关键词里可能有逗号）。
    static func listValue(_ value: JSONValue?) -> [String]? {
        guard let value else { return nil }
        if let items = value.arrayElements {
            let strings = items.compactMap { textValue($0) }.filter { !$0.isEmpty }
            return strings.isEmpty ? nil : strings
        }
        if let text = textValue(value), !text.isEmpty { return [text] }
        return nil
    }

    /// 关键词归一化：数组/标量都收成去重排序的词表；空表返回 nil。
    public static func normalizeKeywordList(_ value: JSONValue?) -> [String]? {
        let strings: [String]
        switch value {
        case .array(let items):
            strings = items.compactMap { item in
                if let s = item.stringValue { return s }
                if let n = item.numberValue { return keywordString(n) }
                return nil
            }
        case .none, .null:
            strings = []
        case .some(let scalar):
            if let s = scalar.stringValue {
                strings = [s]
            } else if let n = scalar.numberValue {
                strings = [keywordString(n)]
            } else {
                strings = []
            }
        }
        let normalized = KeywordCodec.normalized(strings)
        return normalized.isEmpty ? nil : normalized
    }

    /// Double 转关键词字符串（整数值不带 .0；NaN/Infinity 有稳定写法）。
    /// Double → 关键词字符串（整数值不带 .0；NaN/Infinity 有稳定写法）。
    /// #6 复审起 public：Application 侧的 MetadataText 只委托到这里，禁止再抄一份。
    public static func keywordString(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
        if let integer = Int64(exactly: number) { return String(integer) }
        return String(number)
    }
}
