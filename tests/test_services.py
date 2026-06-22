import os
import sys
import time

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from face_keywording.service import FaceKeywordingService
from similarity.service import SimilarityService

# ---------------------------------------------------------------------------
# FaceKeywordingService
# ---------------------------------------------------------------------------


def test_fkws_create_and_get_session(manager):
    from shared.models import SessionStatus

    session = manager.create_session(name="FKWS Test")
    sid = session.id

    retrieved_session = manager.get_session(sid)
    photos = manager.get_photos(sid)
    assert retrieved_session is not None
    assert retrieved_session.name == "FKWS Test"
    assert retrieved_session.status == SessionStatus.DRAFT
    assert len(photos) == 0


def test_fkws_add_photos(manager):
    from shared.session_service import SessionService

    session_svc = SessionService(manager)
    session_data = session_svc.create_session(name="Photo Load")
    sid = session_data["id"]

    result = session_svc.add_photos(sid, ["/tmp/fkws_a.jpg", "/tmp/fkws_b.jpg", "/tmp/fkws_c.jpg"])
    assert result["added"] == 3
    assert result["total"] == 3

    photos = manager.get_photos(sid)
    assert len(photos) == 3
    assert manager.count_photos(sid) == 3


def test_fkws_bind_role(manager):
    svc = FaceKeywordingService(manager)
    session = manager.create_session(name="Bind Test")
    sid = session.id

    # Create a face cluster first (bind_role requires a valid FK reference)
    cluster_ids = manager.save_clusters(
        sid,
        [
            {"label": "Test Cluster", "representative_obs_id": None, "member_count": 1, "status": "unbound"},
        ],
    )
    cluster_id = str(cluster_ids[0])

    result = svc.bind_role(sid, cluster_id, "Bride", ["wedding", "bride"])
    assert result["status"] == "ok"
    assert result["cluster_id"] == cluster_id

    # Cache should have the binding
    with svc._state_lock:
        bindings = svc._bindings_cache.get(sid, {})
        assert cluster_id in bindings
        assert bindings[cluster_id]["role_name"] == "Bride"


def test_fkws_bind_role_invalid_cluster_is_visible(manager):
    svc = FaceKeywordingService(manager)
    session = manager.create_session(name="Bad Bind")
    sid = session.id

    with pytest.raises(ValueError, match="Cluster not found"):
        svc.bind_role(sid, "9999", "Bride", ["wedding"])

    with svc._state_lock:
        assert "9999" not in svc._bindings_cache.get(sid, {})


def test_save_analysis_maps_cluster_ids_and_restores_members(manager):
    from shared.session_service import SessionService

    session_svc = SessionService(manager)
    session_data = session_svc.create_session(name="Persist Analysis")
    sid = session_data["id"]
    session_svc.add_photos(sid, ["/tmp/persist_a.jpg", "/tmp/persist_b.jpg"])
    photos = manager.get_photos(sid)
    photo_map = {p.filepath: p.to_dict() for p in photos}

    p0, p1 = photos[0], photos[1]
    clusters = [
        {
            "cluster_id": 0,
            "label": "Person-01",
            "members": [
                {
                    "photo_id": p0.id,
                    "photo_path": p0.filepath,
                    "filename": p0.filename,
                    "bbox": [1, 2, 3, 4],
                    "confidence": 0.9,
                },
                {
                    "photo_id": p1.id,
                    "photo_path": p1.filepath,
                    "filename": p1.filename,
                    "bbox": [5, 6, 7, 8],
                    "confidence": 0.8,
                },
            ],
            "size": 2,
        }
    ]
    detections = [
        {"photo_path": p0.filepath, "faces": [{"bbox": [1, 2, 3, 4], "confidence": 0.9}]},
        {"photo_path": p1.filepath, "faces": [{"bbox": [5, 6, 7, 8], "confidence": 0.8}]},
    ]

    persisted = FaceKeywordingService._save_analysis_to_db(manager, sid, detections, clusters, photo_map)
    assert persisted[0]["cluster_id"] != "0"

    svc2 = FaceKeywordingService(manager)
    restored = svc2.get_clusters(sid)["clusters"]
    assert len(restored) == 1
    assert restored[0]["cluster_id"] == persisted[0]["cluster_id"]
    assert restored[0]["size"] == 2
    assert [m["photo_id"] for m in restored[0]["members"]] == [p0.id, p1.id]

    result = svc2.bind_role(sid, persisted[0]["cluster_id"], "Lead", ["lead"])
    assert result["status"] == "ok"


