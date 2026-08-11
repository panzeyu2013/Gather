// desktop/native/gather-app/Sources/GatherApp/Host/SidecarXMPProvider.swift
// TS 源: desktop/src/main/services/xmp/xmp-utils.ts + xmp-sidecar-writer.ts（XMP
// 侧车读写的最小宿主实现；3.4 页面阶段的正式 exiftool/XML-DOM 桥落位前先保证
// writeback 链端到端可用）。
//
// 实现说明（与 TS 的语义对齐点 / 有意取舍）：
// - 写入采用「原文件文本逐元素补丁」而非 TS 的完整 XML DOM 重建：只替换/插入
//   本宿主拥有的三个字段（dc:subject 关键词、xmp:Rating、xmp:Label +
//   photoshop:Urgency），其余内容逐字节保留（Capture One 写入的其它命名空间
//   字段不受影响，规避 DOM 重建丢失字段的数据损失风险）。
// - 读取经 Foundation XMLParser 收集 rdf:li / xmp:Rating / xmp:Label /
//   photoshop:Urgency / exif:DateTimeOriginal / exif:GPSLatitude|Longitude，
//   语义对齐 TS extractKeywords / extractXmpAttributes（含 Urgency → C1
//   color label 回映射、Rating 数字解析）。
// - 备份/恢复/删除对齐 TS backupXmpFileAsync / restoreXmpFileAsync / unlink：
//   备份路径 `<sidecar>.gather-backup-<uuid>`，恢复后删除备份。
// - 写入失败消息格式与 TS 逐字一致（`Failed to write XMP attributes to <path>: ...`）。
import Foundation
import GatherCore

/// XMP 侧车（<photo>.xmp）的宿主读写实现。
public final class SidecarXMPProvider: XMPProvider {
    public init() {}

    private func sidecarPath(_ photoPath: String) -> String {
        TSPath.xmpSidecarPath(photoPath)
    }

    // MARK: - 读取（TS extractKeywords / extractXmpAttributes）

    public func readKeywords(photoPath: String) async throws -> [String] {
        try readSidecar(photoPath).keywords
    }

