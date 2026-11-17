// desktop/native/gather-core/Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift
// P1 / IPTC：按 XMPFieldDescriptor 表收集描述性元数据（与写入同一张表，避免读写漂移）。
//
// 独立于既有 SidecarXMLDelegate（那个只管 rating/label/keywords/urgency/EXIF 六项）。
// 单文件二次解析的代价可忽略（sidecar 通常 < 20KB），换来的是不用改动已验证的旧解析路径。
import Foundation
import Synchronization
import GatherProtocol

/// sidecar 读写路径的编译后正则缓存（性能审计 R2）。
///
/// 这些正则出现在逐照片（读）/逐字段（写）路径；旧实现每次调用
/// `NSRegularExpression(pattern:)` 重新编译。NSRegularExpression 创建后不可变，
/// 但未标注 Sendable，故按项目并发约定用 `Synchronization.Mutex` 锁盒子持有
/// （与 `OSAllocatedUnfairLock` 同类的锁盒子写法；不新增 @unchecked Sendable /
/// nonisolated(unsafe)）。匹配也在锁内执行、只把 Sendable 结果带出——不依赖
/// 「正则匹配跨线程安全」这类未写进文档的假设；模式与匹配语义逐字不变。
enum SidecarRegexCache {
    private static let storage = Mutex<[String: NSRegularExpression]>([:])

    static func withRegex<T: Sendable>(
        _ pattern: String,
        options: NSRegularExpression.Options = [],
        _ body: (NSRegularExpression) -> T?
    ) -> T? {
        let key = String(options.rawValue) + "|" + pattern
        return storage.withLock { cache -> T? in
            let compiled: NSRegularExpression
            if let cached = cache[key] {
                compiled = cached
            } else if let fresh = try? NSRegularExpression(pattern: pattern, options: options) {
                cache[key] = fresh
                compiled = fresh
            } else {
                return nil
            }
            return body(compiled)
        }
    }
}

extension SidecarXMPProvider {
    /// 已知命名空间 → 规范前缀（与 XMPFieldDescriptor 表、写入侧共用）。
    static let canonicalPrefixes: [(uri: String, prefix: String)] = {
        var pairs = XMPFieldDescriptor.all.map { (uri: $0.namespace, prefix: $0.prefix) }
        pairs.append((XMPNamespaces.rdf, "rdf"))
        pairs.append((XMPNamespaces.gatherTriage, "gather"))
        return pairs
    }()

    /// 把「绑定到已知命名空间、但用了非规范前缀」的标签/属性改写成规范前缀。
    ///
    /// 为什么需要：IPTC 收集器按 descriptor 表的规范前缀查表；外部工具若把同一命名
    /// 空间绑到 `ipTC:`/`ps:` 之类的前缀，整字段会读不到。只改 XML 标签内部
    /// （`<...>`），不碰文本/CDATA；无法解码或规范前缀被绑到别的 URI 时原样返回。
    struct PrefixNormalization {
        var text: String
        /// 归一化后新出现的规范前缀（原文档没有声明，需要调用方补 xmlns）。
        var introduced: [(prefix: String, uri: String)]
    }

    static func normalizeKnownPrefixes(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(normalizeKnownPrefixes(text).text.utf8)
    }

