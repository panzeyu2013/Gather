// Runtime/Export/SQLiteExportReportSource.swift
// W2d-4 步骤②：ExportReportSource 的生产实现（ExportRuntime.Dependencies 装配用）。
//
// 门禁：本文件不出现 SQL 文本、不引用 SQLiteDatabase/CSQLite；四条报告查询由
// Store/ExportStore.swift 的 SQLiteExportStore 独占（R1：Store 是唯一 SQL 所有者）。
// 本类型只做协议转发，返回值 SQLiteRow 原样透传（columnOrder 不变）。
import Foundation

/// 生产实现：把 ExportReportSource 的四个报告查询转发给注入的 ExportStore。
public struct SQLiteExportReportSource: ExportReportSource {
    private let store: any ExportStore

    public init(store: any ExportStore) {
        self.store = store
    }

    public func sessionSummaryRows(sessionId: String) async throws -> [SQLiteRow] {
        try await store.sessionSummaryRows(sessionId: sessionId)
    }

    public func personRows(sessionId: String) async throws -> [SQLiteRow] {
        try await store.personRows(sessionId: sessionId)
    }

    public func keywordRows(sessionId: String) async throws -> [SQLiteRow] {
        try await store.keywordRows(sessionId: sessionId)
    }

    public func cullingDecisionRows(sessionId: String) async throws -> [SQLiteRow] {
        try await store.cullingDecisionRows(sessionId: sessionId)
    }
}
