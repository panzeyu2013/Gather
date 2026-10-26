// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/ResetSupport.swift
// WP6a：开发重置的文件操作（从 Database.swift 抽出，行为逐字保留）。
//
// 只在 Options.resetPolicy == .renameToIncompatible 时调用；默认 .failClosed 下
// open 只抛错，绝不改名/删除用户库。顺序仍是 -shm → -wal → 主库：
//   * 先移 sidecar：避免「新库 + 旧 WAL」被 SQLite 按同名前缀恢复出旧页；
//   * 最后移主库：中途失败时用户数据仍在原路径，可人工恢复。
// 任一步移动失败抛 .io（不吞），并提示手动备份后重试。
import Foundation
import GatherProtocol

enum SchemaReset {
    /// 把 db/-wal/-shm 改名为 <db>.incompatible-<ts>，返回主库副本路径。
    static func reset(
        at path: String,
        options: Database.Options,
        reason: Database.ResetReason,
        previousVersion: Int?
    ) throws -> String {
        let fileManager = FileManager.default
        let target = uniqueIncompatiblePath(for: path)

        for suffix in ["-shm", "-wal"] where fileManager.fileExists(atPath: path + suffix) {
            do {
                try fileManager.moveItem(atPath: path + suffix, toPath: target + suffix)
            } catch {
                throw DatabaseError.io(
                    "移走 \(path + suffix) 失败：\(error.localizedDescription)。请手动备份 \(path) 后重试"
                )
            }
        }
        if fileManager.fileExists(atPath: path) {
            do {
                try fileManager.moveItem(atPath: path, toPath: target)
            } catch {
                throw DatabaseError.io(
                    "移走 \(path) 失败：\(error.localizedDescription)。请手动备份 \(path) 后重试"
                )
            }
        }

        pruneIncompatibleCopies(for: path, retaining: options.retainIncompatibleCopies)
        let detected = previousVersion.map(String.init) ?? "unreadable"
        GatherLogger.log(
            "schema_reset_dev user_version=\(detected) expected=\(SchemaCurrent.userVersion) "
                + "path=\(path) backup=\(target) reason=\(reason)",
            level: .warn
        )
        return target
    }

    /// <db>.incompatible-<yyyyMMdd-HHmmss>；同秒重复时追加 -2、-3…（不覆盖旧副本）。
    private static func uniqueIncompatiblePath(for path: String) -> String {
        let base = path + ".incompatible-" + incompatibleTimestamp()
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = base + "-\(counter)"
            counter += 1
        }
        return candidate
    }

    private static func incompatibleTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 最多保留 limit 套（主库 + 同套 -wal/-shm），按时间戳从旧到新淘汰；失败不致命。
    private static func pruneIncompatibleCopies(for path: String, retaining limit: Int) {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let baseName = URL(fileURLWithPath: path).lastPathComponent
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }

        let prefix = baseName + ".incompatible-"
        var keys = Set<String>()
        for name in names where name.hasPrefix(prefix) {
            var key = String(name.dropFirst(prefix.count))
            for suffix in ["-wal", "-shm"] where key.hasSuffix(suffix) {
                key = String(key.dropLast(suffix.count))
            }
            keys.insert(key)
        }
        // 至少保留 1 份：limit=0 时把刚改名的旧库当场删掉会违背「改名保留」契约，
        // 且让调用方的 outcome.backup 指向已删文件。
        let keep = max(1, limit)
        guard keys.count > keep else { return }
        for key in keys.sorted().dropLast(keep) {
            for name in [prefix + key, prefix + key + "-wal", prefix + key + "-shm"] {
                try? fileManager.removeItem(atPath: directory.appendingPathComponent(name).path)
            }
        }
    }
}
