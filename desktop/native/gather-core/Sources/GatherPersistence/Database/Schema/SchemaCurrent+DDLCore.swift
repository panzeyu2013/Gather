// desktop/native/gather-core/Sources/GatherPersistence/Database/Schema/SchemaCurrent+DDLCore.swift
// SchemaCurrent DDL 片段 1/3：文件头 + 表 1–24（会话/资产/照片/分析任务/侧车/人脸/相似度快照）。
//
// final-cleanup 纯拆分：本片段与拆分前 SchemaCurrent.ddl 的对应区间逐字节相同；三段按
// ddlCore → ddlDomain → ddlIndexes 拼接（见 SchemaCurrent.swift），不得重排或改字。
// 修改 DDL 必须同步 SchemaCurrent.expectedShapeFingerprint（4e47485e…）。
extension SchemaCurrent {
    /// DDL 片段 1/3（internal：仅供 SchemaCurrent.ddl 拼接，不是公开 API）。
    static let ddlCore: String = """
    -- SchemaCurrent · Gather 本地库最终形态（44 表 / 384 列 / 72 索引 / 65 外键）
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
    """
}
