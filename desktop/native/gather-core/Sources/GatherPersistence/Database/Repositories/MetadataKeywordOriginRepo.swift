// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/MetadataKeywordOriginRepo.swift
// TS 源: desktop/src/main/db/repositories/metadata-keyword-origin.repo.ts
import Foundation

/// metadata_keyword_origins 仓库（TS MetadataKeywordOriginRepository）。
public final class MetadataKeywordOriginRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func markIntroduced(xmpPath: String, source: String, keywords: [String]) throws {
        if keywords.isEmpty { return }
        let timestamp = nowISOString()
        let statement = try connection.prepare("""
            INSERT INTO metadata_keyword_origins (
              xmp_path, source, keyword, active, created_at, updated_at
            ) VALUES (?, ?, ?, 1, ?, ?)
            ON CONFLICT(xmp_path, source, keyword) DO UPDATE SET
              active = 1, updated_at = excluded.updated_at
          """)
        try connection.transaction {
            // TS `new Set(keywords)`：去重且保留首次出现顺序（Swift Set 无序，需显式保持）
            var seen = Set<String>()
            for keyword in keywords where seen.insert(keyword).inserted {
                _ = try statement.run([.text(xmpPath), .text(source), .text(keyword), .text(timestamp), .text(timestamp)])
            }
        }
    }

    public func getActiveIntroduced(xmpPath: String, source: String, keywords: [String]) throws -> [String] {
        if keywords.isEmpty { return [] }
        let placeholders = keywords.map { _ in "?" }.joined(separator: ", ")
        var values: [DBValue?] = [.text(xmpPath), .text(source)]
        values.append(contentsOf: keywords.map { .text($0) })
        let rows = try connection.prepare("""
            SELECT keyword FROM metadata_keyword_origins
            WHERE xmp_path = ? AND source = ? AND active = 1
              AND keyword IN (\(placeholders))
          """).query(values)
        return rows.compactMap { $0[0].textValue }
    }

    public func deactivate(xmpPath: String, source: String, keywords: [String]) throws {
        if keywords.isEmpty { return }
        let placeholders = keywords.map { _ in "?" }.joined(separator: ", ")
        var values: [DBValue?] = [.text(nowISOString()), .text(xmpPath), .text(source)]
        values.append(contentsOf: keywords.map { .text($0) })
        _ = try connection.prepare("""
            UPDATE metadata_keyword_origins
            SET active = 0, updated_at = ?
            WHERE xmp_path = ? AND source = ?
              AND keyword IN (\(placeholders))
          """).run(values)
    }
}
