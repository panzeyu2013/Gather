// desktop/native/gather-core/Sources/GatherPersistence/Database/Backup/BackupVerifier.swift
// P0 / B0：备份文件只读校验（头 / quick_check / user_version / 表数 / 形状指纹 / 大小 / SHA-256）。
import Foundation
import GatherProtocol

public struct BackupVerification: Sendable, Equatable {
    public let schemaVersion: Int
    public let tableCount: Int
    public let sizeBytes: Int64
    public let sha256: String

    public init(schemaVersion: Int, tableCount: Int, sizeBytes: Int64, sha256: String) {
        self.schemaVersion = schemaVersion
        self.tableCount = tableCount
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

public enum BackupVerifier {
    public static func verify(path: String) throws -> BackupVerification {
        let url = URL(fileURLWithPath: path)
        guard let handle = BestEffort.optional("open backup for verification", {
            try FileHandle(forReadingFrom: url)
        }) else {
            throw MaintenanceError.backupVerifyFailed("文件不存在或不可读")
        }
        defer {
            BestEffort.attempt("close backup verification handle") {
                try handle.close()
            }
        }
        let header = try handle.read(upToCount: 16) ?? Data()
        guard header == Data("SQLite format 3\0".utf8) else {
            throw MaintenanceError.backupVerifyFailed("文件头不是 SQLite 3")
        }
        let size = BestEffort.value("backup verification size", default: 0) {
            try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 ?? 0
        }

        let connection: DBConnection
        do {
            connection = try DBConnection(path: path, readOnly: true)
        } catch {
            throw MaintenanceError.backupVerifyFailed("只读打开失败：\(error)")
        }
        defer { connection.close() }

        let check = try readQuickCheck(connection)
        guard check.lowercased() == "ok" else {
            throw MaintenanceError.backupVerifyFailed("quick_check 未通过")
        }
        let rawVersion = try readUserVersion(connection)
        guard rawVersion == SchemaCurrent.userVersion else {
            throw MaintenanceError.restoreVersionUnsupported(
                backup: Int(rawVersion), current: SchemaCurrent.userVersion)
        }
        let tableCount = try readTableCount(connection)
        let shape = try SchemaShapeReader.read(connection)
        let issues = SchemaCurrent.shape.issues(against: shape)
        guard issues.isEmpty else {
            throw MaintenanceError.backupVerifyFailed("形状不符：\(issues.joined(separator: "；"))")
        }
        let sha = try FileHasher.sha256File(path)
        return BackupVerification(
            schemaVersion: Int(rawVersion),
            tableCount: Int(tableCount),
            sizeBytes: size,
            sha256: sha
        )
    }

    private static func readQuickCheck(_ connection: DBConnection) throws -> String {
        do {
            guard let value = try connection.prepare("PRAGMA quick_check;").get([])?[0].textValue else {
                throw MaintenanceError.backupVerifyFailed("quick_check 无结果")
            }
            return value
        } catch let error as MaintenanceError {
            throw error
        } catch {
            throw MaintenanceError.backupVerifyFailed("quick_check 读取失败：\(error)")
        }
    }

    private static func readUserVersion(_ connection: DBConnection) throws -> Int64 {
        do {
            guard let value = try connection.prepare("PRAGMA user_version;").get([])?[0].intValue else {
                throw MaintenanceError.backupVerifyFailed("user_version 无结果")
            }
            return value
        } catch let error as MaintenanceError {
            throw error
        } catch {
            throw MaintenanceError.backupVerifyFailed("user_version 读取失败：\(error)")
        }
    }

    private static func readTableCount(_ connection: DBConnection) throws -> Int64 {
        do {
            guard let row = try connection.prepare(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            ).get([]), let value = row[0].intValue else {
                throw MaintenanceError.backupVerifyFailed("读取表数失败")
            }
            return value
        } catch let error as MaintenanceError {
            throw error
        } catch {
            throw MaintenanceError.backupVerifyFailed("读取表数失败：\(error)")
        }
    }
}
