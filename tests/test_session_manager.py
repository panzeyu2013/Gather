import threading
import uuid

import pytest

from shared.models import AnalysisStatus, SessionStatus, WritebackStatus

# ---------------------------------------------------------------------------
# create_session
# ---------------------------------------------------------------------------


def test_create_session_returns_valid_session(manager):
    session = manager.create_session(name="test session")
    assert session.id is not None
    assert isinstance(session.id, str)
    uuid.UUID(session.id)  # raises ValueError if not valid UUID
    assert session.status == SessionStatus.DRAFT
    assert session.name == "test session"
    assert session.analysis_status == AnalysisStatus.IDLE
    assert session.writeback_status == WritebackStatus.IDLE


def test_create_session_default_name(manager):
    session = manager.create_session()
    assert session.name == ""


# ---------------------------------------------------------------------------
# get_session
# ---------------------------------------------------------------------------


def test_get_session_returns_correct_fields(manager):
    created = manager.create_session(name="find me")
    found = manager.get_session(created.id)
    assert found is not None
    assert found.id == created.id
    assert found.name == "find me"
    assert found.status == SessionStatus.DRAFT


def test_get_session_returns_none_for_bogus_id(manager):
    result = manager.get_session("nonexistent-id-12345")
    assert result is None


# ---------------------------------------------------------------------------
# list_sessions
# ---------------------------------------------------------------------------


def test_list_sessions_empty_initially(manager):
    sessions = manager.list_sessions()
    assert isinstance(sessions, list)
    assert len(sessions) == 0


def test_list_sessions_populated_after_create(manager):
    s1 = manager.create_session(name="first")
    s2 = manager.create_session(name="second")
    sessions = manager.list_sessions()
    assert len(sessions) == 2
    ids = {s.id for s in sessions}
    assert s1.id in ids
    assert s2.id in ids


# ---------------------------------------------------------------------------
# add_photos
# ---------------------------------------------------------------------------


def test_add_photos_returns_photo_list(manager):
    session = manager.create_session()
    photos, failed = manager.add_photos(session.id, ["/tmp/photo1.jpg", "/tmp/photo2.jpg"])
    assert isinstance(photos, list)
    assert len(photos) == 2
    assert isinstance(failed, list)


def test_add_photos_skips_duplicates(manager):
    session = manager.create_session()
    # Duplicate filepaths in the same session are now properly skipped
    # via a pre-fetch check before INSERT.
    photos, _ = manager.add_photos(session.id, ["/tmp/dup.jpg", "/tmp/dup.jpg"])
    assert len(photos) == 1  # second filepath is a duplicate, skipped


def test_add_photos_empty_list(manager):
    session = manager.create_session()
    photos, _ = manager.add_photos(session.id, [])
    assert photos == []


# ---------------------------------------------------------------------------
# get_photos / count_photos
# ---------------------------------------------------------------------------


def test_get_photos_returns_photos_for_session(manager):
    session = manager.create_session()
    manager.add_photos(session.id, ["/tmp/a.jpg", "/tmp/b.jpg"])
    photos = manager.get_photos(session.id)
    assert len(photos) == 2
    filepaths = {p.filepath for p in photos}
    assert "/tmp/a.jpg" in filepaths
    assert "/tmp/b.jpg" in filepaths


def test_count_photos_returns_correct_int(manager):
    session = manager.create_session()
    assert manager.count_photos(session.id) == 0
    manager.add_photos(session.id, ["/tmp/p1.jpg", "/tmp/p2.jpg", "/tmp/p3.jpg"])
    assert manager.count_photos(session.id) == 3


# ---------------------------------------------------------------------------
# update_session_status
# ---------------------------------------------------------------------------


def test_update_session_status_changes_status(manager):
    session = manager.create_session()
    assert session.status == SessionStatus.DRAFT
    manager.update_session_status(session.id, SessionStatus.COMPLETED)
    updated = manager.get_session(session.id)
    assert updated.status == SessionStatus.COMPLETED


def test_update_analysis_status(manager):
    session = manager.create_session()
    manager.update_analysis_status(session.id, AnalysisStatus.RUNNING)
    updated = manager.get_session(session.id)
    assert updated.analysis_status == AnalysisStatus.RUNNING


def test_update_writeback_session_status(manager):
    session = manager.create_session()
    manager.update_writeback_session_status(session.id, WritebackStatus.DONE)
    updated = manager.get_session(session.id)
    assert updated.writeback_status == WritebackStatus.DONE


