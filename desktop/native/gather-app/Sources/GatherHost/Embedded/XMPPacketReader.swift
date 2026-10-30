// desktop/native/gather-app/Sources/GatherHost/Embedded/XMPPacketReader.swift
// 内嵌 XMP 包（APP1）+ IPTC-IIM（APP13/0x0404）→ MetadataWriteAttributes。
//
// 为什么要有它（plan §3.2.5）：旧的内部读取靠 ImageIOExifProvider.parse，会把
// **整份 JPEG** 交给 ImageIO 解码/索引一次；写回一次要读 6–8 遍整文件，其中两遍
// 就是它。写回只需要头部（≤4MB）里的 XMP 包与 IIM 资源，用 Foundation XMLParser
// 解析即可，零 ImageIO、零整文件读。
//
// 读侧契约（与 ImageIO 路径逐字段对齐，靠 MetadataService 同一张映射表）：
// - 顶层 rdf:Description 的属性形式与子元素形式都读（Bridge/第三方工具两种都写）；
// - rdf:Bag/Seq → 数组；rdf:Alt → x-default（多语言容器只取默认语言）；
// - 结构（Iptc4xmpCore:CreatorContactInfo）→ 成员字典，键去掉前缀（CiAdrCity…）；
// - dc:* 归 dc 分段，其余本地名归 xmp 分段（与 CGImageMetadataCopyTags 同构）；
// - xmpPresentKeys 记录"存在但可能为空"的本地名：清空后不得让旧 IIM 把值复活；
// - lr:hierarchicalSubject 单独交出（W3 关键词域读取层级），gather:Triage 落进
//   attributes.triageSignal（ImageIO 不解析私有命名空间）；
// - 包缺失/非 UTF-8/XML 不合法 → 返回 nil，由调用方回退 ImageIO 旧路径。
import Foundation
import GatherApplication
import GatherProtocol

enum XMPPacketReader {

    /// 一次解析的完整结果（属性 + 中间分段 + W3 要用的层级关键词）。
    struct Reading: Equatable, Sendable {
        /// 与 ImageIO 路径同形的可写属性（XMP + IIM 合并，三态语义一致）。
        var attributes: MetadataWriteAttributes
        /// 中间分段（诊断/测试用：xmp / dc / iptc / xmpPresentKeys）。
        var segments: MetadataParseSegments
        /// lr:hierarchicalSubject（层级关键词；读侧交出层表，写入与 sidecar 共用 patchDocument）。
        var hierarchicalKeywords: [String]
        /// gather:Triage 原始信号（空串 = 显式清除，归一化为 nil）。
        var triageSignal: String?
    }

    /// XMP 包 + 全部 APP13 资源区 → 读属性。nil = XMP 包不可解析（回退 ImageIO）。
    static func read(xmpPacket: Data?, photoshopIRBPayloads: [Data]) -> Reading? {
        let iptc = iptcFields(from: photoshopIRBPayloads)
        guard let xmpPacket, !xmpPacket.isEmpty else {
            // 没有 XMP 是合法状态（相机直出 IIM-only）：只用 IIM 组装。
            return assemble(xmp: [:], dc: [:], present: [], iptc: iptc, hierarchical: [], triage: nil)
        }
        guard let text = decode(packet: xmpPacket), let tree = parseTree(text: text) else {
            return nil
        }
        let namespaces = namespaceDeclarations(in: text)
        var xmp: [String: JSONValue] = [:]
        var dc: [String: JSONValue] = [:]
        var present = Set<String>()
        var hierarchical: [String] = []
        var triage: String?
        for block in descriptionBlocks(of: tree) {
            // 属性形式优先读（属性值无结构，只能是简单值）。
            for (name, value) in block.attributes {
                guard let local = propertyLocalName(name, namespaces: namespaces) else { continue }
                classify(
                    local: local, json: .string(value), prefix: prefix(of: name),
                    namespaces: namespaces, xmp: &xmp, dc: &dc, present: &present,
                    hierarchical: &hierarchical, triage: &triage)
            }
            // 子元素形式（同名覆盖属性形式：写入器会删属性、落元素）。
            for child in block.children {
                guard let local = propertyLocalName(child.name, namespaces: namespaces) else {
                    continue
                }
                classify(
                    local: local, json: value(of: child), prefix: prefix(of: child.name),
                    namespaces: namespaces, xmp: &xmp, dc: &dc, present: &present,
                    hierarchical: &hierarchical, triage: &triage)
            }
        }
        return assemble(
            xmp: xmp, dc: dc, present: present, iptc: iptc,
            hierarchical: hierarchical, triage: triage)
    }

