// Tests/GatherCoreTests/Store/StoreSchemaSupport.swift
// R1 共享测试工具：结构指纹与数据摘要（新旧迁移器/建库路径的等价性判定）。
import Foundation
@testable import GatherCore

func storeFNV1a64(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
}

func storeTempPath(_ label: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-\(label)-\(UUID().uuidString).sqlite")
        .path
}

func storeTempDir(_ label: String) -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

func removeStoreFiles(_ path: String) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
    }
}

func removeStoreDirectory(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

/// 结构摘要：表、列（类型/NOT NULL/默认值/主键）、索引 SQL、外键、foreign_key_check。
func storeSchemaLines(_ database: SQLiteDatabase) async throws -> [String] {
    let tables = try await database.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).compactMap { $0.text("name") }

    var lines: [String] = []
    for table in tables {
        lines.append("TABLE \(table)")
        let columns = try await database.query("PRAGMA table_info(\(table))")
            .sorted { ($0.int("cid") ?? 0) < ($1.int("cid") ?? 0) }
        for column in columns {
            lines.append("  COL \(column.text("name") ?? "?") type=\(column.text("type") ?? "") notnull=\(column.int("notnull") ?? 0) pk=\(column.int("pk") ?? 0) default=\(column.text("dflt_value") ?? "<nil>")")
        }
        let indexes = try await database.query(
            "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? ORDER BY name",
            [.text(table)]
        )
        for index in indexes {
            let normalizedSQL = (index.text("sql") ?? "")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            lines.append("  IDX \(index.text("name") ?? "?") \(normalizedSQL)")
        }
        let foreignKeys = try await database.query("PRAGMA foreign_key_list(\(table))")
            .sorted { left, right in
                let leftID = left.int("id") ?? 0
                let rightID = right.int("id") ?? 0
                if leftID != rightID { return leftID < rightID }
                return (left.int("seq") ?? 0) < (right.int("seq") ?? 0)
            }
        for foreignKey in foreignKeys {
            lines.append("  FK \(foreignKey.int("id") ?? 0).\(foreignKey.int("seq") ?? 0) -> \(foreignKey.text("table") ?? "?") from=\(foreignKey.text("from") ?? "?") to=\(foreignKey.text("to") ?? "?") onDelete=\(foreignKey.text("on_delete") ?? "?")")
        }
    }
    let violations = try await database.query("PRAGMA foreign_key_check")
    lines.append("FK_CHECK rows=\(violations.count)")
    return lines
}

func storeSchemaFingerprint(_ database: SQLiteDatabase) async throws -> String {
    storeFNV1a64(try await storeSchemaLines(database).joined(separator: "\n"))
}

/// 数据摘要：逐表 rowid 顺序的全部单元格；默认排除 schema_version（applied_at 为时间戳）。
func storeDataDigest(_ database: SQLiteDatabase, excluding excluded: Set<String> = ["schema_version"]) async throws -> String {
    let tables = try await database.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).compactMap { $0.text("name") }

    var lines: [String] = []
    for table in tables where !excluded.contains(table) {
        let rows = try await database.query("SELECT * FROM \(table) ORDER BY rowid")
        lines.append("TABLE \(table) rows=\(rows.count)")
        for row in rows {
            let cells = row.columnOrder.map { name -> String in
                switch row.values[name] ?? .null {
                case .null: return "NULL"
                case .int(let value): return String(value)
                case .real(let value): return String(value)
                case .text(let value): return value
                case .blob(let value): return value.base64EncodedString()
                }
            }
            lines.append(cells.joined(separator: "\u{1F}"))
        }
    }
    return storeFNV1a64(lines.joined(separator: "\n"))
}
