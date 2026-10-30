// desktop/native/gather-core/Sources/GatherPersistence/Database/Schema/SchemaCurrent+DDLWorkbench.swift
// P1 下一波：策展/反馈/关键词/语义的 11 张新表。
//
// 版本策略：仍为 user_version=1（开发期）；本片段直接追加到建库 DDL，旧库由形状
// 校验判不兼容、按既有 ResetPolicy 归档重建。表组文本单独成文件，避免改动既有
// 表组（索引 SQL 参与列形指纹，改一个字都会让指纹漂移）。

public extension SchemaCurrent {
    static let workbenchDDL: String = """
    -- 44. 保存查询（Gallery/Library 共用；session_id NULL = 全局）
    CREATE TABLE saved_searches (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
      criteria_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (session_id, name)
    );
    CREATE INDEX idx_saved_searches_session ON saved_searches(session_id, updated_at);

    -- 45. 手动集合
    CREATE TABLE collections (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE (session_id, name)
    );
    CREATE INDEX idx_collections_session_order ON collections(session_id, sort_order);

    -- 46. 集合成员（position 步长 1024，拖拽只写一行）
    CREATE TABLE collection_items (
      collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      position INTEGER NOT NULL,
      added_at TEXT NOT NULL,
      PRIMARY KEY (collection_id, photo_id)
    );
    CREATE INDEX idx_collection_items_order ON collection_items(collection_id, position);
    CREATE INDEX idx_collection_items_photo ON collection_items(photo_id);

    -- 47. 堆栈（只影响展示，不影响评分/决策）
    CREATE TABLE photo_stacks (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      name TEXT NOT NULL DEFAULT '',
      cover_photo_id TEXT REFERENCES photos(id) ON DELETE SET NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE INDEX idx_photo_stacks_session ON photo_stacks(session_id, updated_at);
    -- A5：cover_photo_id 是 ON DELETE SET NULL 子键；没有本索引时删一张照片要为每个
    -- 父行全表扫 photo_stacks 去找引用行（封面引用极少，选择性很高）。
    -- 索引放这里而不是 ddlIndexes：拼接序是 ddlIndexes → addendum → workbenchDDL，
    -- 在 ddlIndexes 里引用本表会直接报 "no such table"。
    CREATE INDEX idx_photo_stacks_cover ON photo_stacks(cover_photo_id);

    -- 48. 堆栈成员
    CREATE TABLE photo_stack_members (
      stack_id TEXT NOT NULL REFERENCES photo_stacks(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      position INTEGER NOT NULL,
      PRIMARY KEY (stack_id, photo_id)
    );
    CREATE INDEX idx_photo_stack_members_photo ON photo_stack_members(photo_id);

    -- 49. 关键词库（path 即层级："A|B|C"）
    CREATE TABLE keywords (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      parent_path TEXT,
      usage_count INTEGER NOT NULL DEFAULT 0 CHECK (usage_count >= 0),
      created_at TEXT NOT NULL
    );
    CREATE INDEX idx_keywords_parent ON keywords(parent_path, path);

    -- 50. 同义词（只用于检索展开，不写 XMP）
    CREATE TABLE keyword_synonyms (
      keyword_path TEXT NOT NULL REFERENCES keywords(path) ON DELETE CASCADE,
      synonym TEXT NOT NULL,
      PRIMARY KEY (keyword_path, synonym)
    );

    -- 51. 照片×关键词（facet 用；按逻辑资产去重计数）
    CREATE TABLE photo_keywords (
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      keyword_path TEXT NOT NULL,
      source TEXT NOT NULL DEFAULT 'xmp'
        CHECK (source IN ('xmp','culling','face-keyword','similarity','manual')),
      updated_at TEXT NOT NULL,
      PRIMARY KEY (photo_id, keyword_path)
    );
    CREATE INDEX idx_photo_keywords_path ON photo_keywords(keyword_path, photo_id);

    -- 52. 客户校样反馈（原始、可审计、可重放）
    CREATE TABLE client_proof_feedback (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      batch_id TEXT NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      pick_state TEXT NOT NULL DEFAULT 'unreviewed'
        CHECK (pick_state IN ('unreviewed','picked','rejected')),
      rating INTEGER CHECK (rating IS NULL OR rating BETWEEN 0 AND 5),
      label TEXT NOT NULL DEFAULT '',
      comment TEXT NOT NULL DEFAULT '',
      submitted_at TEXT NOT NULL DEFAULT '',
      imported_at TEXT NOT NULL,
      applied_at TEXT NOT NULL DEFAULT '',
      -- P1-5：字段级应用时间。勾选走 culling 决策、评分/色标走元数据写回，
      -- 两个动作可能一个成功一个失败；只记 applied_at 会让重放分不清该重做哪个。
      pick_applied_at TEXT NOT NULL DEFAULT '',
      rating_applied_at TEXT NOT NULL DEFAULT '',
      UNIQUE (batch_id, photo_id)
    );
    CREATE INDEX idx_client_proof_session ON client_proof_feedback(session_id, imported_at);
    -- A5：photo_id 是 ON DELETE CASCADE 子键（删照片/会话校样记录跟着走），
    -- 没有子键索引时删除要逐父行全扫本表。
    CREATE INDEX idx_client_proof_photo ON client_proof_feedback(photo_id);

    -- 53. 用户对 triage 建议的实际动作（校准样本）
    CREATE TABLE triage_feedback (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      suggestion_verdict TEXT NOT NULL
        CHECK (suggestion_verdict IN ('keep','reject','review')),
      suggestion_confidence REAL NOT NULL,
      user_action TEXT NOT NULL
        CHECK (user_action IN ('keep','reject','review','cleared')),
      policy_version TEXT NOT NULL,
      acted_at TEXT NOT NULL
    );
    CREATE INDEX idx_triage_feedback_session ON triage_feedback(session_id, acted_at);
    CREATE INDEX idx_triage_feedback_photo ON triage_feedback(photo_id, acted_at);

    -- 54. 图像语义（Vision 标签 + feature print；默认不建）
    CREATE TABLE photo_semantics (
      photo_id TEXT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      labels_json TEXT NOT NULL DEFAULT '[]',
      feature BLOB,
      feature_dim INTEGER NOT NULL DEFAULT 0,
      model_version TEXT NOT NULL DEFAULT '',
      computed_at TEXT NOT NULL
    );
    CREATE INDEX idx_photo_semantics_session ON photo_semantics(session_id, computed_at);

    -- A7：keywords.usage_count 是派生值（该路径自身的 photo_keywords 行数）。
    -- 仓储在 replace/delete/merge 三路会重算，但"删照片/删会话"走 DB CASCADE，
    -- 不经过仓储 → 权重只增不减，prefixMatches 的 ORDER BY usage_count 随之失真。
    -- 触发器按行递减（O(1)，不逐行 COUNT）：计数口径本身由重算路径保证，
    -- 这里只需要把 CASCADE 造成的减量同步过去。
    CREATE TRIGGER trg_photo_keywords_usage_after_delete
    AFTER DELETE ON photo_keywords
    BEGIN
      UPDATE keywords
         SET usage_count = CASE WHEN usage_count > 0 THEN usage_count - 1 ELSE 0 END
       WHERE path = OLD.keyword_path;
    END;
    """
}
