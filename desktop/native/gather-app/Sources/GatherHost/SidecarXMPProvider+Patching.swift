// desktop/native/gather-app/Sources/GatherHost/SidecarXMPProvider+Patching.swift
// WP5 纯移动：XMP 写入管线（四字段补丁 / 命名空间 / 标签扫描 / 原子落盘），
// 自 SidecarXMPProvider.swift:285-799 原样搬移（方法体、错误码、调用顺序零改动）。
// 跨文件访问级仅 4 处 private → internal：patchDocument / verify /
// assertNamespacePrefixes / writeAtomic；其余常量与助手仍 private（同文件内使用）。
import Foundation
import GatherProtocol

extension SidecarXMPProvider {

    // MARK: - 写入实现

    private static let newline = String(UnicodeScalar(10)!)

    private static let dcNamespace = "http://purl.org/dc/elements/1.1/"
    private static let xmpNamespace = "http://ns.adobe.com/xap/1.0/"
    private static let photoshopNamespace = "http://ns.adobe.com/photoshop/1.0/"
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    /// 写后校验：目标字段必须与期望一致（label 的 "" 与 nil 等价）。
    static func verify(
        xmpPath: String,
        expected: MetadataWriteAttributes,
        actual: MetadataWriteAttributes
    ) throws {
        if let keywords = expected.keywords {
            let actualKeywords = actual.keywords ?? []
            if actualKeywords != keywords {
                throw SidecarXMPError.verificationFailed(
                    xmpPath: xmpPath, field: .keywords,
                    expected: describeList(keywords), actual: describeList(actualKeywords))
            }
        }
        if let rating = expected.rating {
            if actual.rating != rating {
                throw SidecarXMPError.verificationFailed(
                    xmpPath: xmpPath, field: .rating,
                    expected: String(rating), actual: actual.rating.map { String($0) } ?? "nil")
            }
        }
        if let label = expected.label {
            let actualLabel = actual.label ?? ""
            if actualLabel != label {
                throw SidecarXMPError.verificationFailed(
                    xmpPath: xmpPath, field: .label, expected: label, actual: actualLabel)
            }
        }
        // P1 / E：triage 信号必须落盘（空串 = 清除，读回 nil）。
        if let signal = expected.triageSignal {
            let normalized = signal.isEmpty ? nil : signal
            if actual.triageSignal != normalized {
                throw SidecarXMPError.verificationFailed(
                    xmpPath: xmpPath, field: .descriptive,
                    expected: normalized ?? "nil", actual: actual.triageSignal ?? "nil")
            }
        }
        // P1 / IPTC：逐字段校验（只校验被显式设置的字段；清空的字段期望读到 nil）。
        if let descriptive = expected.descriptive, !descriptive.isEmpty {
            let actualDescriptive = actual.descriptive ?? DescriptiveMetadata()
            for field in descriptive.explicitlySetFields {
                // 清空语义 + 读侧 trim：比较前用同一口径归一化，否则首尾空白
                // 会造成"写成功却抛 verificationFailed"。
                let normalizedExpected = normalizedValue(descriptive.value(for: field))
                let normalizedActual = normalizedValue(actualDescriptive.value(for: field))
                if normalizedExpected != normalizedActual {
                    throw SidecarXMPError.verificationFailed(
                        xmpPath: xmpPath, field: .descriptive,
                        expected: describe(normalizedExpected), actual: describe(normalizedActual))
                }
            }
        }
    }

    /// 读侧 trim + 丢空列表项；写入校验必须用同一口径。
    static func normalizedValue(_ value: XMPFieldValue?) -> XMPFieldValue? {
        switch value {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        case .list(let values):
            let items = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return items.isEmpty ? nil : .list(items)
        case .contact(let contact):
            return contact.isEmpty ? nil : .contact(contact)
        case .none:
            return nil
        }
    }

    /// 校验失败的诊断文本（值形状不同也要稳定可比）。
    private static func describe(_ value: XMPFieldValue?) -> String {
        switch value {
        case .text(let text): return text
        case .list(let values): return "[" + values.joined(separator: ",") + "]"
        case .contact: return "<contact>"
        case .none: return "nil"
        }
    }

    private static func describeList(_ values: [String]) -> String {
        "[" + values.joined(separator: ",") + "]"
    }

