// desktop/native/gather-app/Sources/GatherHost/SidecarXMPProvider.swift
// XMP 侧车（<photo>.xmp）宿主读写实现 —— R4 全量重写。
//
// 与旧实现（replaceElementBlock / insertElement 版）的语义差异，逐条固定为契约：
// 1. 补丁器 insert-or-replace：dc:subject / xmp:Rating / xmp:Label 缺失时插入到
//    rdf:Description 内，并在 rdf:Description 开标签上补齐缺失的命名空间声明
//    （dc/xmp/photoshop；rdf 仅在整份文档都未声明时补）。未命中不再静默返回原文，
//    无法定位 rdf:Description 时抛类型化 documentUnsupported。
// 2. photoshop:Urgency 永远是 rdf:Description 的子元素（与 xmp:Label 同级），
//    绝不出现在 xmp:Label 的文本内部；label 无 C1 映射时删除旧 Urgency。
// 3. 支持属性形式的 XMP（rdf:Description 上直接挂 xmp:Rating="5" xmp:Label="Green"）：
//    读取识别属性形式，写入删除该属性并落为元素形式。
// 4. 写入后重读校验目标字段真的落盘；不一致抛类型化
//    SidecarXMPError.verificationFailed（携带 xmpPath 与字段名），不再用 NSError 散文。
// 5. 侧车路径大小写回退：磁盘上是 photo.XMP 时读写 photo.XMP，绝不另建 photo.xmp。
// 6. 原子写：临时文件 + replace（目标不存在时 move）；目标不存在也能落盘。
// 7. 未知命名空间与未知字段逐字节保留：只改本宿主拥有的四个字段。
// 8. 读取优先级（本 provider 的契约）：侧车文件是本 provider 的唯一读取来源；
//    内嵌 XMP 与侧车的合并由 GatherCore.MetadataService 负责（侧车覆盖内嵌）。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery

/// 类型化错误：code 是稳定错误码（可直接作错误载荷，对齐 ADR-016/017），
/// 结构化字段（xmpPath / 字段 / 原因）经 associated value 暴露给报告卡。
public enum SidecarXMPError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case documentCorrupt(xmpPath: String)
    case documentUnsupported(xmpPath: String, reason: String)
    case readFailed(xmpPath: String, reason: String)
    case writeFailed(xmpPath: String, reason: String)
    case backupMissing(path: String)
    case backupFailed(xmpPath: String, reason: String)
    case restoreFailed(xmpPath: String, backupPath: String, reason: String)
    case verificationFailed(xmpPath: String, field: MetadataField, expected: String, actual: String)

    /// 稳定错误码。XMP_BACKUP_MISSING 复用 GatherErrorCode 既有码。
    public var code: String {
        switch self {
        case .documentCorrupt: "XMP_DOCUMENT_CORRUPT"
        case .documentUnsupported: "XMP_DOCUMENT_UNSUPPORTED"
        case .readFailed: "XMP_DOCUMENT_READ_FAILED"
        case .writeFailed: "XMP_WRITE_FAILED"
        case .backupMissing: "XMP_BACKUP_MISSING"
        case .backupFailed: "XMP_BACKUP_FAILED"
        case .restoreFailed: "XMP_RESTORE_FAILED"
        case .verificationFailed: "XMP_WRITE_VERIFICATION_FAILED"
        }
    }

    /// 错误涉及的侧车路径（报告卡结构化字段）。
    public var xmpPath: String {
        switch self {
        case .documentCorrupt(let path), .documentUnsupported(let path, _), .readFailed(let path, _),
             .writeFailed(let path, _), .backupFailed(let path, _), .verificationFailed(let path, _, _, _):
            return path
        case .backupMissing(let path):
            return path
        case .restoreFailed(let path, _, _):
            return path
        }
    }

    public var description: String {
        switch self {
        case .documentCorrupt(let path):
            "XMP_DOCUMENT_CORRUPT: " + path
        case .documentUnsupported(let path, let reason):
            "XMP_DOCUMENT_UNSUPPORTED: " + path + " reason=" + reason
        case .readFailed(let path, let reason):
            "XMP_DOCUMENT_READ_FAILED: " + path + " reason=" + reason
        case .writeFailed(let path, let reason):
            "XMP_WRITE_FAILED: " + path + " reason=" + reason
        case .backupMissing(let path):
            "XMP_BACKUP_MISSING: " + path
        case .backupFailed(let path, let reason):
            "XMP_BACKUP_FAILED: " + path + " reason=" + reason
        case .restoreFailed(let path, let backupPath, let reason):
            "XMP_RESTORE_FAILED: " + path + " backup=" + backupPath + " reason=" + reason
        case .verificationFailed(let path, let field, let expected, let actual):
            "XMP_WRITE_VERIFICATION_FAILED: " + path + " field=" + field.rawValue
                + " expected=" + expected + " actual=" + actual
        }
    }

    public var errorDescription: String? { description }
}

