// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/MigrationV1ToV2.swift
// WP6b：V1 → V2 的线性迁移（设计 §3.1）。
//
// V2 只 bump user_version，DDL 与 V1 逐字相同，所以 apply 是 no-op。版本号由
// SchemaMigrator 在 BEGIN IMMEDIATE 事务内统一写入（DDL 与版本号同生共死）；
// 本迁移不得自行 BEGIN/COMMIT，也不得写 PRAGMA user_version。
//
// 为什么保留一次「真实升级路径」：备份 → 事务 → 迁移 → foreign_key_check →
// 目标形态校验 → 提交的整条链必须有可执行用例，否则首次带载荷的迁移会在
// 未经验证的路径上裸奔。失败的注入用例见 SchemaMigrationTests。
struct MigrationV1ToV2: SchemaMigration {
    let from: SchemaVersion = .v1
    let to: SchemaVersion = .v2
    let name = "v2-version-only"

    func apply(_ connection: DBConnection) throws {
        // no-op：V2 的 DDL 与 V1 完全相同，唯一变化是迁移器提交前写的 user_version。
    }
}
