// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaV2.swift
// WP6b：V2 版本快照（设计 docs/reviews/wp6-schema-migration-design.md §3.1）。
//
// V2 是**纯版本位**：DDL 与 V1 逐字相同（直接复用 SchemaV1.ddl），只把
// PRAGMA user_version 从 1 提到 2。因此 43 表 / 373 列 / 69 显式索引 / 62 外键
// 与列形指纹全部不变，V1→V2 迁移在事务内是 no-op（见 MigrationV1ToV2）。
//
// 真实载荷留给 V3：第一个有读者的 DDL 变更应同时交 SchemaV3 快照 + 迁移 +
// 计数同步清单，而不是把「先加列再等读者」塞进首个迁移。
public enum SchemaV2 {
    /// 当前库版本（SchemaCatalog.production.current）。
    public static let version = SchemaVersion.v2

    /// 与 V1 逐字相同的 DDL 主体（SchemaV1.ddl 不含 PRAGMA user_version）。
    public static let ddl: String = SchemaV1.ddl

    /// 与 V1 相同的列形期望（no-op V2 不改变任何表/列/索引/外键）。
    public static let shape: SchemaShapeExpectation = SchemaV1.shape
}