    /// 头部段表 → 读属性（内嵌会话的唯一入口）。nil = 回退旧路径。
    static func attributes(segments: [JPEGSegment]) -> MetadataWriteAttributes? {
        read(
            xmpPacket: segments.first(where: \.isXMP)?.xmpPacket,
            photoshopIRBPayloads: segments.compactMap(\.photoshopIRB)
        )?.attributes
    }

    // MARK: - 分段组装

    private static func assemble(
        xmp: [String: JSONValue],
        dc: [String: JSONValue],
        present: Set<String>,
        iptc: [String: JSONValue],
        hierarchical: [String],
        triage: String?
    ) -> Reading {
        let segments = MetadataParseSegments(
            xmp: xmp.isEmpty ? nil : .object(xmp),
            dc: dc.isEmpty ? nil : .object(dc),
            iptc: iptc.isEmpty ? nil : .object(iptc),
            xmpPresentKeys: present)
        // 合并规则唯一实现在 core：XMP 优先、IIM 回退、present-but-empty 阻断回退、
        // contact 结构单独成表。这里绝不复制第二份映射表。
        var attributes = MetadataService.embeddedAttributesFromParse(segments)
            ?? MetadataWriteAttributes()
        // dc:subject（扁平/可能含路径）与 lr:hierarchicalSubject（路径）合并成
        // 唯一的关键词列表；写回时再按 keyword_dc_style 拆回两套。
        if !hierarchical.isEmpty {
            let merged = KeywordCodec.merge(
                flat: attributes.keywords ?? [], hierarchical: hierarchical)
            attributes.keywords = merged.map(\.serialized)
        }
        let normalizedTriage = (triage?.isEmpty ?? true) ? nil : triage
        attributes.triageSignal = normalizedTriage
        return Reading(
            attributes: attributes,
            segments: segments,
            hierarchicalKeywords: hierarchical,
            triageSignal: normalizedTriage)
    }

    /// property 落到哪个分段、是不是 W3/私有信号。
    private static func classify(
        local: String,
        json: JSONValue,
        prefix propertyPrefix: String?,
        namespaces: [String: String],
        xmp: inout [String: JSONValue],
        dc: inout [String: JSONValue],
        present: inout Set<String>,
        hierarchical: inout [String],
        triage: inout String?
    ) {
        let namespace = propertyPrefix.flatMap { namespaces[$0] }
        if namespace == XMPNamespaces.gatherTriage, local == "Triage" {
            triage = json.stringValue ?? triage
            return
        }
        if isLightroom(namespace: namespace, prefix: propertyPrefix),
           local == "hierarchicalSubject" {
            hierarchical = json.arrayElements?.compactMap(\.stringValue)
                ?? json.stringValue.map { [$0] }
                ?? []
            return
        }
        present.insert(local)
        if isDublinCore(namespace: namespace, prefix: propertyPrefix) {
            dc[local] = json
        } else {
            xmp[local] = json
        }
    }

    private static func isDublinCore(namespace: String?, prefix: String?) -> Bool {
        if namespace == XMPNamespaces.dc { return true }
        // 没声明命名空间（残缺包）：退回按前缀判断，与写侧 normalizeKnownPrefixes 同口径。
        return namespace == nil && prefix == "dc"
    }

    private static func isLightroom(namespace: String?, prefix: String?) -> Bool {
        if namespace == "http://ns.adobe.com/lightroom/1.0/" { return true }
        return namespace == nil && prefix == "lr"
    }

