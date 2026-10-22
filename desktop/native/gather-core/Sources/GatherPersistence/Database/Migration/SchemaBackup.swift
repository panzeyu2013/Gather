// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaBackup.swift
// WP6b：迁移前的一致性备份（设计 §4.3）。
//
// 为什么用 VACUUM INTO 而不是 FileManager.copyItem：文件拷贝会把 -wal/-shm 的
// 未提交页带出不一致状态，还要额外处理两个 sidecar；VACUUM INTO 产出单文件、
// 只含已提交页，天然是一致性快照。
//
// 纪律：
//   * 备份是迁移的**前置条件**：备份失败（磁盘满/权限/校验失败）就抛 .io，绝不迁移；
//   * 备份成功后不删除（成功与失败都保留，用于现场恢复）；
//   * 命名 <db>.pre-v<target>-yyyyMMdd-HHmmss[-N]，按 retainMigrationBackups
//     （默认 3）从旧到新淘汰；
//   * 校验用只读连接（SQLITE_OPEN_READONLY）跑 quick_check + user_version，
//     校验过程不得改动备份文件。
import Foundation
import CSQLite
import GatherProtocol

enum SchemaBackup {
    /// 迁移前备份 + 校验；返回备份文件路径。任何失败都收敛为 .io（调用方不迁移）。
    static func create(
        connection: DBConnection,
        at path: String,
        from: SchemaVersion,
        to: SchemaVersion,
        retaining limit: Int
    ) throws -> String {
        do {
            // 先压 WAL，减少副本页；失败不致命（VACUUM INTO 仍只读已提交页）。
            do { _ = try connection.exec("PRAGMA wal_checkpoint(TRUNCATE);") } catch { /* 非致命 */ }

            let backup = uniqueBackupPath(for: path, to: to)
            try connection.exec("VACUUM INTO \(quoteLiteral(backup));")
            try verify(backup, expecting: from)
            pruneBackups(for: path, to: to, retaining: limit)
            GatherLogger.log(
                "schema_backup_ok from=\(from) to=\(to) path=\(path) backup=\(backup)",
                level: .info
            )
            return backup
        } catch let error as DatabaseError {
            throw error
        } catch let error as DBError {
            throw DatabaseError.io("迁移前备份失败（未迁移）：\(DatabaseError(dbError: error).message)")
        } catch {
            throw DatabaseError.io("迁移前备份失败（未迁移）：\(error)")
        }
    }

    // MARK: - 路径

    /// <db>.pre-v<target>-<yyyyMMdd-HHmmss>；同秒重复时追加 -2、-3…（不覆盖旧备份）。
    private static func uniqueBackupPath(for path: String, to: SchemaVersion) -> String {
        let base = path + ".pre-v\(to.rawValue)-" + timestamp()
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = base + "-\(counter)"
            counter += 1
        }
        return candidate
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func quoteLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// 最多保留 limit 套（主库 + 同套 -wal/-shm），按时间戳从旧到新淘汰；失败不致命。
    private static func pruneBackups(for path: String, to: SchemaVersion, retaining limit: Int) {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let baseName = URL(fileURLWithPath: path).lastPathComponent
        let names: [String]
        do { names = try fileManager.contentsOfDirectory(atPath: directory.path) } catch { return }

        let prefix = baseName + ".pre-v\(to.rawValue)-"
        var keys = Set<String>()
        for name in names where name.hasPrefix(prefix) {
            var key = String(name.dropFirst(prefix.count))
            for suffix in ["-wal", "-shm"] where key.hasSuffix(suffix) {
                key = String(key.dropLast(suffix.count))
            }
            keys.insert(key)
        }
        let keep = max(0, limit)
        guard keys.count > keep else { return }
        for key in keys.sorted().dropLast(keep) {
            for name in [prefix + key, prefix + key + "-wal", prefix + key + "-shm"] {
                do { try fileManager.removeItem(atPath: directory.appendingPathComponent(name).path) } catch { /* 淘汰失败不致命 */ }
            }
        }
    }

    // MARK: - 校验（只读）

    private static func verify(_ path: String, expecting version: SchemaVersion) throws {
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { handle.closeFile() }
            header = try handle.read(upToCount: 16) ?? Data()
        } catch {
            throw DatabaseError.io("读取迁移备份失败：\(path)：\(error.localizedDescription)")
        }
        guard header == Data("SQLite format 3\u{0}".utf8) else {
            throw DatabaseError.io("迁移备份不是 SQLite 文件：\(path)")
        }

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw DatabaseError.io("只读打开迁移备份失败（rc=\(rc)）：\(path)")
        }
        defer { sqlite3_close_v2(handle) }

        let quickCheck = try scalarText(handle, "PRAGMA quick_check;", context: "quick_check")
        guard quickCheck == "ok" else {
            throw DatabaseError.io("迁移备份 quick_check 失败（\(quickCheck)）：\(path)")
        }
        let actual = try scalarInt(handle, "PRAGMA user_version;", context: "user_version")
        guard actual == Int64(version.rawValue) else {
            throw DatabaseError.io(
                "迁移备份 user_version=\(actual)，期望 \(version.rawValue)：\(path)"
            )
        }
    }

    private static func scalarText(_ handle: OpaquePointer, _ sql: String, context: String) throws -> String {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw DatabaseError.io("\(context) 编译失败：\(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw DatabaseError.io("\(context) 无结果")
        }
        return String(cString: text)
    }

    private static func scalarInt(_ handle: OpaquePointer, _ sql: String, context: String) throws -> Int64 {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw DatabaseError.io("\(context) 编译失败：\(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.io("\(context) 无结果")
        }
        return sqlite3_column_int64(statement, 0)
    }
}
