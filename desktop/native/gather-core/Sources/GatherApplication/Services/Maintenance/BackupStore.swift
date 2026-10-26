// desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/BackupStore.swift
// P0 / B0：托管备份目录（命名 / sidecar / 列表 / 保留）。
import Foundation
import GatherProtocol
import GatherPersistence

struct BackupSidecar: Codable, Sendable, Equatable {
    var formatVersion: Int
    var createdAt: String
    var appVersion: String
    var schemaVersion: Int
    var tableCount: Int
    var sizeBytes: Int64
    var sha256: String
    var trigger: BackupTrigger
    var verified: Bool

    init(record: BackupRecord, appVersion: String) {
        self.formatVersion = 1
        self.createdAt = record.createdAt
        self.appVersion = appVersion
        self.schemaVersion = record.schemaVersion
        self.tableCount = record.tableCount
        self.sizeBytes = record.sizeBytes
        self.sha256 = record.sha256 ?? ""
        self.trigger = record.trigger
        self.verified = record.verified
    }
}

public struct BackupStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private static let prefix = "Gather-Backup-"

    public func ensureDirectory() throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue {
            return
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func newURLs(now: Date) -> (partial: URL, final: URL, sidecar: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        var base = "\(Self.prefix)\(stamp)"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(base + ".sqlite").path) {
            base = "\(Self.prefix)\(stamp)-\(counter)"
            counter += 1
        }
        let final = directory.appendingPathComponent(base + ".sqlite")
        return (
            directory.appendingPathComponent(base + ".sqlite.partial"),
            final,
            directory.appendingPathComponent(base + ".sqlite.json")
        )
    }

    /// 清理上次崩溃/退出留下的 partial 备份（命名固定，不影响最终备份）。
    public func removeStalePartials() {
        let fm = FileManager.default
        guard let names = BestEffort.optional("list stale partial backups", {
            try fm.contentsOfDirectory(atPath: directory.path)
        }) else { return }
        for name in names where name.hasPrefix(Self.prefix) && name.hasSuffix(".sqlite.partial") {
            BestEffort.attempt("remove stale partial backup") {
                try fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    public func list() throws -> [BackupRecord] {
        let fm = FileManager.default
        guard let names = BestEffort.optional("list backup directory", {
            try fm.contentsOfDirectory(atPath: directory.path)
        }) else { return [] }
        var records: [BackupRecord] = []
        for name in names where name.hasPrefix(Self.prefix) && name.hasSuffix(".sqlite") {
            let url = directory.appendingPathComponent(name)
            let sidecarURL = directory.appendingPathComponent(name + ".json")
            if let data = BestEffort.optional("read backup sidecar", {
                   try Data(contentsOf: sidecarURL)
               }),
               let sidecar = BestEffort.optional("decode backup sidecar", {
                   try JSONDecoder().decode(BackupSidecar.self, from: data)
               }) {
                records.append(BackupRecord(
                    fileName: name, createdAt: sidecar.createdAt,
                    sizeBytes: sidecar.sizeBytes, schemaVersion: sidecar.schemaVersion,
                    tableCount: sidecar.tableCount, trigger: sidecar.trigger,
                    verified: sidecar.verified, sha256: sidecar.sha256.isEmpty ? nil : sidecar.sha256
                ))
            } else {
                let size = BestEffort.value("backup file size", default: 0) {
                    try fm.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
                }
                let date = BestEffort.value("backup file date", default: "") {
                    guard let modified = try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
                    else { return "" }
                    return ISO8601DateFormatter().string(from: modified)
                }
                records.append(BackupRecord(
                    fileName: name, createdAt: date, sizeBytes: size,
                    schemaVersion: 0, tableCount: 0, trigger: .unknown,
                    verified: false, sha256: nil
                ))
            }
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    /// 只删托管备份；保护集合里的文件名永不删除。
    public func prune(keeping limit: Int, protecting: Set<String>) throws {
        let keep = max(1, min(20, limit))
        let records = try list().filter { !protecting.contains($0.fileName) }
        guard records.count > keep else { return }
        for record in records.sorted(by: { $0.createdAt > $1.createdAt }).dropFirst(keep) {
            let sqlite = directory.appendingPathComponent(record.fileName)
            let sidecar = directory.appendingPathComponent(record.fileName + ".json")
            BestEffort.attempt("remove pruned backup") {
                try FileManager.default.removeItem(at: sqlite)
            }
            BestEffort.attempt("remove pruned backup sidecar") {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
    }
}
