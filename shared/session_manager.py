from __future__ import annotations

import json
import logging
import os
import sqlite3
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager, suppress
from datetime import datetime, timezone
from typing import Any

import numpy as np

from .db import Database
from .exceptions import SessionNotFoundError
from .models import (
    AnalysisStatus,
    ClusterBindingStatus,
    Photo,
    PhotoStatus,
    Session,
    SessionStatus,
    WritebackStatus,
)
from .path_utils import file_checksum

logger = logging.getLogger(__name__)

_checksum_pool: ThreadPoolExecutor | None = None
_checksum_pool_lock = threading.Lock()


def _get_checksum_pool() -> ThreadPoolExecutor:
    global _checksum_pool
    if _checksum_pool is None:
        with _checksum_pool_lock:
            if _checksum_pool is None:
                _checksum_pool = ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 4))
    return _checksum_pool


def shutdown_checksum_pool() -> None:
    global _checksum_pool
    with _checksum_pool_lock:
        if _checksum_pool is not None:
            _checksum_pool.shutdown(wait=True)
            _checksum_pool = None


class SessionManager:
    """Thread-safe session + photo store backed by a single SQLite file.

    Accepts a Database instance via dependency injection.  If none is
    provided, creates one with the default path.
    """

    def __init__(self, db: Database | None = None, db_path: str | None = None) -> None:
        if db is not None:
            self._db = db
        else:
            self._db = Database(db_path)
        self._db.migrate()
        self._lock = threading.Lock()
        self._conn = self._db.get_conn()

    @contextmanager
    def _transaction(self):
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            yield
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise

    # ------------------------------------------------------------------
    # Session CRUD
    # ------------------------------------------------------------------

    def count_sessions(self) -> int:
        """Return the number of active sessions (lightweight COUNT query)."""
        with self._lock:
            row = self._conn.execute("SELECT COUNT(*) AS cnt FROM sessions").fetchone()
        # SELECT COUNT(*) always returns a row, so row is never None.
        return int(row["cnt"])
    
    def create_session(self, name: str = "") -> Session:
        session = Session(name=name)
        with self._lock:
            self._conn.execute(
                "INSERT INTO sessions (id, name, status, analysis_status, writeback_status, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    session.id,
                    session.name,
                    session.status.value,
                    session.analysis_status.value,
                    session.writeback_status.value,
                    session.created_at,
                    session.updated_at,
                ),
            )
            self._conn.commit()
        return session

    def get_session(self, session_id: str) -> Session | None:
        with self._lock:
            row = self._conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
        if row is None:
            return None
        return Session.from_dict(dict(row))

    def list_sessions(self) -> list[Session]:
        with self._lock:
            rows = self._conn.execute("SELECT * FROM sessions ORDER BY updated_at DESC").fetchall()
        return [Session.from_dict(dict(r)) for r in rows]

    def update_session_status(self, session_id: str, status: SessionStatus) -> None:
        now = datetime.now(timezone.utc).isoformat()
        with self._lock:
            self._conn.execute(
                "UPDATE sessions SET status = ?, updated_at = ? WHERE id = ?",
                (status.value, now, session_id),
            )
            self._conn.commit()

    def update_session_name(self, session_id: str, name: str) -> bool:
        now = datetime.now(timezone.utc).isoformat()
        truncated = name[:256]
        if len(name) > 256:
            logger.warning("Session name truncated from %d to 256 characters", len(name))
        with self._lock:
            cur = self._conn.execute(
                "UPDATE sessions SET name = ?, updated_at = ? WHERE id = ?",
                (truncated, now, session_id),
            )
            self._conn.commit()
            return cur.rowcount > 0

    def update_analysis_status(self, session_id: str, status: AnalysisStatus) -> None:
        now = datetime.now(timezone.utc).isoformat()
        with self._lock:
            self._conn.execute(
                "UPDATE sessions SET analysis_status = ?, updated_at = ? WHERE id = ?",
                (status.value, now, session_id),
            )
            self._conn.commit()

    def update_writeback_session_status(self, session_id: str, status: WritebackStatus) -> None:
        now = datetime.now(timezone.utc).isoformat()
        with self._lock:
            self._conn.execute(
                "UPDATE sessions SET writeback_status = ?, updated_at = ? WHERE id = ?",
                (status.value, now, session_id),
            )
            self._conn.commit()

    def try_start_writeback(self, session_id: str) -> bool:
        """Atomically set writeback_status to RUNNING if currently idle.

        Returns True if the status was successfully set to RUNNING.
        Returns False if writeback is already RUNNING or DONE.
        The caller should check the current status for the specific error.
        """
        # Only allow writeback to start from IDLE state.
        # RUNNING and DONE are excluded; PARTIAL and CLEANED sessions cannot start again.
        now = datetime.now(timezone.utc).isoformat()
        running = WritebackStatus.RUNNING.value
        with self._lock:
            cur = self._conn.execute(
                "UPDATE sessions SET writeback_status = ?, updated_at = ? "
                "WHERE id = ? AND writeback_status = ?",
                (running, now, session_id, WritebackStatus.IDLE.value),
            )
            self._conn.commit()
            return cur.rowcount > 0

    def delete_session(self, session_id: str) -> bool:
        with self._lock:
            cur = self._conn.execute("DELETE FROM sessions WHERE id = ?", (session_id,))
            self._conn.commit()
        deleted = cur.rowcount > 0
        return deleted

    # ------------------------------------------------------------------
    # Photo management
    # ------------------------------------------------------------------

    def add_photos(self, session_id: str, filepaths: list[str]) -> tuple[list[Photo], list[str]]:
        """Insert photos into a session.  Duplicate filepaths are skipped."""
        now = datetime.now(timezone.utc).isoformat()
        photos: list[Photo] = []
        failed_paths: list[str] = []

        # Compute checksums outside the lock (disk I/O, no DB access needed)
        checksums: dict[str, str | None] = {}
        executor = _get_checksum_pool()
        future_to_fp = {executor.submit(file_checksum, fp, partial_bytes=16): fp for fp in filepaths}
        for future in as_completed(future_to_fp):
            fp = future_to_fp[future]
            checksums[fp] = future.result()

        with self._lock:
            # Verify session exists
            row = self._conn.execute("SELECT id FROM sessions WHERE id = ?", (session_id,)).fetchone()
            if row is None:
                raise SessionNotFoundError(f"Session not found: {session_id}")

            # Pre-fetch existing filepaths for this session to deduplicate
            existing = set()
            for row in self._conn.execute("SELECT filepath FROM photos WHERE session_id = ?", (session_id,)).fetchall():
                existing.add(row["filepath"])

            rows: list[tuple] = []
            for fp in filepaths:
                if fp in existing:
                    continue
                cs = checksums.get(fp)
                if cs is None:
                    logger.warning("Cannot compute checksum for %s", fp)
                    failed_paths.append(fp)
                    continue
                photo = Photo(
                    session_id=session_id,
                    filepath=fp,
                    filename=os.path.basename(fp),
                    checksum=cs,
                    created_at=now,
                    updated_at=now,
                )
                rows.append(
                    (
                        photo.id,
                        photo.session_id,
                        photo.filepath,
                        photo.filename,
                        photo.checksum,
                        photo.status.value,
                        json.dumps(photo.metadata, ensure_ascii=False),
                        json.dumps(photo.result, ensure_ascii=False),
                        photo.created_at,
                        photo.updated_at,
                    )
                )
                photos.append(photo)
                existing.add(fp)

            with self._transaction():
                if rows:
                    self._conn.executemany(
                        "INSERT OR IGNORE INTO photos (id, session_id, filepath, filename, "
                        "checksum, status, metadata, result, created_at, updated_at) "
                        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        rows,
                    )

                # bump session updated_at
                self._conn.execute(
                    "UPDATE sessions SET updated_at = ? WHERE id = ?",
                    (now, session_id),
                )
        return photos, failed_paths

    def get_photos(self, session_id: str) -> list[Photo]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM photos WHERE session_id = ? ORDER BY created_at",
                (session_id,),
            ).fetchall()
        photos: list[Photo] = []
        for r in rows:
            d = dict(r)
            try:
                d["metadata"] = json.loads(d["metadata"])
            except (json.JSONDecodeError, TypeError):
                logger.warning("Corrupted metadata JSON for photo %s", d["id"])
                d["metadata"] = {}
            try:
                d["result"] = json.loads(d["result"])
            except (json.JSONDecodeError, TypeError):
                logger.warning("Corrupted result JSON for photo %s", d["id"])
                d["result"] = {}
            photos.append(Photo.from_dict(d))
        return photos

    def get_photo_filepaths(self, session_id: str) -> list[dict]:
        """Return lightweight [{id, filepath}] mapping, avoiding JSON deserialization."""
        with self._lock:
            rows = self._conn.execute(
                "SELECT id, filepath FROM photos WHERE session_id = ? ORDER BY created_at",
                (session_id,),
            ).fetchall()
        return [{"id": r["id"], "filepath": r["filepath"]} for r in rows]

    def update_photo_result(
        self, photo_id: str, result: dict[str, Any], status: PhotoStatus = PhotoStatus.ANALYZED
    ) -> None:
        now = datetime.now(timezone.utc).isoformat()
        with self._lock:
            self._conn.execute(
                "UPDATE photos SET result = ?, status = ?, updated_at = ? WHERE id = ?",
                (json.dumps(result, ensure_ascii=False), status, now, photo_id),
            )
            self._conn.commit()

    def count_photos(self, session_id: str) -> int:
        with self._lock:
            row = self._conn.execute(
                "SELECT COUNT(*) AS cnt FROM photos WHERE session_id = ?",
                (session_id,),
            ).fetchone()
        return row["cnt"] if row else 0

    def count_photos_by_sessions(self, session_ids: list[str]) -> dict[str, int]:
        """Batch COUNT query to avoid N+1 in session list."""
        if not session_ids:
            return {}
        placeholders = ",".join("?" * len(session_ids))
        with self._lock:
            rows = self._conn.execute(
                f"SELECT session_id, COUNT(*) AS cnt FROM photos WHERE session_id IN ({placeholders}) GROUP BY session_id",
                tuple(session_ids),
            ).fetchall()
        return {r["session_id"]: r["cnt"] for r in rows}

    # ------------------------------------------------------------------
    # Face observations
    # ------------------------------------------------------------------

    def _insert_observations(self, session_id: str, observations: list[dict[str, Any]]) -> list[tuple[int, str, str]]:
        if not observations:
            return []
        rows = []
        for obs in observations:
            bbox = obs.get("bbox", [0, 0, 0, 0])
            embedding_list = obs.get("embedding", [])
            embedding_blob = np.array(embedding_list, dtype=np.float32).tobytes()
            rows.append(
                (
                    obs["photo_id"],
                    session_id,
                    bbox[0] if len(bbox) > 0 else 0,
                    bbox[1] if len(bbox) > 1 else 0,
                    bbox[2] if len(bbox) > 2 else 0,
                    bbox[3] if len(bbox) > 3 else 0,
                    embedding_blob,
                    obs.get("confidence", 0.0),
                    obs.get("thumbnail_path", ""),
                )
            )
        # NOTE: Individual INSERT ... RETURNING per observation; acceptable for typical
        # face counts (<1000 faces per session). For very large batches, batch-INSERT
        # followed by a composite-key SELECT would be more efficient.
        results: list[tuple[int, str, str]] = []
        for row in rows:
            cur = self._conn.execute(
                "INSERT OR IGNORE INTO face_observations "
                "(photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, "
                "embedding, confidence, thumbnail_path) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
                "RETURNING id, photo_id, bbox_x, bbox_y, bbox_w, bbox_h",
                row,
            )
            inserted = cur.fetchone()
            if inserted is not None:
                bbox_json = json.dumps(
                    [inserted["bbox_x"], inserted["bbox_y"], inserted["bbox_w"], inserted["bbox_h"]],
                    ensure_ascii=False,
                )
                results.append((inserted["id"], inserted["photo_id"], bbox_json))
        return results

    def save_observations(self, session_id: str, observations: list[dict[str, Any]]) -> list[int]:
        """Insert face observations and return their auto-increment IDs."""
        if not observations:
            return []
        with self._lock, self._transaction():
            rows = self._insert_observations(session_id, observations)
            ids = [r[0] for r in rows]
        return ids

    def _insert_clusters_with_members(
        self,
        session_id: str,
        clusters: list[dict[str, Any]],
        observation_ids_by_key: dict[tuple[str, str], int] | None = None,
    ) -> list[int]:
        """Insert face clusters and their members. Returns list of cluster row IDs."""
        ids: list[int] = []
        for cl in clusters:
            members = cl.get("members", []) or []
            member_count = cl.get("member_count", cl.get("size", len(members)))
            representative_obs_id = cl.get("representative_obs_id")
            if representative_obs_id is None and members and observation_ids_by_key is not None:
                first = members[0]
                key = (
                    first.get("photo_id", ""),
                    json.dumps(first.get("bbox", [0, 0, 0, 0]), ensure_ascii=False),
                )
                representative_obs_id = observation_ids_by_key.get(key)
            cur = self._conn.execute(
                "INSERT INTO face_clusters "
                "(session_id, label, representative_obs_id, member_count, status) "
                "VALUES (?, ?, ?, ?, ?)",
                (
                    session_id,
                    cl.get("label", ""),
                    representative_obs_id,
                    member_count,
                    cl.get("status", "unbound"),
                ),
            )
            cluster_id = cur.lastrowid
            if cluster_id is None:
                raise RuntimeError("Failed to persist face cluster")
            ids.append(int(cluster_id))

            if members:
                member_rows = []
                for member in members:
                    bbox = member.get("bbox", [0, 0, 0, 0])
                    bbox_json = json.dumps(bbox, ensure_ascii=False)
                    member_rows.append(
                        (
                            cluster_id,
                            session_id,
                            member.get("photo_id", ""),
                            member.get("photo_path", ""),
                            member.get("filename", ""),
                            bbox_json,
                            member.get("confidence", 0.0),
                            member.get("observation_id") if member.get("observation_id") is not None
                            else (observation_ids_by_key or {}).get((member.get("photo_id", ""), bbox_json)),
                        )
                    )
                self._conn.executemany(
                    "INSERT INTO face_cluster_members "
                    "(cluster_id, session_id, photo_id, photo_path, filename, bbox, confidence, observation_id) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    member_rows,
                )
        return ids

    def save_analysis_bundle(
        self,
        session_id: str,
        observations: list[dict[str, Any]],
        clusters: list[dict[str, Any]],
    ) -> list[int]:
        """Persist observations and clusters atomically and return cluster IDs."""
        with self._lock, self._transaction():
            inserted_rows = self._insert_observations(session_id, observations) if observations else []
            observation_ids_by_key: dict[tuple[str, str], int] = {
                (pid, bj): oid for oid, pid, bj in inserted_rows
            }

            if observations:
                obs_keys = [
                    (
                    obs.get("photo_id", ""),
                        json.dumps(obs.get("bbox", [0, 0, 0, 0]), ensure_ascii=False),
                    )
                    for obs in observations
                ]
                missing_keys = [k for k in obs_keys if k not in observation_ids_by_key]
                if missing_keys:
                    affected_photo_ids = list({k[0] for k in missing_keys})
                    placeholders = ",".join("?" * len(affected_photo_ids))
                    existing = self._conn.execute(
                        f"SELECT id, photo_id, bbox_x, bbox_y, bbox_w, bbox_h "
                        f"FROM face_observations WHERE photo_id IN ({placeholders}) AND session_id = ?",
                        (*affected_photo_ids, session_id),
                    ).fetchall()
                    for row in existing:
                        bbox_json = json.dumps(
                            [row["bbox_x"], row["bbox_y"], row["bbox_w"], row["bbox_h"]],
                            ensure_ascii=False,
                        )
                        key = (row["photo_id"], bbox_json)
                        if key not in observation_ids_by_key:
                            observation_ids_by_key[key] = row["id"]

            cluster_ids = self._insert_clusters_with_members(
                session_id, clusters, observation_ids_by_key
            )
        return cluster_ids

    def get_observations(self, session_id: str) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM face_observations WHERE session_id = ? ORDER BY id",
                (session_id,),
            ).fetchall()
        results: list[dict[str, Any]] = []
        for r in rows:
            d = dict(r)
            d["bbox"] = [d["bbox_x"], d["bbox_y"], d["bbox_w"], d["bbox_h"]]
            emb = d["embedding"]
            if isinstance(emb, bytes):
                d["embedding"] = np.frombuffer(emb, dtype=np.float32).tolist()
            else:
                d["embedding"] = json.loads(emb)
            results.append(d)
        return results

    def get_completed_photo_ids(self, session_id: str) -> set[str]:
        """Return set of photo_ids that already have face observations."""
        with self._lock:
            rows = self._conn.execute(
                "SELECT DISTINCT photo_id FROM face_observations WHERE session_id = ?",
                (session_id,),
            ).fetchall()
        return {r["photo_id"] for r in rows}

    def delete_observations(self, session_id: str) -> None:
        with self._lock:
            self._conn.execute("DELETE FROM face_observations WHERE session_id = ?", (session_id,))
            self._conn.commit()

    # ------------------------------------------------------------------
    # Face clusters
    # ------------------------------------------------------------------

    def save_clusters(self, session_id: str, clusters: list[dict[str, Any]]) -> list[int]:
        """Insert face clusters and members; return cluster row IDs."""
        if not clusters:
            return []
        with self._lock, self._transaction():
            ids = self._insert_clusters_with_members(session_id, clusters)
        return ids

    def get_clusters(self, session_id: str, *, include_members: bool = True) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM face_clusters WHERE session_id = ? ORDER BY id",
                (session_id,),
            ).fetchall()
            if include_members:
                member_rows = self._conn.execute(
                    "SELECT * FROM face_cluster_members WHERE session_id = ? ORDER BY id",
                    (session_id,),
                ).fetchall()
            else:
                member_rows = []
        members_by_cluster: dict[int, list[dict[str, Any]]] = {}
        for r in member_rows:
            d = dict(r)
            try:
                bbox = json.loads(d.get("bbox") or "[0, 0, 0, 0]")
            except json.JSONDecodeError:
                bbox = [0, 0, 0, 0]
            member = {
                "photo_id": d.get("photo_id", ""),
                "photo_path": d.get("photo_path", ""),
                "filename": d.get("filename", ""),
                "bbox": bbox,
                "confidence": d.get("confidence", 0.0),
            }
            if d.get("observation_id") is not None:
                member["observation_id"] = d["observation_id"]
            members_by_cluster.setdefault(d["cluster_id"], []).append(member)

        clusters: list[dict[str, Any]] = []
        for r in rows:
            d = dict(r)
            members = members_by_cluster.get(d["id"], [])
            d["members"] = members
            clusters.append(d)
        return clusters

    def update_cluster(self, cluster_id: int, **kwargs: Any) -> None:
        """Update fields on a face cluster row."""
        allowed = {"label", "representative_obs_id", "member_count", "status"}
        updates = {k: v for k, v in kwargs.items() if k in allowed}
        if not updates:
            return
        if "status" in updates:
            valid_statuses = {s.value for s in ClusterBindingStatus}
            if updates["status"] not in valid_statuses:
                raise ValueError(f"Invalid cluster status: {updates['status']!r}. Must be one of {valid_statuses}")
        set_clause = ", ".join(f"{k} = ?" for k in updates)
        values = list(updates.values()) + [cluster_id]
        with self._lock:
            self._conn.execute(
                f"UPDATE face_clusters SET {set_clause} WHERE id = ?",
                values,
            )
            self._conn.commit()

    def replace_cluster_members(
        self,
        session_id: str,
        cluster_id: int,
        members: list[dict[str, Any]],
    ) -> None:
        """Replace persisted members for one cluster and sync member_count."""
        with self._lock, self._transaction():
            row = self._conn.execute(
                "SELECT id FROM face_clusters WHERE id = ? AND session_id = ?",
                (cluster_id, session_id),
            ).fetchone()
            if row is None:
                raise ValueError(f"Cluster not found: {cluster_id}")
            self._conn.execute(
                "DELETE FROM face_cluster_members WHERE cluster_id = ?",
                (cluster_id,),
            )
            for member in members:
                self._conn.execute(
                    "INSERT INTO face_cluster_members "
                    "(cluster_id, session_id, photo_id, photo_path, filename, bbox, confidence, observation_id) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        cluster_id,
                        session_id,
                        member.get("photo_id", ""),
                        member.get("photo_path", ""),
                        member.get("filename", ""),
                        json.dumps(member.get("bbox", [0, 0, 0, 0]), ensure_ascii=False),
                        member.get("confidence", 0.0),
                        member.get("observation_id"),
                    ),
                )

    def delete_clusters(self, session_id: str) -> None:
        with self._lock:
            self._conn.execute("DELETE FROM face_clusters WHERE session_id = ?", (session_id,))
            self._conn.commit()

    def delete_cluster(self, cluster_id: int) -> bool:
        """Delete a single face cluster by its primary key."""
        with self._lock:
            cur = self._conn.execute("DELETE FROM face_clusters WHERE id = ?", (cluster_id,))
            self._conn.commit()
            return cur.rowcount > 0

    def merge_clusters_db(
        self,
        session_id: str,
        source_id: int,
        target_id: int,
        merged_members: list[dict[str, Any]],
    ) -> None:
        """Atomically merge source cluster into target in a single transaction."""
        with self._lock, self._transaction():
            src_binding = self._conn.execute(
                "SELECT role_name, keywords, notes FROM role_bindings WHERE session_id = ? AND cluster_id = ?",
                (session_id, source_id),
            ).fetchone()
            tgt_binding = self._conn.execute(
                "SELECT id FROM role_bindings WHERE session_id = ? AND cluster_id = ?",
                (session_id, target_id),
            ).fetchone()
            if src_binding and not tgt_binding:
                self._conn.execute(
                    "INSERT OR REPLACE INTO role_bindings (cluster_id, session_id, role_name, keywords, notes) VALUES (?, ?, ?, ?, ?)",
                    (target_id, session_id, src_binding["role_name"], src_binding["keywords"], src_binding["notes"]),
                )

            self._conn.execute(
                "DELETE FROM face_cluster_members WHERE cluster_id = ?",
                (target_id,),
            )
            for member in merged_members:
                self._conn.execute(
                    "INSERT INTO face_cluster_members "
                    "(cluster_id, session_id, photo_id, photo_path, filename, bbox, confidence, observation_id) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        target_id,
                        session_id,
                        member.get("photo_id", ""),
                        member.get("photo_path", ""),
                        member.get("filename", ""),
                        json.dumps(member.get("bbox", [0, 0, 0, 0]), ensure_ascii=False),
                        member.get("confidence", 0.0),
                        member.get("observation_id"),
                    ),
                )
            self._conn.execute("DELETE FROM face_clusters WHERE id = ?", (source_id,))
            self._conn.execute(
                "DELETE FROM role_bindings WHERE session_id = ? AND cluster_id = ?",
                (session_id, source_id),
            )

    # ------------------------------------------------------------------
    # Role bindings
    # ------------------------------------------------------------------

    def save_binding(self, session_id: str, cluster_id: int, role_name: str, keywords: list[str], notes: str = "") -> int:
        """Insert or replace a role binding. Returns the row id."""
        kw_json = json.dumps(keywords, ensure_ascii=False)
        with self._lock, self._transaction():
            cluster = self._conn.execute(
                "SELECT id FROM face_clusters WHERE id = ? AND session_id = ?",
                (cluster_id, session_id),
            ).fetchone()
            if cluster is None:
                raise ValueError(f"Cluster not found: {cluster_id}")
            self._conn.execute(
                "INSERT OR REPLACE INTO role_bindings "
                "(cluster_id, session_id, role_name, keywords, notes) "
                "VALUES (?, ?, ?, ?, ?)",
                (cluster_id, session_id, role_name, kw_json, notes),
            )
            self._conn.execute(
                "UPDATE face_clusters SET status = 'bound' WHERE id = ?",
                (cluster_id,),
            )
            row = self._conn.execute("SELECT id FROM role_bindings WHERE cluster_id = ?", (cluster_id,)).fetchone()
            return row["id"] if row else 0

    def delete_binding(self, session_id: str, cluster_id: int) -> bool:
        with self._lock, self._transaction():
            cur = self._conn.execute(
                "DELETE FROM role_bindings WHERE session_id = ? AND cluster_id = ?",
                (session_id, cluster_id),
            )
            if cur.rowcount > 0:
                self._conn.execute(
                    "UPDATE face_clusters SET status = 'unbound' WHERE id = ?",
                    (cluster_id,),
                )
            return cur.rowcount > 0

    def get_bindings(self, session_id: str) -> dict[int, dict[str, Any]]:
        """Return bindings keyed by cluster_id (as int)."""
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM role_bindings WHERE session_id = ?",
                (session_id,),
            ).fetchall()
        result: dict[int, dict[str, Any]] = {}
        for r in rows:
            d = dict(r)
            d["keywords"] = json.loads(d["keywords"])
            result[d["cluster_id"]] = d
        return result

    # ------------------------------------------------------------------
    # Writeback items
    # ------------------------------------------------------------------

    def save_writeback_items(self, session_id: str, items: list[dict[str, Any]]) -> list[int]:
        """Insert writeback tracking items. Returns row IDs."""
        if not items:
            return []
        with self._lock, self._transaction():
            ids: list[int] = []
            for item in items:
                cur = self._conn.execute(
                    "INSERT INTO writeback_items "
                    "(photo_id, session_id, keywords, xmp_path, backup_path, xmp_status, error_message) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?) "
                    "RETURNING id",
                    (
                        item["photo_id"],
                        session_id,
                        json.dumps(item.get("keywords", []), ensure_ascii=False),
                        item.get("xmp_path", ""),
                        item.get("backup_path", ""),
                        item.get("xmp_status", "pending"),
                        item.get("error_message", ""),
                    ),
                )
                row = cur.fetchone()
                if row is None:
                    raise RuntimeError("Failed to persist writeback item")
                ids.append(row[0])
        return ids

    def get_writeback_items(self, session_id: str) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM writeback_items WHERE session_id = ? ORDER BY id",
                (session_id,),
            ).fetchall()
        results: list[dict[str, Any]] = []
        for r in rows:
            d = dict(r)
            d["keywords"] = json.loads(d["keywords"])
            results.append(d)
        return results

    def update_writeback_item_status(self, item_id: int, status: str, error_message: str = "") -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE writeback_items SET xmp_status = ?, error_message = ? WHERE id = ?",
                (status, error_message, item_id),
            )
            self._conn.commit()

    def delete_writeback_items(self, session_id: str) -> None:
        with self._lock:
            self._conn.execute("DELETE FROM writeback_items WHERE session_id = ?", (session_id,))
            self._conn.commit()

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # ------------------------------------------------------------------
    # Similarity hash / result persistence (V6)
    # ------------------------------------------------------------------

    def get_similarity_hashes(self, session_id: str) -> dict[str, str]:
        """Return {filepath: hash_hex} for all cached similarity hashes."""
        with self._lock:
            rows = self._conn.execute(
                "SELECT p.filepath, sh.hash_hex FROM similarity_hashes sh "
                "JOIN photos p ON p.id = sh.photo_id "
                "WHERE sh.session_id = ?",
                (session_id,),
            ).fetchall()
        return {row["filepath"]: row["hash_hex"] for row in rows}

    def save_similarity_hash(self, session_id: str, filepath: str, hash_hex: str) -> None:
        """Persist a single similarity hash (idempotent via INSERT OR IGNORE)."""
        with self._lock:
            photo_row = self._conn.execute(
                "SELECT id FROM photos WHERE session_id = ? AND filepath = ?",
                (session_id, filepath),
            ).fetchone()
            if photo_row:
                self._conn.execute(
                    "INSERT OR IGNORE INTO similarity_hashes (session_id, photo_id, hash_hex) VALUES (?, ?, ?)",
                    (session_id, photo_row["id"], hash_hex),
                )
                self._conn.commit()
            else:
                logger.warning("Cannot persist similarity hash: photo not found for %s in session %s", filepath, session_id)

    def save_similarity_hashes_batch(self, session_id: str, items: list[tuple]) -> None:
        """Persist multiple similarity hashes in a single transaction.

        items: list of (filepath, hash_hex) tuples.
        Does one SELECT to resolve photo_ids, one executemany INSERT, one commit.
        """
        if not items:
            return
        with self._lock, self._transaction():
            filepaths = [fp for fp, _ in items]
            placeholders = ",".join("?" * len(filepaths))
            rows = self._conn.execute(
                f"SELECT id, filepath FROM photos WHERE session_id = ? AND filepath IN ({placeholders})",
                (session_id, *filepaths),
            ).fetchall()
            photo_id_map = {r["filepath"]: r["id"] for r in rows}
            insert_rows = []
            for fp, hex_str in items:
                pid = photo_id_map.get(fp)
                if pid:
                    insert_rows.append((session_id, pid, hex_str))
            if insert_rows:
                self._conn.executemany(
                    "INSERT OR IGNORE INTO similarity_hashes (session_id, photo_id, hash_hex) VALUES (?, ?, ?)",
                    insert_rows,
                )
            with suppress(sqlite3.OperationalError):
                self._db.checkpoint()

    def save_similarity_result(
        self,
        session_id: str,
        groups_json: str,
        stats_json: str,
        threshold: int,
        min_group_size: int,
        snapshot_json: str | None = None,
    ) -> None:
        """Save similarity analysis results.

        Args:
            session_id: The session to persist results for.
            groups_json: Serialized groups list (used only when snapshot_json is None).
            stats_json: Serialized stats dict.
            threshold: The similarity threshold parameter used.
            min_group_size: The minimum group size parameter used.
            snapshot_json: When provided, stored instead of groups_json for
                full result snapshots. groups_json is ignored in this case.
        """
        groups_payload = snapshot_json if snapshot_json is not None else groups_json
        with self._lock, self._transaction():
            self._conn.execute(
                "DELETE FROM similarity_results WHERE session_id = ?",
                (session_id,),
            )
            self._conn.execute(
                "INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size) "
                "VALUES (?, ?, ?, ?, ?)",
                (session_id, groups_payload, stats_json, threshold, min_group_size),
            )
        with suppress(sqlite3.OperationalError):
            self._db.checkpoint()

    def get_similarity_cached_result(self, session_id: str) -> dict[str, Any] | None:
        """Return the most recent cached similarity result, regardless of threshold."""
        with self._lock:
            row = self._conn.execute(
                "SELECT groups_json, stats_json FROM similarity_results "
                "WHERE session_id = ? ORDER BY created_at DESC LIMIT 1",
                (session_id,),
            ).fetchone()
        if row is None:
            return None
        try:
            groups_payload = json.loads(row["groups_json"])
        except json.JSONDecodeError:
            logger.warning("Corrupted similarity result JSON for session %s", session_id)
            return None
        try:
            stats_payload = json.loads(row["stats_json"])
        except json.JSONDecodeError:
            logger.warning("Corrupted similarity stats JSON for session %s", session_id)
            return None
        if isinstance(groups_payload, dict):
            return groups_payload
        return {
            "groups": groups_payload,
            "stats": stats_payload,
        }