def test_fkws_merge_clusters(manager):
    svc = FaceKeywordingService(manager)
    session = manager.create_session(name="Merge Test")
    sid = session.id
    manager.add_photos(sid, ["/tmp/merge_a.jpg", "/tmp/merge_b.jpg"])
    photos = manager.get_photos(sid)
    cluster_ids = manager.save_clusters(
        sid,
        [
            {
                "label": "Person-01",
                "members": [
                    {
                        "photo_id": photos[0].id,
                        "photo_path": photos[0].filepath,
                        "filename": photos[0].filename,
                        "bbox": [0, 0, 50, 50],
                        "confidence": 0.9,
                    }
                ],
            },
            {
                "label": "Person-02",
                "members": [
                    {
                        "photo_id": photos[1].id,
                        "photo_path": photos[1].filepath,
                        "filename": photos[1].filename,
                        "bbox": [0, 0, 50, 50],
                        "confidence": 0.9,
                    }
                ],
            },
        ],
    )

    with svc._state_lock:
        svc._clusters_cache[sid] = [
            {
                "cluster_id": str(cluster_ids[0]),
                "label": "Person-01",
                "members": [
                    {
                        "photo_id": photos[0].id,
                        "photo_path": photos[0].filepath,
                        "filename": photos[0].filename,
                        "bbox": [0, 0, 50, 50],
                        "confidence": 0.9,
                    },
                ],
                "size": 1,
            },
            {
                "cluster_id": str(cluster_ids[1]),
                "label": "Person-02",
                "members": [
                    {
                        "photo_id": photos[1].id,
                        "photo_path": photos[1].filepath,
                        "filename": photos[1].filename,
                        "bbox": [0, 0, 50, 50],
                        "confidence": 0.9,
                    },
                ],
                "size": 1,
            },
        ]

    result = svc.merge_clusters(sid, str(cluster_ids[1]), str(cluster_ids[0]))
    assert result["status"] == "ok"
    assert result["target_id"] == str(cluster_ids[0])

    with svc._state_lock:
        clusters = svc._clusters_cache[sid]
        target = next(c for c in clusters if str(c["cluster_id"]) == str(cluster_ids[0]))
        assert target["size"] == 2
    db_target = next(c for c in manager.get_clusters(sid) if c["id"] == cluster_ids[0])
    assert len(db_target["members"]) == 2


def test_fkws_delete_session(manager):
    session = manager.create_session(name="Delete Me")
    sid = session.id

    assert manager.delete_session(sid) is True
    assert manager.get_session(sid) is None


def test_fkws_list_sessions(manager):
    assert manager.list_sessions() == []

    manager.create_session(name="S1")
    manager.create_session(name="S2")
    assert len(manager.list_sessions()) == 2


def test_fkws_unbind_role(manager):
    svc = FaceKeywordingService(manager)
    session = manager.create_session(name="Unbind Test")
    sid = session.id

    # Create a face cluster first (bind_role requires a valid FK reference)
    cluster_ids = manager.save_clusters(
        sid,
        [
            {"label": "Unbind Cluster", "representative_obs_id": None, "member_count": 1, "status": "unbound"},
        ],
    )
    cluster_id = str(cluster_ids[0])

    svc.bind_role(sid, cluster_id, "Groom", ["groom", "wedding"])
    with svc._state_lock:
        assert cluster_id in svc._bindings_cache.get(sid, {})

    result = svc.unbind_role(sid, cluster_id)
    assert result["status"] == "ok"
    with svc._state_lock:
        bindings = svc._bindings_cache.get(sid, {})
        assert cluster_id not in bindings