    /// 对原始文档文本做四字段补丁（其余内容逐字节保留）。insert-or-replace。
    static func patchDocument(
        _ xml: String,
        attributes: MetadataWriteAttributes,
        xmpPath: String
    ) throws -> String {
        // 前缀归一化：外部工具把已知命名空间绑到别名前缀时，下面的"按 qname 查找/替换"
        // 会找不到既有元素并插入第二个同属性元素（XMP 重复属性）。先统一成规范前缀；
        // 归一化会引入原文档没有声明的规范前缀，一并交给 injectNamespaces 补上。
        let normalized = Self.normalizeKnownPrefixes(xml)
        var parts = try splitDescription(normalized.text, xmpPath: xmpPath)
        var insertions: [String] = []
        var prefixes: [(String, String)] = normalized.introduced

        if let keywords = attributes.keywords {
            prefixes.append(("dc", dcNamespace))
            prefixes.append(("rdf", rdfNamespace))
            // 关键词是结构值，属性形式非法；先清掉任何属性形式残留。
            parts.openTag = removeAttribute(parts.openTag, name: "dc:subject")
            let element = subjectElement(keywords)
            if let replaced = replaceElement(parts.inner, name: "dc:subject", with: element) {
                parts.inner = replaced
            } else {
                insertions.append(element)
            }
        }

        if let rating = attributes.rating {
            prefixes.append(("xmp", xmpNamespace))
            parts.openTag = removeAttribute(parts.openTag, name: "xmp:Rating")
            let element = simpleElement("xmp:Rating", value: String(rating))
            if let replaced = replaceElement(parts.inner, name: "xmp:Rating", with: element) {
                parts.inner = replaced
            } else {
                insertions.append(element)
            }
        }

        if let label = attributes.label {
            prefixes.append(("xmp", xmpNamespace))
            prefixes.append(("photoshop", photoshopNamespace))
            parts.openTag = removeAttribute(parts.openTag, name: "xmp:Label")
            parts.openTag = removeAttribute(parts.openTag, name: "photoshop:Urgency")
            let labelElement = simpleElement("xmp:Label", value: label)
            if let replaced = replaceElement(parts.inner, name: "xmp:Label", with: labelElement) {
                parts.inner = replaced
            } else {
                insertions.append(labelElement)
            }
            if let urgency = c1ColorLabelUrgency(label) {
                let urgencyElement = simpleElement("photoshop:Urgency", value: String(urgency))
                // Urgency 与 Label 同为 rdf:Description 的子元素（兄弟），绝不嵌套进 Label。
                if let replaced = replaceElement(parts.inner, name: "photoshop:Urgency", with: urgencyElement) {
                    parts.inner = replaced
                } else {
                    insertions.append(urgencyElement)
                }
            } else if let removed = replaceElement(parts.inner, name: "photoshop:Urgency", with: "") {
                parts.inner = removed
            }
        }

        // P1 / IPTC：描述性元数据（32 字段）按 descriptor 表逐字段 insert-or-replace。
        if let descriptive = attributes.descriptive, !descriptive.isEmpty {
            for patch in Self.descriptivePatches(descriptive) {
                prefixes.append((patch.prefix, patch.namespace))
                // 属性形式对结构值非法：先清残留，再替换或插入元素。
                // contact 的成员可能以 CiAdrCity/CiEmailWork 等属性挂在
                // rdf:Description 上，必须一并删除，否则旧属性会与写入的结构共存。
                parts.openTag = removeAttribute(parts.openTag, name: patch.qname)
                if patch.shape == .structure {
                    for member in DescriptiveContact.members {
                        parts.openTag = removeAttribute(parts.openTag, name: member.qname)
                    }
                }
                var replacement = patch.element ?? ""
                // rdf:Alt 是"多语言容器"：只替换/清空 x-default，保留其它语言的
                // rdf:li。整块替换会把用户/其它软件的翻译一起删掉。
                // 写入（有 altText）时保留其它语言；清空（altText == nil）时整块删除
                // —— "清空这个字段"是用户的显式动作，不能只删默认语言留个空壳。
                if patch.shape == .alt || patch.shape == .text,
                   let existing = Self.elementBlock(parts.inner, name: patch.qname),
                   patch.shape == .alt || existing.contains("<rdf:Alt") {
                    // altText == nil 是清空：mergedAltElement 会保留其它语言，
                    // 只把 x-default 置空（整块删除会让翻译与 undo 都丢）。
                    replacement = Self.mergedAltElement(
                        existing, qname: patch.qname, defaultText: patch.altText)
                }
                if let replaced = replaceElement(parts.inner, name: patch.qname, with: replacement) {
                    parts.inner = replaced
                } else if let element = patch.element, !element.isEmpty {
                    insertions.append(element)
                }
            }
        }

        // P1 / E：triage 可移植信号（私有命名空间 gather:Triage）。
        if let signal = attributes.triageSignal {
            let qname = "gather:Triage"
            prefixes.append(("gather", XMPNamespaces.gatherTriage))
            parts.openTag = removeAttribute(parts.openTag, name: qname)
            let replacement = signal.isEmpty ? "" : simpleElement(qname, value: signal)
            if let replaced = replaceElement(parts.inner, name: qname, with: replacement) {
                parts.inner = replaced
            } else if !replacement.isEmpty {
                insertions.append(replacement)
            }
        }

        if !insertions.isEmpty {
            parts.inner = appendChildren(parts.inner, insertions)
        }
        // 命名空间判定必须基于「替换后的文档」：被替换块自带的 xmlns 声明会随块一起
        // 消失，按原文判定会漏注入 → 产出未声明前缀的非法 XMP（XMLParser 不校验前缀，
        // 良构检查骗得过去）。作用域只看 rdf:Description 开标签及其未闭合祖先。
        let patched = parts.before + parts.openTag + parts.inner + parts.suffix
        return try injectNamespaces(patched, required: prefixes, xmpPath: xmpPath)
    }

