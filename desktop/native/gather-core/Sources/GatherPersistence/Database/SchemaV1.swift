// desktop/native/gather-core/Sources/GatherPersistence/Database/SchemaV1.swift
// SchemaV1（Cut 2 / S1；WP6b 起为**冻结快照**）：V1 本地库的 DDL 与结构基线。
//
// 内容：43 表 / 373 列 / 69 索引（61 普通 + 8 UNIQUE）/ 62 外键，逐字来自
// docs/schema-v1-draft.md §7.1 的 DDL。`ddl` 是不含版本号的 DDL 主体；
// `createSQL`/`sql` 追加 PRAGMA user_version = 1（复现真实 V1 旧库）。
// Cut 5 / 5b-2b：similarity_cluster_meta +3 列（algorithm_version / input_signature /
// state_digest），370 → 373；当时未 bump userVersion，因此「373 列」与「370 列」
// 都可能带 user_version=1。旧 V1（370 列）的形态由 Migration/HistoricalV1Shape 单独
// 识别：OpenState 判为 .older(.v1)，MigrationV1ToV2 在事务内 ALTER 补三列后再写
// user_version=2；只有未记录过的列形才 fail closed（显式开发重置才改名）。
//
// 当前版本（WP6b）：V2 是纯版本位，DDL 与 V1 逐字相同（SchemaV2.ddl = 本文件.ddl）；
// SchemaCatalog.production.current = .v2，V1 文件库经「备份 → V1→V2 事务迁移
// （373 列 no-op / 370 列补三列）→ 形态校验 → user_version=2」就地升级。
// V1 快照保留，供迁移起点与测试夹具使用。
//
// 唯一真相源：DDL 只定义一次（字面量按表组拆在 Schema/SchemaV1+DDL*.swift，本文件按
// ddlCore → ddlDomain → ddlIndexes 顺序拼接），V1/V2 共享；不做数据搬运、不做 down migration。
// 唯一例外是 MigrationV1ToV2 对已知 370 列旧 V1（Cut 5 漏 bump 版本）补三列：
// 补列文本必须逐字复刻 `SchemaV1.ddl` 的列定义（见 HistoricalV1Shape），仅此一处历史欠账。
// 任何新的真实 schema 变更都必须新增 SchemaVn.ddl + 迁移，并同步更新 expected*
// 计数与 expectedShapeFingerprint（否则正确新库也会被判定不兼容）。
//
// 与 Schema.swift 的关系：Schema.swift 只剩 AnalysisJobRepo 的活跃状态 SQL 字面量与
// check-docs 的版本镜像，不再定义任何 DDL；版本镜像 WP6b 起对齐 2。
//
// 旧库策略（详见 draft §6.1/§6.2，WP6b 起）：形态正确的 V1 库与已知 370 列旧 V1
// 就地迁移；user_version=0 但有表 / 版本高于 current / 未知列形 / 非 SQLite 文件默认 fail closed
// （只抛错，不改文件）。只有显式 Options.resetPolicy=.renameToIncompatible 才把
//   gather.sqlite → gather.sqlite.incompatible-<yyyyMMdd-HHmmss>
// 且 **必须同时移走 gather.sqlite-wal / gather.sqlite-shm** —— 只移主库时，
// 残留 WAL 会被新库按同名前缀恢复出旧页，出现「新 schema + 旧数据」的错位。
// 移动失败要显式抛错（不可吞），保留最多 3 份按时间戳淘汰。
//
// 约束分层：CHECK 只兜「非法值」（状态字符串 / 布尔 / 数值区间）；状态转移
// 合法性由 Swift 状态机负责。时间戳为 ISO-8601 TEXT，布尔为 INTEGER 0/1，
// mtime 为 REAL 毫秒。
//
// 用户数据 FK 策略（docs/refactor-decisions.md D-025）：role_bindings.cluster_id 与
// person_photos.photo_id/session_id 用 RESTRICT；face_identity_feedback.person_id、
// face_clusters.matched_person_id、navigation_groups.lead_photo_id 用 SET NULL；
// 其余 CASCADE 只留给派生/已无锚点的数据，逐条理由见 DDL 内注释。
//
// CHECK 策略（D-027）：只收生产/测试实际写入且被登记的值 —— asset_members.binding_source
// 必须含 'auto_raw_jpeg'；photos.status 不收 WorkspaceStage 的 'indexed'（photos 无
// 写入点，唯一写 'indexed' 的是测试夹具写 sessions.status，见 audit R3-02）。
//
// 接线（Cut 2 / S5c-2b-3b-2b-3）：生产只经 Database.open(at:) 建库；测试夹具直接
// exec 本文件的 sql（不存在第二份 DDL / 迁移形态）。
public enum SchemaV1 {
    /// 期望的库版本号（PRAGMA user_version）。读到别的值即视为不兼容库。
    public static let userVersion: Int = 1

