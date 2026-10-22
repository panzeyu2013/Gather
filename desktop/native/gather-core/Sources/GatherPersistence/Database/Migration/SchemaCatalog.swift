// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaCatalog.swift
// WP6a：版本快照 + 线性迁移注册表（设计 §5.1 / §7.1 a1）。
// WP6b：current = .v2；V1→V2 对 373 列 V1 是 no-op 版本位，对已知 370 列旧 V1
// 补三列（MigrationV1ToV2），本文件的计划算法不变。缺步/跳号/重复 (from,to) 在
// plan/validate 中显式抛 .migration，绝不静默跳过。
import Foundation

public struct SchemaCatalog: Sendable {
    public let current: SchemaVersion
    public let snapshots: [SchemaVersion: SchemaSnapshot]
    public let migrations: [any SchemaMigration]

    public init(
        current: SchemaVersion,
        snapshots: [SchemaVersion: SchemaSnapshot],
        migrations: [any SchemaMigration]
    ) {
        self.current = current
        self.snapshots = snapshots
        self.migrations = migrations
    }

    /// 生产目录：current = v2，snapshots = [v1, v2]，migrations = [V1→V2]。
    /// V2 与 V1 的 DDL 逐字相同；373 列 V1 的迁移是 no-op，370 列旧 V1 由同一
    /// 迁移 ALTER 补三列。版本号由 SchemaMigrator 事务内写。
    public static let production = SchemaCatalog(
        current: .v2,
        snapshots: [
            .v1: SchemaSnapshot(version: .v1, ddl: SchemaV1.ddl, shape: SchemaV1.shape),
            .v2: SchemaSnapshot(version: .v2, ddl: SchemaV2.ddl, shape: SchemaV2.shape),
        ],
        migrations: [MigrationV1ToV2()]
    )

    public func snapshot(_ version: SchemaVersion) throws -> SchemaSnapshot {
        guard let snapshot = snapshots[version] else {
            throw DatabaseError.migration("SchemaCatalog 缺少 \(version) 的快照")
        }
        return snapshot
    }

    /// 当前版本的快照。生产目录恒存在；缺失属于编程错误，直接 fail fast。
    public var currentSnapshot: SchemaSnapshot {
        guard let snapshot = snapshots[current] else {
            preconditionFailure("SchemaCatalog.current = \(current) 没有对应快照")
        }
        return snapshot
    }

    /// 结构校验：每个迁移必须 from+1 == to、落在 current 之内、from 不重复、两端有快照。
    public func validate() throws {
        guard snapshots[current] != nil else {
            throw DatabaseError.migration("SchemaCatalog 缺少 current \(current) 的快照")
        }
        var seenFrom = Set<SchemaVersion>()
        for migration in migrations {
            let expectedTo = SchemaVersion(migration.from.rawValue + 1)
            guard migration.to == expectedTo else {
                throw DatabaseError.migration(
                    "迁移 \(migration.name) 跳号：\(migration.from) → \(migration.to)，期望 \(expectedTo)"
                )
            }
            guard migration.from < current else {
                throw DatabaseError.migration(
                    "迁移 \(migration.name) 的起点 \(migration.from) 不低于 current \(current)"
                )
            }
            guard seenFrom.insert(migration.from).inserted else {
                throw DatabaseError.migration(
                    "迁移起点 \(migration.from) 重复注册（\(migration.name)）"
                )
            }
            guard snapshots[migration.from] != nil else {
                throw DatabaseError.migration("迁移 \(migration.name) 缺少起点快照 \(migration.from)")
            }
            guard snapshots[migration.to] != nil else {
                throw DatabaseError.migration("迁移 \(migration.name) 缺少目标快照 \(migration.to)")
            }
        }
    }

    /// 从 version 到 current 的有序计划；version == current 返回空数组。
    public func plan(from version: SchemaVersion) throws -> [any SchemaMigration] {
        try validate()
        guard version <= current else {
            throw DatabaseError.migration("迁移起点 \(version) 高于 current \(current)")
        }
        if version == current { return [] }
        _ = try snapshot(version)

        var ordered: [any SchemaMigration] = []
        var cursor = version
        while cursor < current {
            let next = SchemaVersion(cursor.rawValue + 1)
            let matches = migrations.filter { $0.from == cursor && $0.to == next }
            if matches.isEmpty {
                throw DatabaseError.migration("缺少 \(cursor) → \(next) 的迁移")
            }
            if matches.count > 1 {
                throw DatabaseError.migration(
                    "\(cursor) → \(next) 重复注册 \(matches.count) 次"
                )
            }
            ordered.append(matches[0])
            cursor = next
        }
        return ordered
    }
}
