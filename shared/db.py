# shared/db.py - SQLite connection management and schema migration.
#
# Manages one sqlite3.Connection with WAL mode + foreign_keys enabled.
# Schema versioning via a `schema_version` table lets us evolve the
# database incrementally without dropping data.

from __future__ import annotations

import logging
import os
import sqlite3
import sys
import time

logger = logging.getLogger("gather.db")


def _default_db_path() -> str:
    if sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support/Gather")
    elif sys.platform == "win32":
        base = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "Gather")
    else:
        base = os.path.join(
            os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
            "Gather",
        )
    os.makedirs(base, exist_ok=True)
    return os.path.join(base, "gather.db")


def retry_on_locked(retries: int = 3, backoff_ms: int = 500):
    """Decorator that retries a function on sqlite3.OperationalError (database is locked)."""
    def decorator(fn):
        def wrapper(*args, **kwargs):
            last_exc: Exception | None = None
            for attempt in range(retries):
                try:
                    return fn(*args, **kwargs)
                except sqlite3.OperationalError as e:  # noqa: PERF203
                    last_exc = e
                    if "locked" not in str(e).lower() or attempt == retries - 1:
                        raise
                    time.sleep(backoff_ms / 1000)
            if last_exc is not None:
                raise last_exc
        return wrapper
    return decorator


