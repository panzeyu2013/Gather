export const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft',
  analysis_status TEXT NOT NULL DEFAULT 'idle',
  writeback_status TEXT NOT NULL DEFAULT 'idle',
  import_source TEXT NOT NULL DEFAULT 'unknown',
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
  confidence REAL NOT NULL DEFAULT 0.0
);

CREATE TABLE IF NOT EXISTS face_clusters (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  label TEXT NOT NULL DEFAULT '',
  member_count INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'unbound',
  thumbnail_base64 TEXT NOT NULL DEFAULT '',
  thumbnail_path TEXT NOT NULL DEFAULT '',
  matched_person_id TEXT REFERENCES persons(id)
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
  keywords TEXT NOT NULL DEFAULT '[]'
);

CREATE TABLE IF NOT EXISTS similarity_hashes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL REFERENCES photos(id),
  hash_hex TEXT NOT NULL
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

CREATE TABLE IF NOT EXISTS writeback_items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  photo_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  module TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]',
  photo_path TEXT NOT NULL DEFAULT '',
  xmp_path TEXT NOT NULL DEFAULT '',
  backup_path TEXT NOT NULL DEFAULT '',
  xmp_status TEXT NOT NULL DEFAULT 'pending',
  error_message TEXT NOT NULL DEFAULT '',
  attempt_count INTEGER NOT NULL DEFAULT 1,
  last_attempt_at TEXT NOT NULL DEFAULT '',
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
  gps_latitude REAL,
  gps_longitude REAL,
  width INTEGER,
  height INTEGER,
  file_size INTEGER,
  file_mtime TEXT,
  keywords TEXT NOT NULL DEFAULT '[]',
  cached_at TEXT NOT NULL
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
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS operation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  operation_type TEXT NOT NULL,
  params TEXT NOT NULL,
  snapshot_before TEXT,
  snapshot_after TEXT,
  is_undo INTEGER NOT NULL DEFAULT 0,
  description TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);
`

export const INDEX_SQL = `
CREATE INDEX IF NOT EXISTS idx_photos_session ON photos(session_id);
CREATE INDEX IF NOT EXISTS idx_photos_filepath ON photos(filepath);
CREATE INDEX IF NOT EXISTS idx_face_observations_session ON face_observations(session_id);
CREATE INDEX IF NOT EXISTS idx_face_observations_photo ON face_observations(photo_id);
CREATE INDEX IF NOT EXISTS idx_face_clusters_session ON face_clusters(session_id);
CREATE INDEX IF NOT EXISTS idx_face_cluster_members_cluster ON face_cluster_members(cluster_id);
CREATE INDEX IF NOT EXISTS idx_face_cluster_members_session ON face_cluster_members(session_id);
CREATE INDEX IF NOT EXISTS idx_similarity_hashes_session ON similarity_hashes(session_id);
CREATE INDEX IF NOT EXISTS idx_similarity_hashes_photo ON similarity_hashes(photo_id);
CREATE INDEX IF NOT EXISTS idx_similarity_results_session ON similarity_results(session_id);
CREATE INDEX IF NOT EXISTS idx_writeback_items_session ON writeback_items(session_id);
CREATE INDEX IF NOT EXISTS idx_writeback_items_photo ON writeback_items(photo_id);
CREATE INDEX IF NOT EXISTS idx_persons_name ON persons(name);
CREATE INDEX IF NOT EXISTS idx_person_embeddings_person ON person_embeddings(person_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_person_embeddings_obs ON person_embeddings(face_observation_id);
CREATE INDEX IF NOT EXISTS idx_person_photos_person ON person_photos(person_id);
CREATE INDEX IF NOT EXISTS idx_person_photos_photo ON person_photos(photo_id);
CREATE INDEX IF NOT EXISTS idx_person_photos_session ON person_photos(session_id);
CREATE INDEX IF NOT EXISTS idx_metadata_cache_session ON photo_metadata_cache(session_id);
CREATE INDEX IF NOT EXISTS idx_duplicate_groups_session ON duplicate_groups(session_id);
CREATE INDEX IF NOT EXISTS idx_duplicate_members_group ON duplicate_group_members(group_id);
CREATE INDEX IF NOT EXISTS idx_duplicate_members_photo ON duplicate_group_members(photo_id);
CREATE INDEX IF NOT EXISTS idx_culling_photo_session ON culling_decisions(session_id, photo_id);
CREATE INDEX IF NOT EXISTS idx_culling_group ON culling_decisions(session_id, group_id);
CREATE INDEX IF NOT EXISTS idx_operation_log_session ON operation_log(session_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_operation_log_type ON operation_log(session_id, operation_type, is_undo);
CREATE INDEX IF NOT EXISTS idx_face_clusters_matched_person ON face_clusters(matched_person_id);
`