def test_fkws_remove_member(manager):
    svc = FaceKeywordingService(manager)
    session = manager.create_session(name="Remove Member")
    sid = session.id
    manager.add_photos(sid, ["/tmp/remove_a.jpg", "/tmp/remove_b.jpg"])
    photos = manager.get_photos(sid)
    cluster_ids = manager.save_clusters(
        sid,
        [
            {
                "label": "Person-01",
                "members": [
                    {
                        "photo_id": photos[0].id,
                        "photo_path": photos[0].filepath,
                        "filename": photos[0].filename,
                        "bbox": [0, 0, 50, 50],
                        "confidence": 0.9,
                    },
                    {
                        "photo_id": photos[1].id,
                        "photo_path": photos[1].filepath,
                        "filename": photos[1].filename,
                        "bbox": [0, 0, 50, 50],
                        "confidence": 0.9,
                    },
                ],
            },
        ],
    )

    with svc._state_lock:
        svc._clusters_cache[sid] = [
            {
                "cluster_id": str(cluster_ids[0]),
                "label": "Person-01",
                "members": [
                    {
                        "photo_id": photos[0].id,
                        "photo_path": photos[0].filepath,
                        "filename": photos[0].filename,
                        "bbox": [0, 0, 50, 50],
                        "confidence": 0.9,
                    },
                    {
                        "photo_id": photos[1].id,
                        "photo_path": photos[1].filepath,
                        "filename": photos[1].filename,
                        "bbox": [0, 0, 50, 50],
                        "confidence": 0.9,
                    },
                ],
                "size": 2,
            },
        ]

    result = svc.remove_member(sid, str(cluster_ids[0]), photos[0].id)
    assert result["status"] == "ok"

    with svc._state_lock:
        clusters = svc._clusters_cache[sid]
        target = next(c for c in clusters if str(c["cluster_id"]) == str(cluster_ids[0]))
        assert target["size"] == 1
    db_target = next(c for c in manager.get_clusters(sid) if c["id"] == cluster_ids[0])
    assert db_target["member_count"] == 1
    assert len(db_target["members"]) == 1


def test_execute_writeback_partial_when_audit_fails(manager, tmp_path, monkeypatch):
    from shared.session_service import SessionService

    svc = FaceKeywordingService(manager)
    session_svc = SessionService(manager)
    session_data = session_svc.create_session(name="Audit Fail")
    sid = session_data["id"]
    photo = tmp_path / "audit.jpg"
    photo.write_text("fake image")
    session_svc.add_photos(sid, [str(photo)])
    photos = manager.get_photos(sid)
    cluster_id = manager.save_clusters(
        sid,
        [
            {
                "label": "Person-01",
                "members": [
                    {
                        "photo_id": photos[0].id,
                        "photo_path": photos[0].filepath,
                        "filename": photos[0].filename,
                        "bbox": [0, 0, 10, 10],
                        "confidence": 0.9,
                    }
                ],
            }
        ],
    )[0]
    svc.bind_role(sid, str(cluster_id), "Lead", ["lead"])

    def fail_audit(*args, **kwargs):
        raise RuntimeError("audit table unavailable")

    monkeypatch.setattr(manager, "save_writeback_items", fail_audit)

    # With audit-first ordering, save_writeback_items failure propagates
    # before any XMP is written. The exception is raised to the caller.
    with pytest.raises(RuntimeError, match="audit table unavailable"):
        svc.execute_writeback(sid)


def test_rollback_writeback_restores_backup(manager, tmp_path):
    from shared.session_service import SessionService

    svc = FaceKeywordingService(manager)
    session_svc = SessionService(manager)
    session_data = session_svc.create_session(name="Rollback")
    sid = session_data["id"]
    photo = tmp_path / "rollback.jpg"
    photo.write_text("fake image")
    session_svc.add_photos(sid, [str(photo)])
    photos = manager.get_photos(sid)
    cluster_id = manager.save_clusters(
        sid,
        [
            {
                "label": "Person-01",
                "members": [
                    {
                        "photo_id": photos[0].id,
                        "photo_path": photos[0].filepath,
                        "filename": photos[0].filename,
                        "bbox": [0, 0, 10, 10],
                        "confidence": 0.9,
                    }
                ],
            }
        ],
    )[0]
    svc.bind_role(sid, str(cluster_id), "Lead", ["lead"])

    xmp_path = tmp_path / "rollback.jpg.xmp"
    backup_path = tmp_path / "rollback.jpg.xmp.gatherbak"
    xmp_path.write_text("<xmpmeta>modified</xmpmeta>")
    backup_path.write_text("<xmpmeta>original</xmpmeta>")

    result = svc.rollback_writeback(sid)

    assert result["rolled_back"] == 1
    assert result["errors"] == []
    assert xmp_path.read_text() == "<xmpmeta>original</xmpmeta>"
    assert not backup_path.exists()