    public func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        let parsed = try readSidecar(photoPath)
        return MetadataWriteAttributes(
            keywords: parsed.keywords.isEmpty ? nil : parsed.keywords,
            rating: parsed.rating,
            label: parsed.label,
            dateTaken: parsed.dateTaken,
            latitude: parsed.latitude,
            longitude: parsed.longitude
        )
    }

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
        let path = sidecarPath(photoPath)
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path)
        else { return ParsedSidecar() }
        let parser = XMLParser(data: data)
        let delegate = SidecarXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            // 损坏 sidecar：readAttributes 语义为 corrupt 视为空（TS 调用方
            // preserveValuesOnCorruptSidecar 的判别依据），不抛错。
            return ParsedSidecar()
        }
        var result = delegate.result
        result.label = result.resolvedLabel
        return result
    }

    // MARK: - 写入（TS buildXmpAttributesXml 的字段子集）

    public func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        let path = sidecarPath(photoPath)
        do {
            var xml: String
            if FileManager.default.fileExists(atPath: path) {
                guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else {
                    throw XMPPatchError.corrupt(path)
                }
                // 与 TS 一致：已存在但解析失败的文件视为 corrupt 抛错。
                let parser = XMLParser(data: Data(existing.utf8))
                let delegate = SidecarXMLDelegate()
                parser.delegate = delegate
                guard parser.parse() else { throw XMPPatchError.corrupt(path) }
                xml = existing
            } else {
                xml = Self.emptyXmpDoc()
            }
            let patched = Self.patchDocument(xml, attributes: attributes)
            try writeAtomic(path: path, content: patched)
        } catch let error as XMPPatchError {
            throw NSError(
                domain: "SidecarXMPProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to write XMP attributes to \(path): \(error.message)"]
            )
        } catch {
            throw NSError(
                domain: "SidecarXMPProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to write XMP attributes to \(path): \(error)"]
            )
        }
    }

    /// 临时文件 + 原子 rename（对齐 TS writeXmpAttributesAsync 的 tmp + rename）。
    private func writeAtomic(path: String, content: String) throws {
        let tmpPath = "\(path).tmp-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())"
        do {
            try content.write(toFile: tmpPath, atomically: false, encoding: .utf8)
            try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: tmpPath)
            )
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
            throw error
        }
    }

    // MARK: - 备份 / 恢复 / 删除（TS backupXmpFileAsync / restoreXmpFileAsync / unlink）

    public func backup(photoPath: String) async throws -> String {
        let path = sidecarPath(photoPath)
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        let backupPath = "\(path).gather-backup-\(UUID().uuidString.lowercased())"
        try FileManager.default.copyItem(atPath: path, toPath: backupPath)
        return backupPath
    }

    public func restore(photoPath: String, backupPath: String) async throws {
        let path = sidecarPath(photoPath)
        guard FileManager.default.fileExists(atPath: backupPath) else { return }
        let tempPath = "\(path).restore-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())"
        do {
            try FileManager.default.copyItem(atPath: backupPath, toPath: tempPath)
            try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: tempPath)
            )
            try? FileManager.default.removeItem(atPath: backupPath)
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func removeFile(_ path: String) async throws {
        try FileManager.default.removeItem(atPath: path)
    }

    // MARK: - 文档补丁

    private enum XMPPatchError: Error {
        case corrupt(String)

        var message: String {
            switch self {
            case .corrupt(let path): "Corrupt XMP file: \(path)"
            }
        }
    }

    /// TS createEmptyXmpDoc + builder.build 的等价物（最小 XMP 文档）。
    private static func emptyXmpDoc() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    /// 对原始文档文本做三字段补丁（其余内容不动）。
    private static func patchDocument(_ xml: String, attributes: MetadataWriteAttributes) -> String {
        var result = xml
        // dc:subject 整块替换（关键词）。
        if let keywords = attributes.keywords {
            result = replaceElementBlock(
                result,
                element: "dc:subject",
                replacement: buildSubjectElement(keywords)
            )
        }
        // xmp:Rating。
        if let rating = attributes.rating {
            result = replaceElementBlock(
                result,
                element: "xmp:Rating",
                replacement: simpleElement("xmp:Rating", value: String(rating))
            )
        }
        // xmp:Label + photoshop:Urgency（TS: 写 label 时清掉旧 Urgency，
        // label 为 C1 色标时补写 Urgency 数字）。
        if let label = attributes.label {
            result = replaceElementBlock(result, element: "xmp:Label", replacement: simpleElement("xmp:Label", value: label))
            result = replaceElementBlock(result, element: "photoshop:Urgency", replacement: "")
            if let urgency = c1ColorLabelUrgency(label) {
                result = insertElement(
                    result,
                    element: simpleElement("photoshop:Urgency", value: String(urgency)),
                    after: "xmp:Label"
                )
            }
        }
        return result
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

    /// `<dc:subject>\n  <rdf:Bag>\n    <rdf:li>…</rdf:li>\n  </rdf:Bag>\n</dc:subject>`。
    private static func buildSubjectElement(_ keywords: [String]) -> String {
        let items = keywords.map { "      <rdf:li>\(xmlEscape($0))</rdf:li>" }.joined(separator: "\n")
        guard !items.isEmpty else {
            return "<dc:subject></dc:subject>"
        }
        return "<dc:subject>\n    <rdf:Bag>\n\(items)\n    </rdf:Bag>\n  </dc:subject>"
    }

    private static func simpleElement(_ name: String, value: String) -> String {
        "<\(name)>\(xmlEscape(value))</\(name)>"
    }

    /// 元素级替换：匹配 `<name …>…</name>` 或自闭合 `<name …/>`，未命中时原样
    /// 返回（调用方再决定插入）。空 replacement 表示删除该元素。
    private static func replaceElementBlock(_ xml: String, element: String, replacement: String) -> String {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: element))(\\s[^>]*)?>.*?</\(NSRegularExpression.escapedPattern(for: element))>|<\(NSRegularExpression.escapedPattern(for: element))(\\s[^>]*)?/>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return xml
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let match = regex.firstMatch(in: xml, range: range)
        guard let match else { return xml }
        guard let swiftRange = Range(match.range, in: xml) else { return xml }
        return xml.replacingCharacters(in: swiftRange, with: replacement)
    }

    /// 在首个 `<element …>` 开始标签之后插入（用于补写 Urgency）。
    private static func insertElement(_ xml: String, element: String, after sibling: String) -> String {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: sibling))(\\s[^>]*)?>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..<xml.endIndex, in: xml)),
              let swiftRange = Range(match.range, in: xml) else { return xml }
        let end = xml.index(swiftRange.upperBound, offsetBy: 0)
        return String(xml[..<end]) + "\n    " + element + String(xml[end...])
    }

    /// TS xmp-utils INVALID_XML_TEXT 过滤 + XML 转义。
    private static func xmlEscape(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" {
                continue
            }
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

/// SAX 收集器：按限定名收集本宿主关心的字段（`rdf:li` 仅在 dc:subject 子树内计数）。
private final class SidecarXMLDelegate: NSObject, XMLParserDelegate {
    private var subjectDepth = 0
    private var bagDepth = 0
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
        switch name {
        case "dc:subject":
            subjectDepth += 1
        case "rdf:Bag":
            if subjectDepth > 0 { bagDepth += 1 }
        default:
            if subjectDepth > 0 && bagDepth > 0 && name == "rdf:li" {
                currentElement = "rdf:li"
                currentText = ""
            } else if name == "xmp:Rating" || name == "xmp:Label"
                || name == "photoshop:Urgency" || name == "exif:DateTimeOriginal"
                || name == "exif:GPSLatitude" || name == "exif:GPSLongitude" {
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
        defer {
            if name == "dc:subject" { subjectDepth = max(0, subjectDepth - 1) }
            if name == "rdf:Bag" { bagDepth = max(0, bagDepth - 1) }
            currentElement = nil
        }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch currentElement {
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
}

/// TS: parseGpsCoordinate 的最小等价（"43,30.5N" 分秒格式与纯十进制）。
private func parseGpsCoordinate(_ value: String) -> Double? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    let sign: Double = trimmed.hasSuffix("S") || trimmed.hasSuffix("W") ? -1 : 1
    let body = trimmed
        .replacingOccurrences(of: "[NSEW]$", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\u{2212}", with: "-")
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
