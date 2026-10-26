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

    /// 批量读取某个来源在多个侧车上的全部 active origin（一次 IN 查询）。
    /// 调用方在 Swift 侧用 fold 比对，避免大小写/NFC 差异绕过生成词保护。
    public func activeKeywordOrigins(
        xmpPaths: [String],
        source: String
    ) throws -> [(xmpPath: String, keyword: String)] {
        let paths = Array(Set(xmpPaths))
        guard !paths.isEmpty else { return [] }
        var result: [(xmpPath: String, keyword: String)] = []
        for chunk in stride(from: 0, to: paths.count, by: 800).map({
            Array(paths[$0..<min($0 + 800, paths.count)])
        }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            var values: [DBValue?] = [.text(source)]
            values.append(contentsOf: chunk.map { .text($0) })
            let rows = try connection.prepare("""
                SELECT xmp_path, keyword FROM metadata_keyword_origins
                WHERE source = ? AND active = 1 AND xmp_path IN (\(placeholders))
                """).query(values)
            for row in rows {
                guard let path = row[0].textValue, let keyword = row[1].textValue else { continue }
                result.append((path, keyword))
            }
        }
        return result
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
