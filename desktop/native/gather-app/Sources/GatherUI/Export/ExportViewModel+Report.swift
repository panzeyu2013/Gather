// desktop/native/gather-app/Sources/GatherUI/Export/ExportViewModel+Report.swift
// Cut 4 / 4c-2f：CSV / Markdown 报告（原 ExportView.swift 465-480）。正文逐字未动。
import GatherProtocol

extension ExportViewModel {
    public func generateReport(format: ReportFormat) async {
        do {
            report = try await exportAPI.report(
                try ExportReportInput(
                    sessionId: sessionId,
                    reportType: "session_summary",
                    format: format
                )
            )
            notice = LocalizedText("报告已生成：%@", params: [report?.path ?? ""])
            fieldError = nil
        } catch {
            errorMessage = CommandError(error)
            fieldError = nil
        }
    }
}
