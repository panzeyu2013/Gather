# tests/test_db.py - Unit tests for shared/db.py (Database class).

import os
import stat
import tempfile

from shared.db import Database

# ---------------------------------------------------------------------------
# Database.__init__ creates file with 0o600 permissions
# ---------------------------------------------------------------------------


def test_init_creates_file_with_restrictive_permissions():
    with tempfile.TemporaryDirectory() as tmp:
        db_path = os.path.join(tmp, "perms.db")
        db = Database(db_path)
        try:
            file_stat = os.stat(db_path)
            actual_mode = stat.S_IMODE(file_stat.st_mode)
            assert actual_mode == 0o600, (
                f"Expected 0o600 but got {oct(actual_mode)}"
            )
            dir_stat = os.stat(tmp)
            dir_mode = stat.S_IMODE(dir_stat.st_mode)
            assert dir_mode == 0o700, (
                f"Expected 0o700 for directory but got {oct(dir_mode)}"
            )
        finally:
            db.close()


# ---------------------------------------------------------------------------
# migrate() is idempotent (run twice, no crash)
# ---------------------------------------------------------------------------


def test_migrate_is_idempotent(db):
    """Running migrate() twice on the same database should not raise."""
    db.migrate()  # second call
    # Also verify it actually ran migrations: the schema_version table should have rows
    conn = db.get_conn()
    max_version = conn.execute(
        "SELECT COALESCE(MAX(version), 0) FROM schema_version"
    ).fetchone()[0]
    assert max_version >= 1


# ---------------------------------------------------------------------------
# checkpoint() doesn't raise on clean DB
# ---------------------------------------------------------------------------


def test_checkpoint_does_not_raise_on_clean_db(db):
    db.checkpoint()  # should not raise
    db.checkpoint(mode="TRUNCATE")  # should also not raise


def test_checkpoint_after_insert_does_not_raise(db):
    conn = db.get_conn()
    conn.execute("INSERT INTO sessions (id, name, status, created_at, updated_at) VALUES (?, ?, ?, datetime('now'), datetime('now'))", ("test-ckpt", "ckpt", "draft"))
    conn.commit()
    db.checkpoint()
    db.checkpoint(mode="PASSIVE")


# ---------------------------------------------------------------------------
# close() can be called multiple times safely
# ---------------------------------------------------------------------------


def test_close_multiple_calls():
    with tempfile.TemporaryDirectory() as tmp:
        db = Database(os.path.join(tmp, "close.db"))
        db.close()
        # Second close should not raise (sqlite3 allows multiple close() calls)
        db.close()


def test_close_called_after_explicit_use():
    with tempfile.TemporaryDirectory() as tmp:
        db = Database(os.path.join(tmp, "close2.db"))
        db.migrate()
        db.checkpoint()
        conn = db.get_conn()
        conn.execute("INSERT INTO sessions (id, name, status, created_at, updated_at) VALUES (?, ?, ?, datetime('now'), datetime('now'))", ("ck2", "test", "draft"))
        conn.commit()
        db.close()
        db.close()  # second close, no error


# ---------------------------------------------------------------------------
# WAL mode is enabled
# ---------------------------------------------------------------------------


def test_wal_mode_is_enabled(db):
    conn = db.get_conn()
    result = conn.execute("PRAGMA journal_mode").fetchone()[0]
    assert result.lower() == "wal"


def test_foreign_keys_are_enabled(db):
    conn = db.get_conn()
    result = conn.execute("PRAGMA foreign_keys").fetchone()[0]
    assert result == 1


def test_busy_timeout_is_set(db):
    conn = db.get_conn()
    result = conn.execute("PRAGMA busy_timeout").fetchone()[0]
    assert result == 5000
