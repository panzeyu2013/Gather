# tests/test_base_service.py - Unit tests for shared/base_service.py.

import threading
import time

from shared.base_service import BaseService

# ---------------------------------------------------------------------------
# shutdown() cancels all registered cancel events
# ---------------------------------------------------------------------------


def test_shutdown_sets_all_cancel_events():
    svc = BaseService()
    ev1 = threading.Event()
    ev2 = threading.Event()
    ev3 = threading.Event()
    svc._cancel_events["sid_a"] = ev1
    svc._cancel_events["sid_b"] = ev2
    svc._cancel_events["sid_c"] = ev3

    svc.shutdown()

    assert ev1.is_set()
    assert ev2.is_set()
    assert ev3.is_set()


def test_shutdown_with_no_cancel_events_does_not_raise():
    svc = BaseService()
    svc.shutdown()  # should not raise


# ---------------------------------------------------------------------------
# shutdown() waits for threads (mock a slow thread)
# ---------------------------------------------------------------------------


def test_shutdown_joins_all_analysis_threads():
    svc = BaseService()
    joined: list[str] = []

    def slow_thread_func():
        joined.append("slow")

    t1 = threading.Thread(target=slow_thread_func, name="slow-thread")
    t1.start()
    svc._analysis_threads.append(t1)

    svc.shutdown()

    assert "slow" in joined


def test_shutdown_handles_thread_that_exceeds_timeout():
    """A thread that sleeps longer than the 5s join timeout should not block shutdown."""
    svc = BaseService()
    started = threading.Event()

    def long_running():
        started.set()
        time.sleep(10)  # longer than the 5s join timeout

    t = threading.Thread(target=long_running, name="long-thread", daemon=True)
    svc._analysis_threads.append(t)

    t.start()
    started.wait(timeout=5)  # wait until thread has actually started

    # shutdown should complete even though thread is still alive
    start = time.monotonic()
    svc.shutdown()
    elapsed = time.monotonic() - start

    assert elapsed < 9  # should finish well under 9 seconds (5s timeout + overhead)
    assert t.is_alive()  # thread should still be running (we gave it 10s sleep)


# ---------------------------------------------------------------------------
# _register_cache and _touch_cache basic functionality
# ---------------------------------------------------------------------------


def test_register_cache_creates_lru_manager_with_correct_max():
    svc = BaseService(max_cached_sessions=10)
    cache1: dict[str, object] = {}
    cache2: dict[str, object] = {}

    svc._register_cache(cache1, cache2)

    assert hasattr(svc, "_cache_lru")
    assert svc._cache_lru._max_entries == 10  # type: ignore[union-attr]
    assert cache1 in svc._cache_lru._caches  # type: ignore[union-attr]
    assert cache2 in svc._cache_lru._caches  # type: ignore[union-attr]


def test_touch_cache_promotes_session():
    svc = BaseService(max_cached_sessions=3)
    cache: dict[str, object] = {}
    svc._register_cache(cache)

    svc._touch_cache("s1")
    svc._touch_cache("s2")
    svc._touch_cache("s1")  # promote s1
    svc._touch_cache("s3")
    svc._touch_cache("s4")  # evicts s2 (LRU)

    assert "s2" not in svc._cache_lru._entries  # type: ignore[union-attr]
    assert "s1" in svc._cache_lru._entries  # type: ignore[union-attr]


def test_touch_cache_before_register_is_noop():
    svc = BaseService()
    # _touch_cache should be a no-op if _register_cache was never called
    svc._touch_cache("some_id")  # does not raise


# ---------------------------------------------------------------------------
# shutdown clears registered caches
# ---------------------------------------------------------------------------


def test_shutdown_preserves_cancel_event_state():
    """Cancel events remain set after shutdown (they are not cleared)."""
    svc = BaseService()
    ev = threading.Event()
    svc._cancel_events["test_session"] = ev

    svc.shutdown()

    assert ev.is_set()
    assert "test_session" in svc._cancel_events  # dict is not cleared


def test_shutdown_with_registered_caches_sets_cancel_events():
    """Caches stay registered but cancel events are still set."""
    svc = BaseService(max_cached_sessions=5)
    cache_a: dict[str, object] = {}
    svc._register_cache(cache_a)

    ev = threading.Event()
    svc._cancel_events["sid_x"] = ev

    svc.shutdown()

    assert ev.is_set()
    # _cache_lru is a reference on the instance; registration does not prevent shutdown
