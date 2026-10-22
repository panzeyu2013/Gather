// desktop/native/gather-core/Sources/GatherPersistence/Database/SchemaV1.swift
// SchemaV1（Cut 2 / S1；WP6b 起为**冻结快照**）：V1 本地库的 DDL 与结构基线。
//
// 内容：43 表 / 373 列 / 69 索引（61 普通 + 8 UNIQUE）/ 62 外键，逐字来自
// docs/schema-v1-draft.md §7.1 的 DDL。`ddl` 是不含版本号的 DDL 主体；
// `createSQL`/`sql` 追加 PRAGMA user_version = 1（复现真实 V1 旧库）。
// Cut 5 / 5b-2b：similarity_cluster_meta +3 列（algorithm_version / input_signature /
// state_digest），370 → 373；当时未 bump userVersion，因此旧 V1 库（370 列）只能
// 靠列形识别：Database.open 对比 expectedColumnCount / requiredTableColumns /
// expectedShapeFingerprint，不匹配默认 fail closed（显式开发重置才改名），不会把
// 缺列旧库当 current 留到运行期报错。
//
// 当前版本（WP6b）：V2 是纯版本位，DDL 与 V1 逐字相同（SchemaV2.ddl = 本文件.ddl）；
// SchemaCatalog.production.current = .v2，V1 文件库经「备份 → V1→V2 no-op 事务迁移 →
// 形态校验 → user_version=2」就地升级。V1 快照保留，供迁移起点与测试夹具使用。
//
// 唯一真相源：DDL 只在本文件定义一次，V1/V2 共享；不做 ALTER、不做数据搬运、不做
// down migration。任何真实 schema 变更都必须新增 SchemaVn.ddl + 迁移，并同步更新
// expected* 计数与 expectedShapeFingerprint（否则正确新库也会被判定不兼容）；
// 不允许再出现「DDL 在 A 处、补列在 B 处」的第二份定义。
//
// 与 Schema.swift 的关系：Schema.swift 只剩 AnalysisJobRepo 的活跃状态 SQL 字面量与
// check-docs 的版本镜像，不再定义任何 DDL；版本镜像 WP6b 起对齐 2。
//
// 旧库策略（详见 draft §6.1/§6.2，WP6b 起）：形态正确的 V1 库就地迁移；
// user_version=0 但有表 / 版本高于 current / 形态不符 / 非 SQLite 文件默认 fail closed
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
    /// Database.open 用计数 + 关键列 + 指纹判断「版本号对，但列形不是当前 V1」，
    /// 不匹配按不兼容库整体重置（含 -wal/-shm）。
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
    public static let ddl: String = """
    -- SchemaV1 · Gather 本地库最终形态（43 表 / 373 列 / 69 索引 / 62 外键）
    -- 约定：时间戳为 ISO-8601 TEXT（与 nowISOString 同格式）；布尔为 INTEGER 0/1；mtime 为 REAL 毫秒。
    -- 约束分层：CHECK 只兜「非法值」，状态转移合法性由 Swift 状态机负责。

    -- 用户数据外键策略（audit R2 / D-025）：判断标准是「父行消失后，子行是否仍有用户含义」。
    --   RESTRICT：role_bindings.cluster_id、person_photos.photo_id / session_id
    --     —— 删除簇/照片/会话前必须显式迁移或删除子行。这三列都是 NOT NULL，无法 SET NULL；
    --        用 RESTRICT 让「删漏了」变成响亮报错，而不是静默丢用户数据。
    --   SET NULL：face_identity_feedback.person_id、face_clusters.matched_person_id、
    --     navigation_groups.lead_photo_id —— 只解绑，保留子行。
    --   CASCADE（仅派生/已无锚点）：person_embeddings.person_id / photo_id / session_id、
    --     face_identity_feedback.photo_id / session_id、culling_decisions.photo_id /
    --     session_id、culling_history.session_id、navigation_groups.session_id、
    --     face_clusters.session_id、person_photos.person_id、role_bindings.session_id。
    -- 绑定是用户身份凭据，也是 XMP 人物关键词的清理依据：删除簇前必须显式迁移/删除绑定。

    PRAGMA foreign_keys = ON;

    -- 1. 工作区会话
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft','photos_loaded','analyzing','review','completed')),
      source_path TEXT NOT NULL DEFAULT '',
      truncated_import INTEGER NOT NULL DEFAULT 0 CHECK (truncated_import IN (0,1)),
      reload_acked_at TEXT,
      index_seq INTEGER NOT NULL DEFAULT 0 CHECK (index_seq >= 0),
      photo_count INTEGER NOT NULL DEFAULT 0 CHECK (photo_count >= 0),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 2. 逻辑资产
    CREATE TABLE assets (
      id TEXT PRIMARY KEY,
      status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active','orphan','offline_unverified')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 3. 物理文件
    CREATE TABLE asset_files (
      id TEXT PRIMARY KEY,
      volume_id TEXT NOT NULL DEFAULT '',
      file_identity TEXT NOT NULL DEFAULT '',
      normalized_path TEXT NOT NULL,
      filename TEXT NOT NULL,
      extension TEXT NOT NULL DEFAULT '',
      media_type TEXT NOT NULL DEFAULT 'unknown'
        CHECK (media_type IN ('unknown','image','raw')),
      file_size INTEGER NOT NULL DEFAULT 0 CHECK (file_size >= 0),
      file_mtime_ms REAL NOT NULL DEFAULT 0,
      checksum TEXT NOT NULL DEFAULT '',
      online_status TEXT NOT NULL DEFAULT 'online'
        CHECK (online_status IN ('online','offline')),
      last_seen_at TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 4. 照片行
    -- status 只收派生阶段（pending/ready/removed/missing）。'indexed' 是 WorkspaceStage 的
    -- UI 阶段，唯一写库点是测试夹具写 sessions.status（audit R3-02）；photos 无任何生产/
    -- 测试写入点，故不加入本 CHECK。若将来 Photo DTO 把 UI 阶段直接落库，必须先改本
    -- CHECK 并给出迁移策略，不得直接写入（旧库整体 reset，无存量值需要搬运）。
    CREATE TABLE photos (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      filepath TEXT NOT NULL,
      filename TEXT NOT NULL DEFAULT '',
      checksum TEXT NOT NULL DEFAULT '',
      checksum_file_size INTEGER NOT NULL DEFAULT 0,
      checksum_file_mtime_ms REAL NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','ready','removed','missing')),
      asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
      asset_file_id TEXT REFERENCES asset_files(id) ON DELETE SET NULL,
      width INTEGER NOT NULL DEFAULT 0 CHECK (width >= 0),
      height INTEGER NOT NULL DEFAULT 0 CHECK (height >= 0),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 5. 分析运行记录
    CREATE TABLE analysis_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('face','similarity')),
      photo_count INTEGER NOT NULL CHECK (photo_count >= 0),
      index_seq INTEGER NOT NULL CHECK (index_seq >= 0),
      started_at TEXT NOT NULL,
      finished_at TEXT NOT NULL DEFAULT '',
      params_json TEXT NOT NULL DEFAULT '{}',
      status TEXT NOT NULL DEFAULT 'running'
        CHECK (status IN ('running','ok','failed')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );

    -- 6. 资产成员
    -- binding_source 覆盖全部生产写入值（audit R3-01 / D-027，已 grep 核对 Sources）：
    --   'import'（DEFAULT）、'backfill'（AssetRepo.ensurePhoto）、'manual_split'（splitFileAsset）、
    --   'auto_raw_jpeg'（mergeFileAssets；acceptCandidate / reconcileRawJpegLinks 路径）。
    -- 漏掉 'auto_raw_jpeg' 会让 RAW/JPEG 合并在 V1 下抛 CHECK constraint failed。
    CREATE TABLE asset_members (
      asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
      file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
      member_role TEXT NOT NULL
        CHECK (member_role IN ('raw','camera_jpeg','rendered_tiff','unknown')),
      is_primary INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0,1)),
      confidence REAL NOT NULL DEFAULT 1.0,
      binding_source TEXT NOT NULL DEFAULT 'import'
        CHECK (binding_source IN ('import','backfill','manual_split','auto_raw_jpeg')),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      PRIMARY KEY (asset_id, file_id),
      UNIQUE (file_id)
    );

    -- 7. 资产配对候选
    CREATE TABLE asset_link_candidates (
      id TEXT PRIMARY KEY,
      left_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
      right_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
      relation_type TEXT NOT NULL CHECK (relation_type IN ('raw_jpeg')),
      confidence REAL NOT NULL,
      evidence_json TEXT NOT NULL DEFAULT '{}',
      status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','accepted','rejected')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 8. 会话↔资产
    CREATE TABLE session_assets (
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
      display_file_id TEXT REFERENCES asset_files(id) ON DELETE SET NULL,
      import_order INTEGER NOT NULL DEFAULT 0 CHECK (import_order >= 0),
      added_at TEXT NOT NULL,
      PRIMARY KEY (session_id, asset_id)
    );

    -- 9. 侧车绑定
    CREATE TABLE sidecar_bindings (
      id TEXT PRIMARY KEY,
      xmp_path TEXT NOT NULL,
      normalized_xmp_path TEXT NOT NULL UNIQUE,
      binding_rule TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 10. 侧车↔文件
    CREATE TABLE sidecar_binding_files (
      sidecar_binding_id TEXT NOT NULL REFERENCES sidecar_bindings(id) ON DELETE CASCADE,
      file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      PRIMARY KEY (sidecar_binding_id, file_id)
    );

    -- 11. 侧车元数据现值
    CREATE TABLE sidecar_metadata_state (
      sidecar_binding_id TEXT PRIMARY KEY REFERENCES sidecar_bindings(id) ON DELETE CASCADE,
      rating INTEGER CHECK (rating IS NULL OR rating BETWEEN 0 AND 5),
      label TEXT,
      keywords TEXT NOT NULL DEFAULT '[]',
      fingerprint TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL
    );

    -- 12. 资产回填游标
    CREATE TABLE asset_backfill_state (
      session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
      last_photo_rowid INTEGER NOT NULL DEFAULT 0 CHECK (last_photo_rowid >= 0),
      total_photos INTEGER NOT NULL DEFAULT 0 CHECK (total_photos >= 0),
      migrated_photos INTEGER NOT NULL DEFAULT 0 CHECK (migrated_photos >= 0),
      offline_files INTEGER NOT NULL DEFAULT 0 CHECK (offline_files >= 0),
      candidate_links INTEGER NOT NULL DEFAULT 0 CHECK (candidate_links >= 0),
      automatic_merges INTEGER NOT NULL DEFAULT 0 CHECK (automatic_merges >= 0),
      status TEXT NOT NULL DEFAULT 'running'
        CHECK (status IN ('running','completed','failed')),
      updated_at TEXT NOT NULL
    );

    -- 13. 异步任务队列
    CREATE TABLE analysis_jobs (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL CHECK (type IN (
        'metadata.scan','thumbnail.build','similarity.analyze','duplicate.scan',
        'face.analyze','quality.score','export.execute','checksum.backfill')),
      scope_type TEXT NOT NULL CHECK (length(scope_type) > 0),
      scope_id TEXT NOT NULL,
      dedupe_key TEXT NOT NULL,
      status TEXT NOT NULL
        CHECK (status IN ('queued','running','succeeded','failed','cancelled','interrupted','cancelling')),
      priority INTEGER NOT NULL DEFAULT 0,
      progress_current INTEGER NOT NULL DEFAULT 0 CHECK (progress_current >= 0),
      progress_total INTEGER NOT NULL DEFAULT 0 CHECK (progress_total >= 0),
      progress_message TEXT NOT NULL DEFAULT '',
      input_fingerprint TEXT NOT NULL DEFAULT '',
      model_id TEXT NOT NULL DEFAULT '',
      model_version TEXT NOT NULL DEFAULT '',
      checkpoint_json TEXT NOT NULL DEFAULT '{}',
      attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
      lease_owner TEXT NOT NULL DEFAULT '',
      heartbeat_at TEXT NOT NULL DEFAULT '',
      cancel_requested_at TEXT NOT NULL DEFAULT '',
      error_code TEXT NOT NULL DEFAULT '',
      error_message TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      started_at TEXT NOT NULL DEFAULT '',
      finished_at TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL
    );

    -- 14. 文件级分析结果
    CREATE TABLE asset_analysis (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      photo_id TEXT REFERENCES photos(id) ON DELETE SET NULL,
      asset_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
      analysis_type TEXT NOT NULL,
      result_json TEXT NOT NULL DEFAULT '{}',
      warnings_json TEXT NOT NULL DEFAULT '[]',
      model_id TEXT NOT NULL DEFAULT '',
      model_version TEXT NOT NULL DEFAULT '',
      input_fingerprint TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (asset_file_id, analysis_type, model_id, model_version, input_fingerprint)
    );

    -- 15. 人脸观察
    CREATE TABLE face_observations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      bbox_x REAL NOT NULL,
      bbox_y REAL NOT NULL,
      bbox_w REAL NOT NULL,
      bbox_h REAL NOT NULL,
      embedding BLOB NOT NULL,
      confidence REAL NOT NULL DEFAULT 0.0,
      analysis_signature TEXT NOT NULL DEFAULT '',
      quality REAL NOT NULL DEFAULT 0 CHECK (quality BETWEEN 0 AND 1),
      face_size_px REAL NOT NULL DEFAULT 0 CHECK (face_size_px >= 0),
      roll_degrees REAL NOT NULL DEFAULT 0,
      model_id TEXT NOT NULL DEFAULT '',
      model_version TEXT NOT NULL DEFAULT '',
      embedding_dim INTEGER NOT NULL DEFAULT 0 CHECK (embedding_dim >= 0),
      created_at TEXT NOT NULL DEFAULT ''
    );

    -- 16. 人脸分析输入指纹（陈旧判定唯一真相源）
    CREATE TABLE face_analysis_state (
      photo_id TEXT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      source_file_size INTEGER NOT NULL,
      source_file_mtime_ms REAL NOT NULL,
      analysis_signature TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 17. 身份反馈（用户的人工确认/否决证据）
    -- person_id 用 SET NULL（不是 CASCADE）：删身份时只解绑，保留「这张脸曾被确认/否决」
    -- 的证据（audit R2-04 / D-025）；photo_id / session_id 保 CASCADE：脸所在的照片或会话
    -- 消失后，针对该脸的反馈已无锚点。
    CREATE TABLE face_identity_feedback (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      bbox_x REAL NOT NULL,
      bbox_y REAL NOT NULL,
      bbox_w REAL NOT NULL,
      bbox_h REAL NOT NULL,
      person_id TEXT REFERENCES persons(id) ON DELETE SET NULL,
      decision TEXT NOT NULL CHECK (decision IN ('confirmed','rejected')),
      keywords TEXT NOT NULL DEFAULT '[]',
      updated_at TEXT NOT NULL
    );

    -- 18. 人脸聚类签名
    CREATE TABLE face_cluster_state (
      session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
      cluster_signature TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 19. 人脸簇（+ 用户绑定的身份）
    -- session_id 保 CASCADE：簇是派生数据，删会话即失效；用户绑定由 role_bindings.cluster_id
    -- 的 RESTRICT 保护（见下）。
    -- matched_person_id 用 SET NULL：删身份只解绑、不删簇。注意 SET NULL 不会改 status，
    -- 调用方必须同步 UPDATE status='unbound'（R2-05；PersonRepo.delete 已显式做，本库不放
    -- 触发器，避免隐藏状态转移）。
    CREATE TABLE face_clusters (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      label TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'unbound' CHECK (status IN ('unbound','bound')),
      thumbnail_path TEXT NOT NULL DEFAULT '',
      matched_person_id TEXT REFERENCES persons(id) ON DELETE SET NULL,
      match_confidence REAL,
      created_at TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL DEFAULT ''
    );

    -- 20. 簇成员
    CREATE TABLE face_cluster_members (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      cluster_id INTEGER NOT NULL REFERENCES face_clusters(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      bbox TEXT NOT NULL,
      confidence REAL NOT NULL DEFAULT 0.0,
      observation_id INTEGER REFERENCES face_observations(id) ON DELETE CASCADE
    );

    -- 21. 角色绑定（用户数据）
    -- cluster_id 用 RESTRICT（不是 CASCADE）：绑定是用户身份凭据，同时也是 XMP 人物关键词的
    -- 清理依据（PersonRepo 的 I2/I4 不变量），丢失不可从派生数据恢复。
    -- **删除簇前必须显式迁移/删除绑定**（FaceRepo.deleteClustersBySession /
    -- removeMemberFromCluster 已按「先删 role_bindings 再删簇」实现；FaceKwService 重聚类
    -- 只删不在 role_bindings 里的簇）。RESTRICT 让绕过这三处保护的新代码立刻报错。
    -- session_id 仍是 CASCADE，但删会话会先撞上 cluster 的 RESTRICT；调用方必须先解绑，
    -- 再删会话（D-025：SessionService.deleteCascade 需显式处理 role_bindings）。
    CREATE TABLE role_bindings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      cluster_id INTEGER NOT NULL UNIQUE REFERENCES face_clusters(id) ON DELETE RESTRICT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      role_name TEXT NOT NULL,
      keywords TEXT NOT NULL DEFAULT '[]',
      created_at TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL DEFAULT ''
    );

    -- 22. 感知哈希
    CREATE TABLE similarity_hashes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      hash_hex TEXT NOT NULL,
      file_size INTEGER NOT NULL DEFAULT 0,
      file_mtime_ms REAL NOT NULL DEFAULT 0
    );

    -- 23. 相似度结果快照
    CREATE TABLE similarity_results (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      groups_json TEXT NOT NULL,
      stats_json TEXT NOT NULL DEFAULT '{}',
      param_threshold INTEGER NOT NULL CHECK (param_threshold BETWEEN 0 AND 64),
      param_min_group_size INTEGER NOT NULL DEFAULT 2 CHECK (param_min_group_size >= 1),
      created_at TEXT NOT NULL
    );

    -- 24. 结果快照成员
    CREATE TABLE similarity_result_members (
      result_id INTEGER NOT NULL REFERENCES similarity_results(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      group_index INTEGER NOT NULL CHECK (group_index >= 0),
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      PRIMARY KEY (result_id, photo_id)
    );

    -- 25. 增量聚类分量（photo_id 刻意无 FK：残留行是「已移除」的依据）
    CREATE TABLE similarity_cluster_state (
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL,
      hash_hex TEXT NOT NULL,
      component_index INTEGER NOT NULL,
      group_seed TEXT,
      PRIMARY KEY (session_id, photo_id)
    );

    -- 26. 聚类参数与版本
    -- Cut 5 / 5b-2b：三列状态版本化（开发期直接改 V1）。
    -- algorithm_version 是状态语义版本（旧实现落的行按版本不符失效）；input_signature
    -- 是参数指纹（阈值/组大小/模式 + 算法版本），state_digest 是内容摘要（规范序、
    -- 与行序无关）。三者任一不符即视为旧/损坏 state：不得增量复用，必须全量覆盖。
    -- 默认值只为兼容「显式省略三列」的插入（空签名/空摘要永远不等于真实指纹）。
    CREATE TABLE similarity_cluster_meta (
      session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
      param_threshold INTEGER NOT NULL CHECK (param_threshold BETWEEN 0 AND 64),
      param_min_group_size INTEGER NOT NULL DEFAULT 2 CHECK (param_min_group_size >= 1),
      grouping_mode TEXT NOT NULL CHECK (grouping_mode IN ('sequential','global')),
      member_count INTEGER NOT NULL DEFAULT 0 CHECK (member_count >= 0),
      version INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
      incremental_updates INTEGER NOT NULL DEFAULT 0 CHECK (incremental_updates >= 0),
      updated_at TEXT NOT NULL,
      algorithm_version INTEGER NOT NULL DEFAULT 1 CHECK (algorithm_version >= 1),
      input_signature TEXT NOT NULL DEFAULT '',
      state_digest TEXT NOT NULL DEFAULT ''
    );

    -- 27. 身份
    CREATE TABLE persons (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      keywords TEXT NOT NULL DEFAULT '[]',
      thumbnail_base64 TEXT NOT NULL DEFAULT '',
      notes TEXT NOT NULL DEFAULT '',
      match_threshold REAL NOT NULL DEFAULT 0.65 CHECK (match_threshold BETWEEN 0 AND 1),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 28. 身份向量（face_observation_id 刻意无 FK）
    -- person_id / photo_id / session_id 保 CASCADE：向量是派生数据，可从 face_observations
    -- 重建，父行消失后不得残留（audit R2-03 明确保留 CASCADE）。三列都是 NOT NULL，无法
    -- SET NULL；改 RESTRICT 只会无谓阻断批量删除路径。
    CREATE TABLE person_embeddings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
      embedding BLOB NOT NULL,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      face_observation_id INTEGER,
      created_at TEXT NOT NULL
    );

    -- 29. 身份↔照片（用户显式落库的桥接）
    -- photo_id / session_id 用 RESTRICT（两列 NOT NULL，无法 SET NULL）：删照片/会话前必须
    -- 显式解除身份关联（先 DELETE person_photos 或走 removePhoto），否则 FK 报错而不是静默
    -- 删掉「谁出现在哪张照片」的用户数据（audit R2-02 / D-025）。
    -- person_id 保 CASCADE：删除身份是显式动作，且 PersonRepo.delete 在同一事务里已显式删桥接。
    CREATE TABLE person_photos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE RESTRICT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      face_bbox TEXT NOT NULL,
      confidence REAL NOT NULL DEFAULT 0.0,
      created_at TEXT NOT NULL
    );

    -- 30. 元数据镜像读模型（唯一）
    CREATE TABLE photo_metadata_cache (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      photo_id TEXT NOT NULL UNIQUE REFERENCES photos(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      date_taken TEXT,
      camera_make TEXT,
      camera_model TEXT,
      lens_model TEXT,
      focal_length REAL,
      f_number REAL,
      exposure_time TEXT,
      iso INTEGER,
      rating INTEGER CHECK (rating IS NULL OR rating BETWEEN 0 AND 5),
      label TEXT,
      gps_latitude REAL,
      gps_longitude REAL,
      width INTEGER,
      height INTEGER,
      file_size INTEGER,
      file_mtime TEXT,
      keywords TEXT NOT NULL DEFAULT '[]',
      cached_at TEXT NOT NULL,
      updated_at TEXT NOT NULL DEFAULT ''
    );

    -- 31. 重复组
    CREATE TABLE duplicate_groups (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      group_type TEXT NOT NULL CHECK (group_type IN ('exact','visual')),
      checksum TEXT,
      hash_hex TEXT,
      member_count INTEGER NOT NULL DEFAULT 0 CHECK (member_count >= 0),
      resolution TEXT CHECK (resolution IS NULL OR resolution IN ('keep_all','keep_one')),
      created_at TEXT NOT NULL
    );

    -- 32. 重复组成员
    CREATE TABLE duplicate_group_members (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      group_id INTEGER NOT NULL REFERENCES duplicate_groups(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      is_kept INTEGER NOT NULL DEFAULT 1 CHECK (is_kept IN (0,1)),
      file_size INTEGER,
      file_mtime TEXT,
      resolution TEXT CHECK (resolution IS NULL OR resolution IN ('keep_all','keep_one'))
    );

    -- 33. 挑片决策
    -- photo_id / session_id 保 CASCADE：决策以照片/会话为作用域，父行消失后无锚点
    -- （audit §2.4 判定可接受）。「删照片即删评分/挑片」是产品确认项；确认前不改 RESTRICT，
    -- 以免阻断 IndexerService 的生成缓存照片清扫。
    CREATE TABLE culling_decisions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      group_id TEXT NOT NULL,
      decision TEXT NOT NULL DEFAULT 'pending'
        CHECK (decision IN ('keep','reject','pending')),
      rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
      color_label TEXT NOT NULL DEFAULT 'None'
        CHECK (color_label IN ('None','Red','Orange','Yellow','Green','Blue','Pink','Purple')),
      decision_source TEXT NOT NULL DEFAULT 'manual'
        CHECK (decision_source IN ('manual','ai','template','imported')),
      revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
      created_at TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL,
      UNIQUE (session_id, photo_id)
    );

    -- 34. 挑片历史
    -- session_id 保 CASCADE：历史是会话审计，随会话消失；但它是用户工作成果，删会话的
    -- UI 必须提示（audit §2.3 路径 4）。
    CREATE TABLE culling_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      operation_json TEXT NOT NULL DEFAULT '[]',
      undone INTEGER NOT NULL DEFAULT 0 CHECK (undone IN (0,1)),
      created_at TEXT NOT NULL
    );

    -- 35. 导航分组
    -- session_id 保 CASCADE：分组是会话内派生 + 手动混合结果，随会话消失。
    -- lead_photo_id 保 SET NULL：lead 照片消失只置空，不删整组（组内其它照片仍有意义）。
    CREATE TABLE navigation_groups (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      group_type TEXT NOT NULL CHECK (group_type IN ('burst','scene')),
      photo_ids_json TEXT NOT NULL DEFAULT '[]',
      lead_photo_id TEXT REFERENCES photos(id) ON DELETE SET NULL,
      explanation TEXT NOT NULL DEFAULT '',
      input_fingerprint TEXT NOT NULL DEFAULT '',
      source TEXT NOT NULL DEFAULT 'automatic' CHECK (source IN ('automatic','manual')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 36. 关键词来源归属
    CREATE TABLE metadata_keyword_origins (
      xmp_path TEXT NOT NULL,
      source TEXT NOT NULL
        CHECK (source IN ('face-keyword','culling','similarity','template')),
      keyword TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (xmp_path, source, keyword)
    );

    -- 37. 设置
    CREATE TABLE app_settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    -- 38. 智能相册（D-008 保留）
    CREATE TABLE smart_albums (
      id TEXT PRIMARY KEY,
      filter_schema_version INTEGER NOT NULL DEFAULT 1 CHECK (filter_schema_version >= 1),
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      filter_criteria TEXT NOT NULL,
      sort_by TEXT NOT NULL DEFAULT 'date_taken',
      sort_order TEXT NOT NULL DEFAULT 'desc' CHECK (sort_order IN ('asc','desc')),
      icon TEXT NOT NULL DEFAULT '📁',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 39. 工作流模板（D-008 保留）
    CREATE TABLE workflow_templates (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      config TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 40. 交付聚合（XMP 侧车为单位的单一状态机）
    CREATE TABLE deliveries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      xmp_path TEXT NOT NULL UNIQUE,
      photo_path TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','writing','written','synced','failed','conflict','cleaned')),
      revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
      base_fingerprint TEXT NOT NULL DEFAULT '',
      base_values_json TEXT NOT NULL DEFAULT '{}',
      backup_path TEXT NOT NULL DEFAULT '',
      error_message TEXT NOT NULL DEFAULT '',
      attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
      lease_owner TEXT NOT NULL DEFAULT '',
      heartbeat_at TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- 41. 交付↔会话确认
    CREATE TABLE delivery_sessions (
      delivery_id INTEGER NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      confirmed_at TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      PRIMARY KEY (delivery_id, session_id)
    );

    -- 42. 交付项（逐照片 × 模块）
    CREATE TABLE delivery_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      delivery_id INTEGER NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      module TEXT NOT NULL
        CHECK (module IN ('culling','face-keyword','similarity','template','metadata')),
      attributes_json TEXT NOT NULL DEFAULT '{}',
      keywords TEXT NOT NULL DEFAULT '[]',
      status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','written','synced','failed')),
      error_message TEXT NOT NULL DEFAULT '',
      attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (delivery_id, photo_id, module)
    );

    -- 43. 交付意图日志（xmp_path 刻意无 FK：父行删除后仍需存活以便回放）
    CREATE TABLE delivery_intents (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL CHECK (kind IN ('cleanup','write')),
      xmp_path TEXT NOT NULL,
      phase TEXT NOT NULL DEFAULT 'prepared'
        CHECK (phase IN ('prepared','fileDone','applied')),
      payload_json TEXT NOT NULL DEFAULT '{}',
      error_message TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    -- ─────────────────────────────── 索引 ───────────────────────────────
    -- photos
    CREATE UNIQUE INDEX idx_photos_session_filepath ON photos(session_id, filepath);
    CREATE INDEX idx_photos_filepath ON photos(filepath);
    CREATE INDEX idx_photos_created_at ON photos(created_at);
    CREATE INDEX idx_photos_asset ON photos(asset_id);
    CREATE INDEX idx_photos_asset_file ON photos(asset_file_id);
    CREATE INDEX idx_photos_asset_group ON photos(session_id, COALESCE(NULLIF(asset_id, ''), id));

    -- asset_files / assets / 关系表
    CREATE UNIQUE INDEX idx_asset_files_volume_path ON asset_files(volume_id, normalized_path);
    CREATE UNIQUE INDEX idx_asset_files_volume_identity
      ON asset_files(volume_id, file_identity) WHERE file_identity != '';
    CREATE INDEX idx_asset_files_checksum ON asset_files(checksum);
    CREATE INDEX idx_asset_files_volume_status ON asset_files(volume_id, online_status);
    CREATE INDEX idx_asset_candidates_relation_status ON asset_link_candidates(relation_type, status);
    CREATE INDEX idx_asset_candidates_left ON asset_link_candidates(left_file_id);
    CREATE INDEX idx_asset_candidates_right ON asset_link_candidates(right_file_id);
    CREATE INDEX idx_session_assets_asset ON session_assets(asset_id);
    CREATE INDEX idx_sidecar_binding_files_file ON sidecar_binding_files(file_id);

    -- analysis
    CREATE INDEX idx_analysis_jobs_status_priority ON analysis_jobs(status, priority, updated_at);
    CREATE INDEX idx_analysis_jobs_scope ON analysis_jobs(scope_type, scope_id);
    CREATE INDEX idx_analysis_runs_session_kind ON analysis_runs(session_id, kind, status, id DESC);
    CREATE UNIQUE INDEX idx_analysis_jobs_active_dedupe
      ON analysis_jobs(dedupe_key)
      WHERE status IN ('queued', 'running', 'cancelling');
    CREATE INDEX idx_asset_analysis_photo_type ON asset_analysis(photo_id, analysis_type);
    CREATE INDEX idx_asset_analysis_file_type ON asset_analysis(asset_file_id, analysis_type);

    -- face
    CREATE INDEX idx_face_observations_session ON face_observations(session_id);
    CREATE INDEX idx_face_observations_photo ON face_observations(photo_id);
    CREATE INDEX idx_face_analysis_state_session ON face_analysis_state(session_id);
    CREATE INDEX idx_face_identity_feedback_session ON face_identity_feedback(session_id, photo_id);
    CREATE INDEX idx_face_identity_feedback_photo ON face_identity_feedback(photo_id);
    CREATE INDEX idx_face_identity_feedback_person ON face_identity_feedback(person_id);
    CREATE INDEX idx_face_clusters_session ON face_clusters(session_id);
    CREATE INDEX idx_face_clusters_matched_person ON face_clusters(matched_person_id);
    CREATE INDEX idx_face_cluster_members_cluster ON face_cluster_members(cluster_id);
    CREATE INDEX idx_face_cluster_members_session ON face_cluster_members(session_id);
    CREATE INDEX idx_face_cluster_members_photo ON face_cluster_members(photo_id);
    CREATE INDEX idx_face_cluster_members_observation ON face_cluster_members(observation_id);
    CREATE INDEX idx_role_bindings_session ON role_bindings(session_id);

    -- similarity
    CREATE INDEX idx_similarity_hashes_photo ON similarity_hashes(photo_id);
    CREATE UNIQUE INDEX idx_similarity_hashes_session_photo ON similarity_hashes(session_id, photo_id);
    CREATE INDEX idx_similarity_results_session ON similarity_results(session_id);
    CREATE INDEX idx_similarity_members_session_photo ON similarity_result_members(session_id, photo_id);
    CREATE INDEX idx_similarity_members_result_group ON similarity_result_members(result_id, group_index);
    CREATE INDEX idx_similarity_members_photo ON similarity_result_members(photo_id);

    -- persons
    CREATE INDEX idx_persons_name ON persons(name);
    CREATE INDEX idx_person_embeddings_person ON person_embeddings(person_id);
    CREATE UNIQUE INDEX idx_person_embeddings_obs ON person_embeddings(face_observation_id);
    CREATE INDEX idx_person_embeddings_photo ON person_embeddings(photo_id);
    CREATE INDEX idx_person_embeddings_session ON person_embeddings(session_id);
    CREATE INDEX idx_person_photos_photo ON person_photos(photo_id);
    CREATE INDEX idx_person_photos_session ON person_photos(session_id);
    CREATE UNIQUE INDEX idx_person_photos_person_photo ON person_photos(person_id, photo_id);

    -- metadata cache
    CREATE INDEX idx_metadata_cache_session ON photo_metadata_cache(session_id);
    CREATE INDEX idx_metadata_cache_session_date ON photo_metadata_cache(session_id, date_taken);
    CREATE INDEX idx_metadata_cache_session_rating ON photo_metadata_cache(session_id, rating);
    CREATE INDEX idx_metadata_cache_session_label ON photo_metadata_cache(session_id, label);
    CREATE INDEX idx_metadata_cache_camera_make ON photo_metadata_cache(camera_make);

    -- duplicates / culling / navigation
    CREATE INDEX idx_duplicate_groups_session ON duplicate_groups(session_id);
    CREATE INDEX idx_duplicate_members_group ON duplicate_group_members(group_id);
    CREATE INDEX idx_duplicate_members_photo ON duplicate_group_members(photo_id);
    CREATE INDEX idx_duplicate_members_session ON duplicate_group_members(session_id);
    CREATE UNIQUE INDEX idx_culling_session_photo_unique ON culling_decisions(session_id, photo_id);
    CREATE INDEX idx_culling_group ON culling_decisions(session_id, group_id);
    CREATE INDEX idx_culling_decisions_photo ON culling_decisions(photo_id);
    CREATE INDEX idx_culling_history_session ON culling_history(session_id, id);
    CREATE INDEX idx_navigation_groups_session_type ON navigation_groups(session_id, group_type, updated_at);
    CREATE INDEX idx_navigation_groups_lead ON navigation_groups(lead_photo_id);
    CREATE INDEX idx_metadata_keyword_origins_source_active
      ON metadata_keyword_origins(source, active, updated_at);

    -- delivery
    CREATE INDEX idx_deliveries_status ON deliveries(status, updated_at);
    CREATE INDEX idx_delivery_sessions_session ON delivery_sessions(session_id, delivery_id);
    CREATE INDEX idx_delivery_items_photo ON delivery_items(photo_id);
    CREATE INDEX idx_delivery_items_module_status ON delivery_items(module, status);
    CREATE INDEX idx_delivery_intents_phase ON delivery_intents(phase, id);

    """

    /// V1 建库 SQL：DDL + 版本号 1（历史基线）。
    ///
    /// WP6b 起当前版本是 V2（DDL 与 V1 逐字相同，见 Migration/SchemaV2.swift）；
    /// 本常量仍保留 V1 语义，供测试夹具/`gather-schema dump` 复现真实旧库，
    /// 也是 V1→V2 迁移的唯一入口形态。新库由 SchemaCatalog.currentSnapshot 建。
    public static let createSQL: String = ddl + "\nPRAGMA user_version = 1;\n"

    /// Cut 2 起的兼容别名（语义 = createSQL；现有测试与工具继续可用）。
    public static let sql: String = createSQL
}