def test_cleanup_falls_back_to_db_photo_paths_when_caches_are_empty(manager, tmp_path):
    from shared.session_service import SessionService
    from shared.xmp_writer import write_keywords

    svc = FaceKeywordingService(manager)
    session_svc = SessionService(manager)
    session_data = session_svc.create_session(name="Cleanup Fallback")
    sid = session_data["id"]
    photo = tmp_path / "cleanup.jpg"
    photo.write_text("fake image")
    session_svc.add_photos(sid, [str(photo)])
    write_keywords([str(photo)], {str(photo): ["cleanup-test"]})

    xmp_path = tmp_path / "cleanup.jpg.xmp"
    assert xmp_path.exists()

    result = svc.cleanup(sid)

    assert result["deleted"] == 1
    assert result["errors"] == []
    assert not xmp_path.exists()


# ---------------------------------------------------------------------------
# SimilarityService
# ---------------------------------------------------------------------------


def create_synthetic_images(tmp_path, count):
    """Create count synthetic JPEG images of different solid colors."""
    from PIL import Image

    paths = []
    for i in range(count):
        r = (i * 50) % 256
        g = (i * 80 + 30) % 256
        b = (i * 110 + 60) % 256
        img = Image.new("RGB", (64, 64), color=(r, g, b))
        p = tmp_path / f"synth_{i:03d}.jpg"
        img.save(str(p), format="JPEG")
        paths.append(str(p))
    return paths


def test_similarity_start_analysis_returns_started(manager, tmp_path):
    svc = SimilarityService(manager)
    session = manager.create_session(name="Sim Test")
    sid = session.id

    img_paths = create_synthetic_images(tmp_path, 5)
    manager.add_photos(sid, img_paths)

    result = svc.start_analysis(sid, threshold=12, min_group_size=2)
    assert result["status"] == "started"
    assert result["session_id"] == sid

    for _ in range(50):
        res = svc.get_result(sid)
        if res.get("status") in ("done", "error"):
            break
        time.sleep(0.2)

    final = svc.get_result(sid)
    assert final["status"] == "done"
    assert "groups" in final
    assert "stats" in final


def test_similarity_get_result_idle(manager):
    svc = SimilarityService(manager)
    session = manager.create_session()

    result = svc.get_result(session.id)
    assert result["status"] == "idle"


def test_similarity_start_analysis_no_photos_raises(manager):
    svc = SimilarityService(manager)
    session = manager.create_session()

    with pytest.raises(ValueError, match="No photos"):
        svc.start_analysis(session.id)


def test_similarity_start_analysis_nonexistent_session_raises(manager):
    svc = SimilarityService(manager)
    with pytest.raises(ValueError, match="Session not found"):
        svc.start_analysis("nonexistent-session")


def test_similarity_recluster_no_cache_raises(manager):
    svc = SimilarityService(manager)
    session = manager.create_session()

    with pytest.raises(ValueError, match="No analysis results"):
        svc.recluster(session.id)


def test_similarity_execute_writeback(manager):
    from shared.models import WritebackStatus

    svc = SimilarityService(manager)
    session = manager.create_session()
    sid = session.id

    groups = [
        {
            "id": 0,
            "label": "Group_01",
            "count": 2,
            "images": [
                {"path": "/photos/a.jpg"},
                {"path": "/photos/b.jpg"},
            ],
        },
        {
            "id": 1,
            "label": "Group_02",
            "count": 1,
            "images": [
                {"path": "/photos/c.jpg"},
            ],
        },
    ]

    report = svc.execute_writeback(sid, groups)
    assert report["status"] == "completed"
    assert "report" in report
    assert report["total_affected"] == 3
    assert "Group_00: 2 images" in report["report"]
    assert "Group_01: 1 images" in report["report"]

    # Report-only writeback does not consume the XMP writeback lifecycle.
    assert manager.get_session(sid).writeback_status == WritebackStatus.IDLE
    second = svc.execute_writeback(sid, groups, {"addPrefix": True})
    assert second["status"] == "completed"
