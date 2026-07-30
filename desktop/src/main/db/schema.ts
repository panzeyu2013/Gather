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
  width INTEGER NOT NULL DEFAULT 0,
  height INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
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
  revision INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL,
  UNIQUE(session_id, photo_id)
);

CREATE TABLE IF NOT EXISTS metadata_outbox (
  xmp_path TEXT PRIMARY KEY,
  owner_session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
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

CREATE TABLE IF NOT EXISTS schema_version (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);
`

export const INDEX_SQL = `
CREATE INDEX IF NOT EXISTS idx_photos_session ON photos(session_id);
CREATE INDEX IF NOT EXISTS idx_photos_filepath ON photos(filepath);
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
CREATE INDEX IF NOT EXISTS idx_culling_photo_session ON culling_decisions(session_id, photo_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_culling_session_photo_unique ON culling_decisions(session_id, photo_id);
CREATE INDEX IF NOT EXISTS idx_culling_group ON culling_decisions(session_id, group_id);
CREATE INDEX IF NOT EXISTS idx_metadata_outbox_session_status ON metadata_outbox(owner_session_id, status);
CREATE INDEX IF NOT EXISTS idx_face_clusters_matched_person ON face_clusters(matched_person_id);
`

export const UNIQUE_PHOTO_PATH_INDEX_SQL = `
CREATE UNIQUE INDEX IF NOT EXISTS idx_photos_session_filepath ON photos(session_id, filepath);
`
