# similarity/service.py - SimilarityService: business logic layer.
#
# Encapsulates all similarity-grouping operations (analysis, recluster,
# writeback report generation) so that the engine layer
# become thin adapters.

from __future__ import annotations

import json
import logging
import os
import threading
from collections.abc import Callable
from typing import Any

from shared.base_service import BaseService
from shared.constants import (
    MAX_SIMILARITY_PHOTOS,
    SIMILARITY_HASH_PERSIST_BATCH_SIZE,
    SIMILARITY_MIN_GROUP_DEFAULT,
    SIMILARITY_MIN_GROUP_MAX,
    SIMILARITY_MIN_GROUP_MIN,
    SIMILARITY_THRESHOLD_DEFAULT,
    SIMILARITY_THRESHOLD_MAX,
    SIMILARITY_THRESHOLD_MIN,
)
from shared.models import AnalysisStatus, SessionStatus, WritebackStatus
from shared.session_manager import SessionManager
from shared.thumbnail import generate_thumbnail

logger = logging.getLogger("gather.similarity")


def clamp_analysis_params(threshold: int, min_group_size: int) -> tuple[int, int]:
    """Clamp similarity analysis parameters to allowed ranges."""
    return (
        max(SIMILARITY_THRESHOLD_MIN, min(SIMILARITY_THRESHOLD_MAX, threshold)),
        max(SIMILARITY_MIN_GROUP_MIN, min(SIMILARITY_MIN_GROUP_MAX, min_group_size)),
    )