# ---------------------------------------------------------------------------
# delete_session
# ---------------------------------------------------------------------------


def test_delete_session_returns_true(manager):
    session = manager.create_session()
    assert manager.delete_session(session.id) is True


def test_delete_session_returns_false_for_bogus(manager):
    assert manager.delete_session("no-such-id") is False


def test_delete_session_subsequent_get_returns_none(manager):
    session = manager.create_session()
    manager.delete_session(session.id)
    assert manager.get_session(session.id) is None


def test_delete_session_cascades_to_photos(manager):
    session = manager.create_session()
    manager.add_photos(session.id, ["/tmp/cascade.jpg"])
    manager.delete_session(session.id)
    assert manager.count_photos(session.id) == 0


# ---------------------------------------------------------------------------
# Face observations round-trip
# ---------------------------------------------------------------------------


def test_save_and_get_observations(manager):
    session = manager.create_session()
    manager.add_photos(session.id, ["/tmp/obs_test.jpg"])
    photos = manager.get_photos(session.id)
    photo_id = photos[0].id

    obs = [
        {
            "photo_id": photo_id,
            "bbox": [10, 20, 100, 120],
            "embedding": [0.1, 0.2, 0.3],
            "confidence": 0.95,
            "thumbnail_path": "/tmp/thumb.jpg",
        }
    ]
    ids = manager.save_observations(session.id, obs)
    assert len(ids) == 1
    assert ids[0] > 0

    retrieved = manager.get_observations(session.id)
    assert len(retrieved) == 1
    assert retrieved[0]["photo_id"] == photo_id
    assert retrieved[0]["bbox"] == [10, 20, 100, 120]
    assert retrieved[0]["confidence"] == 0.95


def test_delete_observations(manager):
    session = manager.create_session()
    manager.add_photos(session.id, ["/tmp/obs_del.jpg"])
    photos = manager.get_photos(session.id)

    manager.save_observations(
        session.id, [{"photo_id": photos[0].id, "bbox": [0, 0, 50, 50], "embedding": [], "confidence": 0.8}]
    )
    assert len(manager.get_observations(session.id)) == 1
    manager.delete_observations(session.id)
    assert len(manager.get_observations(session.id)) == 0


# ---------------------------------------------------------------------------
# Face clusters round-trip
# ---------------------------------------------------------------------------


def test_save_get_update_delete_clusters(manager):
    session = manager.create_session()
    manager.add_photos(session.id, ["/tmp/cluster_a.jpg", "/tmp/cluster_b.jpg"])
    photos = manager.get_photos(session.id)

    ids = manager.save_clusters(
        session.id,
        [
            {
                "label": "Cluster A",
                "representative_obs_id": None,
                "members": [
                    {
                        "photo_id": photos[0].id,
                        "photo_path": photos[0].filepath,
                        "filename": photos[0].filename,
                        "bbox": [1, 2, 3, 4],
                        "confidence": 0.9,
                    },
                    {
                        "photo_id": photos[1].id,
                        "photo_path": photos[1].filepath,
                        "filename": photos[1].filename,
                        "bbox": [5, 6, 7, 8],
                        "confidence": 0.8,
                    },
                ],
                "status": "unbound",
            },
            {"label": "Cluster B", "representative_obs_id": None, "member_count": 5, "status": "unbound"},
        ],
    )
    assert len(ids) == 2
    assert ids[0] > 0

    clusters = manager.get_clusters(session.id)
    assert len(clusters) == 2
    labels = {c["label"] for c in clusters}
    assert "Cluster A" in labels
    cluster_a = next(c for c in clusters if c["label"] == "Cluster A")
    assert cluster_a["member_count"] == 2
    assert len(cluster_a["members"]) == 2
    assert cluster_a["members"][0]["photo_id"] == photos[0].id
    assert cluster_a["members"][0]["bbox"] == [1, 2, 3, 4]

    manager.update_cluster(ids[0], label="Renamed", member_count=10)
    clusters = manager.get_clusters(session.id)
    updated = next(c for c in clusters if c["id"] == ids[0])
    assert updated["label"] == "Renamed"
    assert updated["member_count"] == 10

    manager.delete_clusters(session.id)
    assert len(manager.get_clusters(session.id)) == 0


# ---------------------------------------------------------------------------
# Role bindings round-trip
# ---------------------------------------------------------------------------


