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
        var parts = try splitDescription(xml, xmpPath: xmpPath)
        var insertions: [String] = []
        var prefixes: [(String, String)] = []

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
    private struct DescriptionParts {
        let before: String
        var openTag: String
        var inner: String
        let suffix: String
    }

    private static func splitDescription(_ xml: String, xmpPath: String) throws -> DescriptionParts {
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
        guard let closeRange = xml.range(of: "</rdf:Description>", range: tagEnd..<xml.endIndex) else {
            throw SidecarXMPError.documentCorrupt(xmpPath: xmpPath)
        }
        let inner = String(xml[tagEnd..<closeRange.lowerBound])
        let suffix = String(xml[closeRange.lowerBound...])
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

    private static func simpleElement(_ name: String, value: String) -> String {
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

    /// 元素级 replace：命中 name 元素块时整块替换为 replacement（空串即删除）；
    /// 未命中返回 nil，由调用方决定插入。
    private static func replaceElement(_ text: String, name: String, with replacement: String) -> String? {
        guard let openRange = findOpenTag(text, name: name) else { return nil }
        guard let tagEnd = findTagEnd(text, from: openRange.lowerBound) else { return nil }
        let selfClosing = text[text.index(before: tagEnd)] == "/"
        if selfClosing {
            return text.replacingCharacters(in: openRange.lowerBound..<tagEnd, with: replacement)
        }
        guard let closeRange = text.range(of: "</" + name + ">", range: tagEnd..<text.endIndex) else {
            return nil
        }
        return text.replacingCharacters(in: openRange.lowerBound..<closeRange.upperBound, with: replacement)
    }

    /// 删除开标签上的属性（含其值）；不存在时原样返回。属性形式的 XMP 在此被规整掉。
    private static func removeAttribute(_ tag: String, name: String) -> String {
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
    private static func injectNamespaces(
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
    private static func appendChildren(_ inner: String, _ children: [String]) -> String {
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
    private static func xmlEscape(_ value: String) -> String {
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
