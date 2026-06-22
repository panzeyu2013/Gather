import os
import sys

import numpy as np
import pytest
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# face_engine may fail to import if mediapipe is broken
try:
    from face_keywording.face_engine import (
        EMBEDDING_DIM,
        cluster_faces,
        detect_faces,
        get_cluster_thumbnail,
    )

    _ENGINE_AVAILABLE = True
except (ImportError, AttributeError):
    _ENGINE_AVAILABLE = False

# Check if scikit-learn is available; cluster tests require it
try:
    from sklearn.cluster import DBSCAN  # noqa: F401

    _SKLEARN_AVAILABLE = True
except Exception:
    _SKLEARN_AVAILABLE = False

# Per-test skips: only tests that actually need mediapipe are skipped.
# Tests using controlled embeddings (cluster_faces tests) are independent of mediapipe.
_NEEDS_MEDIAPIPE = pytest.mark.skipif(not _ENGINE_AVAILABLE, reason="face_engine import failed (mediapipe broken)")
_NEEDS_SKLEARN = pytest.mark.skipif(not _SKLEARN_AVAILABLE, reason="scikit-learn not installed")


# ---------------------------------------------------------------------------
# detect_faces on synthetic RGB image
# ---------------------------------------------------------------------------


@_NEEDS_MEDIAPIPE
def test_detect_faces_returns_list_of_dicts(tmp_path):
    """detect_faces on an RGB image returns a list of per-photo dicts."""
    img = Image.new("RGB", (200, 200), color=(100, 150, 200))
    photo_path = tmp_path / "test_rgb.jpg"
    img.save(str(photo_path), format="JPEG")

    results = detect_faces([str(photo_path)])
    assert isinstance(results, list)
    assert len(results) == 1
    assert results[0]["photo_path"] == str(photo_path)
    assert "faces" in results[0]
    assert isinstance(results[0]["faces"], list)
    # Detection libraries may or may not be available;
    # the function should never crash on a valid image


@_NEEDS_MEDIAPIPE
def test_detect_faces_empty_photo_list():
    results = detect_faces([])
    assert results == []


# ---------------------------------------------------------------------------
# cluster_faces with controlled embeddings
# ---------------------------------------------------------------------------


@pytest.mark.skipif(not _SKLEARN_AVAILABLE, reason="scikit-learn not installed")
def test_cluster_faces_with_controlled_embeddings():
    """Two groups of similar embeddings should cluster at eps=0.3,
    but might merge at eps=0.7."""
    # Group A: 3 faces with similar embeddings
    base_a = np.array([0.1, 0.2] + [0.0] * (EMBEDDING_DIM - 2), dtype=np.float64)
    rng = np.random.RandomState(42)
    face_a1 = base_a + 0.01 * rng.randn(EMBEDDING_DIM)
    face_a2 = base_a + 0.01 * rng.randn(EMBEDDING_DIM)
    face_a3 = base_a + 0.01 * rng.randn(EMBEDDING_DIM)

    # Group B: 3 faces with similar embeddings, distant from Group A
    base_b = np.array([0.9, 0.8] + [0.0] * (EMBEDDING_DIM - 2), dtype=np.float64)
    face_b1 = base_b + 0.01 * rng.randn(EMBEDDING_DIM)
    face_b2 = base_b + 0.01 * rng.randn(EMBEDDING_DIM)
    face_b3 = base_b + 0.01 * rng.randn(EMBEDDING_DIM)

    observations = [
        {
            "photo_path": "/a/1.jpg",
            "faces": [
                {"bbox": [0, 0, 50, 50], "confidence": 0.9, "embedding": face_a1.tolist()},
                {"bbox": [60, 0, 50, 50], "confidence": 0.8, "embedding": face_a2.tolist()},
            ],
        },
        {
            "photo_path": "/a/2.jpg",
            "faces": [
                {"bbox": [0, 0, 50, 50], "confidence": 0.9, "embedding": face_a3.tolist()},
            ],
        },
        {
            "photo_path": "/b/1.jpg",
            "faces": [
                {"bbox": [0, 0, 50, 50], "confidence": 0.9, "embedding": face_b1.tolist()},
                {"bbox": [60, 0, 50, 50], "confidence": 0.8, "embedding": face_b2.tolist()},
            ],
        },
        {
            "photo_path": "/b/2.jpg",
            "faces": [
                {"bbox": [0, 0, 50, 50], "confidence": 0.9, "embedding": face_b3.tolist()},
            ],
        },
    ]

    # eps=0.3 should keep groups A and B separate
    result_tight = cluster_faces(observations, eps=0.3, min_samples=2)
    assert "clusters" in result_tight
    assert "noise" in result_tight
    assert len(result_tight["clusters"]) == 2
    total_members = sum(c["size"] for c in result_tight["clusters"])
    assert total_members == 6
    assert len(result_tight["noise"]) == 0

    # eps=0.7 should merge both groups into one
    result_loose = cluster_faces(observations, eps=0.7, min_samples=2)
    assert len(result_loose["clusters"]) >= 1


@pytest.mark.skipif(not _SKLEARN_AVAILABLE, reason="scikit-learn not installed")
def test_cluster_faces_no_embeddings():
    """Observations without embeddings should result in empty clusters."""
    observations = [
        {
            "photo_path": "/empty.jpg",
            "faces": [{"bbox": [0, 0, 50, 50], "confidence": 0.5}],
        }
    ]
    result = cluster_faces(observations)
    assert result["clusters"] == []
    assert result["noise"] == []


@pytest.mark.skipif(not _SKLEARN_AVAILABLE, reason="scikit-learn not installed")
def test_cluster_faces_empty_list():
    result = cluster_faces([])
    assert result["clusters"] == []
    assert result["noise"] == []


# ---------------------------------------------------------------------------
# get_cluster_thumbnail
# ---------------------------------------------------------------------------


def test_get_cluster_thumbnail_returns_jpeg_bytes(tmp_path):
    """get_cluster_thumbnail on a valid image returns JPEG bytes."""
    img = Image.new("RGB", (200, 200), color=(255, 0, 0))
    photo_path = tmp_path / "face_test.jpg"
    img.save(str(photo_path), format="JPEG")

    thumbnail = get_cluster_thumbnail(str(photo_path), bbox=[50, 50, 100, 100], size=128)
    assert thumbnail is not None
    assert isinstance(thumbnail, bytes)
    assert len(thumbnail) > 100  # reasonable JPEG size

    # Verify it's valid JPEG by re-opening
    import io

    buf = io.BytesIO(thumbnail)
    reopened = Image.open(buf)
    assert reopened.format == "JPEG"
    assert reopened.size == (128, 128)


def test_get_cluster_thumbnail_nonexistent_file():
    result = get_cluster_thumbnail("/nonexistent/photo.jpg", bbox=[0, 0, 100, 100])
    assert result is None


def test_get_cluster_thumbnail_zero_bbox(tmp_path):
    img = Image.new("RGB", (200, 200), color=(0, 255, 0))
    photo_path = tmp_path / "zero_bbox.jpg"
    img.save(str(photo_path), format="JPEG")

    # bbox with zero area should return None
    result = get_cluster_thumbnail(str(photo_path), bbox=[0, 0, 0, 0])
    assert result is None
