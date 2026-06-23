# engine/engine.py
# Gather v3.0 Python 引擎 — stdin/stdout MessagePack 模式

from __future__ import annotations

import logging
import os
import re
import signal
import sys
import threading
import time
from collections.abc import Callable
from typing import Any

try:
    from .protocol import emit_event, read_message, serialise_error, write_message
except ImportError:
    import os as _os
    import sys as _sys
    _engine_dir = _os.path.dirname(_os.path.abspath(__file__))
    if _engine_dir not in _sys.path:
        _sys.path.append(_engine_dir)
    from protocol import emit_event, read_message, serialise_error, write_message  # type: ignore[no-redef]

logging.basicConfig(
    stream=sys.stderr,
    level=logging.DEBUG if os.environ.get("GATHER_DEBUG") == "1" else logging.INFO,
    format="[%(asctime)s] [%(name)s] %(levelname)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("gather.engine")

# 路径解析：开发模式找 repo 根，打包模式找 engine 同级
_here = os.path.dirname(os.path.abspath(__file__))
_desktop_root = os.path.dirname(_here)
_repo_root = os.path.dirname(_desktop_root)
if os.path.isdir(os.path.join(_repo_root, "shared")):
    _root = _repo_root
elif os.path.isdir(os.path.join(_desktop_root, "shared")):
    _root = _desktop_root
else:
    _root = _here
if _root not in sys.path:
    sys.path.append(_root)

from shared.db import Database
from shared.path_utils import validate_safe_path
from shared.session_manager import SessionManager
from shared.session_service import SessionService

_shutdown_requested = False


def _handle_sigterm(_signum: int, _frame: object) -> None:
    global _shutdown_requested
    _shutdown_requested = True


def main() -> None:
    global _shutdown_requested
    logger.info("Engine starting")
    db = None
    mgr = None
    fkw = None
    sim = None
    session_svc = None
    try:
        db = Database()
        mgr = SessionManager(db=db)

        from face_keywording.service import FaceKeywordingService
        from similarity.service import SimilarityService

        # 进度回调 → stdout 推送
        _progress_last_emit: dict[str, float] = {}
        _progress_lock = threading.Lock()

        def _progress(sid: str, cur: int, tot: int, msg: str, status: str = "running") -> None:
            is_final = (cur == tot and tot > 0)
            if is_final:
                with _progress_lock:
                    _progress_last_emit.pop(sid, None)
                emit_event("progress", {"session_id": sid, "current": cur, "total": tot, "message": msg, "status": status})
                return
            now = time.monotonic()
            with _progress_lock:
                last = _progress_last_emit.get(sid, 0.0)
                if now - last < 0.2:
                    return
                _progress_last_emit[sid] = now
            emit_event("progress", {"session_id": sid, "current": cur, "total": tot, "message": msg, "status": status})

        fkw = FaceKeywordingService(mgr, progress_callback=_progress)
        fkw.reset_stale_running_sessions()
        sim = SimilarityService(mgr, progress_callback=_progress)
        sim.reset_stale_running_sessions()

        session_svc = SessionService(mgr)

        signal.signal(signal.SIGTERM, _handle_sigterm)

        write_message({"type": "ready", "version": "3.0.0"})
    except Exception:
        logger.exception("Engine initialization failed")
        write_message({"type": "error", "message": "Engine initialization failed"})
        if db is not None:
            db.close()
        return

    try:
        while True:
            if _shutdown_requested:
                logger.info("SIGTERM received, shutting down gracefully...")
                break
            msg_id = None
            cmd = "<unknown>"
            try:
                msg = read_message(sys.stdin)
                if msg is None:
                    break
                if not isinstance(msg, dict):
                    write_message({"ok": False, "error": "Invalid message format"})
                    continue
                msg_id = msg.get("id")
                cmd = msg.get("type", "")
                result = _dispatch(session_svc, fkw, sim, cmd, msg)
                if result is SHUTDOWN:
                    fkw.shutdown()  # type: ignore[union-attr]
                    sim.shutdown()  # type: ignore[union-attr]
                    fkw = None
                    sim = None
                    break
                write_message({"id": msg_id, "ok": True, "data": result})
            except InterruptedError:
                if _shutdown_requested:
                    break
                continue
            except Exception as exc:
                logger.exception("Error processing message cmd=%s id=%s", cmd, msg_id)
                err_response = {"ok": False, "error": serialise_error(exc)}
                if msg_id is not None:
                    err_response["id"] = msg_id
                write_message(err_response)
    finally:
        logger.info("Engine shutting down")
        # fkw and sim were set to None in the SHUTDOWN path (lines 131-132)
        # after already calling .shutdown(), so the guards below correctly
        # skip re-shutdown in that case while still catching other exits.
        if fkw is not None:
            fkw.shutdown()
        if sim is not None:
            sim.shutdown()
        try:
            from face_keywording.face_engine import cleanup_globals
            from face_keywording.face_engine import shutdown_worker_pool as shutdown_face_pool
        except ImportError:
            logger.exception("Failed to import face_keywording modules during shutdown")
        else:
            try:
                cleanup_globals()
                shutdown_face_pool()
            except Exception:
                logger.exception("Failed to call cleanup_globals during shutdown")
        try:
            from similarity.analysis import shutdown_worker_pool as shutdown_sim_pool
        except ImportError:
            logger.exception("Failed to import similarity module during shutdown")
        else:
            try:
                shutdown_sim_pool()
            except Exception:
                logger.exception("Failed to shutdown similarity worker pool during shutdown")
        try:
            from shared.session_manager import shutdown_checksum_pool
        except ImportError:
            logger.exception("Failed to import session_manager during shutdown")
        else:
            try:
                shutdown_checksum_pool()
            except Exception:
                logger.exception("Failed to shutdown checksum pool during shutdown")
        if db is not None:
            try:
                db.checkpoint()
            except Exception:
                logger.exception("Checkpoint failed during shutdown")
            finally:
                db.get_conn().rollback()
                db.close()


class _Shutdown:
    _instance: _Shutdown | None = None

    def __new__(cls) -> _Shutdown:
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance


SHUTDOWN = _Shutdown()


UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE)