class SimilarityService(BaseService):
    """Central business logic for the similarity grouping submodule."""

    def __init__(
        self,
        manager: SessionManager,
        progress_callback: Callable[[str, int, int, str, str], None] | None = None,
    ) -> None:
        super().__init__()
        self._manager = manager
        self._progress_callback = progress_callback

        # In-memory result cache keyed by session_id
        self._results_cache: dict[str, dict[str, Any]] = {}
        self._locks: dict[str, threading.Lock] = {}
        self._progress_callbacks: dict[str, Callable[[str, int, int, str, str], None] | None] = {}
        self._running_sessions: set[str] = set()
        self._register_cache(self._results_cache, self._progress_callbacks)

    def shutdown(self) -> None:
        super().shutdown()

    def reset_stale_running_sessions(self) -> None:
        """Reset any sessions still marked RUNNING in DB (after an engine restart)."""
        sessions = self._manager.list_sessions()
        for s in sessions:
            if s.analysis_status == AnalysisStatus.RUNNING:
                logger.info("Resetting stale RUNNING status for session %s", s.id)
                self._manager.update_analysis_status(s.id, AnalysisStatus.IDLE)
                with self._state_lock:
                    self._running_sessions.discard(s.id)
                    self._cancel_events.pop(s.id, None)
        for s in sessions:
            if s.writeback_status == WritebackStatus.RUNNING:
                logger.info("Resetting stale writeback RUNNING status for session %s", s.id)
                self._manager.update_writeback_session_status(s.id, WritebackStatus.IDLE)

    def delete_session(self, session_id: str) -> bool:
        """Delete a session and all associated analysis state."""
        self.cancel_analysis(session_id)
        self.clear_session_caches(session_id)
        return self._manager.delete_session(session_id)

    def clear_session_caches(self, session_id: str) -> None:
        """Clear all in-memory caches for a session (used before session deletion)."""
        with self._state_lock:
            self._results_cache.pop(session_id, None)
            self._locks.pop(session_id, None)
            self._cancel_events.pop(session_id, None)
            self._running_sessions.discard(session_id)
            self._progress_callbacks.pop(session_id, None)

    def set_progress_callback(self, session_id: str, callback: Callable[[str, int, int, str, str], None] | None) -> None:
        """Register a per-session progress callback (thread-safe)."""
        with self._state_lock:
            self._progress_callbacks[session_id] = callback

    def _get_lock(self, session_id: str) -> threading.Lock:
        with self._state_lock:
            return self._locks.setdefault(session_id, threading.Lock())

    # ------------------------------------------------------------------
    # Analysis
    # ------------------------------------------------------------------

    def start_analysis(
        self,
        session_id: str,
        threshold: int | None = None,
        min_group_size: int | None = None,
    ) -> dict[str, Any]:
        """Start dHash + cluster analysis in a daemon thread."""
        from .analysis import compute_hashes, recluster_from_cache

        threshold = threshold if threshold is not None else SIMILARITY_THRESHOLD_DEFAULT
        min_group_size = min_group_size if min_group_size is not None else SIMILARITY_MIN_GROUP_DEFAULT

        session = self._manager.get_session(session_id)
        if session is None:
            raise ValueError(f"Session not found: {session_id}")

        # M14: prevent duplicate analysis launch
        with self._state_lock:
            if session_id in self._running_sessions:
                raise ValueError("Analysis is already running for this session")
            self._running_sessions.add(session_id)

        try:
            photos = self._manager.get_photo_filepaths(session_id)
            if not photos:
                raise ValueError("No photos in session")
            if len(photos) > MAX_SIMILARITY_PHOTOS:
                raise ValueError(
                    f"Too many photos for similarity analysis: {len(photos)}. Maximum is {MAX_SIMILARITY_PHOTOS}."
                )

            filepaths = [p["filepath"] for p in photos]
            threshold, min_group_size = clamp_analysis_params(threshold, min_group_size)
            existing_hash_cache = self._manager.get_similarity_hashes(session_id)
        except Exception:
            with self._state_lock:
                self._running_sessions.discard(session_id)
            raise
        uncached = [fp for fp in filepaths if fp not in existing_hash_cache]

        cancel_ev = threading.Event()
        with self._state_lock:
            self._cancel_events[session_id] = cancel_ev

        self._manager.update_analysis_status(session_id, AnalysisStatus.RUNNING)
        self._manager.update_session_status(session_id, SessionStatus.ANALYZING)

        lock = self._get_lock(session_id)

        def _progress(current: int, total: int, message: str, status: str = "running") -> None:
            with self._state_lock:
                cb = self._progress_callbacks.get(session_id) or self._progress_callback
            if cb:
                cb(session_id, current, total, message, status)

        _pending_hashes: list[tuple[str, str]] = []
        _hash_batch_size = SIMILARITY_HASH_PERSIST_BATCH_SIZE

        def _flush_hashes() -> None:
            nonlocal _pending_hashes
            if _pending_hashes:
                self._manager.save_similarity_hashes_batch(session_id, _pending_hashes)
                _pending_hashes.clear()

        def _persist_hash_buffer(filepath: str, hex_str: str) -> None:
            _pending_hashes.append((filepath, hex_str))
            if len(_pending_hashes) >= _hash_batch_size:
                _flush_hashes()

        filepath_count = len(filepaths)

        def _run() -> None:
            with lock:
                try:
                    all_hash_cache = dict(existing_hash_cache)
                    hash_result: dict[str, Any] = {"successful": None, "hashes": {}}

                    if uncached:
                        hash_result = compute_hashes(
                            uncached,
                            progress_callback=_progress,
                            cancel_event=cancel_ev,
                            hash_persist_callback=_persist_hash_buffer,
                        )
                        _flush_hashes()
                        all_hash_cache.update(hash_result.get("hashes", {}))

                    if cancel_ev is not None and cancel_ev.is_set():
                        with self._state_lock:
                            self._running_sessions.discard(session_id)
                        self._manager.update_analysis_status(session_id, AnalysisStatus.CANCELLED)
                        self._manager.update_session_status(session_id, SessionStatus.DRAFT)
                        return

                    # Cluster the combined set (cached + newly computed hashes)
                    full_result = recluster_from_cache(
                        all_hash_cache,
                        threshold=threshold,
                        min_group_size=min_group_size,
                        binary_list=hash_result.get("successful"),
                    )
                    full_result["hashes"] = all_hash_cache

                    # Persist results to DB first
                    try:
                        self._manager.save_similarity_result(
                            session_id,
                            json.dumps(full_result.get("groups", []), ensure_ascii=False),
                            json.dumps(full_result.get("stats", {}), ensure_ascii=False),
                            threshold,
                            min_group_size,
                            snapshot_json=json.dumps({
                                "groups": full_result.get("groups", []),
                                "stats": full_result.get("stats", {}),
                                "ungrouped": full_result.get("ungrouped", []),
                                "hashes": full_result.get("hashes", {}),
                            }, ensure_ascii=False),
                        )
                    except Exception:
                        logger.warning("Failed to persist similarity results for %s", session_id, exc_info=True)
                        with self._state_lock:
                            self._results_cache[session_id] = {"error": "Failed to persist results to database"}
                            self._touch_cache(session_id)
                            self._running_sessions.discard(session_id)
                        self._manager.update_analysis_status(session_id, AnalysisStatus.FAILED)
                        self._manager.update_session_status(session_id, SessionStatus.DRAFT)
                        return

                    # Populate in-memory cache after successful persistence
                    with self._state_lock:
                        self._results_cache[session_id] = full_result
                        self._touch_cache(session_id)
                        self._running_sessions.discard(session_id)
                    self._manager.update_analysis_status(session_id, AnalysisStatus.DONE)
                    self._manager.update_session_status(session_id, SessionStatus.REVIEW)
                    _progress(filepath_count, filepath_count, "Analysis complete.", "done")
                except Exception as exc:
                    logger.exception("Analysis failed for session %s", session_id)
                    with self._state_lock:
                        self._results_cache[session_id] = {"error": str(exc)}
                        self._running_sessions.discard(session_id)
                    self._manager.update_analysis_status(session_id, AnalysisStatus.FAILED)
                    self._manager.update_session_status(session_id, SessionStatus.DRAFT)
                finally:
                    with self._state_lock:
                        ct = threading.current_thread()
                        if ct in self._analysis_threads:
                            self._analysis_threads.remove(ct)
                        self._cancel_events.pop(session_id, None)

        thread = threading.Thread(target=_run, name=f"similarity-{session_id[:8]}", daemon=False)
        thread.start()
        with self._state_lock:
            self._analysis_threads.append(thread)

        return {"status": "started", "session_id": session_id}

    def get_result(self, session_id: str) -> dict[str, Any]:
        """Return cached analysis results for a session."""
        with self._state_lock:
            result = self._results_cache.get(session_id)

        if result is not None:
            if "error" in result:
                return {"status": "failed", "error": result["error"]}
            return {
                "status": "done",
                "stats": result.get("stats"),
                "groups": result.get("groups"),
                "ungrouped": result.get("ungrouped"),
            }

        # Check DB for persisted results
        session = self._manager.get_session(session_id)
        if session is None:
            return {"status": "idle"}

        db_result = self._manager.get_similarity_cached_result(session_id)
        if db_result is not None:
            with self._state_lock:
                self._results_cache[session_id] = db_result
                self._touch_cache(session_id)
            return {
                "status": "done",
                "stats": db_result.get("stats"),
                "groups": db_result.get("groups"),
                "ungrouped": db_result.get("ungrouped", []),
            }

        return {"status": "idle"}

    def get_cluster_thumbnail_base64(self, result: dict) -> dict:
        """Enrich group dicts with thumbnail_base64 for each group."""
        updated = dict(result)
        groups = list(updated.get("groups", []))
        for g in groups:
            images = g.get("images") or []
            if not images:
                g["thumbnail_base64"] = None
                continue
            rep_img = next((img for img in images if img.get("representative")), None)
            path = (rep_img or images[0]).get("path", "")
            if not path or not os.path.isfile(path):
                g["thumbnail_base64"] = None
                continue
            try:
                g["thumbnail_base64"] = generate_thumbnail(path)
            except Exception:
                g["thumbnail_base64"] = None
        updated["groups"] = groups
        return updated

    def get_thumbnail(self, path: str) -> dict:
        if not os.path.isfile(path):
            return {"thumbnail_base64": None}
        try:
            thumb = generate_thumbnail(path)
            return {"thumbnail_base64": thumb}
        except Exception:
            logger.debug("Failed to generate similarity thumbnail", exc_info=True)
            return {"thumbnail_base64": None}

    def _resolve_writeback_groups(
        self,
        session_id: str,
        group_ids: list[Any] | None = None,
        fallback_groups: list[dict[str, Any]] | None = None,
    ) -> list[dict[str, Any]]:
        """Resolve requested group IDs against persisted analysis results.

        The renderer should send only group IDs. For backwards-compatible unit
        tests and internal callers, fallback_groups are accepted only when no
        persisted result exists.
        """
        requested = {str(gid) for gid in (group_ids or [])}
        cached = self._manager.get_similarity_cached_result(session_id)
        source_groups = cached.get("groups", []) if cached else []

        if source_groups:
            available = {str(g.get("id")): g for g in source_groups}
            missing = sorted(gid for gid in requested if gid not in available)
            if missing:
                raise ValueError(f"Unknown or stale similarity group id(s): {', '.join(missing)}")
            selected = [available[str(gid)] for gid in (group_ids or [])] if requested else []
        else:
            selected = list(fallback_groups or [])
            if requested:
                available = {str(g.get("id")): g for g in selected}
                missing = sorted(gid for gid in requested if gid not in available)
                if missing:
                    raise ValueError(f"Unknown similarity group id(s): {', '.join(missing)}")
                selected = [available[str(gid)] for gid in (group_ids or [])]

        if not selected:
            raise ValueError("At least one similarity group is required for writeback")

        session_paths = {p["filepath"] for p in self._manager.get_photo_filepaths(session_id)}
        if session_paths:
            for group in selected:
                for image in group.get("images", []) or []:
                    path = image.get("path", "")
                    if path not in session_paths:
                        raise ValueError(f"Image path is not part of this session: {path}")
        return selected

    def preview_writeback(
        self,
        session_id: str,
        group_ids: list[Any],
        options: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Build a file-level Similarity writeback plan without touching disk."""
        session = self._manager.get_session(session_id)
        if session is None:
            raise ValueError(f"Session not found: {session_id}")

        options = options or {}
        selected = self._resolve_writeback_groups(session_id, group_ids=group_ids)
        will_write_xmp = bool(options.get("writeIPTC"))
        plan_groups: list[dict[str, Any]] = []
        warnings: list[str] = []
        total_affected = 0

        for idx, group in enumerate(selected, 1):
            gid_raw = group.get("id")
            gid = str(gid_raw if gid_raw is not None else idx)
            label = str(group.get("label", f"Group_{idx:02d}"))
            files = []
            for image in group.get("images", []) or []:
                path = str(image.get("path", ""))
                exists = os.path.isfile(path)
                if not exists:
                    warnings.append(f"Missing file: {path}")
                files.append({
                    "path": path,
                    "filename": os.path.basename(path),
                    "exists": exists,
                    "keywords": [f"Gather:Similarity:{label}"] if will_write_xmp else [],
                })
            total_affected += len(files)
            plan_groups.append({"id": gid, "label": label, "count": len(files), "files": files})

        return {
            "status": "preview",
            "groups": plan_groups,
            "total_affected": total_affected,
            "will_write_xmp": will_write_xmp,
            "warnings": warnings,
        }

    def cancel_analysis(self, session_id: str) -> dict[str, Any]:
        """Cancel a running similarity analysis for the given session."""
        with self._state_lock:
            ev = self._cancel_events.get(session_id)
            if ev is not None:
                ev.set()
            self._running_sessions.discard(session_id)
        if ev is not None:
            self._manager.update_analysis_status(session_id, AnalysisStatus.CANCELLED)
        with self._state_lock:
            self._cancel_events.pop(session_id, None)
            self._progress_callbacks.pop(session_id, None)
        return {"status": "cancelled", "session_id": session_id}

    def recluster(
        self,
        session_id: str,
        threshold: int | None = None,
        min_group_size: int | None = None,
    ) -> dict[str, Any]:
        """Re-run clustering with new parameters using cached hashes."""
        from .analysis import recluster_from_cache

        # N16: prevent duplicate recluster launch (same guard as start_analysis)
        with self._state_lock:
            if session_id in self._running_sessions:
                raise ValueError("Reclustering is already running for this session")
            self._running_sessions.add(session_id)

        threshold = threshold if threshold is not None else SIMILARITY_THRESHOLD_DEFAULT
        min_group_size = min_group_size if min_group_size is not None else SIMILARITY_MIN_GROUP_DEFAULT
        threshold, min_group_size = clamp_analysis_params(threshold, min_group_size)

        with self._state_lock:
            prev = self._results_cache.get(session_id)

        if prev is None:
            db_result = self._manager.get_similarity_cached_result(session_id)
            if db_result is not None:
                prev = db_result
            else:
                with self._state_lock:
                    self._running_sessions.discard(session_id)
                raise ValueError("No analysis results to recluster from")

        hash_cache = prev.get("hashes")
        if not hash_cache:
            with self._state_lock:
                self._running_sessions.discard(session_id)
            raise ValueError("No cached hashes. Re-run analysis first.")

        lock = self._get_lock(session_id)

        recluster_cancel_ev = threading.Event()
        with self._state_lock:
            self._cancel_events[session_id] = recluster_cancel_ev

        def _run() -> None:
            with lock:
                try:
                    new_result = recluster_from_cache(
                        hash_cache,
                        threshold=threshold,
                        min_group_size=min_group_size,
                        binary_list=prev.get("binary_list"),
                        cancel_event=recluster_cancel_ev,
                    )
                    new_result["hashes"] = hash_cache
                    # Persist updated results to DB first
                    try:
                        self._manager.save_similarity_result(
                            session_id,
                            json.dumps(new_result.get("groups", []), ensure_ascii=False),
                            json.dumps(new_result.get("stats", {}), ensure_ascii=False),
                            threshold,
                            min_group_size,
                            snapshot_json=json.dumps({
                                "groups": new_result.get("groups", []),
                                "stats": new_result.get("stats", {}),
                                "ungrouped": new_result.get("ungrouped", []),
                                "hashes": new_result.get("hashes", {}),
                            }, ensure_ascii=False),
                        )
                    except Exception:
                        logger.warning("Failed to persist recluster results for %s", session_id, exc_info=True)
                        with self._state_lock:
                            self._results_cache[session_id] = {"error": "Failed to persist results to database"}
                            self._running_sessions.discard(session_id)
                        self._manager.update_analysis_status(session_id, AnalysisStatus.FAILED)
                        self._manager.update_session_status(session_id, SessionStatus.DRAFT)
                        return
                    # Populate in-memory cache after successful persistence
                    with self._state_lock:
                        self._results_cache[session_id] = new_result
                        self._running_sessions.discard(session_id)
                except Exception as exc:
                    logger.exception("Recluster failed for session %s", session_id)
                    with self._state_lock:
                        self._results_cache[session_id] = {"error": str(exc)}
                        self._running_sessions.discard(session_id)
                    self._manager.update_analysis_status(session_id, AnalysisStatus.FAILED)
                    self._manager.update_session_status(session_id, SessionStatus.DRAFT)
                finally:
                    with self._state_lock:
                        ct = threading.current_thread()
                        if ct in self._analysis_threads:
                            self._analysis_threads.remove(ct)
                        self._cancel_events.pop(session_id, None)

        thread = threading.Thread(target=_run, name=f"similarity-recluster-{session_id[:8]}", daemon=False)
        thread.start()
        with self._state_lock:
            self._analysis_threads.append(thread)

        return {"status": "started", "session_id": session_id}

    def execute_writeback(
        self,
        session_id: str,
        groups: list[dict[str, Any]] | None = None,
        options: dict[str, Any] | None = None,
        group_ids: list[Any] | None = None,
    ) -> dict[str, Any]:
        """Generate a writeback report and execute write operations."""
        from shared.xmp_writer import write_keywords as xmp_write_keywords

        session = self._manager.get_session(session_id)
        if session is None:
            raise ValueError(f"Session not found: {session_id}")
        if not self._manager.try_start_writeback(session_id):
            raise RuntimeError("Writeback already in progress")

        options = options or {}
        groups = self._resolve_writeback_groups(session_id, group_ids=group_ids, fallback_groups=groups)
        lines: list[str] = []
        lines.append("--- Similarity Writeback Report ---")
        lines.append(f"Session: {session_id}")
        lines.append(f"Create Albums: {options.get('createAlbums', True)}")
        lines.append(f"Add Prefix: {options.get('addPrefix', False)}")
        lines.append(f"Mark Ungrouped: {options.get('markUngrouped', False)}")
        lines.append(f"Write IPTC: {options.get('writeIPTC', False)}")
        lines.append("")

        all_affected = 0
        all_written = 0
        all_failed = 0
        all_errors: list = []

        for idx, g in enumerate(groups, 1):
            gid_raw = g.get("id")
            try:
                gid = int(gid_raw) if gid_raw is not None else idx
            except (TypeError, ValueError):
                gid = idx
            images = g.get("images", [])
            count = len(images)
            all_affected += count
            lines.append(f"  Group_{int(gid):02d}: {count} images")
            for img in images:
                path = img.get("path", "")
                fname = os.path.basename(path)
                prefix = f"{int(gid):04d}__" if options.get("addPrefix") else ""
                lines.append(f"    {prefix}{fname}")

            if options.get("writeIPTC") and images:
                keyword = f"Gather:Similarity:{g.get('label', f'Group_{int(gid):02d}')}"
                kw_map = {}
                for img in images:
                    path = img.get("path", "")
                    if path:
                        kw_map[path] = [keyword]
                result = xmp_write_keywords(list(kw_map.keys()), kw_map)
                all_written += result.get("written", 0)
                all_failed += result.get("failed", 0)
                all_errors.extend(result.get("errors", []))

        lines.append("")
        lines.append(f"Total images affected: {all_affected}")
        if options.get("writeIPTC"):
            lines.append(f"XMP written: {all_written}, failed: {all_failed}")

        report = "\n".join(lines)

        if not options.get("writeIPTC"):
            self._manager.update_writeback_session_status(session_id, WritebackStatus.IDLE)
        elif all_failed > 0:
            self._manager.update_writeback_session_status(session_id, WritebackStatus.PARTIAL)
        else:
            self._manager.update_writeback_session_status(session_id, WritebackStatus.DONE)

        return {
            "status": "completed",
            "report": report,
            "total_affected": all_affected,
            "written": all_written,
            "failed": all_failed,
            "errors": all_errors,
        }
