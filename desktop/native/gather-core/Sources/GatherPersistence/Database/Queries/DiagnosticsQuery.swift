// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/DiagnosticsQuery.swift
// P0 / B0：诊断包的数据库只读查询（原 DiagnosticsCollector 内联 SQL 下沉）。
import Foundation

public struct DiagnosticsJobRow: Sendable, Equatable {
    public let id: String
    public let type: String
    public let status: String
    public let progressCurrent: Int64
    public let progressTotal: Int64
    public let errorCode: String?

    public init(
        id: String, type: String, status: String,
        progressCurrent: Int64, progressTotal: Int64, errorCode: String?
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.progressCurrent = progressCurrent
        self.progressTotal = progressTotal
        self.errorCode = errorCode
    }
}

public struct DiagnosticsQuery {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func tableCount() throws -> Int {
        guard let row = try connection.prepare(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).get([]), let count = row[0].intValue else { return 0 }
        return Int(count)
    }

    public func schemaVersion() throws -> Int {
        guard let row = try connection.prepare("PRAGMA user_version").get([]),
              let value = row[0].intValue else { return 0 }
        return Int(value)
    }

    public func tableCount(_ name: String) throws -> Int {
        guard let row = try connection.prepare("SELECT COUNT(*) FROM \(name)").get([]),
              let count = row[0].intValue else { return 0 }
        return Int(count)
    }

    public func recentJobs(limit: Int) throws -> [DiagnosticsJobRow] {
        let rows = try connection.prepare("""
            SELECT id, type, status, progress_current, progress_total, error_code
            FROM analysis_jobs ORDER BY id DESC LIMIT ?
            """).query([.int(Int64(limit))])
        return rows.map { row in
            DiagnosticsJobRow(
                id: row[0].textValue ?? "",
                type: row[1].textValue ?? "",
                status: row[2].textValue ?? "",
                progressCurrent: row[3].intValue ?? 0,
                progressTotal: row[4].intValue ?? 0,
                errorCode: row[5].textValue
            )
        }
    }
}
