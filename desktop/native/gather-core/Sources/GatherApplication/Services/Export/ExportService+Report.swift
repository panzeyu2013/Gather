// desktop/native/gather-core/Sources/GatherApplication/Services/Export/ExportService+Report.swift
// P1-4 收口：ExportService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：报告生成（session_summary / person / keyword）与 CSV/Markdown 字段转义。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import CoreText
#endif

extension ExportService {

    // MARK: - 报表

    public func generateReport(
        sessionId: String,
        reportType: String,
        format: String? = nil
    ) throws -> ReportData {
        let requested = format == "md" ? ReportFormat.md : ReportFormat.csv
        switch reportType {
        case "session_summary":
            let rows = try photoRepo.reportRows(sessionId: sessionId)
            if requested == .csv {
                var content = "filename,filepath,status\n"
                content += rows.map { row in
                    [row.filename, row.filepath, row.status]
                        .map(Self.csvField).joined(separator: ",")
                }.joined(separator: "\n")
                return ReportData(path: "", content: content, format: .csv)
            }
            var content = "# Session summary\n\n"
            content += "Total photos: \(rows.count)\n\n"
            content += "| # | Filename | Path | Status |\n|---:|---|---|---|\n"
            for (index, row) in rows.enumerated() {
                content += "| \(index + 1) | \(Self.mdField(row.filename)) | \(Self.mdField(row.filepath)) | \(Self.mdField(row.status)) |\n"
            }
            return ReportData(path: "", content: content, format: .md)

        case "person":
            // 成员数唯一真相 = COUNT(face_cluster_members)（face_clusters.member_count
            // 只是派生缓存，可能与实时成员表漂移）；与 FaceRepo 同一口径。
            let rows = try reports.personBindingRows(sessionId: sessionId)
            var content = "# Person report\n\nBindings: \(rows.count)\n\n"
            content += "| Role | Keywords | Cluster | Members |\n|---|---|---|---:|\n"
            for row in rows {
                let keywords = (try? JSONValue.parse(row.keywordsJSON))?.arrayValue?.joined(separator: ", ") ?? ""
                content += "| \(Self.mdField(row.roleName)) | \(Self.mdField(keywords)) | \(Self.mdField(row.label)) | \(row.memberCount) |\n"
            }
            return ReportData(path: "", content: content, format: .md)

        case "keyword":
            let rows = try reports.keywordRows(sessionId: sessionId)
            var keywords = Set<String>()
            for row in rows {
                keywords.formUnion((try? JSONValue.parse(row))?.arrayValue ?? [])
            }
            let culling = try reports.cullingDecisionRows(sessionId: sessionId)
            for decision in culling {
                if decision == "keep" { keywords.insert("culling:keep") }
                if decision == "reject" { keywords.insert("culling:reject") }
            }
            var content = "# Keyword report\n\n"
            content += keywords.sorted().map { "- \(Self.mdField($0))" }.joined(separator: "\n")
            if !keywords.isEmpty { content += "\n" }
            return ReportData(path: "", content: content, format: .md)

        default:
            return ReportData(path: "", content: "", format: requested)
        }
    }

    // MARK: - 报表字段转义

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func mdField(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
