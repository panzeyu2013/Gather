# similarity/analysis.py - Photo similarity grouping via dHash + clustering.
#
# Extracts perceptual hashes (dHash) from images using Pillow + imagehash,
# then performs agglomerative (hierarchical) clustering on the Hamming
# distance matrix to group visually similar photos.
#
# The core algorithms are inlined from the legacy engine/ pipeline to
# avoid cross-directory import dependencies.

from __future__ import annotations

import logging
import os
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

import imagehash as _imagehash
import numpy as np
from PIL import Image
from scipy.cluster.hierarchy import fcluster, linkage
from scipy.spatial.distance import pdist

from shared.constants import HASH_SIZE, MAX_ANALYSIS_WORKERS, MAX_SIMILARITY_PHOTOS

logger = logging.getLogger("gather.similarity")

_CPU_COUNT = os.cpu_count() or 4

_worker_pool: ThreadPoolExecutor | None = None
_worker_pool_size: int = 0
_worker_pool_lock = threading.Lock()


def _get_worker_pool(max_workers: int) -> ThreadPoolExecutor:
    global _worker_pool, _worker_pool_size
    if _worker_pool is not None and _worker_pool_size == max_workers:
        return _worker_pool
    with _worker_pool_lock:
        if _worker_pool is not None and _worker_pool_size == max_workers:
            return _worker_pool
        if _worker_pool is not None:
            _worker_pool.shutdown(wait=True)
        _worker_pool = ThreadPoolExecutor(max_workers=max_workers)
        _worker_pool_size = max_workers
    return _worker_pool


def shutdown_worker_pool() -> None:
    global _worker_pool
    with _worker_pool_lock:
        if _worker_pool is not None:
            _worker_pool.shutdown(wait=True)
            _worker_pool = None


def _compute_single_dhash(
    image_path: str,
    hash_size: int = HASH_SIZE,
) -> tuple[str, np.ndarray | None, str]:
    """Compute dHash for a single image file.

    Returns (path, hash_bits_array, error).
    On success error is "" and hash_bits_array is a flat uint8 ndarray
    of 64 bits (0 or 1).  On failure hash_bits_array is None.
    """
    try:
        # TODO: The os.open + os.fdopen pattern is unnecessary here since
        # Image.open accepts a path directly. The img.load() call is redundant
        # (thumbnail triggers decode). The 512×512 pre-resize may degrade dHash
        # quality for very large images — consider removing or using a dynamic size.
        fd = os.open(image_path, os.O_RDONLY)
        with os.fdopen(fd, 'rb') as fh, Image.open(fh) as img:
            img.load()
            img.thumbnail((512, 512), Image.Resampling.LANCZOS)
            if img.mode != "L":
                img = img.convert("L")  # type: ignore[assignment]
            h = _imagehash.dhash(img, hash_size=hash_size)
            bits = h.hash.flatten().astype(np.uint8)
        return (image_path, bits, "")
    except Exception as e:
        return (image_path, None, str(e))


# ---------------------------------------------------------------------------
# Clustering (inlined from engine/clusterer.py)
# ---------------------------------------------------------------------------


