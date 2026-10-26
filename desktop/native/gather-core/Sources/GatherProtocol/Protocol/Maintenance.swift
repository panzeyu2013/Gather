// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Maintenance.swift
// P0 / B0：维护域契约（备份/恢复/诊断）。纯值；不依赖 Persistence/UI。
import Foundation

public enum BackupTrigger: String, Codable, Sendable, CaseIterable, Equatable {
    case manual
    case autoLaunch = "auto_launch"
    case autoDaily = "auto_daily"
    case unknown
}

public struct BackupRecord: Codable, Sendable, Equatable, Identifiable {
    public let fileName: String
    public let createdAt: String
    public let sizeBytes: Int64
    public let schemaVersion: Int
    public let tableCount: Int
    public let trigger: BackupTrigger
    public let verified: Bool
    public let sha256: String?

    public var id: String { fileName }

    public init(
        fileName: String, createdAt: String, sizeBytes: Int64,
        schemaVersion: Int, tableCount: Int, trigger: BackupTrigger,
        verified: Bool, sha256: String?
    ) {
        self.fileName = fileName
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
        self.schemaVersion = schemaVersion
        self.tableCount = tableCount
        self.trigger = trigger
        self.verified = verified
        self.sha256 = sha256
    }
}

public struct MaintenanceInventory: Codable, Sendable, Equatable {
    public let backupDir: String
    public let backups: [BackupRecord]
    public let lastRestore: RestoreOutcome?
    public let autoPaused: Bool

    public init(backupDir: String, backups: [BackupRecord], lastRestore: RestoreOutcome?, autoPaused: Bool) {
        self.backupDir = backupDir
        self.backups = backups
        self.lastRestore = lastRestore
        self.autoPaused = autoPaused
    }
}

public enum RestoreResult: String, Codable, Sendable, Equatable {
    case applied, failed, rolledBack
}

public struct RestoreOutcome: Codable, Sendable, Equatable {
    public let at: String
    public let backupFileName: String
    public let result: RestoreResult
    public let errorCode: String?
    /// 人类可读失败原因（可选）；设置页优先展示它，避免只有错误码时显示裸 %@。
    public let message: String?

    public init(
        at: String,
        backupFileName: String,
        result: RestoreResult,
        errorCode: String? = nil,
        message: String? = nil
    ) {
        self.at = at
        self.backupFileName = backupFileName
        self.result = result
        self.errorCode = errorCode
        self.message = message
    }
}

public struct MaintenanceBackupInput: Codable, Sendable, Equatable {
    public let trigger: BackupTrigger

    private enum CodingKeys: String, CodingKey { case trigger }

    public init(trigger: BackupTrigger = .manual) throws {
        guard trigger == .manual else {
            throw GatherError(code: .INVALID_PARAM, params: ["field": "trigger"])
        }
        self.trigger = trigger
    }

    /// 显式解码：合成 Decodable 会绕过 throwing init 的校验。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(trigger: try container.decode(BackupTrigger.self, forKey: .trigger))
    }
}

public struct RestoreBackupInput: Codable, Sendable, Equatable {
    public let fileName: String

    private enum CodingKeys: String, CodingKey { case fileName }

    public init(fileName: String) throws {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255,
              !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("..")
        else {
            throw GatherError(code: .INVALID_PARAM, params: ["field": "fileName"])
        }
        self.fileName = trimmed
    }

    /// 显式解码：合成 Decodable 会绕过路径校验（../、斜杠必须拒绝）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fileName: try container.decode(String.self, forKey: .fileName))
    }
}

public struct RestoreReceipt: Codable, Sendable, Equatable {
    public let backupFileName: String
    public let schemaVersion: Int
    public let requiresRestart: Bool
    public let journalPath: String
    public let verifiedAt: String

    public init(backupFileName: String, schemaVersion: Int, requiresRestart: Bool, journalPath: String, verifiedAt: String) {
        self.backupFileName = backupFileName
        self.schemaVersion = schemaVersion
        self.requiresRestart = requiresRestart
        self.journalPath = journalPath
        self.verifiedAt = verifiedAt
    }
}