    /// 属性名 → 可读取的本地名；命名空间声明与 rdf 结构属性（about/parseType）返回 nil。
    private static func propertyLocalName(
        _ qname: String, namespaces: [String: String]
    ) -> String? {
        // xmlns / xmlns:* 是命名空间声明，不是属性值；xml:*（lang/space）是 XML 保留属性。
        if qname == "xmlns" || qname.hasPrefix("xmlns:") { return nil }
        if let qnamePrefix = prefix(of: qname), qnamePrefix == "xml" { return nil }
        let name = localName(qname)
        guard !name.isEmpty else { return nil }
        if isRDF(qname, namespaces: namespaces) { return nil }
        return name
    }

    private static func isRDF(_ qname: String, namespaces: [String: String]) -> Bool {
        guard let qnamePrefix = prefix(of: qname) else { return false }
        if let namespace = namespaces[qnamePrefix] { return namespace == XMPNamespaces.rdf }
        return qnamePrefix == "rdf"
    }

    // MARK: - 值形状

    private static func value(of node: XMPNode) -> JSONValue {
        // rdf:Bag / rdf:Seq / rdf:Alt：按本地名匹配，命名空间别名不影响。
        if let container = node.children.first(where: {
            ["Bag", "Seq", "Alt"].contains(localName($0.name))
        }) {
            let items = container.children.filter { localName($0.name) == "li" }
            if localName(container.name) == "Alt" {
                // 多语言容器：x-default 是默认语言；没有再退首个非空项。
                if let fallback = items.first(where: {
                    ($0.attributes["xml:lang"] ?? "").lowercased() == "x-default"
                }) {
                    return .string(fallback.text)
                }
                return .string(items.first { !$0.text.isEmpty }?.text ?? "")
            }
            return .array(items.map { .string($0.text) })
        }
        // 结构：Iptc4xmpCore:CreatorContactInfo 内嵌 rdf:Description。
        if let structure = node.children.first(where: { localName($0.name) == "Description" }) {
            var object: [String: JSONValue] = [:]
            for (name, member) in structure.attributes where !name.hasPrefix("xmlns") {
                object[localName(name)] = .string(member)
            }
            for child in structure.children where !child.name.hasPrefix("xmlns") {
                object[localName(child.name)] = .string(child.text)
            }
            return .object(object)
        }
        // 空元素（<xmp:Label/>）必须保留"存在但为空"：清空语义靠它阻断 IIM 回退。
        return .string(node.children.isEmpty ? trimmedWhitespaceOnly(node.text) : "")
    }

    /// 全空白 → 空串（缩进不得变成"有值"）；其余原样（用户填的前后空格属于内容，
    /// 由 SidecarXMPProvider.normalizedValue 在校验时统一归一化）。
    private static func trimmedWhitespaceOnly(_ text: String) -> String {
        text.allSatisfy { $0.isWhitespace } ? "" : text
    }

    // MARK: - IIM

    /// APP13 资源区 → ImageIO 形状的 iptc 分段（键名与 MetadataService 的 IIM 表一致）。
    /// 解析失败或没有 0x0404 资源 → 空（读侧不能因为 IIM 坏掉就判整张不可读）。
    private static func iptcFields(from payloads: [Data]) -> [String: JSONValue] {
        guard !payloads.isEmpty else { return [:] }
        var iim: IPTCIIM?
        for payload in payloads {
            guard let resources = tryOptional({ try PhotoshopIRBList.parse(payload) }) else {
                // 坏段只跳过本段：已成功解析的 IIM 不因后续段损坏而整体丢弃。
                continue
            }
            guard iim == nil,
                  let resource = resources.first(where: { $0.resourceID == PhotoshopIRB.iptcNAA })
            else { continue }
            iim = tryOptional { try IPTCIIM.parse(resource.data) }
        }
        guard let iim else { return [:] }
        var fields: [String: JSONValue] = [:]
        for spec in iimFieldTable {
            let values = iim.values(for: spec.key)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            fields[spec.name] = spec.isList ? .array(values.map { .string($0) }) : .string(values[0])
        }
        return fields
    }

