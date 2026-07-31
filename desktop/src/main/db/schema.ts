export const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft',
  analysis_status TEXT NOT NULL DEFAULT 'idle',
  writeback_status TEXT NOT NULL DEFAULT 'idle',
  import_source TEXT NOT NULL DEFAULT 'unknown',
  source_path TEXT NOT NULL DEFAULT '',
  photo_count INTEGER NOT NULL DEFAULT 0,
  failed_writeback_count INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS photos (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  filepath TEXT NOT NULL,
  filename TEXT NOT NULL DEFAULT '',
  checksum TEXT NOT NULL DEFAULT '',
  checksum_file_size INTEGER NOT NULL DEFAULT 0,
  checksum_file_mtime_ms REAL NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending',
  metadata TEXT NOT NULL DEFAULT '{}',
  result TEXT NOT NULL DEFAULT '{}',
  asset_id TEXT REFERENCES assets(id),
  asset_file_id TEXT REFERENCES asset_files(id),
  width INTEGER NOT NULL DEFAULT 0,
  height INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS assets (
  id TEXT PRIMARY KEY,
  capture_fingerprint TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS asset_files (
  id TEXT PRIMARY KEY,
  volume_id TEXT NOT NULL DEFAULT '',
  file_identity TEXT NOT NULL DEFAULT '',
  normalized_path TEXT NOT NULL,
  filename TEXT NOT NULL,
  extension TEXT NOT NULL DEFAULT '',
  media_type TEXT NOT NULL DEFAULT 'unknown',
  file_size INTEGER NOT NULL DEFAULT 0,
  file_mtime_ms REAL NOT NULL DEFAULT 0,
  checksum TEXT NOT NULL DEFAULT '',
  online_status TEXT NOT NULL DEFAULT 'online',
  last_seen_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS asset_members (
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
  member_role TEXT NOT NULL,
  is_primary INTEGER NOT NULL DEFAULT 0,
  confidence REAL NOT NULL DEFAULT 1.0,
  binding_source TEXT NOT NULL DEFAULT 'import',
  PRIMARY KEY (asset_id, file_id),
  UNIQUE (file_id)
);

CREATE TABLE IF NOT EXISTS asset_link_candidates (
  id TEXT PRIMARY KEY,
  left_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
  right_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
  relation_type TEXT NOT NULL,
  confidence REAL NOT NULL,
  evidence_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS session_assets (
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  display_file_id TEXT REFERENCES asset_files(id),
  import_order INTEGER NOT NULL DEFAULT 0,
  added_at TEXT NOT NULL,
  PRIMARY KEY (session_id, asset_id)
);

CREATE TABLE IF NOT EXISTS sidecar_bindings (
  id TEXT PRIMARY KEY,
  xmp_path TEXT NOT NULL,
  normalized_xmp_path TEXT NOT NULL UNIQUE,
  binding_rule TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sidecar_binding_files (
  sidecar_binding_id TEXT NOT NULL REFERENCES sidecar_bindings(id) ON DELETE CASCADE,
  file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
  PRIMARY KEY (sidecar_binding_id, file_id)
);

CREATE TABLE IF NOT EXISTS asset_file_metadata (
  file_id TEXT PRIMARY KEY REFERENCES asset_files(id) ON DELETE CASCADE,
  date_taken TEXT,
  camera_make TEXT,
  camera_model TEXT,
  lens_model TEXT,
  focal_length REAL,
  f_number REAL,
  exposure_time TEXT,
  iso INTEGER,
  gps_latitude REAL,
  gps_longitude REAL,
  width INTEGER,
  height INTEGER,
  cached_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sidecar_metadata_state (
  sidecar_binding_id TEXT PRIMARY KEY REFERENCES sidecar_bindings(id) ON DELETE CASCADE,
  rating INTEGER CHECK (rating BETWEEN 0 AND 5),
  label TEXT,
  keywords TEXT NOT NULL DEFAULT '[]',
  fingerprint TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS asset_backfill_state (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  last_photo_rowid INTEGER NOT NULL DEFAULT 0,
  total_photos INTEGER NOT NULL DEFAULT 0,
  migrated_photos INTEGER NOT NULL DEFAULT 0,
  offline_files INTEGER NOT NULL DEFAULT 0,
  path_conflicts INTEGER NOT NULL DEFAULT 0,
  sidecar_conflicts INTEGER NOT NULL DEFAULT 0,
  candidate_links INTEGER NOT NULL DEFAULT 0,
  automatic_merges INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'running',
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS analysis_jobs (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  scope_type TEXT NOT NULL,
  scope_id TEXT NOT NULL,
  dedupe_key TEXT NOT NULL,
  status TEXT NOT NULL,
  priority INTEGER NOT NULL DEFAULT 0,
  progress_current INTEGER NOT NULL DEFAULT 0,
  progress_total INTEGER NOT NULL DEFAULT 0,
  progress_message TEXT NOT NULL DEFAULT '',
  input_fingerprint TEXT NOT NULL DEFAULT '',
  model_id TEXT NOT NULL DEFAULT '',
  model_version TEXT NOT NULL DEFAULT '',
  checkpoint_json TEXT NOT NULL DEFAULT '{}',
  attempt_count INTEGER NOT NULL DEFAULT 0,
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

CREATE TABLE IF NOT EXISTS asset_analysis (
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
  UNIQUE(asset_file_id, analysis_type, model_id, model_version, input_fingerprint)
);

CREATE TABLE IF NOT EXISTS face_observations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  photo_id TEXT NOT NULL REFERENCES photos(id),
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  bbox_x REAL NOT NULL,
  bbox_y REAL NOT NULL,
  bbox_w REAL NOT NULL,
  bbox_h REAL NOT NULL,
  embedding BLOB NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.0,
  source_file_size INTEGER NOT NULL DEFAULT 0,
  source_file_mtime_ms REAL NOT NULL DEFAULT 0,
  analysis_signature TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS face_analysis_state (
  photo_id TEXT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  source_file_size INTEGER NOT NULL,
  source_file_mtime_ms REAL NOT NULL,
  analysis_signature TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS face_cluster_state (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  cluster_signature TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS face_clusters (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  label TEXT NOT NULL DEFAULT '',
  member_count INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'unbound',
  thumbnail_base64 TEXT NOT NULL DEFAULT '',
  thumbnail_path TEXT NOT NULL DEFAULT '',
  matched_person_id TEXT REFERENCES persons(id),
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS face_cluster_members (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cluster_id INTEGER NOT NULL REFERENCES face_clusters(id),
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id),
  bbox TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.0,
  observation_id INTEGER REFERENCES face_observations(id)
);

CREATE TABLE IF NOT EXISTS role_bindings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cluster_id INTEGER NOT NULL UNIQUE REFERENCES face_clusters(id),
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  role_name TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS similarity_hashes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id),
  hash_hex TEXT NOT NULL,
  file_size INTEGER NOT NULL DEFAULT 0,
  file_mtime_ms REAL NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS similarity_results (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  groups_json TEXT NOT NULL,
  stats_json TEXT NOT NULL DEFAULT '{}',
  param_threshold INTEGER NOT NULL,
  param_min_group_size INTEGER NOT NULL DEFAULT 2,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS similarity_result_members (
  result_id INTEGER NOT NULL REFERENCES similarity_results(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  group_index INTEGER NOT NULL,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  PRIMARY KEY (result_id, photo_id)
);

CREATE TABLE IF NOT EXISTS writeback_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  photo_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  module TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]',
  attributes_json TEXT NOT NULL DEFAULT '{}',
  photo_path TEXT NOT NULL DEFAULT '',
  xmp_path TEXT NOT NULL DEFAULT '',
  backup_path TEXT NOT NULL DEFAULT '',
  xmp_status TEXT NOT NULL DEFAULT 'pending',
  error_message TEXT NOT NULL DEFAULT '',
  attempt_count INTEGER NOT NULL DEFAULT 1,
  last_attempt_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT '',
  FOREIGN KEY (photo_id) REFERENCES photos(id) ON DELETE CASCADE,
  FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS app_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS persons (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]',
  thumbnail_base64 TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  match_threshold REAL NOT NULL DEFAULT 0.65,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS person_embeddings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  embedding BLOB NOT NULL,
  photo_id TEXT NOT NULL REFERENCES photos(id),
  session_id TEXT NOT NULL REFERENCES sessions(id),
  face_observation_id INTEGER,
  face_bbox TEXT NOT NULL,
  quality REAL NOT NULL DEFAULT 0.0,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS person_photos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id),
  session_id TEXT NOT NULL REFERENCES sessions(id),
  face_bbox TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.0,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS photo_metadata_cache (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  photo_id TEXT NOT NULL UNIQUE REFERENCES photos(id),
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  date_taken TEXT,
  camera_make TEXT,
  camera_model TEXT,
  lens_model TEXT,
  focal_length REAL,
  f_number REAL,
  exposure_time TEXT,
  iso INTEGER,
  rating INTEGER DEFAULT 0,
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

CREATE TABLE IF NOT EXISTS duplicate_groups (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  group_type TEXT NOT NULL,
  checksum TEXT,
  hash_hex TEXT,
  member_count INTEGER NOT NULL DEFAULT 0,
  resolution TEXT DEFAULT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS duplicate_group_members (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id INTEGER NOT NULL REFERENCES duplicate_groups(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  is_kept INTEGER NOT NULL DEFAULT 1,
  file_size INTEGER,
  file_mtime TEXT,
  resolution TEXT DEFAULT NULL
);

CREATE TABLE IF NOT EXISTS smart_albums (
  id TEXT PRIMARY KEY,
  schema_version INTEGER NOT NULL DEFAULT 1,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  filter_criteria TEXT NOT NULL,
  sort_by TEXT NOT NULL DEFAULT 'date_taken',
  sort_order TEXT NOT NULL DEFAULT 'desc',
  icon TEXT NOT NULL DEFAULT '📁',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS workflow_templates (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  config TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS culling_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  group_id TEXT NOT NULL,
  decision TEXT NOT NULL DEFAULT 'pending',
  rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
  color_label TEXT NOT NULL DEFAULT 'None' CHECK (
    color_label IN ('None', 'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Pink', 'Purple')
  ),
  decision_source TEXT NOT NULL DEFAULT 'manual',
  revision INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL,
  UNIQUE(session_id, photo_id)
);

CREATE TABLE IF NOT EXISTS culling_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  operation_json TEXT NOT NULL DEFAULT '[]',
  undone INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS navigation_groups (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  group_type TEXT NOT NULL CHECK (group_type IN ('burst', 'scene')),
  photo_ids_json TEXT NOT NULL DEFAULT '[]',
  lead_photo_id TEXT REFERENCES photos(id) ON DELETE SET NULL,
  explanation TEXT NOT NULL DEFAULT '',
  input_fingerprint TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT 'automatic',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS metadata_outbox (
  xmp_path TEXT PRIMARY KEY,
  owner_session_id TEXT,
  created_by_session_id TEXT,
  photo_path TEXT NOT NULL,
  patch_json TEXT NOT NULL DEFAULT '{}',
  dirty_fields TEXT NOT NULL DEFAULT '[]',
  revision INTEGER NOT NULL DEFAULT 0,
  persisted_revision INTEGER NOT NULL DEFAULT 0,
  base_fingerprint TEXT NOT NULL DEFAULT '',
  base_values_json TEXT NOT NULL DEFAULT '{}',
  backup_path TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN ('clean', 'pending', 'writing', 'written', 'failed', 'conflict', 'synced', 'cleaned')
  ),
  attempt_count INTEGER NOT NULL DEFAULT 0,
  error_message TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS metadata_outbox_sessions (
  xmp_path TEXT NOT NULL REFERENCES metadata_outbox(xmp_path) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  confirmed_at TEXT NOT NULL DEFAULT '',
  linked_at TEXT NOT NULL,
  PRIMARY KEY (xmp_path, session_id)
);

CREATE TABLE IF NOT EXISTS metadata_keyword_origins (
  xmp_path TEXT NOT NULL,
  source TEXT NOT NULL,
  keyword TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (xmp_path, source, keyword)
);

CREATE TABLE IF NOT EXISTS schema_version (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);
`

export const INDEX_SQL = `
CREATE INDEX IF NOT EXISTS idx_photos_session ON photos(session_id);
CREATE INDEX IF NOT EXISTS idx_photos_filepath ON photos(filepath);
CREATE INDEX IF NOT EXISTS idx_photos_created_at ON photos(created_at);
CREATE INDEX IF NOT EXISTS idx_photos_asset ON photos(asset_id);
CREATE INDEX IF NOT EXISTS idx_photos_asset_file ON photos(asset_file_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_asset_files_volume_path ON asset_files(volume_id, normalized_path);
CREATE UNIQUE INDEX IF NOT EXISTS idx_asset_files_volume_identity
  ON asset_files(volume_id, file_identity) WHERE file_identity != '';
CREATE INDEX IF NOT EXISTS idx_asset_files_checksum ON asset_files(checksum);
CREATE INDEX IF NOT EXISTS idx_asset_files_volume_status ON asset_files(volume_id, online_status);
CREATE INDEX IF NOT EXISTS idx_asset_members_asset ON asset_members(asset_id);
CREATE INDEX IF NOT EXISTS idx_asset_candidates_status ON asset_link_candidates(status);
CREATE INDEX IF NOT EXISTS idx_session_assets_asset ON session_assets(asset_id);
CREATE INDEX IF NOT EXISTS idx_sidecar_binding_files_file ON sidecar_binding_files(file_id);
CREATE INDEX IF NOT EXISTS idx_asset_backfill_status ON asset_backfill_state(status, updated_at);
CREATE INDEX IF NOT EXISTS idx_analysis_jobs_status_priority ON analysis_jobs(status, priority, updated_at);
CREATE INDEX IF NOT EXISTS idx_analysis_jobs_scope ON analysis_jobs(scope_type, scope_id);
CREATE INDEX IF NOT EXISTS idx_asset_analysis_photo_type ON asset_analysis(photo_id, analysis_type);
CREATE INDEX IF NOT EXISTS idx_asset_analysis_file_type ON asset_analysis(asset_file_id, analysis_type);
CREATE UNIQUE INDEX IF NOT EXISTS idx_analysis_jobs_active_dedupe
  ON analysis_jobs(dedupe_key)
  WHERE status IN ('queued', 'running', 'cancelling');
CREATE INDEX IF NOT EXISTS idx_face_observations_session ON face_observations(session_id);
CREATE INDEX IF NOT EXISTS idx_face_observations_photo ON face_observations(photo_id);
CREATE INDEX IF NOT EXISTS idx_face_analysis_state_session ON face_analysis_state(session_id);
CREATE INDEX IF NOT EXISTS idx_face_clusters_session ON face_clusters(session_id);
CREATE INDEX IF NOT EXISTS idx_face_cluster_members_cluster ON face_cluster_members(cluster_id);
CREATE INDEX IF NOT EXISTS idx_face_cluster_members_session ON face_cluster_members(session_id);
CREATE INDEX IF NOT EXISTS idx_similarity_hashes_session ON similarity_hashes(session_id);
CREATE INDEX IF NOT EXISTS idx_similarity_hashes_photo ON similarity_hashes(photo_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_similarity_hashes_session_photo ON similarity_hashes(session_id, photo_id);
CREATE INDEX IF NOT EXISTS idx_similarity_results_session ON similarity_results(session_id);
CREATE INDEX IF NOT EXISTS idx_similarity_members_session_photo ON similarity_result_members(session_id, photo_id);
CREATE INDEX IF NOT EXISTS idx_similarity_members_result_group ON similarity_result_members(result_id, group_index);
CREATE INDEX IF NOT EXISTS idx_writeback_items_session ON writeback_items(session_id);
CREATE INDEX IF NOT EXISTS idx_writeback_items_photo ON writeback_items(photo_id);
CREATE INDEX IF NOT EXISTS idx_persons_name ON persons(name);
CREATE INDEX IF NOT EXISTS idx_person_embeddings_person ON person_embeddings(person_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_person_embeddings_obs ON person_embeddings(face_observation_id);
CREATE INDEX IF NOT EXISTS idx_person_photos_person ON person_photos(person_id);
CREATE INDEX IF NOT EXISTS idx_person_photos_photo ON person_photos(photo_id);
CREATE INDEX IF NOT EXISTS idx_person_photos_session ON person_photos(session_id);
CREATE INDEX IF NOT EXISTS idx_metadata_cache_session ON photo_metadata_cache(session_id);
CREATE INDEX IF NOT EXISTS idx_metadata_cache_session_date ON photo_metadata_cache(session_id, date_taken);
CREATE INDEX IF NOT EXISTS idx_metadata_cache_session_rating ON photo_metadata_cache(session_id, rating);
CREATE INDEX IF NOT EXISTS idx_metadata_cache_session_label ON photo_metadata_cache(session_id, label);
CREATE INDEX IF NOT EXISTS idx_metadata_cache_camera_make ON photo_metadata_cache(camera_make);
CREATE INDEX IF NOT EXISTS idx_duplicate_groups_session ON duplicate_groups(session_id);
CREATE INDEX IF NOT EXISTS idx_duplicate_members_group ON duplicate_group_members(group_id);
CREATE INDEX IF NOT EXISTS idx_duplicate_members_photo ON duplicate_group_members(photo_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_culling_session_photo_unique ON culling_decisions(session_id, photo_id);
CREATE INDEX IF NOT EXISTS idx_culling_group ON culling_decisions(session_id, group_id);
CREATE INDEX IF NOT EXISTS idx_culling_history_session ON culling_history(session_id, id);
CREATE INDEX IF NOT EXISTS idx_navigation_groups_session_type
  ON navigation_groups(session_id, group_type, updated_at);
CREATE INDEX IF NOT EXISTS idx_metadata_outbox_session_status ON metadata_outbox(owner_session_id, status);
CREATE INDEX IF NOT EXISTS idx_metadata_outbox_sessions_session
  ON metadata_outbox_sessions(session_id, xmp_path);
CREATE INDEX IF NOT EXISTS idx_metadata_keyword_origins_source_active
  ON metadata_keyword_origins(source, active, updated_at);
CREATE INDEX IF NOT EXISTS idx_face_clusters_matched_person ON face_clusters(matched_person_id);
`

export const UNIQUE_PHOTO_PATH_INDEX_SQL = `
CREATE UNIQUE INDEX IF NOT EXISTS idx_photos_session_filepath ON photos(session_id, filepath);
`
