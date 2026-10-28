// desktop/native/gather-core/Sources/GatherPersistence/Database/Schema/SchemaCurrent+DDLDomain.swift
// SchemaCurrent DDL 片段 2/3：表 25–43（相似度状态/身份/元数据/重复/挑片/导航/设置/交付）。
//
// 字面量以空行开头：该空行即原 DDL 中表 24 与表 25 之间的空行，前面的拼接换行
// 是表 24 末行的换行；删掉首行空行或改动顺序都会改变 DDL 字节。
extension SchemaCurrent {
    /// DDL 片段 2/3（internal：仅供 SchemaCurrent.ddl 拼接，不是公开 API）。
    static let ddlDomain: String = """

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
      iptc_json TEXT NOT NULL DEFAULT '{}',
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

    -- 40. 交付聚合（**写目标**为单位的单一状态机）
    -- xmp_path 是写目标路径：sidecar 模式 = <photo>.xmp；embedded 模式 = 照片自身。
    -- target_kind 只是**记录**：写目标类型（sidecar/embedded）落库供审计与排障。
    -- 读写路径都不读它——恢复按备份名标记分派（MetadataWriteRouter）、删除按 .xmp 后缀
    -- 守卫（DeliveryFilePhase）。加读侧之前不要把它写成语义真相。
    CREATE TABLE deliveries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      xmp_path TEXT NOT NULL UNIQUE,
      target_kind TEXT NOT NULL DEFAULT 'sidecar'
        CHECK (target_kind IN ('sidecar','embedded')),
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
    """
}
