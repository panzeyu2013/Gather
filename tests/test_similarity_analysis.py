# tests/test_similarity_analysis.py - Unit tests for similarity/analysis.py.

import numpy as np
from PIL import Image

from similarity.analysis import (
    _bits_to_hex,
    _cluster_hashes,
    _compute_single_dhash,
    _hex_to_bits,
    compute_hashes,
)

# ---------------------------------------------------------------------------
# _compute_single_dhash on a small test image (use PIL to create)
# ---------------------------------------------------------------------------


def test_compute_single_dhash_valid_image(tmp_path):
    img = Image.new("RGB", (128, 128), color=(255, 0, 0))
    img_path = tmp_path / "test_red.jpg"
    img.save(str(img_path), format="JPEG")

    path, bits, err = _compute_single_dhash(str(img_path))

    assert err == ""
    assert path == str(img_path)
    assert bits is not None
    assert isinstance(bits, np.ndarray)
    assert bits.dtype == np.uint8
    assert bits is not None
    assert bits.shape == (64,)


def test_compute_single_dhash_different_images_produce_different_hashes(tmp_path):
    from PIL import ImageDraw

    # Use PNG (lossless) so that gradient boundaries are preserved at low res.
    img1 = Image.new("RGB", (128, 128), color=(255, 255, 255))
    draw1 = ImageDraw.Draw(img1)
    draw1.rectangle([0, 0, 63, 127], fill=(0, 0, 0))

    img2 = Image.new("RGB", (128, 128), color=(255, 255, 255))
    draw2 = ImageDraw.Draw(img2)
    draw2.rectangle([0, 0, 42, 127], fill=(0, 0, 0))
    draw2.rectangle([85, 0, 127, 127], fill=(0, 0, 0))

    p1 = tmp_path / "left_black.png"
    p2 = tmp_path / "stripes.png"
    img1.save(str(p1), format="PNG")
    img2.save(str(p2), format="PNG")

    _, bits1, _ = _compute_single_dhash(str(p1))
    _, bits2, _ = _compute_single_dhash(str(p2))

    bits1_arr = bits1 if bits1 is not None else np.array([], dtype=np.uint8)
    bits2_arr = bits2 if bits2 is not None else np.array([], dtype=np.uint8)
    assert not np.array_equal(bits1_arr, bits2_arr)


def test_compute_single_dhash_nonexistent_file():
    path, bits, err = _compute_single_dhash("/nonexistent/image.jpg")

    assert bits is None
    assert err != ""
    assert path == "/nonexistent/image.jpg"


def test_compute_single_dhash_grayscale_image(tmp_path):
    img = Image.new("L", (64, 64), color=128)
    img_path = tmp_path / "gray.jpg"
    img.save(str(img_path), format="JPEG")

    path, bits, err = _compute_single_dhash(str(img_path))

    assert err == ""
    assert bits is not None
    assert bits.shape == (64,)


# ---------------------------------------------------------------------------
# _cluster_hashes with controlled hash arrays
# ---------------------------------------------------------------------------


def make_hash_bits(*indices: int) -> np.ndarray:
    """Create a 64-bit hash array where only the specified bit indices are 1."""
    arr = np.zeros(64, dtype=np.uint8)
    for idx in indices:
        arr[idx] = 1
    return arr


def test_cluster_hashes_single_cluster():
    """Two nearly identical hashes should cluster together at low threshold."""
    h1 = make_hash_bits(0, 1, 2, 3, 4)
    h2 = make_hash_bits(0, 1, 2, 3, 5)  # differs by 2 bits

    result = _cluster_hashes(
        [("/a.jpg", h1), ("/b.jpg", h2)],
        threshold=12,
        min_group_size=2,
    )

    assert result["stats"]["total"] == 2
    assert result["stats"]["grouped"] == 2
    assert result["stats"]["num_groups"] == 1
    assert len(result["groups"]) == 1
    assert result["groups"][0]["count"] == 2


def test_cluster_hashes_multiple_clusters():
    """Well-separated hash groups should form distinct clusters."""
    h_a1 = make_hash_bits(0, 1, 2)
    h_a2 = make_hash_bits(0, 1, 3)
    h_b1 = make_hash_bits(60, 61, 62)
    h_b2 = make_hash_bits(60, 61, 63)

    result = _cluster_hashes(
        [("/a1.jpg", h_a1), ("/a2.jpg", h_a2), ("/b1.jpg", h_b1), ("/b2.jpg", h_b2)],
        threshold=12,
        min_group_size=2,
    )

    assert result["stats"]["total"] == 4
    assert result["stats"]["num_groups"] >= 1


def test_cluster_hashes_threshold_edge_case_strict():
    """With threshold=0, identical hashes cluster; slightly different ones do not."""
    h1 = make_hash_bits(0, 1)
    h2 = make_hash_bits(0, 1)  # identical
    h3 = make_hash_bits(2, 3)  # different

    result = _cluster_hashes(
        [("/a.jpg", h1), ("/b.jpg", h2), ("/c.jpg", h3)],
        threshold=0,
        min_group_size=2,
    )

    assert result["stats"]["total"] == 3
    grouped = sum(g["count"] for g in result["groups"])
    assert grouped >= 2  # h1 + h2 should cluster
    # h3 should be ungrouped with min_group_size=2
    assert result["stats"]["ungrouped"] >= 1


