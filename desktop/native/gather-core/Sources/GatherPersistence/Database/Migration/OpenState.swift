// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/OpenState.swift
// WP6a：Database.open 的库状态判定（设计 §4.1）。
//
// 六态：empty / current / older / newer / corrupt / unreadableVersion。
// 设计 §4.1 把「读不出 user_version」放在 corrupt(.unreadableVersion)；这里拆成独立态，
// 让 open 能把「文件不是库」「V0 旧库」「形态不符」「版本读不出」分别记日志与 reset 原因。
//
// 判定顺序（与旧 inspectSchema 等价）：
//   v == current → 比对 shape(v)，不符即 corrupt(.shapeMismatch)
//   v == 0       → 0 用户表 = empty；有表 = corrupt(.legacyPreV1)
//   0 < v < current → 必须有快照且 shape 匹配；v1 的 370 列已知旧形
//                     （HistoricalV1Shape）也判 .older(.v1)（补列迁移），
//                     其余未知列形仍 corrupt(.shapeMismatch)（不迁移残缺库）
//   v > current  → newer（不读 shape：旧构建无权解释新库）
//   busy/io 等暂时性错误 → 原样上抛，绝不触发 reset。
import Foundation
import GatherProtocol

enum OpenState: Sendable, Equatable {
    /// user_version == 0 且没有任何用户表。
    case empty
    /// user_version == current 且列形/指纹一致。
    case current(SchemaVersion)
    /// 0 < user_version < current 且列形可迁移：或与该版本快照一致，或是 v1 的
    /// 370 列已知旧形（HistoricalV1Shape；同样返回 .v1，由迁移器补列）。
    case older(SchemaVersion)
    /// user_version > current：本构建不认识，fail closed。
    case newer(Int)
    /// 非 SQLite / V0 有表 / 版本对但形态不对。
    case corrupt(CorruptReason)
    /// PRAGMA user_version 读不出结果（既不是 0 也不是任何具体版本）。
    case unreadableVersion
}

enum CorruptReason: Sendable, Equatable, CustomStringConvertible {
    case notADatabase
    case legacyPreV1
    case shapeMismatch(version: Int, issue: String)

    var version: Int? {
        switch self {
        case .notADatabase:
            return nil
        case .legacyPreV1:
            return 0
        case .shapeMismatch(let version, _):
            return version
        }
    }

    var resetReason: Database.ResetReason {
        switch self {
        case .notADatabase:
            return .notADatabase
        case .legacyPreV1:
            return .legacyPreV1
        case .shapeMismatch(let version, _):
            return .shapeMismatch(version: version)
        }
    }

    var description: String {
        switch self {
        case .notADatabase:
            return "不是 SQLite 文件"
        case .legacyPreV1:
            return "V1 之前的旧库（user_version=0 但已有表）"
        case .shapeMismatch(let version, let issue):
            return "user_version=\(version) 但列形不符：\(issue)"
        }
    }
}

enum SchemaInspector {
    /// 读取并判定库状态；只做只读 PRAGMA，不写文件。
    static func inspect(
        _ connection: DBConnection,
        catalog: SchemaCatalog,
        path: String
    ) throws -> OpenState {
        do {
            guard let version = try readUserVersion(connection) else {
                return .unreadableVersion
            }
            guard version >= 0 else {
                return .corrupt(.shapeMismatch(version: version, issue: "user_version 为负数"))
            }

            let current = catalog.current
            if version == current.rawValue {
                let issue = try shapeIssue(
                    connection,
                    expecting: catalog.currentSnapshot.shape
                )
                if let issue {
                    GatherLogger.log(
                        "schema_shape_mismatch path=\(path) user_version=\(version) issue=\(issue)",
                        level: .warn
                    )
                    return .corrupt(.shapeMismatch(version: version, issue: issue))
                }
                return .current(current)
            }

            if version == 0 {
                return try userTableCount(connection) == 0
                    ? .empty
                    : .corrupt(.legacyPreV1)
            }

            if version > current.rawValue {
                return .newer(version)
            }

            // 0 < version < current：先确认 catalog 认识这个版本，再要求形态匹配。
            let from = SchemaVersion(version)
            let expected = try catalog.snapshot(from).shape
            let actual = try SchemaShapeReader.read(connection)
            let issues = expected.issues(against: actual)
            if issues.isEmpty {
                return .older(from)
            }

            // 例外：Cut 5 之前的 370 列 V1 是**已知**旧形（similarity_cluster_meta
            // 缺状态版本化三列）。它同样可迁移：MigrationV1ToV2 在事务内 ALTER 补列，
            // 失败由 SchemaMigrator 回滚、SchemaBackup 兜底。未记录过的列形仍判 corrupt。
            if from == .v1, HistoricalV1Shape.shape.issues(against: actual).isEmpty {
                GatherLogger.log(
                    "schema_legacy_v1_shape path=\(path) user_version=\(version) "
                        + "columns=\(HistoricalV1Shape.columnCount) action=alter-to-\(current)",
                    level: .info
                )
                return .older(from)
            }

            let issue = issues.joined(separator: "；")
            GatherLogger.log(
                "schema_shape_mismatch path=\(path) user_version=\(version) issue=\(issue)",
                level: .warn
            )
            return .corrupt(.shapeMismatch(version: version, issue: issue))
        } catch let error as DatabaseError {
            throw error
        } catch let error as DBError {
            let mapped = DatabaseError(dbError: error)
            if mapped.indicatesNotDatabaseFile { return .corrupt(.notADatabase) }
            // busy / io 等「暂时性」失败绝不能触发重置：那会挪走仍然有效的用户库。
            throw mapped
        }
    }

    /// 读取 PRAGMA user_version；无结果返回 nil（交给 open 判 .unreadableVersion）。
    static func readUserVersion(_ connection: DBConnection) throws -> Int? {
        guard let row = try connection.prepare("PRAGMA user_version;").get([]) else {
            return nil
        }
        return row[0].intValue.map { Int($0) }
    }

    private static func userTableCount(_ connection: DBConnection) throws -> Int {
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

    private static func shapeIssue(
        _ connection: DBConnection,
        expecting expectation: SchemaShapeExpectation
    ) throws -> String? {
        let issues = expectation.issues(against: try SchemaShapeReader.read(connection))
        return issues.isEmpty ? nil : issues.joined(separator: "；")
    }
}