    /// rdf:Description 的切分结果（before + openTag + inner + suffix 重组即原文）。
    struct DescriptionParts {
        let before: String
        var openTag: String
        var inner: String
        let suffix: String
    }

    static func splitDescription(_ xml: String, xmpPath: String) throws -> DescriptionParts {
        // 多 rdf:Description 的合法 XMP（Bridge/第三方工具常见）：先合并成单块再打补丁。
        // 旧实现直接拒绝写入，导致"部分第三方 XMP 永远不可写"（P2）。
        // 注意 contact 结构内部也有嵌套 rdf:Description，必须只数顶层块。
        if hasSecondTopLevelDescription(xml) {
            return try mergeTopLevelDescriptions(xml, xmpPath: xmpPath)
        }
        return try firstDescriptionParts(xml, xmpPath: xmpPath)
    }

    /// 合并多个顶层 rdf:Description 后返回单块结构（后续补丁只针对这一块）。
    ///
    /// 规则：
    /// - 所有块的 rdf:about 必须一致（缺省视为空）；不同 subject 直接拒绝——它们
    ///   描述的是不同资源，合并会改变语义；
    /// - 子元素按块顺序追加（同名元素保留第一个，避免旧值/新值二义）；
    /// - 开标签属性补缺（第一个块已有的属性不被后续块覆盖）。
    private static func mergeTopLevelDescriptions(
        _ xml: String, xmpPath: String
    ) throws -> DescriptionParts {
        let parts = try firstDescriptionParts(xml, xmpPath: xmpPath)
        let firstAbout = attributeValue(in: parts.openTag, name: "rdf:about") ?? ""
        var inner = parts.inner
        var openTag = parts.openTag
        var suffix = parts.suffix
        var guardCount = 0
        while let openRange = findOpenTag(suffix, name: "rdf:Description") {
            guardCount += 1
            guard guardCount <= 64 else {
                throw SidecarXMPError.documentUnsupported(
                    xmpPath: xmpPath, reason: "too many rdf:Description blocks")
            }
            guard let tagEnd = findTagEnd(suffix, from: openRange.lowerBound) else {
                throw SidecarXMPError.documentCorrupt(xmpPath: xmpPath)
            }
            let blockOpen = String(suffix[openRange.lowerBound..<tagEnd])
            let about = attributeValue(in: blockOpen, name: "rdf:about") ?? ""
            guard about == firstAbout else {
                throw SidecarXMPError.documentUnsupported(
                    xmpPath: xmpPath, reason: "multiple rdf:Description subjects")
            }
            let blockEnd: String.Index
            var blockInner = ""
            if blockOpen.hasSuffix("/>") {
                blockEnd = tagEnd
            } else {
                guard let end = matchingDescriptionEnd(suffix, from: openRange.lowerBound) else {
                    throw SidecarXMPError.documentCorrupt(xmpPath: xmpPath)
                }
                blockEnd = end
                let closing = "</rdf:Description>"
                let closeStart = suffix.index(end, offsetBy: -closing.count)
                blockInner = String(suffix[tagEnd..<closeStart])
            }
            // 同名顶层元素取第一块（避免"旧值/新值"二义）；其余元素原样保留。
            var known = Set(topLevelElements(inner).map(\.name))
            for element in topLevelElements(blockInner) where !known.contains(element.name) {
                inner += newline + element.block
                known.insert(element.name)
            }
            openTag = mergeMissingAttributes(from: blockOpen, into: openTag)
            suffix.removeSubrange(openRange.lowerBound..<blockEnd)
        }
        return DescriptionParts(
            before: parts.before, openTag: openTag, inner: inner, suffix: suffix)
    }

