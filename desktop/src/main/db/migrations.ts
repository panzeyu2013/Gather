import type Database from 'better-sqlite3'

export function runMigrations(db: Database.Database): void {
  db.exec(`
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
      session_id TEXT NOT NULL REFERENCES sessions(id),
      filepath TEXT NOT NULL,
      filename TEXT NOT NULL DEFAULT '',
      checksum TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'pending',
      metadata TEXT NOT NULL DEFAULT '{}',
      result TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS face_observations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      photo_id TEXT NOT NULL REFERENCES photos(id),
      session_id TEXT NOT NULL REFERENCES sessions(id),
      bbox_x REAL NOT NULL,
      bbox_y REAL NOT NULL,
      bbox_w REAL NOT NULL,
      bbox_h REAL NOT NULL,
      embedding BLOB NOT NULL,
      confidence REAL NOT NULL DEFAULT 0.0
    );

    CREATE TABLE IF NOT EXISTS face_clusters (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id),
      label TEXT NOT NULL DEFAULT '',
      member_count INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'unbound',
      thumbnail_base64 TEXT NOT NULL DEFAULT ''
    );

    CREATE TABLE IF NOT EXISTS face_cluster_members (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      cluster_id INTEGER NOT NULL REFERENCES face_clusters(id),
      session_id TEXT NOT NULL REFERENCES sessions(id),
      photo_id TEXT NOT NULL,
      photo_path TEXT NOT NULL,
      bbox TEXT NOT NULL,
      confidence REAL NOT NULL DEFAULT 0.0,
      observation_id INTEGER
    );

    CREATE TABLE IF NOT EXISTS role_bindings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      cluster_id INTEGER NOT NULL UNIQUE REFERENCES face_clusters(id),
      session_id TEXT NOT NULL REFERENCES sessions(id),
      role_name TEXT NOT NULL,
      keywords TEXT NOT NULL DEFAULT '[]'
    );

    CREATE TABLE IF NOT EXISTS similarity_hashes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id),
      photo_id TEXT NOT NULL REFERENCES photos(id),
      hash_hex TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS similarity_results (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id),
      groups_json TEXT NOT NULL,
      stats_json TEXT NOT NULL DEFAULT '{}',
      param_threshold INTEGER NOT NULL,
      param_min_group_size INTEGER NOT NULL DEFAULT 2,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS writeback_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      photo_id TEXT NOT NULL REFERENCES photos(id),
      session_id TEXT NOT NULL REFERENCES sessions(id),
      module TEXT NOT NULL,
      keywords TEXT NOT NULL DEFAULT '[]',
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
  `)

  db.exec(`
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
  `)

  // Migration: ensure thumbnail_base64 column exists (for databases created before this column was added)
  try {
    db.exec(`ALTER TABLE face_clusters ADD COLUMN thumbnail_base64 TEXT NOT NULL DEFAULT ''`)
  } catch {
    // column already exists — ignore
  }
}
