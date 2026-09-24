// desktop/native/gather-core/Sources/GatherCore/Runtime/Export/ExportAssembler.swift
// W2d-4 步骤①：Export 纯函数层（Services/ExportService.swift 的纯逻辑下沉）。
//
// 来源与边界：
// - 逐字移植 ExportService.swift 中的纯逻辑：选项校验（validate）、会话作用域与
//   RAW/JPEG 变体折叠（scopedPhotos/selectVariants）、文件名模板展开（resolveName）、
//   命名冲突消解（uniqueName）、路径规划（sanitize/isPathInside/canonicalPath/
//   assertDestinationPath）与报告聚合（sessionSummary/personReport/keywords/
//   keywordReport/emptyReport/csvField/mdField）。
// - 本文件自身不发起文件读写、不做任何查询：变体折叠输入为 Store 层值类型
//   PhotoProjection，报告聚合输入为 Store 层值类型 SQLiteRow（两者都是纯值袋，
//   只取值）；除此之外只依赖 Foundation 与 Protocol 层 DTO。唯一例外是
//   canonicalPath 依赖 Foundation 的符号链接解析（resolvingSymlinksInPath，只读
//   路径解析），与旧实现逐字一致。设计文档门禁：Runtime/** 内不得出现 SQL 语句
//   文本或数据库连接类型（本文件既不 import C SQLite，也不持有连接）。
//
// 命名注记（设计文档 §2 计划名 vs 本步骤实际）：
// - 设计文档计划把导出纯逻辑拆为 ExportValidation/ExportPaths/ExportVariants/
//   ExportNaming/ExportReportBuilder 多个容器；本步骤①按任务要求先合并为单一
//   caseless enum ExportAssembler（对齐 Runtime/Culling/CullingAssembler.swift
//   形态），后续如需分域可机械拆分，当前不做推测性拆分。
// - Protocol/Export.swift 已声明 public struct ExportNaming，故命名模板逻辑沿用
//   resolveName 方法名，不再另建同名类型。
//
// 行为保持（审计要点）：
// - 所有函数与旧私有实现逐字等价，含：字典分组（groups.values.compactMap）顺序、
//   policy == .all 原样返回（不分组）、空扩展名分支、usedNames 的 lowercased 占用、
//   {time} 每次新建 DateFormatter 的 HH-mm-ss（审计 P1 数据竞争修法）、CSV/MD
//   逐字转义与行拼接、报告 path 恒为空串。
// - 唯一签名变化：把旧实现隐含的 Date()（resolveName）与 FileManager 存在性查询
//   （uniqueName）注入为 date / nameExists 参数；服务侧以 Date() 与 FileManager
//   查询回填，调用序不变，行为不变。
// - 未在本步骤修复的既有缺陷（保持行为不变，留给后续步骤）：
//   E1 分组 key 仍为 assetId ?? id（asset_id = '' 会并组），按设计文档 §F 在
//   ExportVariants 切换步骤统一改成空串归一化并保序输出。

import Foundation

/// TS: export.service.ts 的纯函数面（查询、文件 IO、转码与取消标记均不在此文件）。
public enum ExportAssembler {
    // MARK: - 常量（旧 filteredPhotos 内联集合）

    /// 旧 filteredPhotos 内联 RAW 扩展名集合（含点号、小写）。
    public static let rawExtensions: Set<String> = [
        ".3fr", ".arw", ".cr2", ".cr3", ".dng", ".fff", ".gpr", ".iiq", ".mos",
        ".nef", ".nrw", ".orf", ".pef", ".raf", ".raw", ".rw2", ".rwl", ".sr2",
        ".srf", ".srw", ".x3f",
    ]

    /// 旧 filteredPhotos 内联 JPEG 扩展名集合（含点号、小写）。
    public static let jpegExtensions: Set<String> = [".jpg", ".jpeg"]

    // MARK: - 选项校验（旧 ExportService.validate）

