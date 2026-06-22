# face_keywording/service.py - FaceKeywordingService: business logic layer.
#
# Encapsulates all face-keywording operations (session CRUD, analysis,
# cluster management, role binding, writeback) so that the engine and
# IPC handlers become thin adapters.
#
# Thread safety: a single threading.Lock protects mutable in-memory
# caches; SQLite (WAL mode) is the source of truth for persistence.

from __future__ import annotations

import logging
import os
import threading
from collections.abc import Callable
from typing import Any

from shared.base_service import BaseService
from shared.models import (
    AnalysisStatus,
    SessionStatus,
    WritebackStatus,
)
from shared.session_manager import SessionManager
from shared.thumbnail import generate_thumbnail

logger = logging.getLogger("gather.fkw")


def _friendly_error(exc: Exception) -> str:
    """Convert raw exceptions to user-friendly bilingual messages."""
    msg = str(exc).lower()
    if "no faces" in msg or "not detect" in msg:
        return "No faces detected. Ensure photos contain faces / 未检测到人脸"
    if "modulenotfound" in msg or "importerror" in msg or "no module named" in msg:
        return "Face detection library not installed. Run: pip install mediapipe face-recognition / 人脸检测库未安装"
    if "file not found" in msg or "no such file" in msg:
        return "Photo file not found. Check file path / 照片文件未找到"
    if "memory" in msg or "allocation" in msg:
        return "Out of memory. Try with fewer photos / 内存不足"
    if "permission" in msg:
        return "Permission denied. Check photo directory permissions / 文件权限不足"
    return f"Analysis error. Please retry. Detail: {exc} / 分析出错，请重试"


