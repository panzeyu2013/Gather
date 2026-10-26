// desktop/native/gather-core/Sources/GatherPersistence/Database/Backup/RestoreSupport.swift
// P0 / B0：跨进程恢复 journal、锁、启动时 swap/rollback、恢复结果状态文件。
import Foundation
import GatherProtocol

public enum RestoreJournalState: String, Codable, Sendable {
    case prepared, oldMoved, newInstalled, opened
}

public struct RestoreJournal: Codable, Sendable, Equatable {
    public var journalVersion: Int
    public var state: RestoreJournalState
    public var createdAt: String
    public var backupFileName: String
    public var backupPath: String
    public var backupSHA256: String
    public var backupSchemaVersion: Int
    public var dbPath: String
    public var preRestorePath: String
    public var stagingPath: String
    public var backupDir: String

    public init(
        journalVersion: Int = 1, state: RestoreJournalState, createdAt: String,
        backupFileName: String, backupPath: String, backupSHA256: String,
        backupSchemaVersion: Int, dbPath: String, preRestorePath: String,
        stagingPath: String, backupDir: String
    ) {
        self.journalVersion = journalVersion
        self.state = state
        self.createdAt = createdAt
        self.backupFileName = backupFileName
        self.backupPath = backupPath
        self.backupSHA256 = backupSHA256
        self.backupSchemaVersion = backupSchemaVersion
        self.dbPath = dbPath
        self.preRestorePath = preRestorePath
        self.stagingPath = stagingPath
        self.backupDir = backupDir
    }
}

public enum RestoreApplyOutcome: Sendable, Equatable {
    case none
    case applied(RestoreApplied)
    case rolledBack(RestoreFailure)
    /// 现场已无法安全恢复到“恢复前”状态：继续启动只能新建空库，必须停止。
    case unrecoverable(RestoreFailure)
}

public struct RestoreUnrecoverableError: Error, CustomStringConvertible, Sendable {
    public let failure: RestoreFailure

    public init(failure: RestoreFailure) {
        self.failure = failure
    }

    public var description: String { "\(failure.code): \(failure.message)" }
}

public struct RestoreApplied: Sendable, Equatable {
    public let backupFileName: String
    public let preRestorePath: String
    public let schemaVersion: Int
    public init(backupFileName: String, preRestorePath: String, schemaVersion: Int) {
        self.backupFileName = backupFileName
        self.preRestorePath = preRestorePath
        self.schemaVersion = schemaVersion
    }
}

public struct RestoreFailure: Sendable, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public final class RestoreLock {
    private let fd: Int32
    private let path: String
    private var released = false

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    public static func acquire(at appDir: URL) throws -> RestoreLock {
        let path = appDir.appendingPathComponent(".restore.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw MaintenanceError.restoreBusy
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw MaintenanceError.restoreBusy
        }
        return RestoreLock(fd: fd, path: path)
    }

    public func release() {
        guard !released else { return }
        released = true
        _ = flock(fd, LOCK_UN)
        _ = close(fd)
    }

    deinit { release() }
}

public enum RestoreCoordinator {
    public static func journalPath(dbPath: String) -> String {
        URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            .appendingPathComponent("restore-pending.json").path
    }

    public static func hasPending(dbPath: String) -> Bool {
        FileManager.default.fileExists(atPath: journalPath(dbPath: dbPath))
    }

    /// 取消尚未在启动时 swap 的恢复（UI 的“稍后再说”）。
    /// 只有 prepared/opened 可安全取消；oldMoved/newInstalled 必须走恢复/回滚。
    public static func cancelPending(dbPath: String) throws {
        guard let journal = try readJournal(dbPath: dbPath) else { return }
        switch journal.state {
        case .prepared, .opened:
            removeIfExists(journal.stagingPath)
            removeJournal(dbPath: dbPath)
        case .oldMoved, .newInstalled:
            throw MaintenanceError.restoreBusy
        }
    }