class Database:
    """Thin wrapper around a single sqlite3.Connection.

    Enables WAL journaling, foreign keys, and a versioned migration
    scheme.  Thread-safety is the caller's responsibility (typically
    every public method on SessionManager acquires a threading.Lock).
    """

    def __init__(self, db_path: str | None = None) -> None:
        self._db_path = db_path or _default_db_path()
        self._conn: sqlite3.Connection = sqlite3.connect(self._db_path, check_same_thread=False)
        self._closed = False
        os.chmod(self._db_path, 0o600)
        os.chmod(os.path.dirname(self._db_path), 0o700)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._conn.execute("PRAGMA busy_timeout=5000")
        self._conn.execute("PRAGMA synchronous=NORMAL")
        self._conn.execute("PRAGMA cache_size=-65536")
        self._conn.execute("PRAGMA mmap_size=268435456")

    # ------------------------------------------------------------------
    # Connection access
    # ------------------------------------------------------------------

    @property
    def db_path(self) -> str:
        return self._db_path

    def get_conn(self) -> sqlite3.Connection:
        """Return the underlying connection (for use under a lock)."""
        return self._conn

    # ------------------------------------------------------------------
    # Schema migration
    # ------------------------------------------------------------------

    def migrate(self) -> None:
        """Run all outstanding schema migrations.

        This method is idempotent: every DDL statement uses IF NOT
        EXISTS so that repeated calls are safe.
        """
        conn = self._conn

        # Version tracking table
        conn.execute("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)

        current = conn.execute("SELECT COALESCE(MAX(version), 0) FROM schema_version").fetchone()[0]

        migrations = [
            (1, self._migrate_v1),
            (2, self._migrate_v2),
            (3, self._migrate_v3),
            (4, self._migrate_v4),
            (5, self._migrate_v5),
            (6, self._migrate_v6),
            (7, self._migrate_v7),
            (8, self._migrate_v8),
            (9, self._migrate_v9),
            (10, self._migrate_v10),
        ]

        for ver, fn in migrations:
            if ver > current:
                fn(conn)
                conn.execute(
                    "INSERT OR REPLACE INTO schema_version (version) VALUES (?)",
                    (ver,),
                )
                conn.commit()

    # ------------------------------------------------------------------
    # Version 1: core tables (sessions + photos)
    # ------------------------------------------------------------------

    @staticmethod
    def _migrate_v1(conn: sqlite3.Connection) -> None:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS sessions (
                id          TEXT PRIMARY KEY,
                name        TEXT NOT NULL DEFAULT '',
                status      TEXT NOT NULL DEFAULT 'draft',
                created_at  TEXT NOT NULL,
                updated_at  TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS photos (
                id          TEXT PRIMARY KEY,
                session_id  TEXT NOT NULL,
                filepath    TEXT NOT NULL,
                filename    TEXT NOT NULL DEFAULT '',
                status      TEXT NOT NULL DEFAULT 'pending'
                                CHECK(status IN ('pending', 'analyzing', 'analyzed', 'error')),
                metadata    TEXT NOT NULL DEFAULT '{}',
                result      TEXT NOT NULL DEFAULT '{}',
                created_at  TEXT NOT NULL,
                updated_at  TEXT NOT NULL,
                FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_photos_session
                ON photos(session_id);
        """)

    # ------------------------------------------------------------------
    # Version 2: face keywording tables
    # ------------------------------------------------------------------

    @staticmethod
    def _migrate_v2(conn: sqlite3.Connection) -> None:
        existing = {row[1] for row in conn.execute("PRAGMA table_info(sessions)").fetchall()}
        if "analysis_status" not in existing:
            conn.execute("ALTER TABLE sessions ADD COLUMN analysis_status TEXT NOT NULL DEFAULT 'idle'")
        if "writeback_status" not in existing:
            conn.execute("ALTER TABLE sessions ADD COLUMN writeback_status TEXT NOT NULL DEFAULT 'idle'")
        if "event_date" not in existing:
            conn.execute("ALTER TABLE sessions ADD COLUMN event_date TEXT NOT NULL DEFAULT ''")
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS face_observations (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                photo_id        TEXT NOT NULL,
                session_id      TEXT NOT NULL,
                bbox_x          REAL NOT NULL,
                bbox_y          REAL NOT NULL,
                bbox_w          REAL NOT NULL,
                bbox_h          REAL NOT NULL,
                embedding       TEXT NOT NULL DEFAULT '[]',
                confidence      REAL NOT NULL DEFAULT 0.0,
                thumbnail_path  TEXT NOT NULL DEFAULT '',
                FOREIGN KEY (photo_id) REFERENCES photos(id) ON DELETE CASCADE,
                FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_face_obs_session
                ON face_observations(session_id);

            CREATE INDEX IF NOT EXISTS idx_face_obs_session_photo
                ON face_observations(session_id, photo_id);

            CREATE TABLE IF NOT EXISTS face_clusters (
                id                      INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id              TEXT NOT NULL,
                label                   TEXT NOT NULL DEFAULT '',
                representative_obs_id   INTEGER,
                member_count            INTEGER NOT NULL DEFAULT 0,
                status                  TEXT NOT NULL DEFAULT 'unbound'
                                        CHECK(status IN ('unbound', 'bound', 'skipped')),
                FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
                FOREIGN KEY (representative_obs_id) REFERENCES face_observations(id) ON DELETE SET NULL
            );

            CREATE INDEX IF NOT EXISTS idx_face_clusters_session
                ON face_clusters(session_id);

            CREATE TABLE IF NOT EXISTS role_bindings (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                cluster_id  INTEGER NOT NULL UNIQUE,
                session_id  TEXT NOT NULL,
                role_name   TEXT NOT NULL,
                keywords    TEXT NOT NULL DEFAULT '[]',
                notes       TEXT NOT NULL DEFAULT '',
                FOREIGN KEY (cluster_id) REFERENCES face_clusters(id) ON DELETE CASCADE,
                FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_role_bindings_session
                ON role_bindings(session_id);

            CREATE TABLE IF NOT EXISTS writeback_items (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                photo_id        TEXT NOT NULL,
                session_id      TEXT NOT NULL,
                keywords        TEXT NOT NULL DEFAULT '[]',
                xmp_path        TEXT NOT NULL DEFAULT '',
                backup_path     TEXT NOT NULL DEFAULT '',
                xmp_status      TEXT NOT NULL DEFAULT 'pending',
                error_message   TEXT NOT NULL DEFAULT '',
                FOREIGN KEY (photo_id) REFERENCES photos(id) ON DELETE CASCADE,
                FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_writeback_items_session
                ON writeback_items(session_id);

            CREATE INDEX IF NOT EXISTS idx_face_obs_photo
                ON face_observations(photo_id);

            CREATE INDEX IF NOT EXISTS idx_face_clusters_status
                ON face_clusters(session_id, status);

            CREATE INDEX IF NOT EXISTS idx_role_bindings_cluster
                ON role_bindings(cluster_id);

            CREATE INDEX IF NOT EXISTS idx_writeback_items_photo
                ON writeback_items(photo_id);

            CREATE INDEX IF NOT EXISTS idx_photos_filepath
                ON photos(session_id, filepath);
        """)

    # ------------------------------------------------------------------
    # Version 3: add checksum column to photos
    # ------------------------------------------------------------------

    @staticmethod
    def _migrate_v3(conn: sqlite3.Connection) -> None:
        existing = {row[1] for row in conn.execute("PRAGMA table_info(photos)").fetchall()}
        if "checksum" not in existing:
            conn.execute("ALTER TABLE photos ADD COLUMN checksum TEXT NOT NULL DEFAULT ''")

    # ------------------------------------------------------------------
    # Version 4: persisted face cluster membership
    # ------------------------------------------------------------------

    @staticmethod
    def _migrate_v4(conn: sqlite3.Connection) -> None:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS face_cluster_members (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                cluster_id      INTEGER NOT NULL,
                session_id      TEXT NOT NULL,
                photo_id        TEXT NOT NULL,
                photo_path      TEXT NOT NULL DEFAULT '',
                filename        TEXT NOT NULL DEFAULT '',
                bbox            TEXT NOT NULL DEFAULT '[0, 0, 0, 0]',
                confidence      REAL NOT NULL DEFAULT 0.0,
                observation_id  INTEGER,
                FOREIGN KEY (cluster_id) REFERENCES face_clusters(id) ON DELETE CASCADE,
                FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
                FOREIGN KEY (photo_id) REFERENCES photos(id) ON DELETE CASCADE,
                FOREIGN KEY (observation_id) REFERENCES face_observations(id) ON DELETE SET NULL
            );

            CREATE INDEX IF NOT EXISTS idx_face_cluster_members_cluster
                ON face_cluster_members(cluster_id);

            CREATE INDEX IF NOT EXISTS idx_face_cluster_members_session
                ON face_cluster_members(session_id);

            CREATE INDEX IF NOT EXISTS idx_face_cluster_members_photo
                ON face_cluster_members(photo_id);
        """)

    # ------------------------------------------------------------------
    # Version 5: add index on sessions.updated_at for dashboard queries
    # ------------------------------------------------------------------

    @staticmethod
    def _migrate_v5(conn: sqlite3.Connection) -> None:
        conn.execute("CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at)")

    # ------------------------------------------------------------------
    # Version 6: similarity hash/results persistence
    # ------------------------------------------------------------------

    @staticmethod
    def _migrate_v6(conn: sqlite3.Connection) -> None:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS similarity_hashes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                photo_id TEXT NOT NULL,
                hash_hex TEXT NOT NULL,
                FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
                FOREIGN KEY (photo_id) REFERENCES photos(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_sim_hashes_session
                ON similarity_hashes(session_id);

            CREATE INDEX IF NOT EXISTS idx_sim_hashes_photo
                ON similarity_hashes(photo_id);

            CREATE TABLE IF NOT EXISTS similarity_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                groups_json TEXT NOT NULL,
                stats_json TEXT NOT NULL DEFAULT '{}',
                param_threshold INTEGER NOT NULL,
                param_min_group_size INTEGER NOT NULL DEFAULT 2,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_sim_results_session
                ON similarity_results(session_id);
        """)

    # ------------------------------------------------------------------
    # Version 7: fix similarity_hashes.photo_id type and add CHECK constraints
    # ------------------------------------------------------------------

    @staticmethod
    def _migrate_v7(conn: sqlite3.Connection) -> None:
        # Fix similarity_hashes.photo_id: if column is still INTEGER, recreate the table with TEXT.
        cols = {row[1]: row[2] for row in conn.execute("PRAGMA table_info(similarity_hashes)").fetchall()}
        fc_cols = {row[1]: row[2] for row in conn.execute("PRAGMA table_info(face_clusters)").fetchall()}
        ph_cols = {row[1]: row[2] for row in conn.execute("PRAGMA table_info(photos)").fetchall()}

        needs_v7 = cols.get("photo_id", "").upper() == "INTEGER"
        if not needs_v7:
            return

        # foreign_keys must be disabled OUTSIDE a transaction (SQLite limitation)
        conn.execute("PRAGMA foreign_keys = OFF")
        conn.execute("BEGIN IMMEDIATE")
        try:
            if cols.get("photo_id", "").upper() == "INTEGER":
                conn.execute("""
                    CREATE TABLE IF NOT EXISTS similarity_hashes_v7 (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        session_id TEXT NOT NULL,
                        photo_id TEXT NOT NULL,
                        hash_hex TEXT NOT NULL,
                        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
                        FOREIGN KEY (photo_id) REFERENCES photos(id) ON DELETE CASCADE
                    )
                """)
                conn.execute(
                    "INSERT INTO similarity_hashes_v7 (id, session_id, photo_id, hash_hex) "
                    "SELECT id, session_id, CAST(photo_id AS TEXT), hash_hex FROM similarity_hashes"
                )
                conn.execute("DROP TABLE similarity_hashes")
                conn.execute("ALTER TABLE similarity_hashes_v7 RENAME TO similarity_hashes")
                conn.execute("CREATE INDEX IF NOT EXISTS idx_sim_hashes_session ON similarity_hashes(session_id)")
                conn.execute("CREATE INDEX IF NOT EXISTS idx_sim_hashes_photo ON similarity_hashes(photo_id)")

            if fc_cols.get("status", "").upper() == "TEXT":
                conn.execute("""
                    CREATE TABLE IF NOT EXISTS face_clusters_v7 (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        session_id TEXT NOT NULL,
                        label TEXT NOT NULL DEFAULT '',
                        representative_obs_id INTEGER,
                        member_count INTEGER NOT NULL DEFAULT 0,
                        status TEXT NOT NULL DEFAULT 'unbound'
                            CHECK(status IN ('unbound', 'bound', 'skipped')),
                        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
                        FOREIGN KEY (representative_obs_id) REFERENCES face_observations(id) ON DELETE SET NULL
                    )
                """)
                conn.execute("INSERT INTO face_clusters_v7 SELECT * FROM face_clusters")
                conn.execute("DROP TABLE face_clusters")
                conn.execute("ALTER TABLE face_clusters_v7 RENAME TO face_clusters")
                conn.execute("CREATE INDEX IF NOT EXISTS idx_face_clusters_session ON face_clusters(session_id)")
                conn.execute("CREATE INDEX IF NOT EXISTS idx_face_clusters_status ON face_clusters(session_id, status)")

            if ph_cols.get("status", "").upper() == "TEXT":
                conn.execute("""
                    CREATE TABLE IF NOT EXISTS photos_v7 (
                        id TEXT PRIMARY KEY,
                        session_id TEXT NOT NULL,
                        filepath TEXT NOT NULL,
                        filename TEXT NOT NULL DEFAULT '',
                        status TEXT NOT NULL DEFAULT 'pending'
                            CHECK(status IN ('pending', 'analyzing', 'analyzed', 'error')),
                        metadata TEXT NOT NULL DEFAULT '{}',
                        result TEXT NOT NULL DEFAULT '{}',
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL,
                        checksum TEXT NOT NULL DEFAULT '',
                        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
                    )
                """)
                conn.execute("INSERT INTO photos_v7 SELECT * FROM photos")
                conn.execute("DROP TABLE photos")
                conn.execute("ALTER TABLE photos_v7 RENAME TO photos")
                conn.execute("CREATE INDEX IF NOT EXISTS idx_photos_session ON photos(session_id)")
                conn.execute("CREATE INDEX IF NOT EXISTS idx_photos_filepath ON photos(session_id, filepath)")

            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.execute("PRAGMA foreign_keys = ON")
            fk_violations = conn.execute("PRAGMA foreign_key_check").fetchall()
            if fk_violations:
                logger.warning("Foreign key violations detected after v7 migration: %d rows", len(fk_violations))

    # ------------------------------------------------------------------
    # Version 8: composite index + unique constraint for similarity tables
    # ------------------------------------------------------------------

    @staticmethod
    def _migrate_v8(conn: sqlite3.Connection) -> None:
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_sim_results_session_threshold "
            "ON similarity_results(session_id, param_threshold)"
        )
        conn.execute("""
            DELETE FROM similarity_hashes WHERE rowid NOT IN (
                SELECT MIN(rowid) FROM similarity_hashes GROUP BY session_id, photo_id
            )
        """)
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_sim_hashes_unique ON similarity_hashes(session_id, photo_id)"
        )

    # ------------------------------------------------------------------
    # Version 9: unique constraint on face_observations + member_count triggers
    # ------------------------------------------------------------------

    @staticmethod
    def _migrate_v9(conn: sqlite3.Connection) -> None:
        conn.execute("""
            DELETE FROM face_observations WHERE rowid NOT IN (
                SELECT MIN(rowid) FROM face_observations GROUP BY photo_id, bbox_x, bbox_y, bbox_w, bbox_h
            )
        """)
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_face_obs_unique "
            "ON face_observations(photo_id, bbox_x, bbox_y, bbox_w, bbox_h)"
        )
        conn.executescript("""
            CREATE TRIGGER IF NOT EXISTS sync_cluster_member_count_insert
            AFTER INSERT ON face_cluster_members
            BEGIN
                UPDATE face_clusters SET member_count = (SELECT COUNT(*) FROM face_cluster_members WHERE cluster_id = NEW.cluster_id) WHERE id = NEW.cluster_id;
            END;
            CREATE TRIGGER IF NOT EXISTS sync_cluster_member_count_delete
            AFTER DELETE ON face_cluster_members
            BEGIN
                UPDATE face_clusters SET member_count = (SELECT COUNT(*) FROM face_cluster_members WHERE cluster_id = OLD.cluster_id) WHERE id = OLD.cluster_id;
            END;
        """)

    # ------------------------------------------------------------------
    # Version 10: add CHECK constraints on sessions and writeback_items
    # ------------------------------------------------------------------

    @staticmethod
    def _migrate_v10(conn: sqlite3.Connection) -> None:
        conn.execute("PRAGMA foreign_keys = OFF")
        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS sessions_v10 (
                    id              TEXT PRIMARY KEY,
                    name            TEXT NOT NULL DEFAULT '',
                    status          TEXT NOT NULL DEFAULT 'draft'
                        CHECK(status IN ('draft','photos_loaded','analyzing','review','completed')),
                    created_at      TEXT NOT NULL,
                    updated_at      TEXT NOT NULL,
                    analysis_status TEXT NOT NULL DEFAULT 'idle'
                        CHECK(analysis_status IN ('idle','running','done','failed','cancelled')),
                    writeback_status TEXT NOT NULL DEFAULT 'idle'
                        CHECK(writeback_status IN ('idle','running','done','partial','cleaned')),
                    event_date      TEXT NOT NULL DEFAULT ''
                )
            """)
            conn.execute("UPDATE sessions SET status = 'draft' WHERE status NOT IN ('draft','photos_loaded','analyzing','review','completed')")
            conn.execute("UPDATE sessions SET analysis_status = 'idle' WHERE analysis_status NOT IN ('idle','running','done','failed','cancelled')")
            conn.execute("UPDATE sessions SET writeback_status = 'idle' WHERE writeback_status NOT IN ('idle','running','done','partial','cleaned')")
            conn.execute("INSERT INTO sessions_v10 SELECT * FROM sessions")
            conn.execute("DROP TABLE sessions")
            conn.execute("ALTER TABLE sessions_v10 RENAME TO sessions")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at)")

            conn.execute("""
                CREATE TABLE IF NOT EXISTS writeback_items_v10 (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    photo_id        TEXT NOT NULL,
                    session_id      TEXT NOT NULL,
                    keywords        TEXT NOT NULL DEFAULT '[]',
                    xmp_path        TEXT NOT NULL DEFAULT '',
                    backup_path     TEXT NOT NULL DEFAULT '',
                    xmp_status      TEXT NOT NULL DEFAULT 'pending'
                        CHECK(xmp_status IN ('pending','written','failed','restored')),
                    error_message   TEXT NOT NULL DEFAULT '',
                    FOREIGN KEY (photo_id) REFERENCES photos(id) ON DELETE CASCADE,
                    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
                )
            """)
            conn.execute("INSERT INTO writeback_items_v10 SELECT * FROM writeback_items")
            conn.execute("DROP TABLE writeback_items")
            conn.execute("ALTER TABLE writeback_items_v10 RENAME TO writeback_items")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_writeback_items_session ON writeback_items(session_id)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_writeback_items_photo ON writeback_items(photo_id)")

            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.execute("PRAGMA foreign_keys = ON")
            fk_violations = conn.execute("PRAGMA foreign_key_check").fetchall()
            if fk_violations:
                logger.warning("Foreign key violations detected after v10 migration: %d rows", len(fk_violations))

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    def close(self) -> None:
        if self._closed:
            return
        self.checkpoint()
        self._conn.close()
        self._closed = True

    def checkpoint(self, mode: str = "PASSIVE") -> None:
        if self._closed:
            return
        allowed = {"PASSIVE", "FULL", "RESTART", "TRUNCATE"}
        if mode not in allowed:
            raise ValueError(f"Invalid WAL checkpoint mode: {mode}")
        self._conn.execute(f"PRAGMA wal_checkpoint({mode})")
