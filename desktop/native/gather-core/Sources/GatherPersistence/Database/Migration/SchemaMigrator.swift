// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaMigrator.swift
// WP6a：线性迁移执行器（设计 §4.4 / §5.1）。
//
// 事务纪律：BEGIN IMMEDIATE（WAL 下先拿写锁，避免 deferred 读→写升级撞
// SQLITE_BUSY_SNAPSHOT）；DDL 与 PRAGMA user_version 在同一事务内提交/回滚。
// PRAGMA foreign_keys 必须在 BEGIN 之前关闭（事务内设置是 no-op），提交后用
// foreign_key_check 兜底，再恢复连接级开关。
//
// WP6a 没有注册任何迁移，production.plan(from:) 恒为空；本类型的存在是为了
// 把 WP6b 的「备份 → 迁移 → 校验」中的事务/版本/形态契约先钉死。备份不在本步。
import Foundation
import GatherProtocol

public struct SchemaMigrator: Sendable {
    public let catalog: SchemaCatalog

    public init(catalog: SchemaCatalog = .production) {
        self.catalog = catalog
    }

    /// 把连接从 from 迁移到 catalog.current；空计划是 no-op（返回 from）。
    @discardableResult
    public func migrate(
        _ connection: DBConnection,
        from: SchemaVersion,
        path: String
    ) throws -> SchemaVersion {
        let plan = try catalog.plan(from: from)
        guard !plan.isEmpty else { return from }

        let target = catalog.current
        let targetSnapshot = try catalog.snapshot(target)
        GatherLogger.log(
            "schema_migrate_begin from=\(from) to=\(target) steps=\(plan.count) path=\(path)",
            level: .info
        )

        do {
            try connection.exec("PRAGMA foreign_keys = OFF;")
            var failure: Error?
            do {
                try connection.transaction(.immediate) {
                    for step in plan {
                        try step.apply(connection)
                    }
                    try connection.exec("PRAGMA user_version = \(target.rawValue);")

                    let violations = try connection.prepare("PRAGMA foreign_key_check;").query([])
                    guard violations.isEmpty else {
                        throw DatabaseError.migration(
                            "迁移后 foreign_key_check 发现 \(violations.count) 条违规"
                        )
                    }

                    // 在提交前校验目标形态：不符则连同 DDL/user_version 一起回滚，
                    // 不留下「版本已 bump 但形态不对」的半成品。
                    let issues = targetSnapshot.shape.issues(
                        against: try SchemaShapeReader.read(connection)
                    )
                    guard issues.isEmpty else {
                        throw DatabaseError.migration(
                            "迁移后列形与 \(target) 不符：\(issues.joined(separator: "；"))"
                        )
                    }
                }
            } catch {
                failure = error
            }

            // 迁移成功/失败都必须恢复连接级 FK；恢复失败只在没有更早错误时上报。
            do {
                try connection.exec("PRAGMA foreign_keys = ON;")
            } catch {
                if failure == nil { failure = error }
            }

            if let failure {
                throw migrationFailure(failure)
            }
        } catch {
            let mapped = migrationFailure(error)
            GatherLogger.log(
                "schema_migrate_failed from=\(from) to=\(target) path=\(path) error=\(mapped.message)",
                level: .error
            )
            throw mapped
        }

        GatherLogger.log(
            "schema_migrate_ok from=\(from) to=\(target) steps=\(plan.count) path=\(path)",
            level: .info
        )
        return target
    }

    /// 迁移链上的任何失败都收敛为 .migration（库仍停在旧版本；不重试、不重置）。
    private func migrationFailure(_ error: Error) -> DatabaseError {
        if let error = error as? DatabaseError {
            if case .migration = error { return error }
            return .migration(error.message)
        }
        if let error = error as? DBError {
            return .migration(DatabaseError(dbError: error).message)
        }
        return .migration(String(describing: error))
    }
}
