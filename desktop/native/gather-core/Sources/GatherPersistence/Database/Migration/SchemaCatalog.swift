// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaCatalog.swift
// WP6a：版本快照 + 线性迁移注册表（设计 §5.1 / §7.1 a1）。
//
// WP6a 的生产目录只有 v1、迁移表为空——open 的「就地升级」路径尚不可达，行为与
// 现状一致。WP6b 把 current 改成 .v2、加一份 MigrationV1ToV2 即可，不改本文件的
// 计划算法。缺步/跳号/重复 (from,to) 在 plan/validate 中显式抛 .migration，
// 绝不静默跳过。
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

    /// 生产目录：current = v1，snapshots = [v1]，migrations = []。WP6a 不 bump 版本。
    public static let production = SchemaCatalog(
        current: .v1,
        snapshots: [
            .v1: SchemaSnapshot(version: .v1, ddl: SchemaV1.sql, shape: SchemaV1.shape),
        ],
        migrations: []
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
