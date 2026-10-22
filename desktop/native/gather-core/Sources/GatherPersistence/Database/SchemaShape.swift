// desktop/native/gather-core/Sources/GatherPersistence/Database/SchemaShape.swift
// WP6a：把 Database.open 内联的 schema 列形读取/比对抽成独立文件（设计 §5.1）。
//
// 行为必须与抽取前**逐字等价**：canonical 口径与 SHA-256 指纹算法一行未改，
// 只是从 Database 的 private static 变成同模块 internal 类型，供 open、迁移器与
// 测试共用。改 canonical 任何一段都必须重算 SchemaV1.expectedShapeFingerprint。
//
// canonical 口径：
//   table\t<name>
//   column\t<name>\t<type>\t<notnull>\t<dflt>\t<pk>
//   fk\t<ref table>\t<seq>\t<from>\t<to>\t<on_update>\t<on_delete>\t<match>
//   index\t<name>\t<sql>
// 表按名字、列按 cid、外键按 (id,seq)、显式索引按名字排序；排除 sqlite_* 内部表
// 与 sql 为 NULL 的自动索引。
import Foundation

/// 当前库的规范化列形（读取结果；不参与持久化）。
struct SchemaShapeSnapshot: Sendable {
    let tableCount: Int
    let columnCount: Int
    let explicitIndexCount: Int
    let foreignKeyCount: Int
    let columnsByTable: [String: Set<String>]
    let fingerprint: String
}

/// 某个 schema 版本**应该**具备的列形（来自 SchemaV1.shape / 未来的 SchemaVn.shape）。
///
/// 计数用于可读报错；关键表列集合兜「少关键列」；指纹兜「列名/类型/默认值/外键/
/// 索引变了但计数没变」。三者任一不符都意味着旧库或损坏库。
public struct SchemaShapeExpectation: Sendable, Equatable {
    public let tableCount: Int
    public let columnCount: Int
    public let explicitIndexCount: Int
    public let foreignKeyCount: Int
    public let requiredColumns: [String: Set<String>]
    public let fingerprint: String

    public init(
        tableCount: Int,
        columnCount: Int,
        explicitIndexCount: Int,
        foreignKeyCount: Int,
        requiredColumns: [String: Set<String>],
        fingerprint: String
    ) {
        self.tableCount = tableCount
        self.columnCount = columnCount
        self.explicitIndexCount = explicitIndexCount
        self.foreignKeyCount = foreignKeyCount
        self.requiredColumns = requiredColumns
        self.fingerprint = fingerprint
    }

    /// 返回列形不符的原因（空数组 = 完全一致）。顺序与历史报错一致。
    func issues(against snapshot: SchemaShapeSnapshot) -> [String] {
        var issues: [String] = []

        if snapshot.tableCount != tableCount {
            issues.append("表数 \(snapshot.tableCount)，期望 \(tableCount)")
        }
        if snapshot.columnCount != columnCount {
            issues.append("列数 \(snapshot.columnCount)，期望 \(columnCount)")
        }
        if snapshot.explicitIndexCount != explicitIndexCount {
            issues.append("显式索引 \(snapshot.explicitIndexCount)，期望 \(explicitIndexCount)")
        }
        if snapshot.foreignKeyCount != foreignKeyCount {
            issues.append("外键 \(snapshot.foreignKeyCount)，期望 \(foreignKeyCount)")
        }
        for table in requiredColumns.keys.sorted() {
            guard let actual = snapshot.columnsByTable[table] else {
                issues.append("缺表 \(table)")
                continue
            }
            let required = requiredColumns[table] ?? []
            let missing = required.subtracting(actual).sorted()
            if !missing.isEmpty {
                issues.append("表 \(table) 缺列 [\(missing.joined(separator: ","))]")
            }
        }
        if snapshot.fingerprint != fingerprint {
            issues.append("列形指纹 \(snapshot.fingerprint)，期望 \(fingerprint)")
        }
        return issues
    }
}

/// 读取连接上的完整列形并计算规范化指纹。
enum SchemaShapeReader {
    static func read(_ connection: DBConnection) throws -> SchemaShapeSnapshot {
        let tableNames = try connection.prepare("""
            SELECT name FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
             ORDER BY name
            """).query([]).compactMap { $0[0].textValue }

        var canonical = ""
        var columnsByTable: [String: Set<String>] = [:]
        var columnCount = 0
        var foreignKeyCount = 0

        for table in tableNames {
            canonical += "table\t\(table)\n"
            let quotedTable = quoteIdentifier(table)

            let columnRows = try connection
                .prepare("PRAGMA table_info(\(quotedTable));")
                .query([])
                .map { row -> (cid: Int, name: String, type: String, notNull: Int, defaultValue: String, pk: Int) in
                    (
                        cid: Int(row[0].intValue ?? 0),
                        name: row[1].textValue ?? "",
                        type: row[2].textValue ?? "",
                        notNull: Int(row[3].intValue ?? 0),
                        defaultValue: shapeText(row[4]),
                        pk: Int(row[5].intValue ?? 0)
                    )
                }
                .sorted { $0.cid < $1.cid }
            for column in columnRows {
                columnCount += 1
                columnsByTable[table, default: []].insert(column.name)
                canonical += "column\t\(column.name)\t\(column.type)\t\(column.notNull)"
                    + "\t\(column.defaultValue)\t\(column.pk)\n"
            }

            let foreignKeyRows = try connection
                .prepare("PRAGMA foreign_key_list(\(quotedTable));")
                .query([])
                .map { row -> (id: Int, seq: Int, table: String, from: String, to: String, onUpdate: String, onDelete: String, match: String) in
                    (
                        id: Int(row[0].intValue ?? 0),
                        seq: Int(row[1].intValue ?? 0),
                        table: row[2].textValue ?? "",
                        from: row[3].textValue ?? "",
                        to: row[4].textValue ?? "",
                        onUpdate: row[5].textValue ?? "",
                        onDelete: row[6].textValue ?? "",
                        match: row[7].textValue ?? ""
                    )
                }
                .sorted { ($0.id, $0.seq) < ($1.id, $1.seq) }
            foreignKeyCount += foreignKeyRows.count
            for foreignKey in foreignKeyRows {
                canonical += "fk\t\(foreignKey.table)\t\(foreignKey.seq)\t\(foreignKey.from)"
                    + "\t\(foreignKey.to)\t\(foreignKey.onUpdate)\t\(foreignKey.onDelete)"
                    + "\t\(foreignKey.match)\n"
            }
        }

        let indexRows = try connection.prepare("""
            SELECT name, sql FROM sqlite_master
             WHERE type = 'index' AND sql IS NOT NULL
             ORDER BY name
            """).query([])
        for row in indexRows {
            canonical += "index\t\(row[0].textValue ?? "")\t\(row[1].textValue ?? "")\n"
        }

        let fingerprint = SHA256.hash(Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return SchemaShapeSnapshot(
            tableCount: tableNames.count,
            columnCount: columnCount,
            explicitIndexCount: indexRows.count,
            foreignKeyCount: foreignKeyCount,
            columnsByTable: columnsByTable,
            fingerprint: fingerprint
        )
    }

    private static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 把 PRAGMA 返回值规范化为稳定文本（NULL 与各存储类都显式区分）。
    private static func shapeText(_ value: DBValue?) -> String {
        switch value {
        case .none, .null:
            return "<null>"
        case .int(let value):
            return String(value)
        case .real(let value):
            return String(value)
        case .text(let value):
            return value
        case .blob(let data):
            return "blob:\(data.count)"
        }
    }
}