/// 让内核（MetadataSyncCoordinator）能结构化落库本 provider 的错误码、路径与字段。
extension SidecarXMPError: MetadataCodedError {
    /// 字段级失败（写后校验不通过）暴露结构化字段名；其余为整文档级失败。
    public var field: String? {
        if case .verificationFailed(_, let field, _, _) = self { return field.rawValue }
        return nil
    }
}

/// XMP 侧车（photoPath 同名 .xmp）的宿主读写实现。
public final class SidecarXMPProvider: XMPProvider {
    /// 故障注入点（测试专用）：写盘前对补丁结果做一次变换，用于构造「盘上没生效」的
    /// 写入器以验证写后校验路径。生产构造不传即 nil；校验本身不可关闭。
    private let writeTransform: (@Sendable (String) -> String)?

    public init(writeTransform: (@Sendable (String) -> String)? = nil) {
        self.writeTransform = writeTransform
    }

    // MARK: - XMPProvider（读取）

    public func readKeywords(photoPath: String) async throws -> [String] {
        try readSidecar(photoPath).keywords
    }

    public func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        let parsed = try readSidecar(photoPath)
        return MetadataWriteAttributes(
            keywords: parsed.keywords.isEmpty ? nil : parsed.keywords,
            rating: parsed.rating,
            label: parsed.resolvedLabel,
            dateTaken: parsed.dateTaken,
            latitude: parsed.latitude,
            longitude: parsed.longitude
        )
    }

    // MARK: - XMPProvider（写入）

    /// 并发契约（明确且不可违反）：**同一侧车路径的 write/backup/restore 必须由调用方串行**。
    ///
    /// 为什么不在 provider 内加锁：锁只能约束本进程，而侧车同时被外部软件（Capture One /
    /// Bridge）改写，跨进程互斥本就无法用进程内锁解决；加锁还会掩盖调用方违约（两个并发
    /// 写各自 read-modify-write，后写覆盖先写，静默丢更新）。
    ///
    /// 本仓库的保证链（构造上串行）：
    /// 1. 内核按归一化路径单飞：MetadataSyncCoordinator 的 active 表 + claim 租约（同一
    ///    xmpPath 同时只有一个 writing 行）。
    /// 2. 变更入队：MetadataMutationService 的 actor PathSerialChain 按同一归一化路径串行
    ///    "读当前文件 → 合并 → 入队"。
    /// 3. 写并发上限 2（SlotGate）只跨路径，不跨同一路径。
    /// 因此生产路径不存在两个并发写同一侧车；外部软件并发由租约 + 指纹冲突检测兜底
    /// （写前比对 base_fingerprint，冲突转 conflict 交用户裁决，绝不静默覆盖）。
    public func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        // 没有任何目标字段：不改写、也不创建空侧车（消灭旧的「写空文档报成功」）。
        guard !attributes.isEmpty else { return }
        let xmpPath = Self.resolveSidecarPath(photoPath)
        let document: String
        if FileManager.default.fileExists(atPath: xmpPath) {
            guard let existing = try? String(contentsOfFile: xmpPath, encoding: .utf8) else {
                throw SidecarXMPError.readFailed(xmpPath: xmpPath, reason: "utf8 decode failed")
            }
            try Self.assertWellFormed(existing, xmpPath: xmpPath)
            document = existing
        } else {
            document = Self.emptyXmpDoc
        }
        var patched = try Self.patchDocument(document, attributes: attributes, xmpPath: xmpPath)
        if let writeTransform { patched = writeTransform(patched) }
        // 补丁产物必须是良构 XML：宁可失败也绝不把损坏文档写盘。
        do {
            try Self.assertWellFormed(patched, xmpPath: xmpPath)
        } catch {
            throw SidecarXMPError.documentUnsupported(xmpPath: xmpPath, reason: "patched document is not well-formed")
        }
        // 良构 ≠ 命名空间合法：所有使用到的前缀都必须有作用域内声明。
        try Self.assertNamespacePrefixes(patched, xmpPath: xmpPath)
        try Self.writeAtomic(xmpPath: xmpPath, content: patched)
        // 写后校验：重新从盘上读取，目标字段必须真的生效。
        let actual = try await readAttributes(photoPath: photoPath)
        try Self.verify(xmpPath: xmpPath, expected: attributes, actual: actual)
    }

    // MARK: - XMPProvider（备份 / 恢复 / 存在性 / 删除）

    public func backup(photoPath: String) async throws -> String {
        let xmpPath = Self.resolveSidecarPath(photoPath)
        guard FileManager.default.fileExists(atPath: xmpPath) else { return "" }
        let backupPath = xmpPath + ".gather-backup-" + UUID().uuidString.lowercased()
        do {
            try FileManager.default.copyItem(atPath: xmpPath, toPath: backupPath)
        } catch {
            throw SidecarXMPError.backupFailed(xmpPath: xmpPath, reason: String(describing: error))
        }
        return backupPath
    }

    public func restore(photoPath: String, backupPath: String) async throws {
        let xmpPath = Self.resolveSidecarPath(photoPath)
        guard FileManager.default.fileExists(atPath: backupPath) else {
            throw SidecarXMPError.backupMissing(path: backupPath)
        }
        let tempPath = xmpPath + ".restore-\(ProcessInfo.processInfo.processIdentifier)-"
            + UUID().uuidString.lowercased()
        do {
            try FileManager.default.copyItem(atPath: backupPath, toPath: tempPath)
            try Self.install(tempPath: tempPath, at: xmpPath)
            // 刻意不删除备份：restore 必须是幂等的拷贝语义，否则"恢复成功后删行失败"
            // 会让行永久 backupMissing。备份文件由内核在事务行删除成功后清理。
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw SidecarXMPError.restoreFailed(
                xmpPath: xmpPath, backupPath: backupPath, reason: String(describing: error))
        }
    }

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func removeFile(_ path: String) async throws {
        try FileManager.default.removeItem(atPath: path)
    }

    // MARK: - 路径解析（大小写回退）

    /// 侧车的实际路径：优先返回磁盘上真实存在的条目（photo.XMP → photo.XMP），
    /// 找不到时才使用规范的 .xmp 小写路径（新建侧车）。
    static func resolveSidecarPath(_ photoPath: String) -> String {
        let canonical = TSPath.xmpSidecarPath(photoPath)
        let url = URL(fileURLWithPath: canonical)
        let directory = url.deletingLastPathComponent().path
        let target = url.lastPathComponent.lowercased()
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) {
            for entry in entries where entry.lowercased() == target {
                return (directory as NSString).appendingPathComponent(entry)
            }
        }
        return canonical
    }

    // MARK: - 读取实现

    /// XML 元素文本收集（对齐 TS extractKeywords/extractXmpAttributes 的取值）。
    fileprivate struct ParsedSidecar {
        var keywords: [String] = []
        var rating: Double?
        var label: String?
        var urgency: Double?
        var dateTaken: String?
        var latitude: Double?
        var longitude: Double?

        /// TS: CAPTURE_ONE_URGENCY_LABEL（urgency → color label）。
        var resolvedLabel: String? {
            if let label, !label.isEmpty { return label }
            guard let urgency else { return nil }
            switch urgency {
            case 1: return "Red"
            case 2: return "Green"
            case 3: return "Blue"
            case 4: return "Pink"
            case 5: return "Purple"
            case 6: return "Orange"
            case 7: return "Yellow"
            default: return nil
            }
        }
    }

    private func readSidecar(_ photoPath: String) throws -> ParsedSidecar {
        let path = Self.resolveSidecarPath(photoPath)
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path)
        else { return ParsedSidecar() }
        let parser = XMLParser(data: data)
        let delegate = SidecarXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            // 损坏 sidecar：readAttributes 语义为 corrupt 视为空（调用方
            // preserveValuesOnCorruptSidecar 的判别依据），不抛错；写入路径则抛。
            return ParsedSidecar()
        }
        return delegate.result
    }

    private static func assertWellFormed(_ text: String, xmpPath: String) throws {
        let parser = XMLParser(data: Data(text.utf8))
        let delegate = SidecarXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else { throw SidecarXMPError.documentCorrupt(xmpPath: xmpPath) }
    }

    // MARK: - 写入实现

    private static let newline = String(UnicodeScalar(10)!)

    /// 最小 XMP 骨架：xmpmeta / rdf:RDF / rdf:Description 与三个命名空间齐全。
    private static let emptyXmpDoc = """
    <?xml version="1.0" encoding="UTF-8"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
        </rdf:Description>
      </rdf:RDF>
    </x:xmpmeta>
    """

    private static let dcNamespace = "http://purl.org/dc/elements/1.1/"
    private static let xmpNamespace = "http://ns.adobe.com/xap/1.0/"
    private static let photoshopNamespace = "http://ns.adobe.com/photoshop/1.0/"
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    /// 写后校验：目标字段必须与期望一致（label 的 "" 与 nil 等价）。
    private static func verify(
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
    private static func patchDocument(
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
    private static func assertNamespacePrefixes(_ xml: String, xmpPath: String) throws {
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

    private static func writeAtomic(xmpPath: String, content: String) throws {
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
    private static func install(tempPath: String, at xmpPath: String) throws {
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

/// SAX 收集器：收集本宿主关心的字段。支持元素形式与 rdf:Description 属性形式。
private final class SidecarXMLDelegate: NSObject, XMLParserDelegate {
    private static let elementNames: Set<String> = [
        "xmp:Rating", "xmp:Label", "photoshop:Urgency",
        "exif:DateTimeOriginal", "exif:GPSLatitude", "exif:GPSLongitude",
    ]

    private var subjectDepth = 0
    private var listDepth = 0
    private var currentElement: String?
    private var currentText = ""
    private(set) var result = SidecarXMPProvider.ParsedSidecar()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        if name == "rdf:Description" {
            applyDescriptionAttributes(attributeDict)
            return
        }
        switch name {
        case "dc:subject":
            subjectDepth += 1
        case "rdf:Bag", "rdf:Seq":
            if subjectDepth > 0 { listDepth += 1 }
        default:
            if subjectDepth > 0 && listDepth > 0 && name == "rdf:li" {
                currentElement = "rdf:li"
                currentText = ""
            } else if Self.elementNames.contains(name) {
                currentElement = name
                currentText = ""
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement != nil { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        if name == "dc:subject" { subjectDepth = max(0, subjectDepth - 1) }
        if name == "rdf:Bag" || name == "rdf:Seq" { listDepth = max(0, listDepth - 1) }
        let element = currentElement
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        currentElement = nil
        currentText = ""
        switch element {
        case "rdf:li":
            if !text.isEmpty { result.keywords.append(text) }
        case "xmp:Rating":
            if let parsed = Double(text) { result.rating = parsed }
        case "xmp:Label":
            result.label = text
        case "photoshop:Urgency":
            if let parsed = Double(text) { result.urgency = parsed }
        case "exif:DateTimeOriginal":
            if !text.isEmpty { result.dateTaken = text }
        case "exif:GPSLatitude":
            if let parsed = parseGpsCoordinate(text) { result.latitude = parsed }
        case "exif:GPSLongitude":
            if let parsed = parseGpsCoordinate(text) { result.longitude = parsed }
        default:
            break
        }
    }

    /// XMP 紧凑形式：属性直接挂在 rdf:Description 上。
    private func applyDescriptionAttributes(_ attributes: [String: String]) {
        for (key, value) in attributes {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "xmp:Rating":
                if let parsed = Double(text) { result.rating = parsed }
            case "xmp:Label":
                result.label = text
            case "photoshop:Urgency":
                if let parsed = Double(text) { result.urgency = parsed }
            default:
                break
            }
        }
    }
}

/// TS: parseGpsCoordinate 的最小等价（"43,30.5N" 分秒格式与纯十进制）。
private func parseGpsCoordinate(_ value: String) -> Double? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    let sign: Double = trimmed.hasSuffix("S") || trimmed.hasSuffix("W") ? -1 : 1
    let body = trimmed
        .replacingOccurrences(of: "[NSEW]$", with: "", options: .regularExpression)
        .replacingOccurrences(of: String(UnicodeScalar(0x2212)!), with: "-")
    let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    if parts.count == 1 {
        guard let decimal = Double(parts[0]) else { return nil }
        return sign * decimal
    }
    guard parts.count == 2, let degrees = Double(parts[0]), let minutes = Double(parts[1]) else {
        return nil
    }
    let decimal = degrees + minutes / 60
    // TS: 四舍五入到 6 位小数。
    return sign * (decimal * 1_000_000).rounded() / 1_000_000
}