def test_cluster_hashes_min_group_size_excludes_small_clusters():
    """Groups smaller than min_group_size are placed in ungrouped."""
    h1 = make_hash_bits(0, 1)
    h2 = make_hash_bits(60, 61)

    result = _cluster_hashes(
        [("/a.jpg", h1), ("/b.jpg", h2)],
        threshold=12,
        min_group_size=3,  # larger than total images
    )

    assert result["stats"]["num_groups"] == 0
    assert result["stats"]["ungrouped"] == 2


def test_cluster_hashes_empty_list():
    result = _cluster_hashes([], threshold=12, min_group_size=2)

    assert result["stats"]["total"] == 0
    assert result["stats"]["grouped"] == 0
    assert result["stats"]["ungrouped"] == 0
    assert result["stats"]["num_groups"] == 0
    assert result["groups"] == []
    assert result["ungrouped"] == []


def test_cluster_hashes_single_image():
    h1 = make_hash_bits(0, 1, 2)
    result = _cluster_hashes([("/a.jpg", h1)], threshold=12, min_group_size=2)

    assert result["stats"]["total"] == 1
    assert result["stats"]["grouped"] == 0
    assert result["stats"]["ungrouped"] == 1
    assert result["stats"]["num_groups"] == 0
    assert len(result["ungrouped"]) == 1
    assert result["ungrouped"][0]["path"] == "/a.jpg"


def test_cluster_hashes_representative_is_set():
    """Each group should have exactly one representative image."""
    h1 = make_hash_bits(0, 1, 2, 3)
    h2 = make_hash_bits(0, 1, 2, 4)
    h3 = make_hash_bits(0, 1, 5, 6)

    result = _cluster_hashes(
        [("/a.jpg", h1), ("/b.jpg", h2), ("/c.jpg", h3)],
        threshold=12,
        min_group_size=2,
    )

    for group in result["groups"]:
        rep_count = sum(1 for img in group["images"] if img["representative"])
        assert rep_count == 1


# ---------------------------------------------------------------------------
# hex_to_bits and bits_to_hex roundtrip
# ---------------------------------------------------------------------------


def test_bits_to_hex_to_bits_roundtrip():
    original = make_hash_bits(0, 7, 15, 31, 63)

    hex_str = _bits_to_hex(original)
    assert isinstance(hex_str, str)
    assert len(hex_str) > 0

    restored = _hex_to_bits(hex_str)
    assert restored is not None
    assert np.array_equal(original, restored)


def test_bits_to_hex_produces_consistent_output():
    h1 = make_hash_bits(0, 5, 10, 20)
    h2 = make_hash_bits(0, 5, 10, 20)

    assert _bits_to_hex(h1) == _bits_to_hex(h2)


def test_hex_to_bits_invalid_hex_returns_none():
    assert _hex_to_bits("not a hex string!!") is None
    assert _hex_to_bits("g") is None


def test_hex_to_bits_empty_string_returns_empty_array():
    result = _hex_to_bits("")
    assert isinstance(result, np.ndarray)
    assert result.size == 0


def test_hex_to_bits_none_input():
    result = _hex_to_bits(None)  # type: ignore
    assert result is None


# ---------------------------------------------------------------------------
# compute_hashes on empty list returns empty
# ---------------------------------------------------------------------------


def test_compute_hashes_empty_list_returns_empty():
    result = compute_hashes([])
    assert result["hashes"] == {}
    assert result["successful"] == []
    assert result["failed"] == []


def test_compute_hashes_single_image(tmp_path):
    img = Image.new("RGB", (64, 64), color=(100, 150, 200))
    img_path = tmp_path / "single.jpg"
    img.save(str(img_path), format="JPEG")

    result = compute_hashes([str(img_path)])

    assert len(result["successful"]) == 1
    assert len(result["failed"]) == 0
    assert str(img_path) in result["hashes"]
    hex_val = result["hashes"][str(img_path)]
    assert isinstance(hex_val, str)
    assert len(hex_val) > 0
    # Verify roundtrip
    bits = _hex_to_bits(hex_val)
    assert bits is not None
    assert bits is not None
    assert bits.shape == (64,)


def test_compute_hashes_with_nonexistent_path():
    result = compute_hashes(["/nonexistent/photo.jpg"])

    assert len(result["successful"]) == 0
    assert len(result["failed"]) == 1
    assert result["failed"][0]["path"] == "/nonexistent/photo.jpg"
    assert "error" in result["failed"][0]


def test_compute_hashes_with_progress_callback(tmp_path):
    img = Image.new("RGB", (64, 64), color=(50, 50, 50))
    img_path = tmp_path / "progress.jpg"
    img.save(str(img_path), format="JPEG")

    call_records: list[tuple[int, int, str]] = []

    def progress_cb(current: int, total: int, msg: str) -> None:
        call_records.append((current, total, msg))

    result = compute_hashes([str(img_path)], progress_callback=progress_cb)

    assert len(call_records) >= 1
    assert call_records[0][1] == 1  # total
    assert result["successful"][0][0] == str(img_path)