    /// 逐字移植 ExportService.validate(_:)。
    public static func validate(_ options: ExportOptions) throws {
        guard !options.destination.isEmpty else { throw ExportServiceError.destinationInvalid }
        guard options.destination.hasPrefix("/") else { throw ExportServiceError.destinationAbsoluteRequired }
        let destination = URL(fileURLWithPath: options.destination).standardizedFileURL.path
        guard destination != "/" else { throw ExportServiceError.destinationRootForbidden }
        guard ExportFormat.allCases.contains(options.format) else { throw ExportServiceError.formatInvalid }
        if let policy = options.variantPolicy, !ExportVariantPolicy.allCases.contains(policy) {
            throw ExportServiceError.variantPolicyInvalid
        }
        if options.format == .original, options.maxDimension != nil || options.watermark != nil {
            throw ExportServiceError.originalTransformNotAllowed
        }
        guard !options.naming.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExportServiceError.namingEmpty
        }
        if options.naming.pattern.contains("/") || options.naming.pattern.contains("\\") || options.naming.pattern.contains("\0") {
            throw ExportServiceError.namingInvalidCharacters
        }
        if let quality = options.quality, quality.rounded() != quality || quality < 1 || quality > 100 {
            throw ExportServiceError.qualityInvalid
        }
        if let maxDimension = options.maxDimension, maxDimension < 1 {
            throw ExportServiceError.maxDimensionInvalid
        }
        if let start = options.naming.counterStart, start < 0 {
            throw ExportServiceError.startIndexInvalid
        }
        if let watermark = options.watermark {
            guard watermark.type == .text else { throw ExportServiceError.watermarkTypeUnsupported }
            guard !watermark.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExportServiceError.watermarkTextEmpty
            }
            guard watermark.opacity.isFinite, watermark.opacity >= 0, watermark.opacity <= 1 else {
                throw ExportServiceError.watermarkOpacityInvalid
            }
            if let fontSize = watermark.fontSize, !fontSize.isFinite || fontSize < 1 || fontSize > 1000 {
                throw ExportServiceError.watermarkFontSizeInvalid
            }
        }
    }

    // MARK: - 变体折叠（旧 ExportService.filteredPhotos）

    /// 逐字移植 filteredPhotos 的会话作用域过滤：scope 非 session 报错，removed 行剔除。
    public static func scopedPhotos(_ photos: [PhotoProjection], scope: ExportScope) throws -> [PhotoProjection] {
        guard scope == .session else { throw ExportServiceError.scopeUnsupported }
        return photos.filter { $0.status != "removed" }
    }

    /// 逐字移植 filteredPhotos 的 RAW/JPEG 变体折叠：policy == .all 原样返回（不分组），
    /// 其余按 assetId ?? id 分组后取首个匹配项；分组顺序沿用字典 values 顺序。
    public static func selectVariants(_ photos: [PhotoProjection], policy: ExportVariantPolicy) -> [PhotoProjection] {
        if policy == .all { return photos }
        var groups: [String: [PhotoProjection]] = [:]
        for photo in photos { groups[photo.assetId ?? photo.id, default: []].append(photo) }
        return groups.values.compactMap { variants in
            let isRaw: (PhotoProjection) -> Bool = { rawExtensions.contains(URL(fileURLWithPath: $0.filename).pathExtension.lowercased().isEmpty ? "" : ".\(URL(fileURLWithPath: $0.filename).pathExtension.lowercased())") }
            let isJPEG: (PhotoProjection) -> Bool = { jpegExtensions.contains(".\(URL(fileURLWithPath: $0.filename).pathExtension.lowercased())") }
            switch policy {
            case .raw: return variants.first(where: isRaw)
            case .jpeg: return variants.first(where: isJPEG)
            case .preferred: return variants.first(where: isRaw) ?? variants.first(where: isJPEG) ?? variants.first
            case .all: return variants.first
            }
        }
    }

    // MARK: - 文件名模板与冲突消解（旧 ExportService.resolveName / uniqueName）

    /// 逐字移植 ExportService.resolveName(photo:options:counter:sessionName:)；
    /// 唯一变化：photo.filename 与隐含的 Date() 改为显式入参。
    public static func resolveName(
        filename: String,
        options: ExportOptions,
        counter: Int,
        sessionName: String,
        date: Date
    ) -> String {
        let filename = URL(fileURLWithPath: filename).lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension
        let base = sanitize(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent)
        let session = sanitize(sessionName)
        let dateFormat = options.naming.dateFormat ?? "YYYY-MM-DD"
        let dateString = dateFormat
            .replacingOccurrences(of: "YYYY", with: String(Calendar.current.component(.year, from: date)))
            .replacingOccurrences(of: "MM", with: String(format: "%02d", Calendar.current.component(.month, from: date)))
            .replacingOccurrences(of: "DD", with: String(format: "%02d", Calendar.current.component(.day, from: date)))
        // {time} 固定 HH-mm-ss（24h 制）：localizedString(.medium) 在 12h locale
        // 下产出 "3-45-30 PM"（含空格 + AM/PM），与 ExportView 预览的 HH-mm-ss
        // 不符。与 TS 的差异：TS 两端统一 24h 制，此处对齐该语义。
        // 审计 P1：静态 DateFormatter 被 worker 线程（并发导出）与主线程共用
        // 存在数据竞争，改为函数内新建（格式化成本可忽略）。
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        let time = formatter.string(from: date)
        var pattern = options.naming.pattern
        pattern = pattern.replacingOccurrences(of: "{date}", with: dateString)
        pattern = pattern.replacingOccurrences(of: "{time}", with: time)
        pattern = pattern.replacingOccurrences(of: "{counter}", with: String(format: "%04d", counter))
        pattern = pattern.replacingOccurrences(of: "{original}", with: base)
        // Older UI versions exposed {filename}; keep it as a compatibility
        // alias so an existing saved preset never exports a literal token.
        pattern = pattern.replacingOccurrences(of: "{filename}", with: base)
        pattern = pattern.replacingOccurrences(of: "{session}", with: session)
        let targetExt = options.format == .jpeg ? "jpg" : options.format == .tiff ? "tiff" : ext
        return "\(pattern).\(targetExt.isEmpty ? "jpg" : targetExt)"
    }

    /// 逐字移植 ExportService.uniqueName(_:usedNames:destination:)；
    /// 唯一变化：FileManager 存在性查询改为注入的 nameExists 闭包
    /// （调用方仅在 usedNames 未命中时才执行查询，短路顺序与旧实现一致）。
    public static func uniqueName(
        _ input: String,
        usedNames: inout Set<String>,
        nameExists: (String) -> Bool
    ) -> String {
        let url = URL(fileURLWithPath: input)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        var candidate = input
        var index = 2
        while usedNames.contains(candidate.lowercased()) || nameExists(candidate) {
            candidate = "\(base)_\(index)\(ext)"
            index += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }

    // MARK: - 路径规划（旧 ExportService.sanitize / isPathInside / canonicalPath / assertDestinationPath）

    /// 逐字移植 ExportService.sanitize(_:)。
    public static func sanitize(_ value: String) -> String {
        let replaced = value.replacingOccurrences(of: "[<>:\"/\\\\|?*]", with: "_", options: .regularExpression)
        return URL(fileURLWithPath: replaced).lastPathComponent
    }

    /// 逐字移植 ExportService.isPathInside(_:_:)（纯字符串/路径分量判定）。
    public static func isPathInside(_ candidate: String, _ directory: String) -> Bool {
        let candidateComponents = URL(fileURLWithPath: candidate).pathComponents
        let directoryComponents = URL(fileURLWithPath: directory).pathComponents
        guard candidateComponents.count > directoryComponents.count else { return false }
        return Array(candidateComponents.prefix(directoryComponents.count)) == directoryComponents
    }

    /// 逐字移植 ExportService.canonicalPath(_:)。
    /// 注：resolvingSymlinksInPath 会做只读的符号链接解析（唯一触碰文件系统的路径）。
    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 逐字移植 ExportService.assertDestinationPath(_:inside:)。
    public static func assertDestinationPath(_ url: URL, inside directory: URL) throws {
        let candidate = canonicalPath(url.path)
        let root = canonicalPath(directory.path)
        guard candidate == root || isPathInside(candidate, root) else { throw ExportServiceError.exportPathInvalid }
    }

    // MARK: - 报告聚合（旧 ExportService.generateReport / csvField / mdField）

    /// 逐字移植 generateReport 的 session_summary 分支（CSV 与 MD 两条路径）。
    public static func sessionSummary(rows: [SQLiteRow], format: ReportFormat) -> ReportData {
        if format == .csv {
            var content = "filename,filepath,status\n"
            content += rows.map {
                [($0.values[$0.columnOrder[0]]?.textValue ?? ""), ($0.values[$0.columnOrder[1]]?.textValue ?? ""), ($0.values[$0.columnOrder[2]]?.textValue ?? "")]
                    .map(Self.csvField).joined(separator: ",")
            }.joined(separator: "\n")
            return ReportData(path: "", content: content, format: .csv)
        }
        var content = "# Session summary\n\n"
        content += "Total photos: \(rows.count)\n\n"
        content += "| # | Filename | Path | Status |\n|---:|---|---|---|\n"
        for (index, row) in rows.enumerated() {
            content += "| \(index + 1) | \(Self.mdField(row.values[row.columnOrder[0]]?.textValue ?? "")) | \(Self.mdField(row.values[row.columnOrder[1]]?.textValue ?? "")) | \(Self.mdField(row.values[row.columnOrder[2]]?.textValue ?? "")) |\n"
        }
        return ReportData(path: "", content: content, format: .md)
    }

    /// 逐字移植 generateReport 的 person 分支（keywords 列按 JSON 数组展开）。
    public static func personReport(rows: [SQLiteRow]) -> ReportData {
        var content = "# Person report\n\nBindings: \(rows.count)\n\n"
        content += "| Role | Keywords | Cluster | Members |\n|---|---|---|---:|\n"
        for row in rows {
            let keywords = (try? JSONValue.parse(row.values[row.columnOrder[1]]?.textValue ?? "[]"))?.arrayValue?.joined(separator: ", ") ?? ""
            content += "| \(Self.mdField(row.values[row.columnOrder[0]]?.textValue ?? "")) | \(Self.mdField(keywords)) | \(Self.mdField(row.values[row.columnOrder[2]]?.textValue ?? "")) | \(row.values[row.columnOrder[3]]?.intValue ?? 0) |\n"
        }
        return ReportData(path: "", content: content, format: .md)
    }

    /// 逐字移植 generateReport 的 keyword 分支前半：关键字集合聚合
    /// （role_bindings.keywords 的 JSON 数组 + culling 决策 keep/reject 标记）。
    public static func keywords(bindingRows: [SQLiteRow], cullingRows: [SQLiteRow]) -> Set<String> {
        var keywords = Set<String>()
        for row in bindingRows {
            keywords.formUnion((try? JSONValue.parse(row.values[row.columnOrder[0]]?.textValue ?? "[]"))?.arrayValue ?? [])
        }
        for row in cullingRows {
            if row.values[row.columnOrder[0]]?.textValue == "keep" { keywords.insert("culling:keep") }
            if row.values[row.columnOrder[0]]?.textValue == "reject" { keywords.insert("culling:reject") }
        }
        return keywords
    }

    /// 逐字移植 generateReport 的 keyword 分支后半（排序后逐行 "- 值"，非空补尾换行）。
    public static func keywordReport(keywords: Set<String>) -> ReportData {
        var content = "# Keyword report\n\n"
        content += keywords.sorted().map { "- \(Self.mdField($0))" }.joined(separator: "\n")
        if !keywords.isEmpty { content += "\n" }
        return ReportData(path: "", content: content, format: .md)
    }

    /// 逐字移植 generateReport 的 default 分支：空内容、保留请求格式。
    public static func emptyReport(format: ReportFormat) -> ReportData {
        ReportData(path: "", content: "", format: format)
    }

    /// 逐字移植 ExportService.csvField(_:)。
    public static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// 逐字移植 ExportService.mdField(_:)。
    public static func mdField(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
