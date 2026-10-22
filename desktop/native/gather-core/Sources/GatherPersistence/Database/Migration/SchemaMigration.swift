// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaMigration.swift
// WP6a：单步线性迁移协议（设计 §5.1）。
//
// apply 在 SchemaMigrator 已开启的 BEGIN IMMEDIATE 事务中执行：
//   * 不得自行 BEGIN/COMMIT/ROLLBACK；
//   * 不得写 PRAGMA user_version（迁移器在提交前统一写，保证 DDL 与版本号同生共死）。
// 迁移失败由迁移器回滚；库仍停在旧版本，下次启动可重试（apply 必须幂等/自洽）。
public protocol SchemaMigration: Sendable {
    var from: SchemaVersion { get }
    var to: SchemaVersion { get }
    /// 日志/测试标识，如 "v2-version-and-legacy-v1"。
    var name: String { get }

    func apply(_ connection: DBConnection) throws
}
