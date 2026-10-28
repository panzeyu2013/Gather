// desktop/native/gather-core/Sources/GatherSchema/main.swift
// Cut 3 / 3a-5（D-015）：GatherSchema —— schema 工具可执行（dump / verify）。
// verify 对齐 user_version=4 与完整的 44/384/72/65 数字；dump 打印当前 schema 建库 DDL。
//
// DDL 的唯一真相源仍在 GatherPersistence（Sources/GatherPersistence/Database/SchemaCurrent.swift）；
// 本 target 依赖 GatherPersistence 而**不导出库**，也不复制任何 DDL 文本。
//
// 用法：
//   swift run gather-schema dump      # 打印当前 schema（V4）建库 DDL
//   swift run gather-schema verify    # 在内存库上重建 schema 并校验不变量
//   swift run gather-schema --help    # 打印帮助
//
// 退出码：0 成功；1 校验失败（不变量不满足 / 建库抛错）；2 参数用法错误。
//
// 为什么 verify 不打开磁盘上的库：Database.open(at:) 对 V1 库会备份并迁移、对不兼容库
// 默认 fail closed、显式 reset 时还会改名。这都不是一个「只读校验」工具该做的事；
// 文件级只读校验需要独立连接实现，不在本步范围内。这里只验证当前 DDL 能否一次成型
// 且不变量成立。
import Foundation
import GatherPersistence

/// verify 钉死的不变量（与 Tests/GatherCoreTests/Database/SchemaCurrentTests.swift 同源）。
private enum SchemaInvariant {
    static let tableCount = SchemaCurrent.expectedTableCount
    static let columnCount = SchemaCurrent.expectedColumnCount
    static let explicitIndexCount = SchemaCurrent.expectedExplicitIndexCount
    static let foreignKeyCount = SchemaCurrent.expectedForeignKeyCount
    static let userVersion = SchemaCurrent.userVersion
}

/// 校验失败（携带人类可读原因；由顶层统一转成 exit 1）。
private struct VerifyFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private let usage = """
gather-schema — Gather 本地库 schema 工具（Cut 3 / 3a-5，D-015）

用法：
  gather-schema dump      打印当前 schema（V4）建库 DDL（含 PRAGMA user_version = 4）
  gather-schema verify    在内存库上重建 schema 并校验不变量：
                            \(SchemaInvariant.tableCount) 张表 / \(SchemaInvariant.columnCount) 列 /
                            \(SchemaInvariant.explicitIndexCount) 显式索引 / \(SchemaInvariant.foreignKeyCount) 外键 /
                            PRAGMA user_version = \(SchemaInvariant.userVersion) /
                            PRAGMA foreign_key_check 无违规
  gather-schema --help    打印本帮助

退出码：0 成功；1 校验失败；2 参数用法错误。
"""

private func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

private func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

private func fail(_ message: String) -> Never {
    writeStderr("gather-schema: \(message)\n")
    exit(1)
}

private func quoteIdentifier(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

private struct SchemaCounts {
    let tables: Int
    let columns: Int
    let indexes: Int
    let foreignKeys: Int
    let version: Int
    let violations: Int
}

/// 在内存库上按当前快照一次成型，并校验表/列/索引/外键/版本/外键一致性。
private func verifySchema() throws -> SchemaCounts {
    let database = try Database.openInMemory()
    defer { database.close() }

    return try database.read { connection in
        guard let versionRow = try connection.prepare("PRAGMA user_version;").get([]),
              let version = versionRow[0].intValue
        else {
            throw VerifyFailure("读取 PRAGMA user_version 无结果")
        }

        let tables = try connection.prepare("""
            SELECT name FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
             ORDER BY name
            """).query([]).compactMap { $0[0].textValue }

        var columns = 0
        var foreignKeys = 0
        for table in tables {
            columns += try connection.prepare("PRAGMA table_info(\(quoteIdentifier(table)));")
                .query([]).count
            foreignKeys += try connection.prepare("PRAGMA foreign_key_list(\(quoteIdentifier(table)));")
                .query([]).count
        }

        guard let indexRow = try connection.prepare("""
            SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'index' AND sql IS NOT NULL
            """).get([]),
            let indexes = indexRow[0].intValue
        else {
            throw VerifyFailure("统计显式索引失败")
        }

        let violations = try connection.prepare("PRAGMA foreign_key_check;").query([]).count

        guard version == Int64(SchemaInvariant.userVersion) else {
            throw VerifyFailure(
                "user_version=\(version)，期望 \(SchemaInvariant.userVersion)"
            )
        }
        guard tables.count == SchemaInvariant.tableCount else {
            throw VerifyFailure(
                "表数=\(tables.count)，期望 \(SchemaInvariant.tableCount)"
            )
        }
        guard columns == SchemaInvariant.columnCount else {
            throw VerifyFailure(
                "列数=\(columns)，期望 \(SchemaInvariant.columnCount)"
            )
        }
        guard indexes == Int64(SchemaInvariant.explicitIndexCount) else {
            throw VerifyFailure(
                "显式索引=\(indexes)，期望 \(SchemaInvariant.explicitIndexCount)"
            )
        }
        guard foreignKeys == SchemaInvariant.foreignKeyCount else {
            throw VerifyFailure(
                "外键=\(foreignKeys)，期望 \(SchemaInvariant.foreignKeyCount)"
            )
        }
        guard violations == 0 else {
            throw VerifyFailure("foreign_key_check 发现 \(violations) 条违规")
        }
        return SchemaCounts(
            tables: tables.count,
            columns: columns,
            indexes: Int(indexes),
            foreignKeys: foreignKeys,
            version: Int(version),
            violations: violations
        )
    }
}

// MARK: - 入口

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "--help", "-h":
    writeStdout(usage)
    exit(0)

case "dump":
    guard arguments.count == 1 else {
        writeStderr("gather-schema: dump 不接受额外参数\n\n\(usage)")
        exit(2)
    }
    // 打印当前 schema 建库 DDL；末尾补一个换行，便于终端拼接。
    let sql = SchemaCurrent.createSQL
    writeStdout(sql.hasSuffix("\n") ? sql : sql + "\n")
    exit(0)

case "verify":
    guard arguments.count == 1 else {
        writeStderr("gather-schema: verify 不接受额外参数（文件级校验不在本步范围）\n\n\(usage)")
        exit(2)
    }
    do {
        let result = try verifySchema()
        writeStdout(
            "schema ok: tables=\(result.tables) columns=\(result.columns) indexes=\(result.indexes) "
                + "fks=\(result.foreignKeys) user_version=\(result.version) "
                + "foreign_key_violations=\(result.violations)\n"
        )
        exit(0)
    } catch {
        fail("verify 失败: \(error)")
    }

case nil:
    writeStderr("gather-schema: 缺少子命令\n\n\(usage)")
    exit(2)

case let other?:
    writeStderr("gather-schema: 未知子命令 \(other)\n\n\(usage)")
    exit(2)
}
