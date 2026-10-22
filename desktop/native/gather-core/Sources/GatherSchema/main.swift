// desktop/native/gather-core/Sources/GatherSchema/main.swift
// Cut 3 / 3a-5（D-015）：GatherSchema —— schema 工具可执行（dump / verify）。
//
// DDL 的唯一真相源仍在 GatherPersistence（Sources/GatherPersistence/Database/SchemaV1.swift）；
// 本 target 依赖 GatherPersistence 而**不导出库**，也不复制任何 DDL 文本。
//
// 用法：
//   swift run gather-schema dump      # 打印 SchemaV1.sql（建库 DDL 全文）
//   swift run gather-schema verify    # 在内存库上重建 schema 并校验不变量
//   swift run gather-schema --help    # 打印帮助
//
// 退出码：0 成功；1 校验失败（不变量不满足 / 建库抛错）；2 参数用法错误。
//
// 为什么 verify 不打开磁盘上的库：Database.open(at:) 对 user_version 不兼容的库会
// **重置**（改名备份 + 重建），这对一个「只读校验」工具是破坏性的。文件级校验需要
// 单独的只读连接实现，不在本步范围内；这里只验证 DDL 能否一次成型且不变量成立。
import Foundation
import GatherPersistence

/// verify 钉死的不变量（与 Tests/GatherCoreTests/Database/SchemaV1Tests.swift 同源）。
private enum SchemaInvariant {
    /// SchemaV1 的表数（不含 SQLite 内部表 sqlite_*）。
    static let tableCount = 43
    /// 期望的库版本号（PRAGMA user_version）。
    static let userVersion = SchemaV1.userVersion
}

/// 校验失败（携带人类可读原因；由顶层统一转成 exit 1）。
private struct VerifyFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private let usage = """
gather-schema — Gather 本地库 schema 工具（Cut 3 / 3a-5，D-015）

用法：
  gather-schema dump      打印 SchemaV1.sql（建库 DDL 的唯一真相源）
  gather-schema verify    在内存库上重建 schema 并校验不变量：
                            \(SchemaInvariant.tableCount) 张表 / PRAGMA user_version = \(SchemaInvariant.userVersion) /
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

/// 在内存库上按 SchemaV1 一次成型，并校验 43 表 / user_version / 外键一致性。
private func verifySchema() throws -> (tables: Int, version: Int, violations: Int) {
    let database = try Database.openInMemory()
    defer { database.close() }

    return try database.read { connection in
        guard let versionRow = try connection.prepare("PRAGMA user_version;").get([]),
              let version = versionRow[0].intValue
        else {
            throw VerifyFailure("读取 PRAGMA user_version 无结果")
        }

        guard let countRow = try connection
            .prepare("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';")
            .get([]),
            let tables = countRow[0].intValue
        else {
            throw VerifyFailure("统计 sqlite_master 用户表失败")
        }

        let violations = try connection.prepare("PRAGMA foreign_key_check;").query([]).count

        guard version == Int64(SchemaInvariant.userVersion) else {
            throw VerifyFailure(
                "user_version=\(version)，期望 \(SchemaInvariant.userVersion)"
            )
        }
        guard tables == Int64(SchemaInvariant.tableCount) else {
            throw VerifyFailure(
                "表数=\(tables)，期望 \(SchemaInvariant.tableCount)"
            )
        }
        guard violations == 0 else {
            throw VerifyFailure("foreign_key_check 发现 \(violations) 条违规")
        }
        return (Int(tables), Int(version), violations)
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
    // 原样输出 DDL 全文：末尾补一个换行，便于终端拼接。
    writeStdout(SchemaV1.sql.hasSuffix("\n") ? SchemaV1.sql : SchemaV1.sql + "\n")
    exit(0)

case "verify":
    guard arguments.count == 1 else {
        writeStderr("gather-schema: verify 不接受额外参数（文件级校验不在本步范围）\n\n\(usage)")
        exit(2)
    }
    do {
        let result = try verifySchema()
        writeStdout(
            "schema ok: tables=\(result.tables) user_version=\(result.version) "
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
