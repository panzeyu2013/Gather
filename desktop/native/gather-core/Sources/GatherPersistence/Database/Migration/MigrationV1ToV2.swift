// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/MigrationV1ToV2.swift
// WP6b：V1 → V2 的线性迁移；同时补齐 Cut 5 之前的 370 列旧 V1。
//
// V2 对**当前 V1（373 列）**只是版本位：DDL 与 V1 逐字相同，apply 不碰任何列。
// 但 Cut 2–4 期间生成的旧 V1（user_version=1、similarity_cluster_meta 缺
// algorithm_version / input_signature / state_digest）必须真的补列，否则这些库
// 永远到不了 V2 的 373 列形态。两种来源共用同一条迁移：
//   * 373 列：三列都已存在 → 本步 no-op；
//   * 370 列：逐列检测并 ALTER，默认值/CHECK 与 SchemaV1.ddl 逐字一致。
//
// 版本号由 SchemaMigrator 在 BEGIN IMMEDIATE 事务内统一写入（DDL 与版本号同生共死）；
// 本迁移不得自行 BEGIN/COMMIT，也不得写 PRAGMA user_version。失败由迁移器回滚，
// 库仍停在旧的 370 列 V1，下次启动可重试（迁移前备份由 SchemaBackup 保留）。
//
// ALTER 顺序固定为 algorithm_version → input_signature → state_digest：与
// SchemaV1.ddl 的列序一致，PRAGMA table_info 的 cid 与列形指纹才能和 373 对得上。
// 提交前 SchemaMigrator 会校验目标指纹，任何顺序/默认值漂移都会整体回滚。
//
// 为什么保留一次「真实升级路径」：备份 → 事务 → 迁移 → foreign_key_check →
// 目标形态校验 → 提交的整条链必须有可执行用例，否则首次带载荷的迁移会在
// 未经验证的路径上裸奔。失败的注入用例见 SchemaMigrationTests。
struct MigrationV1ToV2: SchemaMigration {
    let from: SchemaVersion = .v1
    let to: SchemaVersion = .v2
    let name = "v2-version-and-legacy-v1"

    /// 旧 V1 缺的三列；定义必须与 SchemaV1.ddl 逐字一致（NOT NULL 默认值 + CHECK）。
    private static let legacyV1Columns: [(name: String, definition: String)] = [
        ("algorithm_version", "INTEGER NOT NULL DEFAULT 1 CHECK (algorithm_version >= 1)"),
        ("input_signature", "TEXT NOT NULL DEFAULT ''"),
        ("state_digest", "TEXT NOT NULL DEFAULT ''"),
    ]

    func apply(_ connection: DBConnection) throws {
        // 373 列 V1 上三列已存在（重复 ALTER 会报 duplicate column name），
        // 因此按列名逐列判断，而不是按列数猜。
        let existing = Set(
            try connection.prepare("PRAGMA table_info('similarity_cluster_meta');")
                .query([])
                .compactMap { $0[1].textValue }
        )
        for column in Self.legacyV1Columns where !existing.contains(column.name) {
            try connection.exec(
                "ALTER TABLE similarity_cluster_meta ADD COLUMN \(column.name) \(column.definition);"
            )
        }
    }
}
