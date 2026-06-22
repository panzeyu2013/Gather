# shared/cache.py - Generic LRU eviction helper for in-memory caches.
from __future__ import annotations

import threading
from collections import OrderedDict
from typing import Any


class LRUCacheManager:
    """Manages eviction of per-session in-memory caches with a max entry limit.

    Usage:
        cache_lru = LRUCacheManager(max_entries=50)
        cache_lru.touch(session_id)
        # Register cache dicts whose entries should be cleared on eviction:
        cache_lru.register(clusters_cache, observations_cache, ...)
    """

    def __init__(self, max_entries: int = 50) -> None:
        self._lock = threading.Lock()
        self._entries: OrderedDict[str, None] = OrderedDict()
        self._max_entries = max_entries
        self._caches: list[dict[str, Any]] = []

    def register(self, *caches: dict[str, Any]) -> None:
        self._caches.extend(caches)

    def touch(self, session_id: str) -> None:
        with self._lock:
            self._entries.pop(session_id, None)
            self._entries[session_id] = None
            self._evict_if_needed()

    def _evict_if_needed(self) -> None:
        while len(self._entries) > self._max_entries:
            old_sid, _ = self._entries.popitem(last=False)
            for cache_dict in self._caches:
                cache_dict.pop(old_sid, None)
