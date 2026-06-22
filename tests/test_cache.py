# tests/test_cache.py - Unit tests for shared/cache.py (LRU eviction manager).

import threading

from shared.cache import LRUCacheManager

# ---------------------------------------------------------------------------
# LRUCacheManager.touch() promotes recently-used entries
# ---------------------------------------------------------------------------


def test_touch_promotes_recently_used_entry():
    """A touched session_id stays in the cache even after N-1 other touches."""
    mgr = LRUCacheManager(max_entries=3)
    mgr.touch("A")
    mgr.touch("B")
    mgr.touch("C")
    mgr.touch("A")  # promote A
    mgr.touch("D")  # should evict B (oldest)

    assert "A" in mgr._entries
    assert "C" in mgr._entries
    assert "D" in mgr._entries
    assert "B" not in mgr._entries  # B was LRU, should be gone


def test_touch_repeated_same_id_keeps_only_one_entry():
    """Touching the same ID multiple times results in a single entry."""
    mgr = LRUCacheManager(max_entries=5)
    for _ in range(10):
        mgr.touch("repeated")
    assert list(mgr._entries.keys()) == ["repeated"]


# ---------------------------------------------------------------------------
# Eviction removes least-recently-used entry when > max_entries
# ---------------------------------------------------------------------------


def test_eviction_removes_lru_when_exceeding_max():
    mgr = LRUCacheManager(max_entries=2)
    mgr.touch("first")
    mgr.touch("second")
    mgr.touch("third")  # triggers eviction of "first"

    assert "first" not in mgr._entries
    assert "second" in mgr._entries
    assert "third" in mgr._entries
    assert len(mgr._entries) == 2


def test_eviction_clears_registered_cache_dicts():
    mgr = LRUCacheManager(max_entries=1)
    cache1: dict[str, object] = {"A": 1, "B": 2}
    cache2: dict[str, object] = {"A": 10, "B": 20}
    mgr.register(cache1, cache2)

    mgr.touch("A")
    mgr.touch("B")  # evicts A

    assert "A" not in mgr._entries
    assert "A" not in cache1
    assert "A" not in cache2
    assert "B" in cache1
    assert "B" in cache2


def test_eviction_without_registered_caches_does_not_raise():
    mgr = LRUCacheManager(max_entries=1)
    mgr.touch("X")
    mgr.touch("Y")  # evicts X — no caches registered, should not crash

    assert "X" not in mgr._entries
    assert "Y" in mgr._entries


# ---------------------------------------------------------------------------
# register() adds cache dicts
# ---------------------------------------------------------------------------


def test_register_stores_cache_dicts():
    mgr = LRUCacheManager(max_entries=10)
    c1: dict[str, object] = {}
    c2: dict[str, object] = {}
    mgr.register(c1, c2)

    assert mgr._caches == [c1, c2]


def test_register_extends_previous_caches():
    mgr = LRUCacheManager(max_entries=10)
    old: dict[str, object] = {"a": 1}
    mgr.register(old)

    new1: dict[str, object] = {}
    new2: dict[str, object] = {}
    mgr.register(new1, new2)

    assert mgr._caches == [old, new1, new2]
    assert "a" in old  # old dict not mutated


# ---------------------------------------------------------------------------
# Concurrent touch/evict doesn't raise (thread safety basic check)
# ---------------------------------------------------------------------------


def test_concurrent_touch_does_not_raise():
    mgr = LRUCacheManager(max_entries=50)
    errors: list[Exception] = []

    def worker(worker_id: int) -> None:
        try:
            for i in range(200):
                sid = f"session_{worker_id}_{i}"
                mgr.touch(sid)
        except Exception as e:
            errors.append(e)

    threads = [threading.Thread(target=worker, args=(t,)) for t in range(5)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert len(errors) == 0
    assert len(mgr._entries) <= 50


def test_concurrent_touch_and_evict_with_caches_does_not_raise():
    mgr = LRUCacheManager(max_entries=3)
    shared_cache1: dict[str, object] = {}
    shared_cache2: dict[str, object] = {}
    mgr.register(shared_cache1, shared_cache2)
    errors: list[Exception] = []

    def worker(worker_id: int) -> None:
        try:
            for i in range(100):
                mgr.touch(f"w{worker_id}_s{i}")
        except Exception as e:
            errors.append(e)

    threads = [threading.Thread(target=worker, args=(t,)) for t in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert len(errors) == 0
    assert len(mgr._entries) <= mgr._max_entries
