// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataTransferService.swift
// Wave5（Batch5 / task-23）：元数据模板与词库的导入/导出（UI 层，不改 core 协议）。
//
// 为什么放 UI 层：核心协议已有 templates/templateFields/saveTemplate/deleteTemplate
// 与 keywordLibrary/createKeyword/setKeywordSynonyms；本文件只做「编解码 + 预览 + 规划 +
// 批量执行」这一层，不新增第 17 个域 API，也不碰 schema/XMP。
//
// 文件格式：
// - 模板：JSON（version / exportedAt / templates[name,fields,client]）；fields 直接复用
//   协议里的 DescriptiveMetadata（Codable），跨版本由 decode 的逐条容错兜住；
// - 词库：CSV，两列 `path,synonyms`；path 是层级路径（A|B），synonyms 用 `;` 分隔，
//   单元格按 RFC4180 加引号转义；同义词内部若含 `;`/`\\` 用反斜杠转义（可逆）。
//
// 安全口径：
// - 导出只读；导入全部走**预览 → 确认**，执行入口只接受 Confirmed<T>（D-011 同款门禁，
//   取消分支在 UI 层根本不调用执行器）；
// - 导入只增/覆盖同义词，**不删除**现有词，也不做层级移动；不写 XMP；
// - 失败逐条计数（不静默部分成功）；文件级非法（空/超 2000 行/版本过高）显式报错。
import Foundation
import GatherProtocol

// MARK: - 失败 / 非法条目

/// 逐条失败（导入执行期）：name 是模板名或关键词路径。
struct MetadataTransferFailure: Equatable, Sendable {
    var name: String
    var reason: String
}

/// 文件内的非法条目（预览期，不执行）。
struct MetadataTransferInvalidItem: Equatable, Sendable {
    /// 1-based：模板在文件里的序号 / CSV 的行号。
    var index: Int
    var name: String
    var reason: String
}

// MARK: - 模板：导出文件 / 导入预览 / 规划

/// 模板导出文件（当前 version = 1）。
struct MetadataTemplateExportFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var exportedAt: String
    var templates: [Entry]

    struct Entry: Codable, Equatable, Sendable {
        var name: String
        var fields: DescriptiveMetadata
        var client: String?

        init(name: String, fields: DescriptiveMetadata, client: String? = nil) {
            self.name = name
            self.fields = fields
            self.client = client
        }
    }
}

/// 一条可导入的模板（已通过名字/字段校验）。
struct MetadataTemplateImportEntry: Equatable, Sendable {
    var name: String
    var fields: DescriptiveMetadata
    var client: String?
}

struct MetadataTemplateImportPreview: Equatable, Sendable {
    static let empty = MetadataTemplateImportPreview(
        entries: [], invalid: [], duplicateNameCount: 0,
        existingNameCount: 0, exportedAt: "")

    var entries: [MetadataTemplateImportEntry]
    var invalid: [MetadataTransferInvalidItem]
    /// 文件内重名（第二次出现起计数，不导入）。
    var duplicateNameCount: Int
    /// 与现有模板同名的条数（策略决定跳过或覆盖）。
    var existingNameCount: Int
    var exportedAt: String
}

/// 同名模板的处置口径（默认跳过：导入不会悄悄改掉本机已有模板）。
enum MetadataTemplateImportStrategy: String, CaseIterable, Hashable, Sendable {
    case skip
    case overwrite
}

struct MetadataTemplateImportPlan: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var name: String
        var fields: DescriptiveMetadata
        var client: String?
        /// 非 nil = 覆盖该既有模板（保留 createdAt）。
        var overwriteTemplateId: String?
    }

    var items: [Item]
    var skippedExisting: [String]
    var invalid: [MetadataTransferInvalidItem]
}

struct MetadataTemplateImportOutcome: Equatable, Sendable {
    var created = 0
    var overwritten = 0
    var skipped = 0
    var failures: [MetadataTransferFailure] = []
}