def _cluster_hashes(
    paths_and_hashes: list[tuple[str, np.ndarray]],
    threshold: int = 12,
    min_group_size: int = 2,
) -> dict[str, Any]:
    """Run hierarchical clustering on precomputed dHash bit arrays.

    Args:
        paths_and_hashes: list of (path, hash_bits_array) tuples.
        threshold: max Hamming distance for images to be clustered together.
                   Lower = stricter similarity. Typical range: 4-20.
        min_group_size: minimum number of images to form a group.

    Returns a dict with keys "stats", "groups", "ungrouped".
    """
    n = len(paths_and_hashes)
    paths = [p for p, _ in paths_and_hashes]
    hashes = [h for _, h in paths_and_hashes]

    if n == 0:
        return {
            "stats": {"total": 0, "grouped": 0, "ungrouped": 0, "num_groups": 0},
            "groups": [],
            "ungrouped": [],
        }

    if n == 1:
        return {
            "stats": {"total": 1, "grouped": 0, "ungrouped": 1, "num_groups": 0},
            "groups": [],
            "ungrouped": [{"path": paths[0], "error": None}],
        }

    binary_matrix = np.stack(hashes, axis=0)

    condensed_dist = pdist(binary_matrix, metric="hamming")
    bits_per_hash = binary_matrix.shape[1]
    condensed_dist *= bits_per_hash

    z = linkage(condensed_dist, method="average")
    labels = fcluster(z, t=threshold, criterion="distance")

    group_map: dict[int, list[int]] = {}
    for idx, label in enumerate(labels):
        group_map.setdefault(int(label), []).append(idx)

    groups_out: list[dict[str, Any]] = []
    ungrouped: list[dict[str, Any]] = []
    group_counter = 0

    for indices in group_map.values():
        if len(indices) >= min_group_size:
            group_counter += 1
            if len(indices) > 1:
                sub_matrix = binary_matrix[indices]
                centroid = sub_matrix.mean(axis=0)
                dists = np.abs(sub_matrix - centroid).sum(axis=1)
                rep_idx_in_group = int(np.argmin(dists))
            else:
                rep_idx_in_group = 0

            images: list[dict[str, Any]] = []
            for gi, orig_idx in enumerate(indices):
                images.append(
                    {
                        "path": paths[orig_idx],
                        "representative": gi == rep_idx_in_group,
                    }
                )
            groups_out.append(
                {
                    "id": group_counter,
                    "label": f"Group_{group_counter:02d}",
                    "count": len(indices),
                    "images": images,
                }
            )
        else:
            ungrouped.extend({"path": paths[orig_idx], "error": None} for orig_idx in indices)

    total = n
    grouped_count = sum(g["count"] for g in groups_out)

    return {
        "stats": {
            "total": total,
            "grouped": grouped_count,
            "ungrouped": len(ungrouped),
            "num_groups": len(groups_out),
        },
        "groups": groups_out,
        "ungrouped": ungrouped,
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def compute_hashes(
    photo_paths: list[str],
    workers: int | None = None,
    progress_callback: Callable[[int, int, str], None] | None = None,
    cancel_event: threading.Event | None = None,
    hash_persist_callback: Callable[[str, str], None] | None = None,
) -> dict[str, Any]:
    """Compute dHash for all photos, returning only the hex hash map.

    This omits the clustering step so that hashes from this batch can
    be merged with previously cached hashes before running a single
    clustering pass on the combined set.
    """
    total = len(photo_paths)

    if total > MAX_SIMILARITY_PHOTOS:
        raise ValueError(f"Too many photos for similarity analysis: {total}. Maximum is {MAX_SIMILARITY_PHOTOS}.")

    if workers is None:
        workers = min(_CPU_COUNT, MAX_ANALYSIS_WORKERS)

    workers = max(workers, 1)

    successful: list[tuple[str, np.ndarray]] = []
    failed: list[dict[str, Any]] = []
    hash_cache: dict[str, str] = {}

    if progress_callback:
        progress_callback(0, total, "Computing hashes...")

    last_emit = 0.0

    def _handle_result(path: str, bits: np.ndarray | None, err: str) -> None:
        nonlocal last_emit
        if err:
            failed.append({"path": path, "error": err})
        else:
            if bits is not None:
                successful.append((path, bits))
                hex_str = _bits_to_hex(bits)
                hash_cache[path] = hex_str
                if hash_persist_callback is not None:
                    try:
                        hash_persist_callback(path, hex_str)
                    except Exception:
                        logger.warning("Individual hash persist callback failed for %s", path, exc_info=True)

    if workers <= 1 or total <= 1:
        for i, p in enumerate(photo_paths):
            if cancel_event is not None and cancel_event.is_set():
                break
            path, bits, err = _compute_single_dhash(p)
            _handle_result(path, bits, err)
            now = time.monotonic()
            if progress_callback and (now - last_emit >= 0.2 or i + 1 == total):
                progress_callback(i + 1, total, f"Computing hashes... ({path})")
                last_emit = now
    else:
        executor = _get_worker_pool(workers)
        future_to_path = {executor.submit(_compute_single_dhash, p): p for p in photo_paths}
        for done, future in enumerate(as_completed(future_to_path), 1):
            if cancel_event is not None and cancel_event.is_set():
                for f in future_to_path:
                    f.cancel()
                break
            path, bits, err = future.result()
            _handle_result(path, bits, err)
            now = time.monotonic()
            if progress_callback and (now - last_emit >= 0.2 or done == total):
                progress_callback(done, total, f"Computing hashes... ({path})")
                last_emit = now

    if progress_callback:
        progress_callback(total, total, "Hash computation complete.")

    return {
        "hashes": hash_cache,
        "successful": successful,
        "failed": failed,
    }


def run_analysis(
    photo_paths: list[str],
    threshold: int = 12,
    min_group_size: int = 2,
    workers: int | None = None,
    progress_callback: Callable[[int, int, str], None] | None = None,
    cancel_event: threading.Event | None = None,
    hash_persist_callback: Callable[[str, str], None] | None = None,
) -> dict[str, Any]:
    """Compute dHash for all photos and cluster them by similarity.

    Args:
        photo_paths: list of absolute file paths to analyze.
        threshold: max Hamming distance for grouping (4-20, default 12).
        min_group_size: minimum images per group (default 2).
        workers: max thread workers (None = auto).
        progress_callback: optional fn(current, total, message).
        cancel_event: optional threading.Event; checked between hash computations.
        hash_persist_callback: optional fn(path, hex_str) called after each hash
            is computed, for incremental persistence.

    Returns:
        dict with keys "stats", "groups", "ungrouped", "hashes".
        The "hashes" key contains {path: hex_string} for caching so that
        reclustering can skip recomputation.
    """
    total = len(photo_paths)

    hash_result = compute_hashes(
        photo_paths,
        workers=workers,
        progress_callback=progress_callback,
        cancel_event=cancel_event,
        hash_persist_callback=hash_persist_callback,
    )

    successful = hash_result["successful"]
    failed = hash_result["failed"]
    hash_cache = hash_result["hashes"]

    if progress_callback:
        progress_callback(total, total, "Clustering...")

    if cancel_event is not None and cancel_event.is_set():
        result = {
            "stats": {"total": total, "grouped": 0, "ungrouped": total, "num_groups": 0},
            "groups": [],
            "ungrouped": [{"path": p, "error": "Cancelled"} for p, _ in successful] + failed,
            "hashes": hash_cache,
        }
        if progress_callback:
            progress_callback(total, total, "Cancelled.")
        return result

    result = _cluster_hashes(successful, threshold, min_group_size)

    for f in failed:
        result["ungrouped"].append(f)

    grouped_count = sum(g["count"] for g in result["groups"])
    result["stats"]["total"] = total
    result["stats"]["grouped"] = grouped_count
    result["stats"]["ungrouped"] = len(result["ungrouped"])

    result["hashes"] = hash_cache
    result["binary_list"] = successful

    if progress_callback:
        progress_callback(total, total, "Analysis complete.")

    return result


def recluster_from_cache(
    hash_cache: dict[str, str],
    threshold: int = 12,
    min_group_size: int = 2,
    binary_list: list[tuple[str, np.ndarray]] | None = None,
    cancel_event: threading.Event | None = None,
) -> dict[str, Any]:
    """Re-run clustering using previously computed hashes.

    Args:
        hash_cache: {path: hex_string} from a previous run_analysis() call.
        threshold: new Hamming distance threshold.
        min_group_size: new minimum group size.
        binary_list: optional pre-parsed list of (path, np.ndarray) tuples.
                     When provided and paths match, skips hex-to-bits conversion.

    Returns:
        Same dict shape as run_analysis() (without "hashes" key).
    """
    successful: list[tuple[str, np.ndarray]] = []
    failed: list[dict[str, Any]] = []

    if binary_list is not None and {p for p, _ in binary_list} == set(hash_cache):
        binary_map = dict(binary_list)
        for path in hash_cache:
            bits = binary_map.get(path)
            if bits is not None:
                successful.append((path, bits))
            else:
                failed.append({"path": path, "error": "Binary list path mismatch"})
    else:
        paths = list(hash_cache.keys())
        hex_values = list(hash_cache.values())
        if not hex_values:
            return {"groups": [], "ungrouped": [{"path": p, "error": None} for p in paths], "stats": {}}
        try:
            expected_len = len(hex_values[0]) if hex_values else 0
            if expected_len and not all(len(h) == expected_len for h in hex_values):
                raise ValueError("Inconsistent hex string lengths in hash cache")
            all_hex = ''.join(hex_values)
            all_bytes = bytes.fromhex(all_hex)
            all_bits = np.unpackbits(np.frombuffer(all_bytes, dtype=np.uint8), bitorder='big')
            all_bits = all_bits.reshape(len(paths), -1)  # type: ignore[assignment]
            for i, path in enumerate(paths):
                successful.append((path, all_bits[i]))
        except (ValueError, TypeError) as exc:
            logger.warning("Fast-path hex conversion failed (%s), falling back to per-hash conversion", exc)
            for path, hex_str in hash_cache.items():
                bits = _hex_to_bits(hex_str)
                if bits is not None:
                    successful.append((path, bits))
                else:
                    failed.append({"path": path, "error": "Invalid hash hex string"})

    if cancel_event is not None and cancel_event.is_set():
        return {
            "stats": {"total": len(hash_cache), "grouped": 0, "ungrouped": len(hash_cache), "num_groups": 0},
            "groups": [],
            "ungrouped": [{"path": p, "error": "Cancelled"} for p in hash_cache],
            "binary_list": [],
        }

    result = _cluster_hashes(successful, threshold, min_group_size)

    for f in failed:
        result["ungrouped"].append(f)

    grouped_count = sum(g["count"] for g in result["groups"])
    total = len(hash_cache)
    result["stats"]["total"] = total
    result["stats"]["grouped"] = grouped_count
    result["stats"]["ungrouped"] = len(result["ungrouped"])
    result["binary_list"] = successful

    return result


# ---------------------------------------------------------------------------
# Helpers: hex <-> bits conversion for caching
# ---------------------------------------------------------------------------


def _bits_to_hex(bits: np.ndarray) -> str:
    """Convert a flat uint8 bit array (64 elements) to a hex string."""
    return np.packbits(bits, bitorder='big').tobytes().hex()


def _hex_to_bits(hex_str: str) -> np.ndarray | None:
    """Convert a hex string back to a flat uint8 bit array.

    Returns None if the hex string is invalid.
    """
    try:
        raw = bytes.fromhex(hex_str)
    except (ValueError, TypeError):
        return None
    return np.unpackbits(np.frombuffer(raw, dtype=np.uint8), bitorder='big')
