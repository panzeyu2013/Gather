# shared/base_service.py - Shared base class for Gather services.

from __future__ import annotations

import logging
import threading
from typing import Any

from .cache import LRUCacheManager
from .constants import MAX_CACHED_SESSIONS

logger = logging.getLogger("gather.service")


class BaseService:
    """Shared infrastructure for Gather analysis services.

    Provides thread-safe LRU cache management, analysis-thread tracking,
    cancel-event management, and graceful shutdown.
    """

    def __init__(self, max_cached_sessions: int = MAX_CACHED_SESSIONS) -> None:
        self._max_cached_sessions = max_cached_sessions
        self._state_lock: threading.Lock = threading.Lock()
        self._cache_lru: LRUCacheManager | None = None
        self._analysis_threads: list[threading.Thread] = []
        self._cancel_events: dict[str, threading.Event] = {}

    def _register_cache(self, *caches: dict[str, Any]) -> LRUCacheManager:
        if self._cache_lru is not None:
            msg = "_register_cache must only be called once per service instance"
            raise RuntimeError(msg)
        self._cache_lru = LRUCacheManager(max_entries=self._max_cached_sessions)
        self._cache_lru.register(*caches)
        return self._cache_lru

    def _touch_cache(self, session_id: str) -> None:
        if self._cache_lru is None:
            return
        self._cache_lru.touch(session_id)

    def shutdown(self) -> None:
        with self._state_lock:
            threads = list(self._analysis_threads)
            self._analysis_threads.clear()
            for sid in self._cancel_events:
                self._cancel_events[sid].set()
        for t in threads:
            t.join(timeout=5)
            if t.is_alive():
                logger.warning("Analysis thread %s did not finish within timeout", t.name)