    /// 单块路径（原 splitDescription 主体）：定位第一块并切分 before/openTag/inner/suffix。
    private static func firstDescriptionParts(
        _ xml: String, xmpPath: String
    ) throws -> DescriptionParts {
        guard let openRange = findOpenTag(xml, name: "rdf:Description") else {
            throw SidecarXMPError.documentUnsupported(xmpPath: xmpPath, reason: "missing rdf:Description")
        }
        guard let tagEnd = findTagEnd(xml, from: openRange.lowerBound) else {
            throw SidecarXMPError.documentCorrupt(xmpPath: xmpPath)
        }
        let before = String(xml[xml.startIndex..<openRange.lowerBound])
        let rawOpenTag = String(xml[openRange.lowerBound..<tagEnd])
        let afterTag = String(xml[tagEnd...])
        if rawOpenTag.hasSuffix("/>") {
            let head = trimmingTrailingSpaces(String(rawOpenTag.dropLast(2)))
            return DescriptionParts(
                before: before, openTag: head + ">", inner: "",
                suffix: "</rdf:Description>" + afterTag)
        }
        // 必须按嵌套深度找闭合：contact 结构内部还有一层 rdf:Description，
        // 取第一个闭合会把后续新字段追加进 contact 内部（C1 顶层读不到）。
        guard let closeEnd = matchingDescriptionEnd(xml, from: openRange.lowerBound) else {
            throw SidecarXMPError.documentCorrupt(xmpPath: xmpPath)
        }
        let closing = "</rdf:Description>"
        let closeStart = xml.index(closeEnd, offsetBy: -closing.count)
        let inner = String(xml[tagEnd..<closeStart])
        let suffix = String(xml[closeStart...])
        return DescriptionParts(before: before, openTag: rawOpenTag, inner: inner, suffix: suffix)
    }

    /// 关键词元素：dc:subject / rdf:Bag / rdf:li 列表。
    private static func subjectElement(_ keywords: [String]) -> String {
        guard !keywords.isEmpty else {
            return "<dc:subject>" + newline + "  <rdf:Bag>" + newline + "  </rdf:Bag>" + newline + "</dc:subject>"
        }
        let items = keywords.map { "    <rdf:li>" + xmlEscape($0) + "</rdf:li>" }
            .joined(separator: newline)
        return "<dc:subject>" + newline + "  <rdf:Bag>" + newline + items + newline + "  </rdf:Bag>"
            + newline + "</dc:subject>"
    }

    static func simpleElement(_ name: String, value: String) -> String {
        "<" + name + ">" + xmlEscape(value) + "</" + name + ">"
    }

    /// TS: CAPTURE_ONE_LABEL_URGENCY。
    private static func c1ColorLabelUrgency(_ label: String) -> Int? {
        switch label {
        case "Red": return 1
        case "Green": return 2
        case "Blue": return 3
        case "Pink": return 4
        case "Purple": return 5
        case "Orange": return 6
        case "Yellow": return 7
        default: return nil
        }
    }

    // MARK: - 文本扫描原语（replaceElement / removeAttribute / ensureNamespaces）