class FaceKeywordingService(BaseService):
    """Central business logic for the face keywording submodule."""

    @staticmethod
    def _save_analysis_to_db(
        manager: SessionManager, session_id: str, detections: list, clusters_out: list, photo_map: dict
    ) -> list[dict[str, Any]]:
        """Persist analysis results to SQLite for checkpoint/resume support.

        Args:
            manager: SessionManager instance (injected, not singleton).
            session_id: Session UUID.
            detections: Face detection results keyed by filepath.
            clusters_out: Cluster summaries for save_clusters().
            photo_map: Dict mapping filepath -> Photo dict (for UUID lookup).
        """
        all_observations: list = []
        for detection in detections:
            photo_path = detection.get("photo_path", "")
            photo_obj = photo_map.get(photo_path, {})
            photo_id = photo_obj.get("id", "")
            if not photo_id:
                raise ValueError(f"Cannot persist face observations; photo not found in session: {photo_path}")
            for face in detection.get("faces", []):
                embedding = face.get("embedding", [])
                all_observations.append(
                    {
                        "photo_id": photo_id,
                        "bbox": face.get("bbox", [0, 0, 1, 1]),
                        "embedding": embedding if embedding else [],
                        "confidence": face.get("confidence", 0.0),
                    }
                )

        if not clusters_out:
            if all_observations:
                manager.save_analysis_bundle(session_id, all_observations, [])
            return []

        cluster_ids = manager.save_analysis_bundle(session_id, all_observations, clusters_out)
        persisted: list[dict[str, Any]] = []
        if len(clusters_out) != len(cluster_ids):
            raise RuntimeError(f"Cluster count mismatch: {len(clusters_out)} vs {len(cluster_ids)}")
        for cluster, db_id in zip(clusters_out, cluster_ids, strict=True):
            persisted_cluster = dict(cluster)
            persisted_cluster["cluster_id"] = str(db_id)
            persisted_cluster["size"] = len(persisted_cluster.get("members", []))
            persisted.append(persisted_cluster)
        return persisted

    def __init__(
        self,
        manager: SessionManager,
        progress_callback: Callable[[str, int, int, str, str], None] | None = None,
    ) -> None:
        super().__init__()
        self._manager = manager
        self._default_progress_callback = progress_callback

        self._progress_callbacks: dict[str, Callable[[str, int, int, str, str], None] | None] = {}

        self._clusters_cache: dict[str, list[dict[str, Any]]] = {}
        self._bindings_cache: dict[str, dict[str, dict[str, Any]]] = {}
        self._progress_cache: dict[str, dict[str, Any]] = {}
        self._photo_map_cache: dict[str, dict[str, dict[str, Any]]] = {}
        self._session_locks: dict[str, threading.Lock] = {}
        self._register_cache(
            self._clusters_cache,
            self._bindings_cache,
            self._progress_cache,
            self._photo_map_cache,
            self._progress_callbacks,
        )
        self._active_analysis_sessions: set[str] = set()

    def shutdown(self) -> None:
        """Join all daemon analysis threads before app exit to avoid corrupting SQLite."""
        with self._state_lock:
            self._active_analysis_sessions.clear()
        super().shutdown()

    def reset_stale_running_sessions(self) -> None:
        sessions = self._manager.list_sessions()
        for s in sessions:
            if s.analysis_status == AnalysisStatus.RUNNING:
                logger.info("Resetting stale RUNNING status for session %s", s.id)
                self._manager.update_analysis_status(s.id, AnalysisStatus.IDLE)
                with self._state_lock:
                    self._progress_cache.pop(s.id, None)
                    self._cancel_events.pop(s.id, None)
                    self._active_analysis_sessions.discard(s.id)
        for s in sessions:
            if s.writeback_status == WritebackStatus.RUNNING:
                logger.info("Resetting stale writeback RUNNING status for session %s", s.id)
                self._manager.update_writeback_session_status(s.id, WritebackStatus.IDLE)

    def _check_cancelled(self, cancel_event: threading.Event, session_id: str) -> bool:
        if cancel_event.is_set():
            self._manager.update_analysis_status(session_id, AnalysisStatus.CANCELLED)
            with self._state_lock:
                self._progress_cache.pop(session_id, None)
                self._cancel_events.pop(session_id, None)
            return True
        return False

    def _load_clusters_and_bindings(self, session_id: str) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
        """Return cluster/binding caches, hydrating them from SQLite as needed."""
        with self._state_lock:
            clusters = self._clusters_cache.get(session_id)
            bindings = self._bindings_cache.get(session_id)

        if clusters is None:
            db_clusters = self._manager.get_clusters(session_id)
            clusters = []
            for row in db_clusters:
                cid = str(row.get("id", row.get("cluster_id", "")))
                members = row.get("members", []) or []
                clusters.append(
                    {
                        "cluster_id": cid,
                        "label": row.get("label", f"Person-{cid}"),
                        "members": members,
                        "size": len(members) if members else row.get("member_count", 0),
                        "status": row.get("status", "unbound"),
                    }
                )
            with self._state_lock:
                self._clusters_cache[session_id] = clusters
                self._touch_cache(session_id)

        if bindings is None:
            raw_bindings = self._manager.get_bindings(session_id)
            bindings = {str(k): v for k, v in raw_bindings.items()}
            with self._state_lock:
                existing = self._bindings_cache.get(session_id)
                if existing is not None:
                    existing.update(bindings)
                    bindings = existing
                self._bindings_cache[session_id] = bindings
                self._touch_cache(session_id)

        return clusters, bindings

    # ------------------------------------------------------------------
    # Session CRUD (delegated to SessionManager)
    # ------------------------------------------------------------------

    # ------------------------------------------------------------------
    # Session CRUD removed — session operations are now handled by SessionService.
    # Internal callers (e.g. reset_stale_running_sessions) use self._manager directly.
    # ------------------------------------------------------------------

    def clear_session_caches(self, session_id: str) -> None:
        """Clear all in-memory caches for a session (used before session deletion)."""
        with self._state_lock:
            self._clusters_cache.pop(session_id, None)
            self._bindings_cache.pop(session_id, None)
            self._progress_cache.pop(session_id, None)
            self._photo_map_cache.pop(session_id, None)
            self._cancel_events.pop(session_id, None)
            self._session_locks.pop(session_id, None)
            self._progress_callbacks.pop(session_id, None)

    def update_session_status(self, session_id: str, status: str) -> None:
        """Update a session's status to any valid SessionStatus value."""
        try:
            st = SessionStatus(status)
        except ValueError as err:
            raise ValueError(f"Invalid session status: {status}") from err
        self._manager.update_session_status(session_id, st)

    # ------------------------------------------------------------------
    # Analysis
    # ------------------------------------------------------------------

    def start_analysis(self, session_id: str, **options: Any) -> dict[str, Any]:
        """Start face detection + clustering in a daemon thread."""
        session = self._manager.get_session(session_id)
        if session is None:
            raise ValueError(f"Session not found: {session_id}")

        # H4: Check + immediate state reset in single critical section
        cancel_event = threading.Event()
        with self._state_lock:
            cached_status = self._progress_cache.get(session_id, {}).get("status")
            db_session = self._manager.get_session(session_id)
            db_status = db_session.analysis_status.value if db_session else "idle"
            if cached_status == "running" or db_status == "running":
                if session_id in self._active_analysis_sessions:
                    raise ValueError("Analysis is already running for this session")
                self._progress_cache.pop(session_id, None)
                self._cancel_events.pop(session_id, None)
                self._active_analysis_sessions.discard(session_id)
                self._manager.update_analysis_status(session_id, AnalysisStatus.IDLE)
            self._cancel_events[session_id] = cancel_event
            self._progress_cache[session_id] = {"current": 0, "total": 0, "message": "Starting...", "status": "running"}
            self._clusters_cache.pop(session_id, None)
            self._bindings_cache.pop(session_id, None)
            self._active_analysis_sessions.add(session_id)

        all_photos = self._manager.get_photos(session_id)
        if not all_photos:
            with self._state_lock:
                self._progress_cache.pop(session_id, None)
                self._cancel_events.pop(session_id, None)
                self._active_analysis_sessions.discard(session_id)
            raise ValueError("No photos in session")

        # N6: Always repopulate _photo_map_cache from ALL photos, even if cache
        # already exists — otherwise photos added via add_photos() but not yet
        # in the cache (or stale entries) can cause analysis thread failures.
        with self._state_lock:
            self._photo_map_cache[session_id] = {p.filepath: p.to_dict() for p in all_photos}
            self._touch_cache(session_id)

        all_filepaths = [p.filepath for p in all_photos]

        # Checkpoint/resume: skip photos that already have observations in SQLite
        completed_photo_ids = self._manager.get_completed_photo_ids(session_id)
        photo_id_map = {p.id: p.filepath for p in all_photos}
        completed_paths = {photo_id_map[pid] for pid in completed_photo_ids if pid in photo_id_map}
        filepaths = [fp for fp in all_filepaths if fp not in completed_paths]
        skipped = len(all_filepaths) - len(filepaths)
        if skipped > 0:
            with self._state_lock:
                cb = self._progress_callbacks.get(session_id) or self._default_progress_callback
            if cb:
                cb(
                    session_id,
                    0,
                    len(all_filepaths),
                    f"Resuming: {skipped} photos already analyzed, {len(filepaths)} remaining",
                    "running",
                )
        if not filepaths:
            # All photos already analyzed; try loading from SQLite cache
            db_clusters = self._manager.get_clusters(session_id)
            if db_clusters:
                transformed = []
                for row in db_clusters:
                    cid = str(row.get("id", row.get("cluster_id", "")))
                    members = row.get("members", []) or []
                    transformed.append({
                        "cluster_id": cid,
                        "label": row.get("label", f"Person-{cid}"),
                        "members": members,
                        "size": len(members) if members else row.get("member_count", 0),
                        "status": row.get("status", "unbound"),
                    })
                with self._state_lock:
                    self._clusters_cache[session_id] = transformed
                    self._touch_cache(session_id)
                    self._progress_cache.pop(session_id, None)
                    self._cancel_events.pop(session_id, None)
                self._manager.update_analysis_status(session_id, AnalysisStatus.DONE)
                self._manager.update_session_status(session_id, SessionStatus.REVIEW)
                with self._state_lock:
                    self._active_analysis_sessions.discard(session_id)
                return {"status": "already_complete", "session_id": session_id}
            # Observations without clusters means the prior persist step was interrupted.
            # Re-run from scratch instead of treating the session as a legitimate no-face result.
            self._manager.delete_observations(session_id)
            self._manager.delete_clusters(session_id)
            with self._state_lock:
                self._progress_cache[session_id] = {
                    "current": 0,
                    "total": len(all_filepaths),
                    "message": "Detected partial cached analysis; restarting from scratch.",
                    "status": "running",
                }
            filepaths = all_filepaths
        eps = float(options.get("eps", 0.5))
        min_samples = int(options.get("min_samples", 2))

        self._manager.update_analysis_status(session_id, AnalysisStatus.RUNNING)
        self._manager.update_session_status(session_id, SessionStatus.ANALYZING)

        def _progress(current: int, total: int, message: str, status: str = "running") -> None:
            with self._state_lock:
                self._progress_cache[session_id] = {
                    "current": current,
                    "total": total,
                    "message": message,
                    "status": status,
                }
                cb = self._progress_callbacks.get(session_id) or self._default_progress_callback
            if cb:
                cb(session_id, current, total, message, status)

        all_filepaths_len = len(all_filepaths)

        def _run() -> None:
            try:
                from .face_engine import cluster_faces, detect_faces

                if self._check_cancelled(cancel_event, session_id):
                    return

                _progress(0, len(filepaths), "Detecting faces...")
                detections = detect_faces(filepaths, progress_callback=_progress, cancel_event=cancel_event)

                if self._check_cancelled(cancel_event, session_id):
                    return

                _progress(0, len(filepaths), "Clustering faces...")
                cluster_result = cluster_faces(detections, eps=eps, min_samples=min_samples)

                if self._check_cancelled(cancel_event, session_id):
                    return

                # Build cluster output
                with self._state_lock:
                    photo_map_snapshot = dict(self._photo_map_cache.get(session_id, {}))
                clusters_out: list[dict] = []
                for cl in cluster_result.get("clusters", []):
                    members_out: list[dict] = []
                    for m in cl["members"]:
                        photo_obj = photo_map_snapshot.get(m["photo_path"], {})
                        members_out.append(
                            {
                                "photo_id": photo_obj.get("id", ""),
                                "photo_path": m["photo_path"],
                                "filename": os.path.basename(m["photo_path"]),
                                "bbox": m["bbox"],
                                "confidence": m.get("confidence", 0.0),
                            }
                        )
                    clusters_out.append(
                        {
                            "cluster_id": cl["cluster_id"],
                            "members": members_out,
                            "size": cl["size"],
                            "label": f"Person-{cl['cluster_id'] + 1:02d}",
                        }
                    )

                noise_out: list[dict] = []
                for n in cluster_result.get("noise", []):
                    photo_obj = photo_map_snapshot.get(n["photo_path"], {})
                    noise_out.append(
                        {
                            "photo_id": photo_obj.get("id", ""),
                            "photo_path": n["photo_path"],
                            "filename": os.path.basename(n["photo_path"]),
                            "bbox": n["bbox"],
                            "confidence": n.get("confidence", 0.0),
                        }
                    )

                # Persist to SQLite for checkpoint/resume
                persisted_clusters = self._save_analysis_to_db(
                    self._manager, session_id, detections, clusters_out, photo_map_snapshot
                )

                # N17: re-check cancel BEFORE setting progress to "done"
                if self._check_cancelled(cancel_event, session_id):
                    self._manager.update_session_status(session_id, SessionStatus.REVIEW)
                    return

                with self._state_lock:
                    self._clusters_cache[session_id] = persisted_clusters
                    self._touch_cache(session_id)
                    self._progress_cache[session_id] = {
                        "current": len(filepaths),
                        "total": len(filepaths),
                        "message": "Analysis complete",
                        "status": "done",
                    }

                self._manager.update_analysis_status(session_id, AnalysisStatus.DONE)
                self._manager.update_session_status(session_id, SessionStatus.REVIEW)

                with self._state_lock:
                    cb = self._progress_callbacks.get(session_id) or self._default_progress_callback
                if cb:
                    cb(session_id, len(filepaths), len(filepaths), "Analysis complete", "done")

            except Exception as exc:
                logger.exception("Analysis failed for session %s", session_id)
                with self._state_lock:
                    self._progress_cache[session_id] = {
                        "current": 0,
                        "total": all_filepaths_len,
                        "message": _friendly_error(exc),
                        "status": "failed",
                    }
                self._manager.update_analysis_status(session_id, AnalysisStatus.FAILED)
                self._manager.update_session_status(session_id, SessionStatus.REVIEW)
            finally:
                with self._state_lock:
                    ct = threading.current_thread()
                    if ct in self._analysis_threads:
                        self._analysis_threads.remove(ct)
                    self._active_analysis_sessions.discard(session_id)

        thread = threading.Thread(
            target=_run,
            name=f"facekw-analyze-{session_id[:8]}",
            daemon=False,
        )
        thread.start()
        with self._state_lock:
            self._analysis_threads.append(thread)

        return {"status": "started", "session_id": session_id}

    def set_progress_callback(self, session_id: str, callback: Callable[[str, int, int, str, str], None] | None = None) -> None:
        """Register a per-session progress callback (thread-safe).
        This avoids the race condition that would occur if multiple clients
        simultaneously set a single _progress_callback attribute."""
        with self._state_lock:
            self._progress_callbacks[session_id] = callback

    def cancel_analysis(self, session_id: str) -> dict[str, Any]:
        """Cancel a running face keywording analysis for the given session."""
        with self._state_lock:
            cancel_event = self._cancel_events.pop(session_id, None)
            self._progress_cache.pop(session_id, None)
        if cancel_event is not None:
            cancel_event.set()
            self._manager.update_analysis_status(session_id, AnalysisStatus.CANCELLED)
        return {"status": "cancelled", "session_id": session_id}

    # ------------------------------------------------------------------
    # Clusters
    # ------------------------------------------------------------------

    def get_clusters(self, session_id: str) -> dict[str, Any]:
        """Get face clusters with binding status."""
        clusters, bindings = self._load_clusters_and_bindings(session_id)

        with self._state_lock:
            progress = self._progress_cache.get(session_id, {})

        if progress.get("status") == "failed":
            return {
                "clusters": [],
                "noise": [],
                "analysis_done": False,
                "error": progress.get("message", "Analysis failed"),
            }

        if not clusters:
            analysis_done = progress.get("status") == "done"
            status_val = progress.get("status", "idle")
            return {"clusters": [], "noise": [], "analysis_done": analysis_done, "analysis_status": status_val}

        clusters_out: list[dict] = []
        for cl in clusters:
            cid = str(cl["cluster_id"])
            cluster_data = dict(cl)
            if cid in bindings:
                cluster_data["binding"] = {
                    "role_name": bindings[cid].get("role_name", ""),
                    "keywords": bindings[cid].get("keywords", []),
                }
                cluster_data["status"] = "bound"
            else:
                cluster_data["status"] = "unbound"
            clusters_out.append(cluster_data)

        analysis_done = progress.get("status") == "done"
        status_val = progress.get("status", "idle")

        return {
            "clusters": clusters_out,
            "noise": [],
            "analysis_done": analysis_done,
            "analysis_status": status_val,
        }

    def get_cluster_thumbnail_base64(self, clusters: dict) -> dict:
        """Enrich cluster dicts with thumbnail_base64 for each cluster."""
        updated = dict(clusters)
        cluster_list = [dict(c) for c in updated.get("clusters", [])]
        for c in cluster_list:
            try:
                members = c.get("members") or []
                if not members:
                    c["thumbnail_base64"] = None
                    continue
                first = members[0]
                path = first.get("photo_path", "")
                if not path or not os.path.isfile(path):
                    c["thumbnail_base64"] = None
                    continue
                bbox = first.get("bbox", [])
                if len(bbox) != 4:
                    c["thumbnail_base64"] = None
                    continue
                c["thumbnail_base64"] = generate_thumbnail(path, size=200, bbox=list(bbox))
            except Exception:
                c["thumbnail_base64"] = None
        updated["clusters"] = cluster_list
        return updated

    def get_thumbnail(self, path: str, bbox: list) -> dict:
        if not os.path.isfile(path):
            return {"thumbnail_base64": None}
        try:
            thumb = generate_thumbnail(path, size=200, bbox=bbox)
            return {"thumbnail_base64": thumb}
        except Exception:
            logger.debug("Failed to generate cluster thumbnail", exc_info=True)
            return {"thumbnail_base64": None}

    def bind_role(self, session_id: str, cluster_id: str, role_name: str, keywords: list[str]) -> dict[str, Any]:
        if not cluster_id or not role_name:
            raise ValueError("cluster_id and role_name are required")

        try:
            int_cluster_id = int(cluster_id)
        except (TypeError, ValueError) as err:
            raise ValueError(f"Invalid cluster_id: {cluster_id}") from err

        if int_cluster_id < 0:
            raise ValueError(f"Invalid cluster_id (must be >= 0): {cluster_id}")

        with self._state_lock:
            session_lock = self._session_locks.setdefault(session_id, threading.Lock())
        with session_lock, self._state_lock:
            self._manager.save_binding(session_id, int_cluster_id, role_name, keywords)
            bindings = self._bindings_cache.setdefault(session_id, {})
            bindings[cluster_id] = {
                "role_name": role_name,
                "keywords": keywords,
            }
            clusters = self._clusters_cache.get(session_id, [])
            for cl in clusters:
                if str(cl.get("cluster_id")) == cluster_id:
                    cl["binding"] = {"role_name": role_name, "keywords": keywords}
                    cl["status"] = "bound"
                    break
            self._touch_cache(session_id)

        return {"status": "ok", "cluster_id": cluster_id}

    def unbind_role(self, session_id: str, cluster_id: str) -> dict[str, Any]:
        try:
            int_cluster_id = int(cluster_id)
        except (TypeError, ValueError) as err:
            raise ValueError(f"Invalid cluster_id: {cluster_id}") from err

        if int_cluster_id < 0:
            raise ValueError(f"Invalid cluster_id (must be >= 0): {cluster_id}")

        with self._state_lock:
            session_lock = self._session_locks.setdefault(session_id, threading.Lock())
        with session_lock, self._state_lock:
            self._manager.delete_binding(session_id, int_cluster_id)
            bindings = self._bindings_cache.get(session_id, {})
            bindings.pop(cluster_id, None)
            clusters = self._clusters_cache.get(session_id, [])
            for cl in clusters:
                if str(cl.get("cluster_id")) == cluster_id:
                    cl.pop("binding", None)
                    cl["status"] = "unbound"
                    break
            self._touch_cache(session_id)

        return {"status": "ok", "cluster_id": cluster_id}

    def merge_clusters(self, session_id: str, source_id: str, target_id: str) -> dict[str, Any]:
        if source_id == target_id:
            raise ValueError("Cannot merge a cluster into itself")

        try:
            int_source = int(source_id)
            int_target = int(target_id)
        except (TypeError, ValueError) as err:
            raise ValueError(f"Invalid cluster_id: source={source_id}, target={target_id}") from err

        if int_source < 0:
            raise ValueError(f"Invalid cluster_id (must be >= 0): source={source_id}")
        if int_target < 0:
            raise ValueError(f"Invalid cluster_id (must be >= 0): target={target_id}")

        with self._state_lock:
            session_lock = self._session_locks.setdefault(session_id, threading.Lock())
        with session_lock, self._state_lock:
            clusters = self._clusters_cache.get(session_id, [])
            source_cluster = None
            target_cluster = None
            for cl in clusters:
                if str(cl["cluster_id"]) == source_id:
                    source_cluster = cl
                if str(cl["cluster_id"]) == target_id:
                    target_cluster = cl

            if source_cluster is None or target_cluster is None:
                raise ValueError("Cluster not found")

            merged_members = target_cluster["members"] + source_cluster["members"]

            self._manager.merge_clusters_db(session_id, int_source, int_target, merged_members)

            new_clusters_list = [c for c in clusters if c is not source_cluster]
            bindings = dict(self._bindings_cache.get(session_id, {}))
            if source_id in bindings:
                if target_id not in bindings:
                    bindings[target_id] = bindings.pop(source_id)
                else:
                    bindings.pop(source_id)

            target_cluster["members"] = merged_members
            target_cluster["size"] = len(merged_members)
            self._clusters_cache[session_id] = new_clusters_list
            self._bindings_cache[session_id] = bindings
            self._touch_cache(session_id)

        return {"status": "ok", "target_id": target_id}

    def remove_member(self, session_id: str, cluster_id: str, photo_id: str) -> dict[str, Any]:
        try:
            int_cluster_id = int(cluster_id)
        except (TypeError, ValueError) as err:
            raise ValueError(f"Invalid cluster_id: {cluster_id}") from err

        if int_cluster_id < 0:
            raise ValueError(f"Invalid cluster_id (must be >= 0): {cluster_id}")

        with self._state_lock:
            session_lock = self._session_locks.setdefault(session_id, threading.Lock())
        with session_lock, self._state_lock:
            new_members: list[dict[str, Any]] = []
            target_cluster = None
            clusters = self._clusters_cache.get(session_id, [])
            for cl in clusters:
                if str(cl["cluster_id"]) == cluster_id:
                    new_members = [m for m in cl["members"] if m["photo_id"] != photo_id]
                    target_cluster = cl
                    break

            if target_cluster is not None:
                self._manager.replace_cluster_members(session_id, int_cluster_id, new_members)
                target_cluster["members"] = new_members
                target_cluster["size"] = len(new_members)
                self._touch_cache(session_id)
            else:
                db_clusters = self._manager.get_clusters(session_id)
                for db_cl in db_clusters:
                    if str(db_cl.get("id", "")) == cluster_id:
                        members = db_cl.get("members", []) or []
                        new_members = [m for m in members if m.get("photo_id") != photo_id]
                        self._manager.replace_cluster_members(session_id, int_cluster_id, new_members)
                        return {"status": "ok"}
                raise ValueError(f"Cluster {cluster_id} not found")

        return {"status": "ok"}

    # ------------------------------------------------------------------
    # Preview / Writeback / Cleanup
    # ------------------------------------------------------------------

    def preview_writeback(self, session_id: str) -> dict[str, Any]:
        clusters, bindings = self._load_clusters_and_bindings(session_id)

        photo_keywords: dict[str, dict[str, Any]] = {}

        for cl in clusters:
            cid = str(cl["cluster_id"])
            binding = bindings.get(cid)
            if not binding:
                continue

            keywords = binding["keywords"]
            for member in cl["members"]:
                path = member["photo_path"]
                if path not in photo_keywords:
                    photo_keywords[path] = {
                        "photo_path": path,
                        "filename": member["filename"],
                        "keywords": [],
                        "sources": [],
                    }
                pk = photo_keywords[path]
                for kw in keywords:
                    if kw not in pk["keywords"]:
                        pk["keywords"].append(kw)
                pk["sources"].append(
                    {
                        "role_name": binding["role_name"],
                        "keywords": keywords,
                    }
                )

        preview_list = list(photo_keywords.values())
        total_assigned = sum(1 for p in preview_list if p["keywords"])
        total_no_keywords = sum(1 for p in preview_list if not p["keywords"])

        return {
            "photos": preview_list,
            "stats": {
                "total_photos": len(preview_list),
                "with_keywords": total_assigned,
                "without_keywords": total_no_keywords,
            },
        }

    def execute_writeback(self, session_id: str) -> dict[str, Any]:
        from .writeback import write_keywords

        session = self._manager.get_session(session_id)
        if session is None:
            raise ValueError(f"Session not found: {session_id}")
        if session.writeback_status == WritebackStatus.DONE:
            raise RuntimeError("Writeback already completed for this session")

        if not self._manager.try_start_writeback(session_id):
            raise RuntimeError("Writeback already in progress")
        clusters, bindings = self._load_clusters_and_bindings(session_id)

        keywords_map: dict[str, list[str]] = {}

        for cl in clusters:
            cid = str(cl["cluster_id"])
            binding = bindings.get(cid)
            if not binding:
                continue

            keywords = binding["keywords"]
            for member in cl["members"]:
                path = member["photo_path"]
                if path not in keywords_map:
                    keywords_map[path] = []
                for kw in keywords:
                    if kw not in keywords_map[path]:
                        keywords_map[path].append(kw)

        photo_paths = list(keywords_map.keys())

        # Phase 1: Persist pending audit items FIRST so that if XMP write
        # fails later, the audit trail shows pending items that can be retried.
        photo_filepaths = self._manager.get_photo_filepaths(session_id)
        photo_id_map = {p["filepath"]: p["id"] for p in photo_filepaths}
        writeback_items = []
        writeback_paths: list[str] = []
        for path, keywords in keywords_map.items():
            xmp_path = path + ".xmp"
            photo_id = photo_id_map.get(path, "")
            if photo_id:
                writeback_items.append(
                    {
                        "photo_id": photo_id,
                        "keywords": keywords,
                        "xmp_path": xmp_path,
                        "backup_path": xmp_path + ".gatherbak",
                        "xmp_status": "pending",
                        "error_message": "",
                    }
                )
                writeback_paths.append(path)

        item_ids: list[int] = []
        if writeback_items:
            item_ids = self._manager.save_writeback_items(session_id, writeback_items)

        path_to_item_id = dict(zip(writeback_paths, item_ids, strict=True))

        # Phase 2: Write XMP files to disk
        try:
            result = write_keywords(photo_paths, keywords_map)

            # Phase 3: Update audit statuses based on writeback result
            error_by_path = {e.get("path", ""): e.get("error", "") for e in result.get("errors", [])}
            for path, item_id in path_to_item_id.items():
                if path in error_by_path:
                    self._manager.update_writeback_item_status(item_id, "failed", error_by_path[path])
                else:
                    self._manager.update_writeback_item_status(item_id, "written")

            if int(result.get("failed", 0)) > 0:
                self._manager.update_writeback_session_status(session_id, WritebackStatus.PARTIAL)
            else:
                self._manager.update_writeback_session_status(session_id, WritebackStatus.DONE)

            return result
        except Exception:
            error_by_path = {}
            for item_id in path_to_item_id.values():
                self._manager.update_writeback_item_status(item_id, "failed", "Writeback interrupted")
            self._manager.update_writeback_session_status(session_id, WritebackStatus.PARTIAL)
            raise

    def confirm_sync(self, session_id: str) -> dict[str, Any]:
        """Mark the session as synced after user confirms metadata load in CO."""
        session = self._manager.get_session(session_id)
        if session is None:
            raise ValueError(f"Session not found: {session_id}")
        self._manager.update_writeback_session_status(session_id, WritebackStatus.DONE)
        self._manager.update_session_status(session_id, SessionStatus.COMPLETED)
        return {"status": "synced", "session_id": session_id}

    def rollback_writeback(self, session_id: str) -> dict[str, Any]:
        """Roll back XMP writeback: restore original XMPs from backups."""
        from shared.path_utils import validate_safe_path

        from .writeback import _is_gather_xmp, restore_xmp

        session = self._manager.get_session(session_id)
        if session is None:
            raise ValueError(f"Session not found: {session_id}")

        with self._state_lock:
            clusters = self._clusters_cache.get(session_id, [])
            photo_map = self._photo_map_cache.get(session_id, {})

        if not clusters:
            clusters, _bindings = self._load_clusters_and_bindings(session_id)

        all_paths: set = set()
        for cl in clusters or []:
            for m in cl.get("members", []):
                all_paths.add(m.get("photo_path", ""))
        photo_paths = list(all_paths) if all_paths else list(photo_map.keys())
        if not photo_paths:
            photo_paths = [p["filepath"] for p in self._manager.get_photo_filepaths(session_id)]

        rolled_back = 0
        skipped = 0
        errors: list = []
        for path in photo_paths:
            if not path:
                continue
            try:
                path = validate_safe_path(path, allow_temp=True)
            except ValueError:
                errors.append({"path": path, "error": "path outside allowed directories"})
                continue
            xmp_path = path + ".xmp"
            backup_path = xmp_path + ".gatherbak"
            try:
                if os.path.isfile(backup_path):
                    if restore_xmp(path, backup_path):
                        rolled_back += 1
                    else:
                        errors.append({"path": path, "error": "restore failed"})
                elif os.path.isfile(xmp_path):
                    if _is_gather_xmp(xmp_path):
                        os.remove(xmp_path)
                        rolled_back += 1
                    else:
                        skipped += 1
            except Exception as exc:
                errors.append({"path": path, "error": str(exc)})

        if errors:
            self._manager.update_writeback_session_status(session_id, WritebackStatus.PARTIAL)
        else:
            self._manager.update_writeback_session_status(session_id, WritebackStatus.IDLE)
            self._manager.delete_writeback_items(session_id)

        return {"rolled_back": rolled_back, "skipped": skipped, "errors": errors}

    def cleanup(self, session_id: str) -> dict[str, Any]:
        """Full cleanup: remove temp XMP files and clear in-memory caches."""
        from .writeback import cleanup_xmp

        with self._state_lock:
            clusters = self._clusters_cache.get(session_id, [])
            photo_map = self._photo_map_cache.get(session_id, {})

        photo_paths = list(photo_map.keys()) if photo_map else []
        if not photo_paths:
            all_paths: set = set()
            for cl in clusters or []:
                for m in cl.get("members", []):
                    all_paths.add(m.get("photo_path", ""))
            photo_paths = list(all_paths)
        if not photo_paths:
            photo_paths = [p["filepath"] for p in self._manager.get_photo_filepaths(session_id)]

        result = cleanup_xmp(photo_paths)
        self._manager.update_writeback_session_status(session_id, WritebackStatus.CLEANED)

        # Clear caches
        with self._state_lock:
            self._clusters_cache.pop(session_id, None)
            self._bindings_cache.pop(session_id, None)
            self._progress_cache.pop(session_id, None)
            self._photo_map_cache.pop(session_id, None)
            self._cancel_events.pop(session_id, None)

        return result