    /// IIM dataset → ImageIO 的 IPTC 键名（MetadataService.embeddedDescriptiveFields 的
    /// iimKeys 逐字对应；只列真有 dataset 的字段）。
    private static let iimFieldTable: [(key: IIMKey, name: String, isList: Bool)] = [
        (.objectName, "ObjectName", false),
        (.caption, "Caption/Abstract", false),
        (.byline, "Byline", true),
        (.copyrightNotice, "CopyrightNotice", false),
        (.bylineTitle, "BylineTitle", false),
        (.credit, "Credit", false),
        (.source, "Source", false),
        (.headline, "Headline", false),
        (.writerEditor, "Writer/Editor", false),
        (.transmissionReference, "OriginalTransmissionReference", false),
        (.city, "City", false),
        (.provinceState, "Province/State", false),
        (.countryName, "Country/PrimaryLocationName", false),
        (.countryCode, "Country/PrimaryLocationCode", false),
        (.sublocation, "SubLocation", false),
        (.contentLocationName, "ContentLocationName", false),
        (.objectAttributeReference, "ObjectAttributeReference", false),
        (.subjectReference, "SubjectReference", true),
        (.dateCreated, "DateCreated", false),
        (.scene, "Scene", true),
        (.keywords, "Keywords", true),
    ]

    /// 把可能抛错的纯解析包成可选（读路径"坏了就当没有"，不吞写入错误）。
    private static func tryOptional<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            return nil
        }
    }

    // MARK: - XML

    private static func decode(packet: Data) -> String? {
        guard var text = String(data: packet, encoding: .utf8) else { return nil }
        // ImageIO 写出的包体末尾常带 NUL 填充：XMLParser 会判整份文档不合法。
        if text.contains("\u{0}") {
            text = text.replacingOccurrences(of: "\u{0}", with: "")
        }
        return text
    }

    private static func parseTree(text: String) -> XMPNode? {
        let parser = XMLParser(data: Data(text.utf8))
        let builder = XMPPacketTreeBuilder()
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return builder.roots.first
    }

    /// 顶层的 rdf:Description 块（结构内部的 Description 不算：它们只作为属性值读取）。
    private static func descriptionBlocks(of root: XMPNode) -> [XMPNode] {
        if localName(root.name) == "Description" { return [root] }
        var blocks: [XMPNode] = []
        for child in root.children {
            blocks.append(contentsOf: descriptionBlocks(of: child))
        }
        return blocks
    }

    /// 包内 xmlns 声明（前缀 → URI）；未声明的前缀由调用方按字面前缀兜底。
    private static func namespaceDeclarations(in xml: String) -> [String: String] {
        var result: [String: String] = [:]
        var searchStart = xml.startIndex
        while let range = xml.range(of: "xmlns:", range: searchStart..<xml.endIndex) {
            var index = range.upperBound
            var declared = ""
            while index < xml.endIndex, xml[index] != "=", !xml[index].isWhitespace {
                declared.append(xml[index])
                index = xml.index(after: index)
            }
            while index < xml.endIndex, xml[index].isWhitespace || xml[index] == "=" {
                index = xml.index(after: index)
            }
            if index < xml.endIndex, xml[index] == "\"" || xml[index] == "'" {
                let quote = xml[index]
                index = xml.index(after: index)
                var uri = ""
                while index < xml.endIndex, xml[index] != quote {
                    uri.append(xml[index])
                    index = xml.index(after: index)
                }
                if !declared.isEmpty { result[declared] = uri }
            }
            searchStart = range.upperBound
        }
        return result
    }

    private static func prefix(of qname: String) -> String? {
        guard let colon = qname.firstIndex(of: ":") else { return nil }
        return String(qname[qname.startIndex..<colon])
    }

    private static func localName(_ qname: String) -> String {
        guard let colon = qname.lastIndex(of: ":") else { return qname }
        return String(qname[qname.index(after: colon)...])
    }
}

/// XML 元素（只保留解析需要的四样东西：限定名、属性、子元素、文本）。
final class XMPNode {
    let name: String
    let attributes: [String: String]
    var children: [XMPNode] = []
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
}

/// XMLParser 委托：把事件摊平成 XMPNode 树（XMP 包 ≤4MB，树的开销可忽略）。
final class XMPPacketTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var roots: [XMPNode] = []
    private var stack: [XMPNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMPNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            roots.append(node)
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !stack.isEmpty { stack.removeLast() }
    }
}