    /// 查找 name 开标签的起始区间（要求后随空白、> 或 /）。
    private static func findOpenTag(_ text: String, name: String) -> Range<String.Index>? {
        let needle = "<" + name
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            let next = range.upperBound
            if next < text.endIndex {
                let c = text[next]
                if c.isWhitespace || c == ">" || c == "/" {
                    return range
                }
            }
            searchStart = range.upperBound
        }
        return nil
    }

    /// 标签结束位置（> 之后的下标），跳过引号内的 >。
    private static func findTagEnd(_ text: String, from index: String.Index) -> String.Index? {
        let doubleQuote = Character(UnicodeScalar(0x22)!)
        let singleQuote = Character(UnicodeScalar(0x27)!)
        var i = index
        var quote: Character?
        while i < text.endIndex {
            let c = text[i]
            if let openQuote = quote {
                if c == openQuote { quote = nil }
            } else if c == doubleQuote || c == singleQuote {
                quote = c
            } else if c == ">" {
                return text.index(after: i)
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// 读开标签上的属性值（单/双引号或无引号）。
    private static func attributeValue(in openTag: String, name: String) -> String? {
        var searchStart = openTag.startIndex
        while let range = openTag.range(of: name, range: searchStart..<openTag.endIndex) {
            let beforeOK = range.lowerBound == openTag.startIndex
                || openTag[openTag.index(before: range.lowerBound)].isWhitespace
            var index = range.upperBound
            while index < openTag.endIndex, openTag[index].isWhitespace {
                index = openTag.index(after: index)
            }
            if beforeOK, index < openTag.endIndex, openTag[index] == "=" {
                index = openTag.index(after: index)
                while index < openTag.endIndex, openTag[index].isWhitespace {
                    index = openTag.index(after: index)
                }
                if index < openTag.endIndex, openTag[index] == "\"" || openTag[index] == "'" {
                    let quote = openTag[index]
                    index = openTag.index(after: index)
                    let start = index
                    while index < openTag.endIndex, openTag[index] != quote {
                        index = openTag.index(after: index)
                    }
                    return String(openTag[start..<index])
                }
                let start = index
                while index < openTag.endIndex,
                      !openTag[index].isWhitespace, openTag[index] != ">" {
                    index = openTag.index(after: index)
                }
                return String(openTag[start..<index])
            }
            searchStart = range.upperBound
        }
        return nil
    }

    /// 开标签上的原始属性片段（name + 原样 "name="value""，保留引号风格）。
    private static func rawAttributes(in openTag: String) -> [(name: String, raw: String)] {
        var result: [(String, String)] = []
        guard let nameEnd = openTag.firstIndex(where: {
            $0.isWhitespace || $0 == ">" || $0 == "/"
        }) else { return result }
        var index = nameEnd
        while index < openTag.endIndex {
            while index < openTag.endIndex, openTag[index].isWhitespace {
                index = openTag.index(after: index)
            }
            guard index < openTag.endIndex, openTag[index] != ">", openTag[index] != "/" else {
                break
            }
            let start = index
            while index < openTag.endIndex,
                  !openTag[index].isWhitespace, openTag[index] != "=", openTag[index] != ">" {
                index = openTag.index(after: index)
            }
            let name = String(openTag[start..<index])
            while index < openTag.endIndex, openTag[index].isWhitespace {
                index = openTag.index(after: index)
            }
            guard index < openTag.endIndex, openTag[index] == "=" else { continue }
            index = openTag.index(after: index)
            while index < openTag.endIndex, openTag[index].isWhitespace {
                index = openTag.index(after: index)
            }
            if index < openTag.endIndex, openTag[index] == "\"" || openTag[index] == "'" {
                let quote = openTag[index]
                index = openTag.index(after: index)
                while index < openTag.endIndex, openTag[index] != quote {
                    index = openTag.index(after: index)
                }
                if index < openTag.endIndex { index = openTag.index(after: index) }
            } else {
                while index < openTag.endIndex,
                      !openTag[index].isWhitespace, openTag[index] != ">" {
                    index = openTag.index(after: index)
                }
            }
            result.append((name, String(openTag[start..<index])))
        }
        return result
    }

    /// XML 标签名（去 <、</、属性与收尾符号）。
    private static func tagName(_ tag: String) -> String {
        var text = tag
        if text.hasPrefix("</") { text = String(text.dropFirst(2)) }
        else if text.hasPrefix("<") { text = String(text.dropFirst()) }
        if text.hasSuffix("/>") { text = String(text.dropLast(2)) }
        else if text.hasSuffix(">") { text = String(text.dropLast()) }
        let name = text.prefix { !$0.isWhitespace && $0 != "/" }
        return String(name)
    }

    /// 直接子元素列表（name + 原文块）。用于合并多块时做"同名取第一份"。
    private static func topLevelElements(_ text: String) -> [(name: String, block: String)] {
        var result: [(String, String)] = []
        var stack: [String] = []
        var start: String.Index?
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "<"),
              let end = findTagEnd(text, from: open) {
            let tag = String(text[open..<end])
            if tag.hasPrefix("<?") || tag.hasPrefix("<!") {
                index = end
                continue
            }
            let isClosing = tag.hasPrefix("</")
            let selfClosing = tag.hasSuffix("/>")
            let name = tagName(tag)
            if isClosing {
                if stack.last == name { stack.removeLast() }
                if stack.isEmpty, let elementStart = start {
                    result.append((name, String(text[elementStart..<end])))
                    start = nil
                }
            } else if selfClosing {
                if stack.isEmpty { result.append((name, String(text[open..<end]))) }
            } else {
                if stack.isEmpty { start = open }
                stack.append(name)
            }
            index = end
        }
        return result
    }

    /// 把后续块的属性补进第一块（同名属性保留第一块的值）。
    private static func mergeMissingAttributes(from blockOpen: String, into openTag: String) -> String {
        var additions = ""
        for attribute in rawAttributes(in: blockOpen)
        where attributeValue(in: openTag, name: attribute.name) == nil {
            additions += " " + attribute.raw
        }
        guard !additions.isEmpty, let close = openTag.lastIndex(of: ">") else { return openTag }
        var head = String(openTag[openTag.startIndex..<close])
        let selfClosing = head.hasSuffix("/")
        if selfClosing { head.removeLast() }
        while head.hasSuffix(" ") || head.hasSuffix("\n") { head.removeLast() }
        return head + additions + ">"
    }

    /// 是否存在第二个顶层 rdf:Description（嵌套结构块不算）。
    private static func hasSecondTopLevelDescription(_ xml: String) -> Bool {
        guard let first = findOpenTag(xml, name: "rdf:Description"),
              let end = matchingDescriptionEnd(xml, from: first.lowerBound)
        else { return false }
        return xml.range(of: "<rdf:Description", range: end..<xml.endIndex) != nil
    }

    /// 从第一个 rdf:Description 开标签起，按标签嵌套深度找到它的闭合位置。
    private static func matchingDescriptionEnd(
        _ xml: String, from start: String.Index
    ) -> String.Index? {
        var index = start
        var depth = 0
        while index < xml.endIndex {
            guard let open = xml[index...].firstIndex(of: "<"),
                  let end = findTagEnd(xml, from: open) else { return nil }
            let tag = String(xml[open..<end])
            let selfClosing = tag.hasSuffix("/>")
            if tag.hasPrefix("</rdf:Description") {
                depth -= 1
                if depth == 0 { return end }
            } else if tag.hasPrefix("<rdf:Description") {
                if selfClosing, depth == 0 { return end }
                if !selfClosing { depth += 1 }
            }
            index = end
        }
        return nil
    }

    /// 取出 name 元素块原文（含起止标签）；未命中返回 nil。
    static func elementBlock(_ text: String, name: String) -> String? {
        guard let openRange = findOpenTag(text, name: name) else { return nil }
        guard let tagEnd = findTagEnd(text, from: openRange.lowerBound) else { return nil }
        if text[openRange.lowerBound..<tagEnd].hasSuffix("/>") {
            return String(text[openRange.lowerBound..<tagEnd])
        }
        guard let closeRange = text.range(of: "</" + name + ">", range: tagEnd..<text.endIndex) else {
            return nil
        }
        return String(text[openRange.lowerBound..<closeRange.upperBound])
    }

    /// 元素级 replace：命中 name 元素块时整块替换为 replacement（空串即删除）；
    /// 未命中返回 nil，由调用方决定插入。
    static func replaceElement(_ text: String, name: String, with replacement: String) -> String? {
        guard let openRange = findOpenTag(text, name: name) else { return nil }
        guard let tagEnd = findTagEnd(text, from: openRange.lowerBound) else { return nil }
        let selfClosing = text[openRange.lowerBound..<tagEnd].hasSuffix("/>")
        if selfClosing {
            return text.replacingCharacters(in: openRange.lowerBound..<tagEnd, with: replacement)
        }
        guard let closeRange = text.range(of: "</" + name + ">", range: tagEnd..<text.endIndex) else {
            return nil
        }
        return text.replacingCharacters(in: openRange.lowerBound..<closeRange.upperBound, with: replacement)
    }

    /// 删除开标签上的属性（含其值）；不存在时原样返回。属性形式的 XMP 在此被规整掉。
    static func removeAttribute(_ tag: String, name: String) -> String {
        guard tag.hasPrefix("<"), tag.hasSuffix(">") else { return tag }
        var content = String(tag[tag.startIndex..<tag.index(before: tag.endIndex)])
        while let range = findAttribute(content, name: name) {
            content.removeSubrange(range)
        }
        return content + ">"
    }

    /// 定位 name = "value" 属性块的区间（从属性名开始，含尾随空白）。
    /// 扫描时跟踪引号上下文：属性值内部的同名子串绝不误删。
    private static func findAttribute(_ text: String, name: String) -> Range<String.Index>? {
        let doubleQuote = Character(UnicodeScalar(0x22)!)
        let singleQuote = Character(UnicodeScalar(0x27)!)
        var i = text.startIndex
        var quote: Character?
        while i < text.endIndex {
            let c = text[i]
            if let openQuote = quote {
                if c == openQuote { quote = nil }
                i = text.index(after: i)
                continue
            }
            if c == doubleQuote || c == singleQuote {
                quote = c
                i = text.index(after: i)
                continue
            }
            let isBoundary = i == text.startIndex
                || text[text.index(before: i)].isWhitespace
                || text[text.index(before: i)] == "<"
            if isBoundary,
               let nameEnd = text.index(i, offsetBy: name.count, limitedBy: text.endIndex),
               String(text[i..<nameEnd]) == name {
                var j = nameEnd
                while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
                if j < text.endIndex, text[j] == "=" {
                    j = text.index(after: j)
                    while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
                    if j < text.endIndex, text[j] == doubleQuote || text[j] == singleQuote {
                        let valueQuote = text[j]
                        var k = text.index(after: j)
                        while k < text.endIndex, text[k] != valueQuote { k = text.index(after: k) }
                        if k < text.endIndex { k = text.index(after: k) }
                        while k < text.endIndex, text[k].isWhitespace { k = text.index(after: k) }
                        return i..<k
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func trimmingTrailingSpaces(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            if text[prev].isWhitespace { end = prev } else { break }
        }
        return String(text[text.startIndex..<end])
    }

    /// 在 rdf:Description 开标签上补齐缺失的命名空间声明。
    /// 「缺失」= 进入该元素时不在作用域内（openTag 自身声明 ∪ 未闭合祖先的声明）。
    /// 注：随块消失的声明、以及只在已闭合兄弟元素上声明过的前缀都会被重新注入；
    /// 冗余声明是合法 XML，正确性优先。
    static func injectNamespaces(
        _ document: String,
        required: [(String, String)],
        xmpPath: String
    ) throws -> String {
        guard let openRange = findOpenTag(document, name: "rdf:Description"),
              let tagEnd = findTagEnd(document, from: openRange.lowerBound) else {
            throw SidecarXMPError.documentUnsupported(xmpPath: xmpPath, reason: "missing rdf:Description")
        }
        let before = String(document[document.startIndex..<openRange.lowerBound])
        var openTag = String(document[openRange.lowerBound..<tagEnd])
        var inScope = inScopePrefixes(before: before, openTag: openTag)
        var injections: [String] = []
        for (prefix, uri) in required where !inScope.contains(prefix) {
            inScope.insert(prefix)
            injections.append("xmlns:" + prefix + "=\"" + uri + "\"")
        }
        guard !injections.isEmpty else { return document }
        let isSelfClosing = openTag.hasSuffix("/>")
        let head = isSelfClosing
            ? trimmingTrailingSpaces(String(openTag.dropLast(2)))
            : trimmingTrailingSpaces(String(openTag.dropLast(1)))
        openTag = head + " " + injections.joined(separator: " ") + (isSelfClosing ? "/>" : ">")
        return before + openTag + String(document[tagEnd...])
    }

    /// 进入 (before 之后的第一个) 元素内部时作用域内的命名空间前缀。
    private static func inScopePrefixes(before: String, openTag: String) -> Set<String> {
        var stack: [Set<String>] = []
        scanTags(before) { tag in applyNamespaceTag(tag, stack: &stack) }
        var scope = Set(["xml"])
        for declarations in stack { scope.formUnion(declarations) }
        scope.formUnion(declarations(in: openTag))
        return scope
    }

    /// 写盘前的命名空间合法性校验：所有使用到的前缀必须在作用域内有声明。
    /// 良构 ≠ 命名空间合法（XMLParser 默认不解析前缀），因此必须显式校验。
    static func assertNamespacePrefixes(_ xml: String, xmpPath: String) throws {
        var stack: [Set<String>] = []
        var failure: String?
        scanTags(xml) { tag in
            guard failure == nil else { return }
            let own = declarations(in: tag)
            var scope = Set(["xml"])
            for declarations in stack { scope.formUnion(declarations) }
            scope.formUnion(own)
            for prefix in tagPrefixes(in: tag) where !scope.contains(prefix) {
                failure = prefix
            }
            applyNamespaceTag(tag, stack: &stack)
        }
        if let failure {
            throw SidecarXMPError.documentUnsupported(
                xmpPath: xmpPath, reason: "undeclared namespace prefix '" + failure + "'")
        }
    }

    /// 顺序遍历文档中的所有标签（跳过注释 / PI / DTD）。
    private static func scanTags(_ text: String, _ body: (String) -> Void) {
        var index = text.startIndex
        while index < text.endIndex, let lt = text[index...].firstIndex(of: "<") {
            guard let gt = findTagEnd(text, from: lt) else { return }
            let tag = String(text[lt..<gt])
            if !tag.hasPrefix("<!--"), !tag.hasPrefix("<?"), !tag.hasPrefix("<!") {
                body(tag)
            }
            index = gt
        }
    }

    /// 标签上的 xmlns 声明（含默认命名空间不计入前缀，但记录 xmlns: 前缀）。
    private static func declarations(in tag: String) -> Set<String> {
        var result: Set<String> = []
        for name in attributeNames(in: tag) where name.hasPrefix("xmlns:") {
            result.insert(String(name.dropFirst("xmlns:".count)))
        }
        return result
    }

    /// 标签名与属性名使用到的前缀（排除 xmlns / xml）。
    private static func tagPrefixes(in tag: String) -> Set<String> {
        var result: Set<String> = []
        func collect(_ name: String) {
            guard let colon = name.firstIndex(of: ":") else { return }
            let prefix = String(name[name.startIndex..<colon])
            if prefix != "xmlns", prefix != "xml" { result.insert(prefix) }
        }
        collect(elementName(in: tag))
        for name in attributeNames(in: tag) { collect(name) }
        return result
    }

    private static func elementName(in tag: String) -> String {
        var start = tag.index(after: tag.startIndex)
        if start < tag.endIndex, tag[start] == "/" { start = tag.index(after: start) }
        var end = start
        while end < tag.endIndex, !tag[end].isWhitespace, tag[end] != ">", tag[end] != "/" {
            end = tag.index(after: end)
        }
        return String(tag[start..<end])
    }

    private static func attributeNames(in tag: String) -> [String] {
        var names: [String] = []
        var i = tag.index(after: tag.startIndex)
        if i < tag.endIndex, tag[i] == "/" { i = tag.index(after: i) }
        // 跳过元素名
        while i < tag.endIndex, !tag[i].isWhitespace, tag[i] != ">", tag[i] != "/" {
            i = tag.index(after: i)
        }
        while i < tag.endIndex {
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard i < tag.endIndex, tag[i] != ">", tag[i] != "/" else { break }
            var end = i
            while end < tag.endIndex, !tag[end].isWhitespace, tag[end] != "=", tag[end] != ">", tag[end] != "/" {
                end = tag.index(after: end)
            }
            names.append(String(tag[i..<end]))
            i = end
            // 跳到属性值末尾
            while i < tag.endIndex, tag[i] != ">" {
                if tag[i] == "=" {
                    i = tag.index(after: i)
                    while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
                    if i < tag.endIndex, tag[i] == Character(UnicodeScalar(0x22)!) || tag[i] == "'" {
                        let quote = tag[i]
                        i = tag.index(after: i)
                        while i < tag.endIndex, tag[i] != quote { i = tag.index(after: i) }
                        if i < tag.endIndex { i = tag.index(after: i) }
                    }
                    break
                }
                i = tag.index(after: i)
            }
        }
        return names
    }

    /// 维护未闭合元素栈（自闭合不压栈，闭合标签弹栈）。
    private static func applyNamespaceTag(_ tag: String, stack: inout [Set<String>]) {
        if tag.hasPrefix("</") {
            if !stack.isEmpty { stack.removeLast() }
            return
        }
        if tag.hasSuffix("/>") { return }
        stack.append(declarations(in: tag))
    }

    /// 把新元素追加到 rdf:Description 内容的末尾（保留闭合标签缩进）。
    static func appendChildren(_ inner: String, _ children: [String]) -> String {
        var body = inner
        var closeIndent = ""
        if let lastNewline = body.lastIndex(of: "\n") {
            let tail = String(body[body.index(after: lastNewline)...])
            if tail.allSatisfy({ $0.isWhitespace }) {
                closeIndent = tail
                body = String(body[body.startIndex..<lastNewline])
            }
        }
        let childIndent = closeIndent + "  "
        let rendered = children.map { childIndent + $0 }.joined(separator: newline)
        if body.isEmpty { return newline + rendered + newline + closeIndent }
        return body + newline + rendered + newline + closeIndent
    }

    // MARK: - 原子落盘

    static func writeAtomic(xmpPath: String, content: String) throws {
        let tempPath = xmpPath + ".tmp-\(ProcessInfo.processInfo.processIdentifier)-"
            + UUID().uuidString.lowercased()
        do {
            try content.write(toFile: tempPath, atomically: false, encoding: .utf8)
            try install(tempPath: tempPath, at: xmpPath)
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw SidecarXMPError.writeFailed(xmpPath: xmpPath, reason: String(describing: error))
        }
    }

    /// 目标存在 → 原子替换；目标不存在 → move（旧实现无条件 replaceItemAt 会抛）。
    static func install(tempPath: String, at xmpPath: String) throws {
        if FileManager.default.fileExists(atPath: xmpPath) {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: xmpPath),
                withItemAt: URL(fileURLWithPath: tempPath)
            )
        } else {
            try FileManager.default.moveItem(atPath: tempPath, toPath: xmpPath)
        }
    }

    /// TS xmp-utils INVALID_XML_TEXT 过滤 + XML 转义。
    static func xmlEscape(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D {
                continue
            }
            switch scalar.value {
            case 0x26: escaped += "&amp;"
            case 0x3C: escaped += "&lt;"
            case 0x3E: escaped += "&gt;"
            case 0x22: escaped += "&quot;"
            case 0x27: escaped += "&apos;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