    static func normalizeKnownPrefixes(_ text: String) -> PrefixNormalization {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let declarations: [(prefix: String, uri: String)] = SidecarRegexCache.withRegex(
            #"xmlns:([A-Za-z_][-\w.]*)\s*=\s*["']([^"']*)["']"#,
            { regex in
                regex.matches(in: text, range: fullRange).map {
                    (nsText.substring(with: $0.range(at: 1)), nsText.substring(with: $0.range(at: 2)))
                }
            })
        else { return PrefixNormalization(text: text, introduced: []) }
        var declared: [String: String] = [:]
        for (prefix, uri) in declarations {
            declared[prefix] = uri
        }
        var replacements: [(from: String, to: String)] = []
        var introduced: [(prefix: String, uri: String)] = []
        var introducedSet = Set<String>()
        for (uri, canonical) in canonicalPrefixes {
            // 规范前缀已被绑到别的 URI：改写会制造歧义，跳过该命名空间。
            if let bound = declared[canonical], bound != uri { continue }
            for (prefix, boundURI) in declared where boundURI == uri && prefix != canonical {
                replacements.append((prefix + ":", canonical + ":"))
                if declared[canonical] == nil, introducedSet.insert(canonical).inserted {
                    introduced.append((canonical, uri))
                }
            }
        }
        guard !replacements.isEmpty,
              let tagRanges: [NSRange] = SidecarRegexCache.withRegex(
                  #"<[^>]*>"#,
                  { regex in regex.matches(in: text, range: fullRange).map(\.range) })
        else { return PrefixNormalization(text: text, introduced: []) }
        var result = text
        // escapedPattern 与 tag 无关：每个替换前缀只算一次（性能审计 R2）。
        let escapedReplacements = replacements.map {
            (escaped: NSRegularExpression.escapedPattern(for: $0.from), to: $0.to)
        }
        // 逆序替换：前面的 range 不受后面编辑影响。
        for tagRange in tagRanges.reversed() {
            guard let range = Range(tagRange, in: result) else { continue }
            var segment = String(result[range])
            for (escaped, to) in escapedReplacements {
                // 前缀前的字符：空白/属性分隔、开标签的 <、闭标签的 /。
                segment = segment.replacingOccurrences(
                    of: "([\\s</])" + escaped, with: "$1" + to, options: .regularExpression)
            }
            result.replaceSubrange(range, with: segment)
        }
        return PrefixNormalization(text: result, introduced: introduced)
    }
}

/// 描述性元数据的 SAX 收集器。
final class IPTCXMLDelegate: NSObject, XMLParserDelegate {
    private struct Capture {
        let name: String
        let lang: String?
        var text: String
    }

    private static let byQName: [String: XMPFieldDescriptor] = Dictionary(
        uniqueKeysWithValues: XMPFieldDescriptor.all.map { ($0.qname, $0) }
    )
    private static let contactByQName: [String: String] = Dictionary(
        uniqueKeysWithValues: DescriptiveContact.members.map { ($0.qname, $0.key) }
    )

    private var capture: Capture?
    private var listField: DescriptiveField?
    private var listItems: [String] = []
    private var altDefault: String?
    private var altFirst: String?
    /// 是否存在 x-default 槽位（即使为空）：存在即"显式默认值"，不得回退到其它语言。
    private var altHasDefault = false
    /// .text 字段被外部工具写成 Lang Alt 时，按 alt 语义读取，避免串接语言。
    private var textAltField: DescriptiveField?
    private var listDepth = 0
    private var inContact = false
    private var contact = DescriptiveContact()