    private static func readJournal(dbPath: String) throws -> RestoreJournal? {
        let path = journalPath(dbPath: dbPath)
        guard let data = BestEffort.optional("read restore journal", {
            try Data(contentsOf: URL(fileURLWithPath: path))
        }) else { return nil }
        return try JSONDecoder().decode(RestoreJournal.self, from: data)
    }

    private static func writeJournal(_ journal: RestoreJournal) throws {
        let path = journalPath(dbPath: journal.dbPath)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func removeJournal(dbPath: String) {
        BestEffort.attempt("remove restore journal") {
            try FileManager.default.removeItem(atPath: journalPath(dbPath: dbPath))
        }
    }

    private static func moveIfExists(_ from: String, _ to: String) throws {
        guard FileManager.default.fileExists(atPath: from) else { return }
        BestEffort.attempt("remove restore destination") {
            try FileManager.default.removeItem(atPath: to)
        }
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }

    private static func removeIfExists(_ path: String) {
        BestEffort.attempt("remove restore file") {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private static func writeState(_ outcome: RestoreOutcome, dbPath: String) {
        let stateURL = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            .appendingPathComponent("maintenance-state.json")
        var object: [String: Any] = [:]
        if let data = BestEffort.optional("read maintenance state", { try Data(contentsOf: stateURL) }),
           let decoded = BestEffort.optional("decode maintenance state", {
               try JSONSerialization.jsonObject(with: data)
           }),
           let existing = decoded as? [String: Any] {
            object = existing
        }
        object["lastRestore"] = [
            "at": outcome.at,
            "backupFileName": outcome.backupFileName,
            "result": outcome.result.rawValue,
            "errorCode": outcome.errorCode ?? "",
            "message": outcome.message ?? "",
        ]
        if let data = BestEffort.optional("encode maintenance state", {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }) {
            BestEffort.attempt("write maintenance state") {
                try data.write(to: stateURL, options: .atomic)
            }
        }
    }

    /// 待执行恢复引用的备份文件名：备份 prune 必须保护它（否则下次启动报 BACKUP_INVALID）。
    public static func pendingBackupFileName(dbPath: String) throws -> String? {
        try readJournal(dbPath: dbPath)?.backupFileName
    }

    /// 目录里是否存在 pre-restore 套件（journal 损坏时用于判断能否安全继续）。
    private static func hasPreRestoreFiles(dbPath: String) -> Bool {
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let prefix = URL(fileURLWithPath: dbPath).lastPathComponent + ".pre-restore-"
        guard let names = BestEffort.optional("list pre-restore for corrupt journal", {
            try FileManager.default.contentsOfDirectory(atPath: dir.path)
        }) else { return true }
        return names.contains { $0.hasPrefix(prefix) }
    }

    /// 统一的回滚出口：写 lastRestore（设置页可见）+ 返回失败；不允许静默回滚。
    private static func rolledBack(
        _ journal: RestoreJournal,
        code: String,
        message: String,
        dbPath: String
    ) -> RestoreApplyOutcome {
        writeState(RestoreOutcome(
            at: ISO8601DateFormatter().string(from: Date()),
            backupFileName: journal.backupFileName,
            result: .rolledBack,
            errorCode: code,
            message: message), dbPath: dbPath)
        return .rolledBack(RestoreFailure(code: code, message: message))
    }

    /// 启动时（Database.open 之前）调用；成功返回 .applied，调用方负责 open + finalize。
    public static func applyPendingIfNeeded(dbPath: String) throws -> RestoreApplyOutcome {
        let loaded: RestoreJournal
        do {
            guard let journal = try readJournal(dbPath: dbPath) else { return .none }
            loaded = journal
        } catch {
            // journal 损坏：只有在“现有库存在且没有 pre-restore 套件”时才可安全继续，
            // 否则继续启动会新建空库、掩盖一次真实的数据恢复现场。
            BestEffort.attempt("move corrupt restore journal") {
                try moveToCorrupt(dbPath: dbPath)
            }
            GatherLogger.log("restore journal unreadable: \(error)", level: .error)
            let fm = FileManager.default
            let dbExists = fm.fileExists(atPath: dbPath)
            let preExists = hasPreRestoreFiles(dbPath: dbPath)
            if !dbExists || preExists {
                return .unrecoverable(RestoreFailure(
                    code: "RESTORE_FAILED",
                    message: "恢复记录损坏且现场无法确认（db 存在=\(dbExists)，pre-restore=\(preExists)）；请保留数据库与 *.pre-restore-* 后联系支持"))
            }
            return .none
        }
        var journal = loaded
        guard journal.dbPath == dbPath else {
            BestEffort.attempt("move corrupt restore journal") {
                try moveToCorrupt(dbPath: dbPath)
            }
            return .none
        }
        let fm = FileManager.default
        let dbExists = fm.fileExists(atPath: dbPath)
        let preExists = fm.fileExists(atPath: journal.preRestorePath)

        switch journal.state {
        case .opened:
            if !dbExists {
                // 已标记 opened 但库文件消失：不能静默建空库。
                return .unrecoverable(RestoreFailure(
                    code: "RESTORE_FAILED",
                    message: "恢复完成后数据库文件缺失；请从备份目录手动恢复"))
            }
            removeJournal(dbPath: dbPath)
            return .none

        case .prepared:
            if dbExists, preExists {
                // 当前库与 pre-restore 同时存在：journal 与现场矛盾，不能静默
                // 当作“无恢复”；写 lastRestore 供设置页提示，并清理 staging。
                writeState(RestoreOutcome(
                    at: ISO8601DateFormatter().string(from: Date()),
                    backupFileName: journal.backupFileName,
                    result: .failed,
                    errorCode: "RESTORE_STATE_CONFLICT"), dbPath: dbPath)
                BestEffort.attempt("remove restore staging") {
                    try FileManager.default.removeItem(atPath: journal.stagingPath)
                }
                BestEffort.attempt("move corrupt restore journal") {
                    try moveToCorrupt(dbPath: dbPath)
                }
                return .none
            }
            // 安全：journal 写入后到下次启动之间备份可能被替换；安装前必须
            // 重算 SHA 并与 journal 记录比对。失败不触碰当前库。
            let verified: BackupVerification
            do {
                verified = try BackupVerifier.verify(path: journal.backupPath)
            } catch {
                BestEffort.attempt("move corrupt restore journal") {
                    try moveToCorrupt(dbPath: dbPath)
                }
                return rolledBack(
                    journal, code: "RESTORE_BACKUP_INVALID",
                    message: "备份不可校验：\(error)", dbPath: dbPath)
            }
            guard !journal.backupSHA256.isEmpty,
                  verified.sha256 == journal.backupSHA256 else {
                BestEffort.attempt("move corrupt restore journal") {
                    try moveToCorrupt(dbPath: dbPath)
                }
                return rolledBack(
                    journal, code: "RESTORE_BACKUP_CHANGED",
                    message: "备份哈希与恢复记录不一致，已拒绝安装", dbPath: dbPath)
            }
            if !dbExists, preExists {
                try rollbackJournal(&journal)
                return rolledBack(
                    journal, code: "RESTORE_FAILED", message: "库文件缺失，已回滚旧库",
                    dbPath: dbPath)
            }
            do {
                try moveIfExists(dbPath, journal.preRestorePath)
                try moveIfExists(dbPath + "-wal", journal.preRestorePath + "-wal")
                try moveIfExists(dbPath + "-shm", journal.preRestorePath + "-shm")
                journal.state = .oldMoved
                try writeJournal(journal)
                try fm.createDirectory(
                    at: URL(fileURLWithPath: journal.stagingPath).deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                BestEffort.attempt("remove restore staging") {
                    try fm.removeItem(atPath: journal.stagingPath)
                }
                try fm.copyItem(atPath: journal.backupPath, toPath: journal.stagingPath)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.stagingPath)
                BestEffort.attempt("remove current db before install") {
                    try fm.removeItem(atPath: dbPath)
                }
                try fm.moveItem(atPath: journal.stagingPath, toPath: dbPath)
                removeIfExists(dbPath + "-wal")
                removeIfExists(dbPath + "-shm")
                journal.state = .newInstalled
                try writeJournal(journal)
                return .applied(RestoreApplied(
                    backupFileName: journal.backupFileName,
                    preRestorePath: journal.preRestorePath,
                    schemaVersion: journal.backupSchemaVersion
                ))
            } catch {
                BestEffort.attempt("rollback restore journal") {
                    try rollbackJournal(&journal)
                }
                return rolledBack(
                    journal, code: "RESTORE_FAILED", message: "\(error)", dbPath: dbPath)
            }

        case .oldMoved:
            try rollbackJournal(&journal)
            return rolledBack(
                journal, code: "RESTORE_FAILED", message: "恢复中断，已回滚旧库",
                dbPath: dbPath)

        case .newInstalled:
            if dbExists, preExists {
                return .applied(RestoreApplied(
                    backupFileName: journal.backupFileName,
                    preRestorePath: journal.preRestorePath,
                    schemaVersion: journal.backupSchemaVersion
                ))
            }
            if !dbExists, preExists {
                try rollbackJournal(&journal)
                return rolledBack(
                    journal, code: "RESTORE_FAILED", message: "新库缺失，已回滚旧库",
                    dbPath: dbPath)
            }
            if !dbExists, !preExists {
                // 新库与旧库副本都不存在：任何“空库重建”都会让用户以为恢复成功。
                writeState(RestoreOutcome(
                    at: ISO8601DateFormatter().string(from: Date()),
                    backupFileName: journal.backupFileName,
                    result: .failed,
                    errorCode: "RESTORE_FAILED"), dbPath: dbPath)
                return .unrecoverable(RestoreFailure(
                    code: "RESTORE_FAILED",
                    message: "新库与旧库副本都不存在；请从备份目录手动恢复（pre-restore: \(journal.preRestorePath)）"))
            }
            // dbExists && !preExists：恢复已完成但旧副本缺失（被手工清理）。
            GatherLogger.log(
                "restore finished but pre-restore copy missing: \(journal.preRestorePath)",
                level: .warn)
            removeJournal(dbPath: dbPath)
            return .applied(RestoreApplied(
                backupFileName: journal.backupFileName,
                preRestorePath: journal.preRestorePath,
                schemaVersion: journal.backupSchemaVersion))
        }
    }

    public static func finalizeOpened(dbPath: String) throws {
        guard var journal = try readJournal(dbPath: dbPath) else { return }
        journal.state = .opened
        try writeJournal(journal)
        writeState(
            RestoreOutcome(
                at: ISO8601DateFormatter().string(from: Date()),
                backupFileName: journal.backupFileName,
                result: .applied,
                errorCode: nil
            ),
            dbPath: dbPath
        )
        removeJournal(dbPath: dbPath)
        prunePreRestore(dbPath: dbPath, keeping: 2)
    }

    public static func rollbackToPrevious(dbPath: String) throws {
        guard var journal = try readJournal(dbPath: dbPath) else { return }
        try rollbackJournal(&journal)
        writeState(
            RestoreOutcome(
                at: ISO8601DateFormatter().string(from: Date()),
                backupFileName: journal.backupFileName,
                result: .rolledBack,
                errorCode: "RESTORE_FAILED"
            ),
            dbPath: dbPath
        )
    }

    private static func rollbackJournal(_ journal: inout RestoreJournal) throws {
        let fm = FileManager.default
        // 崩溃窗口：主库已搬到 pre，但 -wal 还留在 dbPath（此时 state 仍是 prepared）。
        // 该 WAL 属于旧库、含已提交事务；回滚前必须归入 pre 套件，不能在第 468 行被删掉。
        if journal.state != .newInstalled,
           fm.fileExists(atPath: journal.preRestorePath),
           !fm.fileExists(atPath: journal.preRestorePath + "-wal"),
           fm.fileExists(atPath: journal.dbPath + "-wal") {
            try moveIfExists(journal.dbPath + "-wal", journal.preRestorePath + "-wal")
        }
        removeIfExists(journal.stagingPath)
        let temp = journal.preRestorePath + ".rollback"
        // 崩溃恢复 A：pre 已整体搬到临时名（或已装回 db 但 sidecar 未搬完）。
        if !fm.fileExists(atPath: journal.preRestorePath),
           fm.fileExists(atPath: temp) {
            removeIfExists(journal.dbPath)
            removeIfExists(journal.dbPath + "-wal")
            removeIfExists(journal.dbPath + "-shm")
            try moveIfExists(temp, journal.dbPath)
            try moveIfExists(temp + "-wal", journal.dbPath + "-wal")
            try moveIfExists(temp + "-shm", journal.dbPath + "-shm")
            removeJournal(dbPath: journal.dbPath)
            return
        }
        // 崩溃恢复 B：pre 主库已就位，sidecar 还留在临时名。
        if fm.fileExists(atPath: journal.dbPath),
           fm.fileExists(atPath: temp + "-wal"),
           !fm.fileExists(atPath: journal.dbPath + "-wal") {
            try moveIfExists(temp + "-wal", journal.dbPath + "-wal")
        }
        if fm.fileExists(atPath: journal.dbPath),
           fm.fileExists(atPath: temp + "-shm"),
           !fm.fileExists(atPath: journal.dbPath + "-shm") {
            try moveIfExists(temp + "-shm", journal.dbPath + "-shm")
        }
        guard fm.fileExists(atPath: journal.preRestorePath) else {
            removeJournal(dbPath: journal.dbPath)
            return
        }
        // 1) 先把 pre 三件套整组搬到临时名：当前库保持完整，此阶段崩溃不丢 WAL。
        try moveIfExists(journal.preRestorePath, temp)
        try moveIfExists(journal.preRestorePath + "-wal", temp + "-wal")
        try moveIfExists(journal.preRestorePath + "-shm", temp + "-shm")
        // 2) 移除当前三件套，再把临时三件套整体就位。
        removeIfExists(journal.dbPath)
        removeIfExists(journal.dbPath + "-wal")
        removeIfExists(journal.dbPath + "-shm")
        try moveIfExists(temp, journal.dbPath)
        try moveIfExists(temp + "-wal", journal.dbPath + "-wal")
        try moveIfExists(temp + "-shm", journal.dbPath + "-shm")
        removeJournal(dbPath: journal.dbPath)
    }

    private static func moveToCorrupt(dbPath: String) throws {
        let path = journalPath(dbPath: dbPath)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let ts = Int(Date().timeIntervalSince1970)
        BestEffort.attempt("move corrupt restore journal") {
            try FileManager.default.moveItem(atPath: path, toPath: path + ".corrupt-\(ts)")
        }
    }

    /// 按“套”（主库 + -wal + -shm）保留最近 `keeping` 份恢复前副本。
    /// 不能按文件数保留：字典序下主库排在同套 sidecar 之前，按文件淘汰会先删主库，
    /// 只留下孤立的 -wal/-shm，UI 承诺的回滚副本实际不可用。
    static func prunePreRestore(dbPath: String, keeping: Int) {
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let base = URL(fileURLWithPath: dbPath).lastPathComponent + ".pre-restore-"
        guard let files = BestEffort.optional("list pre-restore backups", {
            try FileManager.default.contentsOfDirectory(atPath: dir.path)
        }) else { return }
        var keys = Set<String>()
        for name in files where name.hasPrefix(base) {
            var key = String(name.dropFirst(base.count))
            for suffix in ["-wal", "-shm"] where key.hasSuffix(suffix) {
                key = String(key.dropLast(suffix.count))
            }
            guard !key.isEmpty else { continue }
            keys.insert(key)
        }
        let keep = max(1, keeping)
        guard keys.count > keep else { return }
        for key in keys.sorted().dropLast(keep) {
            for suffix in ["", "-wal", "-shm"] {
                BestEffort.attempt("remove old pre-restore backup") {
                    try FileManager.default.removeItem(
                        atPath: dir.appendingPathComponent(base + key + suffix).path)
                }
            }
        }
    }
}
