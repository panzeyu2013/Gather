// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/ResetSupport.swift
// WP6a：不兼容库的归档改名（从 Database.swift 抽出）。生产（.renameOlderOnly）与
// 开发（.renameToIncompatible）共用，唯一区别是调用方放不放行。
//
// 只在 Options.resetPolicy 允许时调用（生产 .renameOlderOnly / 开发 .renameToIncompatible）；
// 默认 .failClosed 下 open 只抛错，绝不改名/删除用户库。
// 顺序：主库 → 同目录临时名 → -shm/-wal → 主库临时名改成 .incompatible-<ts>。
//   * 旧 WAL 必须跟着主库一起走，否则「新库 + 旧 WAL」会被 SQLite 按同名前缀恢复出旧页；
//   * 主库先离开原路径，任何一步失败都能按逆序回滚，用户数据不会与 sidecar 分家。
// 任一步移动失败回滚后抛 .io（不吞），并提示手动备份后重试。
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
        // 先把主库改到同目录临时名：此刻原路径上没有库文件，新库还不会被创建；
        // 随后搬 sidecar，最后把临时名改成 .incompatible-<ts>。
        // 任何一步失败都按逆序回滚 —— 主库与它的 -wal/-shm 绝不会分家
        // （WAL 里可能有未 checkpoint 的已提交事务）。
        let staging = path + ".gather-reset-" + UUID().uuidString.lowercased()
        let hadMain = fileManager.fileExists(atPath: path)
        var movedSuffixes: [String] = []
        if hadMain {
            do {
                try fileManager.moveItem(atPath: path, toPath: staging)
            } catch {
                throw DatabaseError.io(
                    "移走 \(path) 失败：\(error.localizedDescription)。请手动备份 \(path) 后重试"
                )
            }
        }
        do {
            for suffix in ["-shm", "-wal"] where fileManager.fileExists(atPath: path + suffix) {
                try fileManager.moveItem(atPath: path + suffix, toPath: target + suffix)
                movedSuffixes.append(suffix)
            }
            if hadMain {
                try fileManager.moveItem(atPath: staging, toPath: target)
            }
        } catch {
            // 逆序回滚：sidecar 先回原位，再把主库挪回来，库仍保持可打开的原状。
            for suffix in movedSuffixes.reversed() {
                try? fileManager.moveItem(atPath: target + suffix, toPath: path + suffix)
            }
            if hadMain {
                try? fileManager.moveItem(atPath: staging, toPath: path)
            }
            throw DatabaseError.io(
                "归档 \(path) 失败：\(error.localizedDescription)。已尝试回滚，库保持原样；"
                    + "请手动备份后重试"
            )
        }

        pruneIncompatibleCopies(for: path, retaining: options.retainIncompatibleCopies)
        let detected = previousVersion.map(String.init) ?? "unreadable"
        GatherLogger.log(
            "schema_reset user_version=\(detected) expected=\(SchemaCurrent.userVersion) "
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