    private(set) var descriptive = DescriptiveMetadata()
    /// P1 / E：私有命名空间 gather:Triage 的信号（keep / reject）。
    private(set) var triageSignal: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        if name == "rdf:Description" {
            // 属性形式：text 字段直接挂属性；contact 成员（CiAdrCity 等）也常以
            // 属性形式出现，必须收集，否则紧凑 XMP 的 contact 会读成 nil 并在
            // 后续结构写入时整块丢成员。
            var attributeContact = DescriptiveContact()
            var hasContactMember = false
            for (key, value) in attributeDict {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let descriptor = Self.byQName[key], descriptor.shape == .text {
                    descriptive.set(text.isEmpty ? nil : .text(text), for: descriptor.field)
                } else if let memberKey = Self.contactByQName[key] {
                    assign(contact: memberKey, value: text, to: &attributeContact)
                    hasContactMember = true
                }
            }
            if hasContactMember {
                descriptive.contactInfo = (descriptive.contactInfo ?? DescriptiveContact())
                    .merging(attributeContact)
            }
            return
        }
        if name == "gather:Triage" {
            capture = Capture(name: name, lang: nil, text: "")
            return
        }
        if name == "rdf:Alt", let active = capture,
           let descriptor = Self.byQName[active.name], descriptor.shape == .text {
            textAltField = descriptor.field
            capture = nil
            listField = descriptor.field
            listDepth = 1
            listItems = []
            altDefault = nil
            altFirst = nil
            altHasDefault = false
            return
        }
        if name == "rdf:li" {
            if listField != nil {
                capture = Capture(name: "rdf:li", lang: attributeDict["xml:lang"] ?? attributeDict["lang"], text: "")
            }
            return
        }
        if let descriptor = Self.byQName[name] {
            switch descriptor.shape {
            case .text:
                capture = Capture(name: name, lang: nil, text: "")
            case .alt, .bag, .seq:
                if listDepth == 0 {
                    listField = descriptor.field
                    listItems = []
                    altDefault = nil
                    altFirst = nil
                    altHasDefault = false
                }
                listDepth += 1
            case .structure:
                inContact = true
                contact = DescriptiveContact()
            }
            return
        }
        if inContact, Self.contactByQName[name] != nil {
            capture = Capture(name: name, lang: nil, text: "")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture != nil { capture?.text += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName

        if name == "rdf:Alt", let field = textAltField {
            if altHasDefault {
                if let value = altDefault, !value.isEmpty {
                    descriptive.set(.text(value), for: field)
                }
            } else if let value = altFirst, !value.isEmpty {
                descriptive.set(.text(value), for: field)
            }
            textAltField = nil
            listField = nil
            listDepth = 0
            return
        }

        if var active = capture, active.name == name {
            let text = active.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "gather:Triage" {
                triageSignal = text.isEmpty ? nil : text
            } else if name == "rdf:li" {
                listItems.append(text)
                // 空 li 不是"显式清空"：读成 nil 才能在后续无关写入时保留
                // 其它语言的 rdf:li（否则 whole-element 删除会连翻译一起删）。
                if active.lang == "x-default" {
                    altHasDefault = true
                    if altDefault == nil, !text.isEmpty { altDefault = text }
                }
                if altFirst == nil, !text.isEmpty { altFirst = text }
            } else if Self.byQName[name] != nil {
                descriptive.set(text.isEmpty ? nil : .text(text), for: Self.byQName[name]!.field)
            } else if inContact, let key = Self.contactByQName[name] {
                assign(contact: key, value: text)
            } else if Self.contactByQName[name] != nil, let key = Self.contactByQName[name] {
                assign(contact: key, value: text)
            }
            active.text = ""
            capture = nil
        }

        guard let descriptor = Self.byQName[name] else { return }
        switch descriptor.shape {
        case .alt:
            listDepth = max(0, listDepth - 1)
            if listDepth == 0 {
                if altHasDefault {
                    // x-default 存在但为空 = 显式清空；其它语言保留在文件里但不生效。
                    if let value = altDefault, !value.isEmpty {
                        descriptive.set(.text(value), for: descriptor.field)
                    }
                } else if let value = altFirst, !value.isEmpty {
                    descriptive.set(.text(value), for: descriptor.field)
                }
                listField = nil
            }
        case .bag, .seq:
            listDepth = max(0, listDepth - 1)
            if listDepth == 0 {
                descriptive.set(.list(listItems.filter { !$0.isEmpty }), for: descriptor.field)
                listField = nil
            }
        case .structure:
            // 属性形式与元素形式可能混存（CiEmailWork 属性 + CiAdrCity 元素）：
            // 结构结束时必须成员级合并，整块 set 会把属性成员冲掉。
            // 空结构 = 没有联系人信息（外部工具常留空壳）。**不写字段**：否则
            // mergeAttributes 的 overlay 语义会把 JPEG 内嵌联系人整块抹掉
            // （面板显示"无联系人"，JPEG_EMBEDDED_CLEAR_UNSUPPORTED 也永不触发）。
            // 显式清空走写侧 clearedContactMembers / replaceContact，不靠读侧空结构。
            if !contact.isEmpty {
                let merged = (descriptive.contactInfo ?? DescriptiveContact())
                    .merging(contact)
                descriptive.set(.contact(merged), for: descriptor.field)
            }
            inContact = false
        case .text:
            break
        }
    }

    private func assign(contact key: String, value: String) {
        assign(contact: key, value: value, to: &contact)
    }

    private func assign(contact key: String, value: String, to target: inout DescriptiveContact) {
        let text: String? = value.isEmpty ? nil : value
        switch key {
        case "city": target.city = text
        case "country": target.country = text
        case "address": target.address = text
        case "postalCode": target.postalCode = text
        case "region": target.region = text
        case "email": target.email = text
        case "telephone": target.telephone = text
        case "url": target.url = text
        default: break
        }
    }
}