REQUIRE_SID = frozenset({
    "session.delete",
    "session.add_photos",
    "session.get",
    "session.update",
    "fkw.analyze",
    "fkw.cancel_analysis",
    "fkw.clusters",
    "fkw.bind",
    "fkw.unbind",
    "fkw.merge",
    "fkw.remove_member",
    "fkw.preview",
    "fkw.writeback",
    "fkw.confirm_sync",
    "fkw.cleanup",
    "fkw.confirm_cleanup",
    "sim.analyze",
    "sim.cancel_analysis",
    "sim.result",
    "sim.recluster",
    "sim.preview_writeback",
    "sim.writeback",
})


# ------------------------------------------------------------------
# Command handlers — each receives (svc, fkw, sim, params)
# ------------------------------------------------------------------

def _handle_session_create(svc, fkw, sim, params):
    raw = params.get("name", "")
    name = str(raw) if raw is not None else ""
    return svc.create_session(name=name[:256])


def _handle_session_delete(svc, fkw, sim, params):
    sid = params["session_id"]
    if fkw is not None:
        fkw.cancel_analysis(sid)
        fkw.clear_session_caches(sid)
    if sim is not None:
        sim.cancel_analysis(sid)
        sim.clear_session_caches(sid)
    return svc.delete_session(sid)


def _handle_session_list(svc, fkw, sim, params):
    return {"sessions": svc.list_sessions()}


def _handle_session_add_photos(svc, fkw, sim, params):
    filepaths = params.get("filepaths", [])
    validated = [validate_safe_path(fp) for fp in filepaths]
    return svc.add_photos(params["session_id"], validated)


def _handle_session_get(svc, fkw, sim, params):
    return svc.get_session(params["session_id"])


def _handle_session_update(svc, fkw, sim, params):
    sid = params["session_id"]
    name = str(params.get("name", ""))[:256]
    return svc.update_session(sid, name)