def test_save_delete_get_bindings(manager):
    session = manager.create_session()
    # Need a cluster first: role_bindings FK references face_clusters(id)
    cluster_ids = manager.save_clusters(
        session.id,
        [
            {"label": "Test Cluster", "representative_obs_id": None, "member_count": 1, "status": "unbound"},
        ],
    )
    cluster_id = cluster_ids[0]

    bid = manager.save_binding(session.id, cluster_id=cluster_id, role_name="Engineer", keywords=["tech", "coding"])
    assert bid > 0

    bindings = manager.get_bindings(session.id)
    assert cluster_id in bindings
    assert bindings[cluster_id]["role_name"] == "Engineer"
    assert "tech" in bindings[cluster_id]["keywords"]

    deleted = manager.delete_binding(session.id, cluster_id=cluster_id)
    assert deleted is True

    bindings = manager.get_bindings(session.id)
    assert cluster_id not in bindings


# ---------------------------------------------------------------------------
# Writeback items round-trip
# ---------------------------------------------------------------------------


def test_writeback_items_round_trip(manager):
    session = manager.create_session()
    manager.add_photos(session.id, ["/tmp/wb_test.jpg"])
    photos = manager.get_photos(session.id)
    photo_id = photos[0].id

    item_ids = manager.save_writeback_items(
        session.id,
        [
            {
                "photo_id": photo_id,
                "keywords": ["hello", "world"],
                "xmp_path": "/tmp/wb_test.jpg.xmp",
                "backup_path": "/tmp/wb_test.jpg.xmp.gatherbak",
                "xmp_status": "pending",
                "error_message": "",
            }
        ],
    )
    assert len(item_ids) == 1
    assert item_ids[0] > 0

    items = manager.get_writeback_items(session.id)
    assert len(items) == 1
    assert items[0]["photo_id"] == photo_id
    assert items[0]["keywords"] == ["hello", "world"]
    assert items[0]["xmp_status"] == "pending"

    manager.update_writeback_item_status(item_ids[0], "written", "")
    items = manager.get_writeback_items(session.id)
    assert items[0]["xmp_status"] == "written"

    manager.update_writeback_item_status(item_ids[0], "failed", "disk full")
    items = manager.get_writeback_items(session.id)
    assert items[0]["xmp_status"] == "failed"
    assert items[0]["error_message"] == "disk full"


def test_save_writeback_items_returns_all_ids_for_batch(manager):
    session = manager.create_session()
    manager.add_photos(session.id, ["/tmp/wb_batch_a.jpg", "/tmp/wb_batch_b.jpg"])
    photos = manager.get_photos(session.id)

    item_ids = manager.save_writeback_items(
        session.id,
        [
            {
                "photo_id": photos[0].id,
                "keywords": ["a"],
                "xmp_path": "/tmp/wb_batch_a.jpg.xmp",
                "backup_path": "/tmp/wb_batch_a.jpg.xmp.gatherbak",
            },
            {
                "photo_id": photos[1].id,
                "keywords": ["b"],
                "xmp_path": "/tmp/wb_batch_b.jpg.xmp",
                "backup_path": "/tmp/wb_batch_b.jpg.xmp.gatherbak",
            },
        ],
    )

    assert len(item_ids) == 2
    assert item_ids[0] != item_ids[1]

    manager.update_writeback_item_status(item_ids[0], "written", "")
    manager.update_writeback_item_status(item_ids[1], "failed", "write failed")

    items = manager.get_writeback_items(session.id)
    assert [item["id"] for item in items] == item_ids
    assert [item["xmp_status"] for item in items] == ["written", "failed"]
    assert items[1]["error_message"] == "write failed"


# ---------------------------------------------------------------------------
# Concurrent session creation (no duplicate IDs)
# ---------------------------------------------------------------------------


def test_concurrent_create_sessions_no_duplicate_ids(manager):
    results_lock = threading.Lock()
    ids = []

    def create():
        s = manager.create_session(name="concurrent")
        with results_lock:
            ids.append(s.id)

    threads = [threading.Thread(target=create) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert len(ids) == 10
    assert len(set(ids)) == 10  # all unique


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


def test_add_photos_to_nonexistent_session_raises(manager):
    from shared.exceptions import SessionNotFoundError
    with pytest.raises(SessionNotFoundError, match="Session not found"):
        manager.add_photos("nonexistent-session-id", ["/tmp/foo.jpg"])


def test_save_observations_empty_list(manager):
    session = manager.create_session()
    ids = manager.save_observations(session.id, [])
    assert ids == []