public struct DiagnosticsExportInput: Codable, Sendable, Equatable {
    public let destinationPath: String
    public let includePaths: Bool?

    private enum CodingKeys: String, CodingKey { case destinationPath, includePaths }

    public init(destinationPath: String, includePaths: Bool? = nil) throws {
        guard destinationPath.hasPrefix("/"), destinationPath.lowercased().hasSuffix(".zip") else {
            throw GatherError(code: .INVALID_PARAM, params: ["field": "destinationPath"])
        }
        self.destinationPath = destinationPath
        self.includePaths = includePaths
    }

    /// 显式解码：合成 Decodable 会绕过绝对路径/.zip 校验。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            destinationPath: try container.decode(String.self, forKey: .destinationPath),
            includePaths: try container.decodeIfPresent(Bool.self, forKey: .includePaths)
        )
    }
}

public struct DiagnosticsExportResult: Codable, Sendable, Equatable {
    public let path: String
    public let sizeBytes: Int64
    public let logFileCount: Int
    public let redactedPaths: Bool

    public init(path: String, sizeBytes: Int64, logFileCount: Int, redactedPaths: Bool) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.logFileCount = logFileCount
        self.redactedPaths = redactedPaths
    }
}

public enum MaintenanceError: Error, Equatable, Sendable, CustomStringConvertible {
    case backupBusy
    case backupVerifyFailed(String)
    case backupInsufficientSpace(needed: Int64, available: Int64)
    case backupPermissionDenied(String)
    case backupFailed(String)
    case restoreBusy
    case restoreVerifyFailed(String)
    case restoreVersionUnsupported(backup: Int, current: Int)
    case restoreInsufficientSpace(needed: Int64, available: Int64)
    case restorePermissionDenied(String)
    case restoreFailed(String)
    case diagnosticsExportFailed(String)

    public var code: String {
        switch self {
        case .backupBusy: "BACKUP_BUSY"
        case .backupVerifyFailed: "BACKUP_VERIFY_FAILED"
        case .backupInsufficientSpace: "BACKUP_INSUFFICIENT_SPACE"
        case .backupPermissionDenied: "BACKUP_PERMISSION_DENIED"
        case .backupFailed: "BACKUP_FAILED"
        case .restoreBusy: "RESTORE_BUSY"
        case .restoreVerifyFailed: "RESTORE_VERIFY_FAILED"
        case .restoreVersionUnsupported: "RESTORE_VERSION_UNSUPPORTED"
        case .restoreInsufficientSpace: "RESTORE_INSUFFICIENT_SPACE"
        case .restorePermissionDenied: "RESTORE_PERMISSION_DENIED"
        case .restoreFailed: "RESTORE_FAILED"
        case .diagnosticsExportFailed: "DIAGNOSTICS_EXPORT_FAILED"
        }
    }

    public var description: String {
        switch self {
        case .backupBusy: "BACKUP_BUSY"
        case .backupVerifyFailed(let reason): "BACKUP_VERIFY_FAILED: \(reason)"
        case .backupInsufficientSpace(let needed, let available): "BACKUP_INSUFFICIENT_SPACE: \(needed) > \(available)"
        case .backupPermissionDenied(let reason): "BACKUP_PERMISSION_DENIED: \(reason)"
        case .backupFailed(let reason): "BACKUP_FAILED: \(reason)"
        case .restoreBusy: "RESTORE_BUSY"
        case .restoreVerifyFailed(let reason): "RESTORE_VERIFY_FAILED: \(reason)"
        case .restoreVersionUnsupported(let backup, let current): "RESTORE_VERSION_UNSUPPORTED: \(backup) > \(current)"
        case .restoreInsufficientSpace(let needed, let available): "RESTORE_INSUFFICIENT_SPACE: \(needed) > \(available)"
        case .restorePermissionDenied(let reason): "RESTORE_PERMISSION_DENIED: \(reason)"
        case .restoreFailed(let reason): "RESTORE_FAILED: \(reason)"
        case .diagnosticsExportFailed(let reason): "DIAGNOSTICS_EXPORT_FAILED: \(reason)"
        }
    }
}
