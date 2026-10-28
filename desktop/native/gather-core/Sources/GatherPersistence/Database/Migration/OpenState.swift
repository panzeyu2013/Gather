// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/OpenState.swift
// Database.open 的库状态判定（当前 schema 唯一）。
//
// 三态：empty / current / incompatible。旧版本（含重置前发布过的 user_version 2…5）
// 不再迁移，默认 fail closed；只有显式 resetPolicy 才归档重建，未来版本永远 fail closed。
import Foundation
import GatherProtocol

enum OpenState: Sendable, Equatable {
    /// user_version == 0 且没有任何用户表。
    case empty
    /// user_version == current 且列形/指纹一致。
    case current
    /// 其余一律不兼容：非 SQLite / V0 有表 / 旧版本 / 更高版本 / 形态不符 / 版本读不出。
    case incompatible(CorruptReason)
}

enum CorruptReason: Sendable, Equatable, CustomStringConvertible {
    case notADatabase
    case legacyPreV1
    case oldVersion(Int)
    case newerVersion(Int)
    case shapeMismatch(version: Int, issue: String)
    case unreadableVersion

    var version: Int? {
        switch self {
        case .notADatabase, .unreadableVersion: return nil
        case .legacyPreV1: return 0
        case .oldVersion(let version), .newerVersion(let version): return version
        case .shapeMismatch(let version, _): return version
        }
    }

    var resetReason: Database.ResetReason {
        switch self {
        case .notADatabase: return .notADatabase
        case .legacyPreV1: return .legacyPreV1
        case .oldVersion(let version): return .oldVersion(version)
        case .newerVersion(let version): return .newerVersion(version)
        case .shapeMismatch(let version, _): return .shapeMismatch(version: version)
        case .unreadableVersion: return .unreadableVersion
        }
    }

    var description: String {
        switch self {
        case .notADatabase: return "不是 SQLite 文件"
        case .legacyPreV1: return "V1 之前的旧库（user_version=0 但已有表）"
        case .oldVersion(let version):
            return "旧版本库 user_version=\(version)（当前 \(SchemaCurrent.userVersion)），不支持就地迁移"
        case .newerVersion(let version):
            return "库版本 \(version) 高于本构建 \(SchemaCurrent.userVersion)"
        case .shapeMismatch(let version, let issue):
            return "user_version=\(version) 但列形不符：\(issue)"
        case .unreadableVersion:
            return "无法读取 user_version"
        }
    }
}

enum SchemaInspector {
    /// 读取并判定库状态；只做只读 PRAGMA，不写文件。
    static func inspect(_ connection: DBConnection, path: String) throws -> OpenState {
        do {
            guard let version = try readUserVersion(connection) else {
                return .incompatible(.unreadableVersion)
            }
            guard version >= 0 else {
                return .incompatible(.shapeMismatch(version: version, issue: "user_version 为负数"))
            }

            if version == SchemaCurrent.userVersion {
                let issue = try shapeIssue(
                    connection, expecting: SchemaCurrent.shape)
                if let issue {
                    GatherLogger.log(
                        "schema_shape_mismatch path=\(path) user_version=\(version) issue=\(issue)",
                        level: .warn
                    )
                    return .incompatible(.shapeMismatch(version: version, issue: issue))
                }
                return .current
            }

            if version == 0 {
                return try userTableCount(connection) == 0
                    ? .empty
                    : .incompatible(.legacyPreV1)
            }
            // 重置版 v1 之前的历史版本（2…5）数值上更高，必须显式按「旧库」处理，
            // 否则会被当成未来版本 fail closed —— 升级即打不开（见 SchemaCurrent.legacyVersions）。
            if version < SchemaCurrent.userVersion
                || SchemaCurrent.legacyVersions.contains(version) {
                return .incompatible(.oldVersion(version))
            }
            return .incompatible(.newerVersion(version))
        } catch let error as DatabaseError {
            throw error
        } catch let error as DBError {
            let mapped = DatabaseError(dbError: error)
            if mapped.indicatesNotDatabaseFile { return .incompatible(.notADatabase) }
            // busy / io 等暂时性失败绝不能触发重置。
            throw mapped
        }
    }

    /// 读取 PRAGMA user_version；无结果返回 nil。
    static func readUserVersion(_ connection: DBConnection) throws -> Int? {
        guard let row = try connection.prepare("PRAGMA user_version;").get([]) else {
            return nil
        }
        return row[0].intValue.map { Int($0) }
    }

    static func userTableCount(_ connection: DBConnection) throws -> Int {
        guard let row = try connection.prepare("""
            SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            """).get([]),
              let raw = row[0].intValue
        else {
            throw DatabaseError.schema("读取 sqlite_master 表数无结果")
        }
        return Int(raw)
    }

    static func shapeIssue(
        _ connection: DBConnection,
        expecting expectation: SchemaShapeExpectation
    ) throws -> String? {
        let issues = expectation.issues(against: try SchemaShapeReader.read(connection))
        return issues.isEmpty ? nil : issues.joined(separator: "；")
    }
}