/// 模板导入的宽松形状：单条坏数据不拖垮整个文件（逐条进 invalid）。
/// 所有字段解析失败都降级为 nil（上层按"缺少 name/fields"逐条判非法）。
private struct MetadataTemplateImportFile: Decodable {
    var version: Int?
    var exportedAt: String?
    var templates: [MetadataTemplateImportRaw]

    private enum CodingKeys: String, CodingKey { case version, exportedAt, templates }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        exportedAt = try container.decodeIfPresent(String.self, forKey: .exportedAt)
        // 缺失/非数组 → 文件级非法（由 decode 统一包成 GatherError）。
        templates = try container.decode([MetadataTemplateImportRaw].self, forKey: .templates)
    }
}

private struct MetadataTemplateImportRaw: Decodable {
    var name: String?
    var fields: DescriptiveMetadata?
    var client: String?

    private enum CodingKeys: String, CodingKey { case name, fields, client }

    init(from decoder: Decoder) throws {
        name = nil
        fields = nil
        client = nil
        let container: KeyedDecodingContainer<CodingKeys>
        do { container = try decoder.container(keyedBy: CodingKeys.self) } catch { return }
        do { name = try container.decodeIfPresent(String.self, forKey: .name) } catch { name = nil }
        do { fields = try container.decodeIfPresent(DescriptiveMetadata.self, forKey: .fields) } catch { fields = nil }
        do { client = try container.decodeIfPresent(String.self, forKey: .client) } catch { client = nil }
    }
}
/// 模板 JSON 的编解码 + 预览 + 规划（纯函数，无 IO，可单测）。
enum MetadataTemplateTransfer {
    /// 导出（只读路径）：entries 来自 listTemplates + templateFields。
    static func makeExportData(
        _ entries: [MetadataTemplateImportEntry], exportedAt: String = isoNow()
    ) throws -> Data {
        let file = MetadataTemplateExportFile(
            version: MetadataTemplateExportFile.currentVersion,
            exportedAt: exportedAt,
            templates: entries.map { entry in
                MetadataTemplateExportFile.Entry(
                    name: entry.name, fields: entry.fields, client: entry.client)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// 解析导入文件：文件级非法显式抛错，条目级非法进 invalid（不中断整批预览）。
    static func decode(
        _ data: Data, existingNames: Set<String>
    ) throws -> MetadataTemplateImportPreview {
        guard !data.isEmpty else {
            throw GatherError.invalidParameter(field: "file", reason: "模板文件为空")
        }
        let file: MetadataTemplateImportFile
        do {
            file = try JSONDecoder().decode(MetadataTemplateImportFile.self, from: data)
        } catch {
            throw GatherError.invalidParameter(
                field: "file", reason: "模板文件不是合法的 JSON（需含 templates 数组）")
        }
        let version = file.version ?? MetadataTemplateExportFile.currentVersion
        guard version <= MetadataTemplateExportFile.currentVersion else {
            throw GatherError.invalidParameter(
                field: "version",
                reason: "文件版本 \(version) 高于当前支持的 \(MetadataTemplateExportFile.currentVersion)")
        }
        guard !file.templates.isEmpty else {
            throw GatherError.invalidParameter(field: "templates", reason: "文件里没有任何模板")
        }
        var entries: [MetadataTemplateImportEntry] = []
        var invalid: [MetadataTransferInvalidItem] = []
        var seenNames = Set<String>()
        var duplicates = 0
        var existingCount = 0
        for (offset, raw) in file.templates.enumerated() {
            let index = offset + 1
            guard let rawName = raw.name else {
                invalid.append(MetadataTransferInvalidItem(
                    index: index, name: "", reason: "条目缺少 name"))
                continue
            }
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                invalid.append(MetadataTransferInvalidItem(
                    index: index, name: rawName, reason: "模板名为空"))
                continue
            }
            if trimmed.utf8.count > 120 {
                invalid.append(MetadataTransferInvalidItem(
                    index: index, name: trimmed, reason: "模板名超过 120 字节"))
                continue
            }
            guard let fields = raw.fields else {
                invalid.append(MetadataTransferInvalidItem(
                    index: index, name: trimmed, reason: "条目缺少 fields"))
                continue
            }
            var client: String? = nil
            if let rawClient = raw.client {
                let clientTrimmed = rawClient.trimmingCharacters(in: .whitespacesAndNewlines)
                if clientTrimmed.utf8.count > 120 {
                    invalid.append(MetadataTransferInvalidItem(
                        index: index, name: trimmed, reason: "客户名超过 120 字节"))
                    continue
                }
                client = clientTrimmed.isEmpty ? nil : clientTrimmed
            }
            if seenNames.contains(trimmed) {
                duplicates += 1
                invalid.append(MetadataTransferInvalidItem(
                    index: index, name: trimmed, reason: "文件内模板名重复（只导入第一次出现的）"))
                continue
            }
            seenNames.insert(trimmed)
            if existingNames.contains(trimmed) { existingCount += 1 }
            entries.append(MetadataTemplateImportEntry(
                name: trimmed, fields: fields, client: client))
        }
        return MetadataTemplateImportPreview(
            entries: entries,
            invalid: invalid,
            duplicateNameCount: duplicates,
            existingNameCount: existingCount,
            exportedAt: file.exportedAt ?? "")
    }
    /// 按策略生成执行计划：同名 skip（默认）或 overwrite（带既有模板 id）。
    static func plan(
        _ preview: MetadataTemplateImportPreview,
        existing: [String: MetadataTemplateSummary],
        strategy: MetadataTemplateImportStrategy
    ) -> MetadataTemplateImportPlan {
        var items: [MetadataTemplateImportPlan.Item] = []
        var skipped: [String] = []
        for entry in preview.entries {
            if let current = existing[entry.name] {
                switch strategy {
                case .skip:
                    skipped.append(entry.name)
                case .overwrite:
                    items.append(MetadataTemplateImportPlan.Item(
                        name: entry.name, fields: entry.fields, client: entry.client,
                        overwriteTemplateId: current.id))
                }
            } else {
                items.append(MetadataTemplateImportPlan.Item(
                    name: entry.name, fields: entry.fields, client: entry.client,
                    overwriteTemplateId: nil))
            }
        }
        return MetadataTemplateImportPlan(
            items: items, skippedExisting: skipped, invalid: preview.invalid)
    }
}

// MARK: - 词库：CSV 编解码 / 预览 / 规划

struct KeywordCsvRow: Equatable, Sendable {
    var lineNumber: Int
    var path: String
    var synonyms: [String]
    /// true = 词库还没有这个路径（导入时 createKeyword）；false = 只更新同义词。
    var isNew: Bool
}

struct KeywordCsvInvalidRow: Equatable, Sendable {
    var lineNumber: Int
    var raw: String
    var reason: String
}

struct KeywordCsvPreview: Equatable, Sendable {
    static let empty = KeywordCsvPreview(
        rows: [], invalid: [], dataLineCount: 0, unchangedCount: 0)

    var rows: [KeywordCsvRow]
    var invalid: [KeywordCsvInvalidRow]
    var dataLineCount: Int
    /// 词库已有、且同义词完全一致（执行时只跳过）。
    var unchangedCount: Int

    var newCount: Int { rows.filter { $0.isNew }.count }
    var synonymUpdateCount: Int { rows.filter { !$0.isNew }.count }
}

struct KeywordImportPlan: Equatable, Sendable {
    var newRows: [KeywordCsvRow]
    var synonymUpdates: [KeywordCsvRow]
    var unchangedCount: Int
    var invalid: [KeywordCsvInvalidRow]
}

struct KeywordImportOutcome: Equatable, Sendable {
    var createdPaths = 0
    var updatedSynonyms = 0
    var unchanged = 0
    var failures: [MetadataTransferFailure] = []
}

enum KeywordLibraryTransfer {
    /// 单次导入的行数硬上限（词库是受控词表，不是批量数据通道）。
    static let maxImportLines = 2_000
    static let headerLine = "path,synonyms"

    /// 导出 CSV（只读）：按 path 排序，行尾 \n；同义词用 `; ` 连接并反斜杠转义；
    /// 单元格按 RFC4180 在必要时加引号。
    static func encodeCSV(_ nodes: [KeywordLibraryNode]) -> String {
        var lines = [headerLine]
        for node in nodes.sorted(by: { $0.path < $1.path }) {
            let synonyms = node.synonyms.map(escapeSynonym).joined(separator: "; ")
            lines.append(csvQuote(node.path) + "," + csvQuote(synonyms))
        }
        return lines.joined(separator: "\n")
    }

    static func decodeCSV(
        _ text: String, existing: [KeywordLibraryNode]
    ) throws -> KeywordCsvPreview {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var dataLines: [(number: Int, text: String)] = []
        var skippedHeader = false
        for (offset, rawLine) in rawLines.enumerated() {
            var line = String(rawLine)
            if offset == 0, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if !skippedHeader, trimmed.lowercased() == headerLine {
                skippedHeader = true
                continue
            }
            dataLines.append((number: offset + 1, text: line))
        }
        guard !dataLines.isEmpty else {
            throw GatherError.invalidParameter(field: "file", reason: "词库 CSV 没有数据行")
        }
        guard dataLines.count <= maxImportLines else {
            throw GatherError.invalidParameter(
                field: "file",
                reason: "词库 CSV 超过 \(maxImportLines) 行（\(dataLines.count) 行），请拆分后分批导入")
        }
        let existingByPath = Dictionary(existing.map { ($0.path, $0) }) { first, _ in first }
        var rows: [KeywordCsvRow] = []
        var invalid: [KeywordCsvInvalidRow] = []
        var unchanged = 0
        var seenPaths = Set<String>()
        for line in dataLines {
            guard let fields = parseCSVLine(line.text) else {
                invalid.append(KeywordCsvInvalidRow(
                    lineNumber: line.number, raw: line.text, reason: "引号未闭合"))
                continue
            }
            guard fields.count == 2 else {
                invalid.append(KeywordCsvInvalidRow(
                    lineNumber: line.number, raw: line.text,
                    reason: "列数不是 2（path,synonyms）"))
                continue
            }
            let rawPath = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let path: String
            do {
                path = try KeywordLibraryValidator.parsePath(rawPath).serialized
            } catch {
                invalid.append(KeywordCsvInvalidRow(
                    lineNumber: line.number, raw: line.text, reason: "关键词路径非法"))
                continue
            }
            if seenPaths.contains(path) {
                invalid.append(KeywordCsvInvalidRow(
                    lineNumber: line.number, raw: line.text,
                    reason: "文件内重复路径（只导入第一次出现的）"))
                continue
            }
            seenPaths.insert(path)
            let synonyms = KeywordLibraryValidator.normalizeSynonyms(
                splitSynonyms(fields[1]))
            if synonyms.count > KeywordSynonymsInput.maxSynonyms {
                invalid.append(KeywordCsvInvalidRow(
                    lineNumber: line.number, raw: line.text,
                    reason: "同义词超过 \(KeywordSynonymsInput.maxSynonyms) 个"))
                continue
            }
            if let node = existingByPath[path] {
                let current = Set(KeywordLibraryValidator.normalizeSynonyms(node.synonyms))
                let incoming = Set(synonyms)
                if current == incoming {
                    unchanged += 1
                    continue
                }
                rows.append(KeywordCsvRow(
                    lineNumber: line.number, path: path, synonyms: synonyms, isNew: false))
            } else {
                rows.append(KeywordCsvRow(
                    lineNumber: line.number, path: path, synonyms: synonyms, isNew: true))
            }
        }
        return KeywordCsvPreview(
            rows: rows, invalid: invalid,
            dataLineCount: dataLines.count, unchangedCount: unchanged)
    }

    static func plan(_ preview: KeywordCsvPreview) -> KeywordImportPlan {
        KeywordImportPlan(
            newRows: preview.rows.filter { $0.isNew },
            synonymUpdates: preview.rows.filter { !$0.isNew },
            unchangedCount: preview.unchangedCount,
            invalid: preview.invalid)
    }

    // MARK: CSV 细节

    /// RFC4180：含逗号/双引号/换行的字段加引号，内部双引号写成两个。
    static func csvQuote(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains(";")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 解析一行 CSV（支持引号内的逗号与转义双引号）；引号未闭合返回 nil。
    static func parseCSVLine(_ line: String) -> [String]? {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        current.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                current.append(character)
                index += 1
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
                index += 1
            case ",":
                fields.append(current)
                current = ""
                index += 1
            default:
                current.append(character)
                index += 1
            }
        }
        guard !inQuotes else { return nil }
        fields.append(current)
        return fields
    }

    /// 同义词单元格 → 数组：`;` 分隔；`\;` 是字面分号，`\\` 是字面反斜杠。
    static func splitSynonyms(_ cell: String) -> [String] {
        var result: [String] = []
        var current = ""
        var escaping = false
        for character in cell {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            switch character {
            case "\\":
                escaping = true
            case ";":
                result.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func escapeSynonym(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
    }
}

// MARK: - 批量执行器（只接受 Confirmed<T>：取消分支在 UI 层不调用）

struct MetadataTransferExecutor: Sendable {
    typealias ListTemplates = @Sendable () async throws -> [MetadataTemplateSummary]
    typealias LoadTemplateFields = @Sendable (String) async throws -> DescriptiveMetadata
    typealias SaveTemplate = @Sendable (MetadataTemplateSaveInput) async throws -> MetadataTemplateSummary
    typealias ListKeywords = @Sendable () async throws -> [KeywordLibraryNode]
    typealias CreateKeyword = @Sendable (Confirmed<KeywordCreateInput>) async throws -> KeywordMutationSummary
    typealias SetSynonyms = @Sendable (Confirmed<KeywordSynonymsInput>) async throws -> KeywordMutationSummary

    private let listTemplates: ListTemplates
    private let loadTemplateFields: LoadTemplateFields
    private let saveTemplate: SaveTemplate
    private let listKeywords: ListKeywords
    private let createKeyword: CreateKeyword
    private let setSynonyms: SetSynonyms

    init(
        listTemplates: @escaping ListTemplates,
        loadTemplateFields: @escaping LoadTemplateFields,
        saveTemplate: @escaping SaveTemplate,
        listKeywords: @escaping ListKeywords,
        createKeyword: @escaping CreateKeyword,
        setSynonyms: @escaping SetSynonyms
    ) {
        self.listTemplates = listTemplates
        self.loadTemplateFields = loadTemplateFields
        self.saveTemplate = saveTemplate
        self.listKeywords = listKeywords
        self.createKeyword = createKeyword
        self.setSynonyms = setSynonyms
    }

    /// 生产接线：直接取 MetadataAPI 的只读/写入口（写入口本身已要求 Confirmed）。
    init(metadata: any MetadataAPI) {
        self.init(
            listTemplates: { try await metadata.templates() },
            loadTemplateFields: { id in try await metadata.templateFields(id: id) },
            saveTemplate: { input in try await metadata.saveTemplate(input) },
            listKeywords: { try await metadata.keywordLibrary(KeywordLibraryQuery()) },
            createKeyword: { input in try await metadata.createKeyword(input) },
            setSynonyms: { input in try await metadata.setKeywordSynonyms(input) })
    }

    /// 导出全部模板（只读）：读列表 + 逐模板读字段，任一步失败显式抛错。
    func exportTemplates() async throws -> (data: Data, count: Int) {
        let summaries = try await listTemplates()
        var entries: [MetadataTemplateImportEntry] = []
        for summary in summaries {
            let fields = try await loadTemplateFields(summary.id)
            entries.append(MetadataTemplateImportEntry(
                name: summary.name, fields: fields, client: summary.client))
        }
        let data = try MetadataTemplateTransfer.makeExportData(entries)
        return (data, entries.count)
    }

    /// 失败原因收敛成「错误码：参数」形状，供 UI 走码表本地化（不外泄内部散文）。
    private static func failureReason(_ error: any Error) -> String {
        if let gather = error as? GatherError {
            let detail = gather.params["reason"] ?? gather.params["field"] ?? ""
            return detail.isEmpty
                ? gather.code.rawValue
                : gather.code.rawValue + ": " + detail
        }
        return String(describing: error)
    }

    /// 导入模板（已确认）。逐条独立提交；失败逐条计数并继续后续条目。
    // DOMAIN-EVENT: none — 模板定义不是照片元数据，不写任何 XMP
    func importTemplates(
        _ confirmed: Confirmed<MetadataTemplateImportPlan>
    ) async -> MetadataTemplateImportOutcome {
        var outcome = MetadataTemplateImportOutcome(
            skipped: confirmed.value.skippedExisting.count)
        for item in confirmed.value.items {
            do {
                let input = try MetadataTemplateSaveInput(
                    id: item.overwriteTemplateId,
                    name: item.name,
                    fields: item.fields,
                    client: item.client)
                _ = try await saveTemplate(input)
                if item.overwriteTemplateId == nil {
                    outcome.created += 1
                } else {
                    outcome.overwritten += 1
                }
            } catch {
                outcome.failures.append(MetadataTransferFailure(
                    name: item.name, reason: Self.failureReason(error)))
            }
        }
        return outcome
    }

    /// 导出词库 CSV（只读）。
    func exportKeywordCSV() async throws -> (text: String, count: Int) {
        let nodes = try await listKeywords()
        return (KeywordLibraryTransfer.encodeCSV(nodes), nodes.count)
    }

    /// 导入词库（已确认）：新路径 createKeyword（空缺路径服务端会物化祖先），
    /// 既有路径只覆盖同义词。**不删除**任何既有词，不写 XMP。
    // DOMAIN-EVENT: none — 由调用方（KeywordLibrarySheet）在成功后广播 .metadata
    func importKeywords(
        _ confirmed: Confirmed<KeywordImportPlan>
    ) async -> KeywordImportOutcome {
        var outcome = KeywordImportOutcome(unchanged: confirmed.value.unchangedCount)
        for row in confirmed.value.newRows {
            do {
                _ = try await createKeyword(Confirmed(
                    try KeywordCreateInput(path: row.path), source: .userDialog))
                if !row.synonyms.isEmpty {
                    _ = try await setSynonyms(Confirmed(
                        try KeywordSynonymsInput(path: row.path, synonyms: row.synonyms),
                        source: .userDialog))
                }
                outcome.createdPaths += 1
            } catch {
                outcome.failures.append(MetadataTransferFailure(
                    name: row.path, reason: Self.failureReason(error)))
            }
        }
        for row in confirmed.value.synonymUpdates {
            do {
                _ = try await setSynonyms(Confirmed(
                    try KeywordSynonymsInput(path: row.path, synonyms: row.synonyms),
                    source: .userDialog))
                outcome.updatedSynonyms += 1
            } catch {
                outcome.failures.append(MetadataTransferFailure(
                    name: row.path, reason: Self.failureReason(error)))
            }
        }
        return outcome
    }
}

// MARK: - 工具

/// ISO-8601 导出时间戳（UI 层自足，不依赖 Persistence 的 nowISOString）。
func isoNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: Date())
}
