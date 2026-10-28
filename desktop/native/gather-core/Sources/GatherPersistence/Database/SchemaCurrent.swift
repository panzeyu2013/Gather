// desktop/native/gather-core/Sources/GatherPersistence/Database/SchemaCurrent.swift
// 当前 schema 的唯一 DDL 与结构基线（44 表 / 386 列 / 72 索引 / 65 外键，user_version=1）。
//
// 唯一真相源：DDL 字面量按表组拆在 Schema/SchemaCurrent+DDL*.swift，本文件按
// ddlCore → ddlDomain → ddlIndexes → addendumDDL 顺序拼接。addendumDDL 含
// triage_suggestions 与 face_cluster_constraints，文本逐字保留（索引 SQL 参与指纹）。
//
// 版本策略：只有当前版本可打开；V1/V2 迁移链已删除。旧版本库默认 fail closed；
// 显式 Options.resetPolicy 才把 db/-wal/-shm 一起改名为 <db>.incompatible-<ts>
// （最多 3 套）后重建：生产用 .renameOlderOnly（只归档比当前构建旧的库，未来版本
// 仍 fail closed），开发/测试用 .renameToIncompatible（任何不兼容库都归档）。
// 移动失败显式抛错，绝不吞错。
//
// 任何真实 schema 变更只改这一份 DDL，并同步 expected* 计数与 expectedShapeFingerprint；
// 不再新增 SchemaVn 快照、迁移器或历史形态补列。
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
// 必须含 'auto_raw_jpeg'；photos.status 不收 WorkspaceStage 的 'indexed'。
public enum SchemaCurrent {
    /// 当前（唯一）库版本号（PRAGMA user_version）。
    public static let userVersion: Int = 1

    /// 重置版 schema（v1）之前发布过的历史 user_version：2…5。
    ///
    /// 版本号在「放弃兼容」时被重置回 1，而历史旧库写的是 2…5 —— 数值上比 1 大，
    /// 纯按数值比较会把真实旧库误判成「未来版本」而 fail closed（升级即打不开）。
    /// 这里显式列出旧构建写过的版本，让 SchemaInspector 按 oldVersion 归类，
    /// 从而被 .renameOlderOnly 归档重建。
    ///
    /// 维护约定：以后每次 bump userVersion，都要把「上一版真正发布给用户的版本号」
    /// 加进来；未列入且 > userVersion 的库仍然 fail closed（绝不覆盖更新构建的数据）。
    public static let legacyVersions: Set<Int> = [2, 3, 4, 5]

    /// 期望的表/列/索引/外键总数（与 createSQL 同源；任何 DDL 变更必须同步改）。
    ///
    /// user_version 只证明曾按该版本建库，不能证明列形完整；Database.open 同时校验
    /// 计数、关键列与指纹，形态不符按不兼容库处理。
    public static let expectedTableCount: Int = 44
    public static let expectedColumnCount: Int = 386
    public static let expectedExplicitIndexCount: Int = 72
    public static let expectedForeignKeyCount: Int = 65

    /// 关键表必须存在的列（子集）。缺失即视为旧库/损坏库；全量列形由指纹兜底。
    public static let requiredTableColumns: [String: Set<String>] = [
        "sessions": ["id", "status", "index_seq", "source_path"],
        "photos": [
            "id", "session_id", "filepath", "status", "asset_id", "asset_file_id",
            "archived_at",
        ],
        "person_photos": ["person_id", "photo_id", "session_id"],
        "role_bindings": ["cluster_id", "session_id", "role_name"],
        "deliveries": [
            "id", "xmp_path", "target_kind", "status", "revision", "base_fingerprint", "lease_owner",
        ],
        "delivery_items": ["delivery_id", "photo_id", "module", "status"],
        "similarity_cluster_meta": [
            "session_id", "param_threshold", "param_min_group_size", "grouping_mode",
            "member_count", "version", "incremental_updates", "updated_at",
            "algorithm_version", "input_signature", "state_digest",
        ],
        "triage_suggestions": [
            "photo_id", "session_id", "verdict", "score", "confidence",
            "reasons_json", "group_id", "policy_version", "input_fingerprint", "computed_at",
        ],
        "face_cluster_constraints": [
            "id", "session_id", "kind", "member_keys_json", "peer_keys_json", "created_at",
        ],
    ]

    /// 规范化列形指纹（表/列定义/外键/显式索引的 SHA-256）。
    ///
    /// 口径见 Database.readSchemaShape：canonical 文本排序后取 SHA-256。更新 DDL 后必须
    /// 同步更新本值（先让正确库的 open 报出实际指纹，再粘贴；不要用 DDL 自动计算，
    /// 否则旧库也能自证「当前」）。当前值对应 44 表 / 386 列 / 72 索引 / 65 外键。
    public static let expectedShapeFingerprint: String =
        "a364328e93562c633c7e43ce5cee46c9b29e60171f25d4f270823f2cc4669132"

    /// 列形期望的类型化视图：Database.open / BackupVerifier 共用同一份计数、关键列与指纹。
    /// 与上面四个 expected* 常量同源，禁止另写第二份。
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
    /// createSQL = ddl + PRAGMA user_version = 1；唯一版本，没有迁移链/快照层，
    /// 拆分只为把 DDL 字面量按表组分开维护。
    ///
    /// final-cleanup 纯拆分：DDL 字面量按表组存放在 Schema/SchemaCurrent+DDL*.swift，
    /// 本常量按 ddlCore → ddlDomain → ddlIndexes 的顺序拼接；片段之间的分隔换行
    /// 与下一片段开头的空行都属于原 DDL 字节序，顺序/分隔符不得改动。
    /// 当前 schema 的增量表/索引（triage_suggestions / face_cluster_constraints）。
    /// 文本逐字保留：索引 SQL 会进入列形指纹，改写一个字符都会让既有库判形态不符。
    public static let addendumDDL: String = """
    CREATE TABLE IF NOT EXISTS triage_suggestions (
      photo_id TEXT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      verdict TEXT NOT NULL CHECK (verdict IN ('keep','reject','review')),
      score REAL NOT NULL DEFAULT 0,
      confidence REAL NOT NULL DEFAULT 0 CHECK (confidence BETWEEN 0 AND 1),
      reasons_json TEXT NOT NULL DEFAULT '[]',
      group_id TEXT,
      policy_version TEXT NOT NULL DEFAULT '',
      input_fingerprint TEXT NOT NULL DEFAULT '',
      computed_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_triage_session_verdict
      ON triage_suggestions(session_id, verdict, confidence);

    CREATE INDEX IF NOT EXISTS idx_triage_session_confidence
      ON triage_suggestions(session_id, confidence);

    CREATE TABLE IF NOT EXISTS face_cluster_constraints (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('separate','together')),
      member_keys_json TEXT NOT NULL DEFAULT '[]',
      peer_keys_json TEXT NOT NULL DEFAULT '[]',
      created_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_face_cluster_constraints_session
      ON face_cluster_constraints(session_id, kind);
    """

    public static let ddl: String =
        ddlCore + "\n" + ddlDomain + "\n" + ddlIndexes + "\n" + addendumDDL

    /// 唯一建库 SQL：当前 DDL + user_version = 1。
    public static let createSQL: String = ddl + "\nPRAGMA user_version = 1;\n"
}