def _handle_fkw_analyze(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    sid = params["session_id"]
    eps = params.get("eps", 0.5)
    if isinstance(eps, (int, float)):
        eps = max(0.1, min(2.0, float(eps)))
    min_samples = params.get("min_samples", 2)
    if isinstance(min_samples, (int, float)):
        min_samples = max(1, int(min_samples))
    return fkw.start_analysis(sid, eps=eps, min_samples=min_samples)


def _handle_fkw_cancel_analysis(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    return fkw.cancel_analysis(params["session_id"])


def _handle_fkw_clusters(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    clusters = fkw.get_clusters(params["session_id"])
    return fkw.get_cluster_thumbnail_base64(clusters)


def _handle_fkw_bind(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    role = str(params.get("role", ""))
    cluster_id = params.get("cluster_id", "")
    try:
        int(cluster_id)
    except (TypeError, ValueError) as err:
        raise ValueError(f"Invalid cluster_id (expected numeric string): {cluster_id}") from err
    keywords = [str(kw)[:128] for kw in (params.get("keywords") or [])]
    return fkw.bind_role(params["session_id"], cluster_id, role[:256], keywords)


def _handle_fkw_unbind(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    cluster_id = params.get("cluster_id", "")
    try:
        int(cluster_id)
    except (TypeError, ValueError) as err:
        raise ValueError(f"Invalid cluster_id (expected numeric string): {cluster_id}") from err
    return fkw.unbind_role(params["session_id"], cluster_id)


def _handle_fkw_merge(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    source = params.get("source", "")
    target = params.get("target", "")
    try:
        int(source)
        int(target)
    except (TypeError, ValueError) as err:
        raise ValueError(f"Invalid cluster_id (expected numeric strings): source={source}, target={target}") from err
    return fkw.merge_clusters(params["session_id"], source, target)


def _handle_fkw_remove_member(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    cluster_id = params.get("cluster_id", "")
    photo_id = str(params.get("photo_id", ""))
    try:
        int(cluster_id)
    except (TypeError, ValueError) as err:
        raise ValueError(f"Invalid cluster_id (expected numeric string): {cluster_id}") from err
    if not UUID_RE.match(photo_id):
        raise ValueError(f"Invalid photo_id format: {photo_id}")
    return fkw.remove_member(params["session_id"], cluster_id, photo_id)


def _handle_fkw_preview(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    return fkw.preview_writeback(params["session_id"])


def _handle_fkw_writeback(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    return fkw.execute_writeback(params["session_id"])


def _handle_fkw_confirm_cleanup(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    cleanup_result = fkw.cleanup(params["session_id"])
    sync_result = fkw.confirm_sync(params["session_id"])
    return {"status": sync_result["status"], "session_id": sync_result["session_id"], "cleanup": cleanup_result}


def _handle_fkw_confirm_sync(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    return fkw.confirm_sync(params["session_id"])


def _handle_fkw_cleanup(svc, fkw, sim, params):
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    return fkw.cleanup(params["session_id"])


def _handle_thumbnail_get(svc, fkw, sim, params):
    path = validate_safe_path(str(params.get("path", "")))
    source = str(params.get("source", "cluster"))
    if source not in ("cluster", "similarity"):
        raise ValueError(f"Invalid thumbnail source: {source}")
    if source == "similarity":
        if sim is None:
            raise RuntimeError("SimilarityService is not available")
        return sim.get_thumbnail(path)
    bbox = params.get("bbox")
    bbox_list = list(bbox) if isinstance(bbox, (list, tuple)) and len(bbox) == 4 else []
    if not bbox_list:
        return {"thumbnail_base64": None}
    if fkw is None:
        raise RuntimeError("FaceKeywordingService is not available")
    return fkw.get_thumbnail(path, bbox_list)


def _handle_sim_analyze(svc, fkw, sim, params):
    if sim is None:
        raise RuntimeError("SimilarityService is not available")
    sid = params["session_id"]
    threshold = params.get("threshold")
    if isinstance(threshold, (int, float)):
        threshold = int(threshold)
    min_group_size = params.get("min_group_size")
    if isinstance(min_group_size, (int, float)):
        min_group_size = int(min_group_size)
    return sim.start_analysis(sid, threshold=threshold, min_group_size=min_group_size)


def _handle_sim_cancel_analysis(svc, fkw, sim, params):
    if sim is None:
        raise RuntimeError("SimilarityService is not available")
    return sim.cancel_analysis(params["session_id"])


def _handle_sim_result(svc, fkw, sim, params):
    if sim is None:
        raise RuntimeError("SimilarityService is not available")
    result = sim.get_result(params["session_id"])
    return sim.get_cluster_thumbnail_base64(result)


def _handle_sim_recluster(svc, fkw, sim, params):
    if sim is None:
        raise RuntimeError("SimilarityService is not available")
    sid = params["session_id"]
    threshold = params.get("threshold")
    if isinstance(threshold, (int, float)):
        threshold = int(threshold)
    min_group_size = params.get("min_group_size")
    if isinstance(min_group_size, (int, float)):
        min_group_size = int(min_group_size)
    return sim.recluster(sid, threshold, min_group_size)


def _handle_sim_writeback(svc, fkw, sim, params):
    if sim is None:
        raise RuntimeError("SimilarityService is not available")
    sid = params["session_id"]
    group_ids = params.get("group_ids")
    if group_ids is not None:
        if not isinstance(group_ids, list):
            raise ValueError("group_ids must be a list")
        if not group_ids:
            raise ValueError("group_ids must be a non-empty list")
    groups = params.get("groups", [])
    if not isinstance(groups, list):
        raise ValueError("groups must be a list")
    for g in groups:
        if not isinstance(g, dict):
            raise ValueError("groups must contain objects")
        for img in g.get("images", []):
            if not isinstance(img, dict):
                raise ValueError("group images must contain objects")
            path = img.get("path", "")
            if path:
                img["path"] = validate_safe_path(path)
    return sim.execute_writeback(sid, groups, params.get("options", {}), group_ids=group_ids)


def _handle_sim_preview_writeback(svc, fkw, sim, params):
    if sim is None:
        raise RuntimeError("SimilarityService is not available")
    group_ids = params.get("group_ids")
    if not isinstance(group_ids, list) or not group_ids:
        raise ValueError("group_ids must be a non-empty list")
    return sim.preview_writeback(params["session_id"], group_ids, params.get("options", {}))


def _handle_shutdown(svc, fkw, sim, params):
    return SHUTDOWN


COMMAND_HANDLERS: dict[str, Callable[..., Any]] = {
    "session.create": _handle_session_create,
    "session.delete": _handle_session_delete,
    "session.list": _handle_session_list,
    "session.get": _handle_session_get,
    "session.update": _handle_session_update,
    "session.add_photos": _handle_session_add_photos,
    "fkw.analyze": _handle_fkw_analyze,
    "fkw.cancel_analysis": _handle_fkw_cancel_analysis,
    "fkw.clusters": _handle_fkw_clusters,
    "fkw.bind": _handle_fkw_bind,
    "fkw.unbind": _handle_fkw_unbind,
    "fkw.merge": _handle_fkw_merge,
    "fkw.remove_member": _handle_fkw_remove_member,
    "fkw.preview": _handle_fkw_preview,
    "fkw.writeback": _handle_fkw_writeback,
    "fkw.confirm_sync": _handle_fkw_confirm_sync,
    "fkw.cleanup": _handle_fkw_cleanup,
    "fkw.confirm_cleanup": _handle_fkw_confirm_cleanup,
    "thumbnail.get": _handle_thumbnail_get,
    "sim.analyze": _handle_sim_analyze,
    "sim.cancel_analysis": _handle_sim_cancel_analysis,
    "sim.result": _handle_sim_result,
    "sim.recluster": _handle_sim_recluster,
    "sim.preview_writeback": _handle_sim_preview_writeback,
    "sim.writeback": _handle_sim_writeback,
    "shutdown": _handle_shutdown,
}


def _validate_params(cmd: str, params: dict) -> None:
    """Validate command-specific parameters before dispatch."""

    if cmd in ("fkw.bind", "fkw.unbind", "fkw.merge", "fkw.remove_member"):
        cluster_id = params.get("cluster_id", "")
        try:
            int(cluster_id)
        except (TypeError, ValueError):
            raise ValueError(f"Invalid cluster_id (expected numeric): {cluster_id}") from None

    if cmd == "fkw.bind":
        role = str(params.get("role", "")).strip()
        if not role:
            raise ValueError("role must be present and non-empty")
        keywords = params.get("keywords")
        if not isinstance(keywords, list) or len(keywords) == 0:
            raise ValueError("keywords must be a non-empty list")

    if cmd == "session.add_photos":
        filepaths = params.get("filepaths")
        if not isinstance(filepaths, list) or len(filepaths) == 0:
            raise ValueError("filepaths must be a non-empty list")

    if cmd == "session.update":
        name = str(params.get("name", "")).strip()
        if not name:
            raise ValueError("name must be present and non-empty")

    if cmd in ("session.delete", "fkw.writeback", "fkw.cleanup", "fkw.confirm_cleanup", "sim.writeback") and not params.get("confirmed"):
        raise ValueError(f"Destructive command {cmd} requires confirmed=true")


def _dispatch(svc, fkw, sim, cmd: str, params: dict) -> Any:
    sid = str(params.get("session_id", ""))

    if cmd in REQUIRE_SID and not sid.strip():
        raise ValueError("session_id is required")
    if sid and not UUID_RE.match(sid):
        raise ValueError("Invalid session_id format")

    _validate_params(cmd, params)

    handler = COMMAND_HANDLERS.get(cmd)
    if handler is None:
        raise ValueError(f"Unknown command: {cmd}")
    return handler(svc, fkw, sim, params)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        logger.exception("Unhandled exception in main()")
        write_message({"type": "error", "message": "Engine crashed"})
