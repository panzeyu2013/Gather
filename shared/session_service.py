# shared/session_service.py - SessionService: domain service for session CRUD.
#
# Thin wrapper around SessionManager providing session create/delete/list/get/update
# and photo-add operations.  Extracted from engine.py so it can be imported and
# tested independently.

from __future__ import annotations

from typing import Any

from .exceptions import SessionNotFoundError
from .models import SessionStatus
from .session_manager import SessionManager


class SessionService:
    """Thin wrapper around SessionManager for session CRUD operations."""

    def __init__(self, manager: SessionManager) -> None:
        self._manager = manager

    def create_session(self, name: str = "") -> dict[str, Any]:
        session = self._manager.create_session(name)
        return session.to_dict()

    def delete_session(self, session_id: str) -> dict[str, Any]:
        return {"deleted": self._manager.delete_session(session_id)}

    def list_sessions(self) -> list[dict[str, Any]]:
        sessions = self._manager.list_sessions()
        counts = self._manager.count_photos_by_sessions([s.id for s in sessions])
        result = [s.to_dict() for s in sessions]
        for d in result:
            d["photo_count"] = counts.get(d["id"], 0)
        return result

    def add_photos(self, session_id: str, filepaths: list[str]) -> dict[str, Any]:
        photos, failed_paths = self._manager.add_photos(session_id, filepaths)
        total = self._manager.count_photos(session_id)
        if total > 0:
            self._manager.update_session_status(session_id, SessionStatus.PHOTOS_LOADED)
        return {
            "added": len(photos),
            "total": total,
            "failed_paths": failed_paths,
        }

    def get_session(self, session_id: str) -> dict[str, Any]:
        session = self._manager.get_session(session_id)
        if session is None:
            raise SessionNotFoundError(f"Session not found: {session_id}")
        result = session.to_dict()
        result["photo_count"] = self._manager.count_photos(session_id)
        return result

    def update_session(self, session_id: str, name: str) -> dict[str, Any]:
        ok = self._manager.update_session_name(session_id, name)
        if not ok:
            raise SessionNotFoundError(f"Session not found: {session_id}")
        return self.get_session(session_id)
