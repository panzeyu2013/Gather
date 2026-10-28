// desktop/native/gather-app/Sources/GatherHost/SidecarXMPProvider+IPTC.swift
// P1 / IPTC：按 XMPFieldDescriptor 表驱动的描述性元数据补丁（Core 22 + Extension 10）。
//
// 与既有四字段补丁的关系：同一条 patchDocument 管线、同一份命名空间注入与良构校验；
// 本文件只负责"字段值 -> RDF 片段"的序列化，不碰文件。
//
// 形状规则（与 Protocol/DescriptiveMetadata.swift 的 descriptor 表一致）：
//   text      <photoshop:City>..</photoshop:City>
//   alt       <dc:title><rdf:Alt><rdf:li xml:lang="x-default">..</rdf:li></rdf:Alt></dc:title>
//   bag/seq   <dc:creator><rdf:Seq><rdf:li>..</rdf:li></rdf:Seq></dc:creator>
//   structure <Iptc4xmpCore:CreatorContactInfo><rdf:Description>..</rdf:Description></...>
// 空值（空串/空数组/空结构）= 删除该元素（显式清空语义，见 DescriptiveMetadata 三态）。
import Foundation
import GatherProtocol

/// 一次字段补丁：qname 用于定位/删除，element 为 nil 表示"清空"。
struct DescriptivePatch: Equatable {
    let qname: String
    let element: String?
    let prefix: String
    let namespace: String
    let shape: XMPValueShape
    /// alt 形状的 x-default 文本（nil = 清空 x-default；其它语言的 rdf:li 保留）。
    let altText: String?
}

extension SidecarXMPProvider {

    /// 把描述性元数据展开为逐字段补丁（仅包含被显式设置的字段）。
    static func descriptivePatches(_ metadata: DescriptiveMetadata) -> [DescriptivePatch] {
        var patches: [DescriptivePatch] = []
        for descriptor in XMPFieldDescriptor.all {
            guard let value = metadata.value(for: descriptor.field) else { continue }
            let element = serializedElement(descriptor, value)
            let altText: String? = {
                guard (descriptor.shape == .alt || descriptor.shape == .text),
                      case .text(let text) = value, !text.isEmpty else {
                    return nil
                }
                return text
            }()
            patches.append(DescriptivePatch(
                qname: descriptor.qname,
                element: element,
                prefix: descriptor.prefix,
                namespace: descriptor.namespace,
                shape: descriptor.shape,
                altText: altText
            ))
        }
        return patches
    }

    private static func serializedElement(_ descriptor: XMPFieldDescriptor, _ value: XMPFieldValue) -> String? {
        switch descriptor.shape {
        case .text:
            guard case .text(let text) = value else { return nil }
            return text.isEmpty ? nil : simpleElement(descriptor.qname, value: text)
        case .alt:
            guard case .text(let text) = value else { return nil }
            return text.isEmpty ? nil : altElement(descriptor.qname, text)
        case .bag:
            guard case .list(let values) = value, !values.isEmpty else { return nil }
            return listElement(descriptor.qname, container: "rdf:Bag", items: values)
        case .seq:
            guard case .list(let values) = value, !values.isEmpty else { return nil }
            return listElement(descriptor.qname, container: "rdf:Seq", items: values)
        case .structure:
            guard case .contact(let contact) = value, !contact.isEmpty else { return nil }
            return contactElement(descriptor.qname, contact)
        }
    }

    private static func altElement(_ qname: String, _ value: String) -> String {
        let nl = "\n"
        return "<" + qname + ">" + nl
            + "  <rdf:Alt>" + nl
            + "    <rdf:li xml:lang=\"x-default\">" + xmlEscape(value) + "</rdf:li>" + nl
            + "  </rdf:Alt>" + nl
            + "</" + qname + ">"
    }

    private static func listElement(_ qname: String, container: String, items: [String]) -> String {
        let nl = "\n"
        let body = items.map { "    <rdf:li>" + xmlEscape($0) + "</rdf:li>" }.joined(separator: nl)
        return "<" + qname + ">" + nl
            + "  <" + container + ">" + nl
            + body + nl
            + "  </" + container + ">" + nl
            + "</" + qname + ">"
    }

    /// 合并 rdf:Alt：保留其它语言，只替换/删除 x-default。
    /// - defaultText == nil 且没有其它语言 → 返回空串（删除整个元素，清空语义）；
    /// - 有其它语言时即使清空 x-default 也保留容器（不替用户删翻译）。
    /// 注意：清空后「旧 IIM 复活」的防线在写侧（删对应 dataset，见 IPTCIIMMapping）
    /// 与读侧（XMP 独有字段不回退 IIM），不能靠保留空元素——那会改变 XMP 语义并
    /// 让外部工具看到「字段存在但为空」。
    static func mergedAltElement(_ existing: String, qname: String, defaultText: String?) -> String {
        let text = existing as NSString
        let pattern = #"<rdf:li\b([^>]*)>(.*?)</rdf:li>"#
        var kept: [String] = []
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            for match in regex.matches(in: existing, range: NSRange(location: 0, length: text.length)) {
                let attributes = text.substring(with: match.range(at: 1))
                let lang = langAttribute(attributes)
                // 默认语言槽位由本次写入决定；无 lang 的 li 视作默认（旧文件兼容）。
                guard let lang, lang != "x-default" else { continue }
                kept.append(text.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if defaultText == nil, kept.isEmpty { return "" }
        var lines: [String] = ["<" + qname + ">", "  <rdf:Alt>"]
        if let defaultText {
            lines.append("    <rdf:li xml:lang=\"x-default\">" + xmlEscape(defaultText) + "</rdf:li>")
        } else {
            // 清空默认语言但保留其它语言：显式留一个空 x-default，
            // 读侧据此判定「字段已清空」而不再回退到 en/de（翻译不丢）。
            lines.append("    <rdf:li xml:lang=\"x-default\"></rdf:li>")
        }
        lines.append(contentsOf: kept.map { "    " + $0 })
        lines.append("  </rdf:Alt>")
        lines.append("</" + qname + ">")
        return lines.joined(separator: "\n")
    }

    private static func langAttribute(_ attributes: String) -> String? {
        let pattern = #"xml:lang\s*=\s*["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = attributes as NSString
        guard let match = regex.firstMatch(
            in: attributes, range: NSRange(location: 0, length: text.length)) else { return nil }
        return text.substring(with: match.range(at: 1))
    }

    /// Contact Info 必须是结构（内嵌 rdf:Description），成员各为其子元素。
    private static func contactElement(_ qname: String, _ contact: DescriptiveContact) -> String {
        let nl = "\n"
        var members: [String] = []
        for member in DescriptiveContact.members {
            let value: String? = switch member.key {
            case "city": contact.city
            case "country": contact.country
            case "address": contact.address
            case "postalCode": contact.postalCode
            case "region": contact.region
            case "email": contact.email
            case "telephone": contact.telephone
            case "url": contact.url
            default: nil
            }
            guard let value, !value.isEmpty else { continue }
            members.append("    <" + member.qname + ">" + xmlEscape(value) + "</" + member.qname + ">")
        }
        guard !members.isEmpty else { return "" }
        return "<" + qname + ">" + nl
            + "  <rdf:Description>" + nl
            + members.joined(separator: nl) + nl
            + "  </rdf:Description>" + nl
            + "</" + qname + ">"
    }
}
