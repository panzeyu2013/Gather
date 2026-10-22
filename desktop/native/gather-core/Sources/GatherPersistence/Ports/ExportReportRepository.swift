// desktop/native/gather-core/Sources/GatherPersistence/Ports/ExportReportRepository.swift
// WP3b-1：ExportService 报告查询端口。
import Foundation

public protocol ExportReportRepository {
    func personBindingRows(sessionId: String) throws -> [ExportPersonBindingRow]
    func keywordRows(sessionId: String) throws -> [String]
    func cullingDecisionRows(sessionId: String) throws -> [String]
    func keptPhotoIds(sessionId: String) throws -> Set<String>
}

extension ExportReportRepo: ExportReportRepository {}
