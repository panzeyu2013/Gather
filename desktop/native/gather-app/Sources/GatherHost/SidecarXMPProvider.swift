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
//    内嵌 XMP 与侧车的合并由 GatherApplication.MetadataService 负责（侧车覆盖内嵌）。
// 注（WP5 拆分）：写入管线（补丁 / 命名空间 / 原子落盘）见 SidecarXMPProvider+Patching.swift；

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
            longitude: parsed.longitude,
            descriptive: parsed.descriptive.isEmpty ? nil : parsed.descriptive,
            triageSignal: parsed.triageSignal
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
        /// P1 / IPTC：描述性元数据（由 IPTCXMLDelegate 二次解析填入）。
        var descriptive = DescriptiveMetadata()
        /// P1 / E：私有命名空间信号（gather:Triage）。
        var triageSignal: String?

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
        var result = delegate.result
        // P1 / IPTC：同一份数据再跑一次描述性字段收集（表驱动，与写入共用 descriptor 表）。
        let iptcParser = XMLParser(data: data)
        let iptcDelegate = IPTCXMLDelegate()
        iptcParser.delegate = iptcDelegate
        if iptcParser.parse() {
            result.descriptive = iptcDelegate.descriptive
            result.triageSignal = iptcDelegate.triageSignal
        }
        return result
    }

    private static func assertWellFormed(_ text: String, xmpPath: String) throws {
        let parser = XMLParser(data: Data(text.utf8))
        let delegate = SidecarXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else { throw SidecarXMPError.documentCorrupt(xmpPath: xmpPath) }
    }

    // MARK: - 新建侧车的骨架文档

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