    /// 期望的表/列/索引/外键总数（与 SchemaV1.sql 的 DDL 同源；任何 DDL 变更必须同步改）。
    ///
    /// 为什么 user_version 之外还要列形：Cut 5 给 similarity_cluster_meta 加 3 列时没有
    /// bump userVersion（370 → 373），旧 V1 库的 user_version 仍是 1。只看版本号会把
    /// 「缺列的旧库」当成 current，直到运行期第一次访问新列才抛 no such column。
    /// Database.open 用计数 + 关键列 + 指纹判断「版本号对，但列形不是当前 V1」：
    /// 370 列的已知旧形走 Migration/HistoricalV1Shape + 补列迁移；其余未知列形默认
    /// fail closed，只有显式 reset 才整体改名（含 -wal/-shm）。
    public static let expectedTableCount: Int = 43
    public static let expectedColumnCount: Int = 373
    public static let expectedExplicitIndexCount: Int = 69
    public static let expectedForeignKeyCount: Int = 62

    /// 关键表必须存在的列（子集）。缺失即视为旧库/损坏库；全量列形由指纹兜底。
    public static let requiredTableColumns: [String: Set<String>] = [
        "sessions": ["id", "status", "index_seq", "source_path"],
        "photos": ["id", "session_id", "filepath", "status", "asset_id", "asset_file_id"],
        "person_photos": ["person_id", "photo_id", "session_id"],
        "role_bindings": ["cluster_id", "session_id", "role_name"],
        "deliveries": ["id", "xmp_path", "status", "revision", "base_fingerprint", "lease_owner"],
        "delivery_items": ["delivery_id", "photo_id", "module", "status"],
        "similarity_cluster_meta": [
            "session_id", "param_threshold", "param_min_group_size", "grouping_mode",
            "member_count", "version", "incremental_updates", "updated_at",
            "algorithm_version", "input_signature", "state_digest",
        ],
    ]

    /// 规范化列形指纹（表/列定义/外键/显式索引的 SHA-256）。
    ///
    /// 口径见 Database.readSchemaShape：canonical 文本排序后取 SHA-256。更新 DDL 后必须
    /// 同步更新本值（先让正确库的 open 报出实际指纹，再粘贴；不要用 DDL 自动计算，
    /// 否则旧库也能自证「当前」）。当前值对应 43 表 / 373 列 / 69 索引 / 62 外键。
    public static let expectedShapeFingerprint: String =
        "7c7e0d143f93951e5c68fa07b962c65f157750f11bd638950c0931e5e0ee44c2"

    /// 列形期望的类型化视图（WP6a）：open / SchemaCatalog / SchemaMigrator 共用同一份
    /// 计数、关键列与指纹。与上面四个 expected* 常量同源，禁止另写第二份。
    public static let shape = SchemaShapeExpectation(
        tableCount: expectedTableCount,
        columnCount: expectedColumnCount,
        explicitIndexCount: expectedExplicitIndexCount,
        foreignKeyCount: expectedForeignKeyCount,
        requiredColumns: requiredTableColumns,
        fingerprint: expectedShapeFingerprint
    )

    /// 建库 DDL 主体（单次 exec 执行；含 PRAGMA foreign_keys，不含 user_version）。
    ///
    /// createSQL = ddl + PRAGMA user_version = 1；SchemaSnapshot 依赖这个拆分，
    /// 让 V1/V2 共享同一份 DDL 而版本号由快照决定。
    ///
    /// final-cleanup 纯拆分：DDL 字面量按表组存放在 Schema/SchemaV1+DDL*.swift，
    /// 本常量按 ddlCore → ddlDomain → ddlIndexes 的顺序拼接；片段之间的分隔换行
    /// 与下一片段开头的空行都属于原 DDL 字节序，顺序/分隔符不得改动。
    public static let ddl: String = ddlCore + "\n" + ddlDomain + "\n" + ddlIndexes

    /// V1 建库 SQL：DDL + 版本号 1（历史基线）。
    ///
    /// WP6b 起当前版本是 V2（DDL 与 V1 逐字相同，见 Migration/SchemaV2.swift）；
    /// 本常量仍保留 V1 语义，供测试夹具/`gather-schema dump` 复现真实旧库，
    /// 也是 V1→V2 迁移的唯一入口形态。新库由 SchemaCatalog.currentSnapshot 建。
    public static let createSQL: String = ddl + "\nPRAGMA user_version = 1;\n"

    /// Cut 2 起的兼容别名（语义 = createSQL；现有测试与工具继续可用）。
    public static let sql: String = createSQL
}
