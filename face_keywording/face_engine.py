# face_keywording/face_engine.py - Face detection and clustering engine.
#
# Detection pipeline: load image -> scale to 1024px long edge ->
# mediapipe detection -> extract bbox.  Falls back to face_recognition
# if mediapipe is not available.  Embeddings use face_recognition
# (128-d vectors); if that also fails, mediapipe landmarks are used
# as a feature vector.  Clustering via sklearn.cluster.DBSCAN.

from __future__ import annotations

import contextlib
import io

# ---------------------------------------------------------------------------
# Optional imports (graceful fallback)
# ---------------------------------------------------------------------------
import logging
import os
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

import numpy as np

from shared.constants import (
    EMBEDDING_DIM,
    MAX_ANALYSIS_WORKERS,
    MAX_FACE_DETECTION_PHOTOS,
    MAX_LONG_EDGE,
    MEDIAPIPE_DETECTION_CONFIDENCE,
    THUMBNAIL_JPEG_QUALITY,
)

logger = logging.getLogger("gather.face_engine")

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

_mediapipe_available = False
_mp_face_detection = None
_mp = None

_cv2_available = False
_cv2 = None

_face_recognition_available = False
_face_recognition = None

_sklearn_available = False
_DBSCAN = None

_import_lock = threading.Lock()

_mp_ensured = False
_cv2_ensured = False
_fr_ensured = False
_skl_ensured = False


def _ensure_mediapipe():
    global _mediapipe_available, _mp_face_detection, _mp, _mp_ensured
    if _mp_ensured:
        return
    with _import_lock:
        if _mp_ensured:
            return
        try:
            import mediapipe as _mp

            _ = _mp.solutions  # type: ignore[attr-defined]
            _mp_face_detection = _mp.solutions.face_detection  # type: ignore[attr-defined]
            _mediapipe_available = True
        except (ImportError, AttributeError):
            logger.info("mediapipe not available; face detection will use face_recognition fallback")
        finally:
            _mp_ensured = True


def _ensure_face_recognition():
    global _face_recognition_available, _face_recognition, _fr_ensured
    if _fr_ensured:
        return
    with _import_lock:
        if _fr_ensured:
            return
        try:
            import face_recognition as _fr

            _face_recognition = _fr
            _face_recognition_available = True
        except ImportError:
            logger.info("face_recognition not available; embeddings will use mediapipe landmarks fallback")
        finally:
            _fr_ensured = True


def _ensure_cv2():
    global _cv2_available, _cv2, _cv2_ensured
    if _cv2_ensured:
        return
    with _import_lock:
        if _cv2_ensured:
            return
        try:
            import cv2 as _cv2

            _cv2_available = True
        except ImportError:
            logger.debug("OpenCV (cv2) not available; face crop resize will use PIL fallback")
        finally:
            _cv2_ensured = True


def _ensure_sklearn():
    global _sklearn_available, _DBSCAN, _skl_ensured
    if _skl_ensured:
        return
    with _import_lock:
        if _skl_ensured:
            return
        try:
            from sklearn.cluster import DBSCAN as _DBSCAN

            _sklearn_available = True
        except ImportError:
            logger.info("scikit-learn not available; face clustering disabled")
        finally:
            _skl_ensured = True


FACE_CROP_PADDING_RATIO = 0.2


# ---------------------------------------------------------------------------
# Per-thread MediaPipe instances (replaces global + lock pattern)
# ---------------------------------------------------------------------------

_face_detector_local = threading.local()
_face_mesh_local = threading.local()

_detector_instances: set[Any] = set()
_detector_instances_lock = threading.Lock()
_detector_generation = 0


def _get_thread_face_detector():
    """Get or create a thread-local FaceDetection instance."""
    _ensure_mediapipe()
    inst = getattr(_face_detector_local, "instance", None)
    gen = getattr(_face_detector_local, "_generation", None)
    with _detector_instances_lock:
        current_gen = _detector_generation
    if gen != current_gen:
        if inst is not None:
            with contextlib.suppress(Exception):
                inst.close()
        inst = None
        _face_detector_local._generation = current_gen
    if inst is None and _mediapipe_available and _mp_face_detection is not None:
        inst = _mp_face_detection.FaceDetection(model_selection=1, min_detection_confidence=MEDIAPIPE_DETECTION_CONFIDENCE)
        _face_detector_local.instance = inst
        _face_detector_local._generation = current_gen
        with _detector_instances_lock:
            _detector_instances.add(inst)
    return inst


def _get_thread_face_mesh():
    """Get or create a thread-local FaceMesh instance."""
    _ensure_mediapipe()
    inst = getattr(_face_mesh_local, "instance", None)
    gen = getattr(_face_mesh_local, "_generation", None)
    with _detector_instances_lock:
        current_gen = _detector_generation
    if gen != current_gen:
        if inst is not None:
            try:
                inst.close()
            except Exception:
                logger.debug("Failed to close mediapipe instance", exc_info=True)
        inst = None
        _face_mesh_local._generation = current_gen
    if inst is None and _mediapipe_available:
        inst = _mp.solutions.face_mesh.FaceMesh(static_image_mode=True, max_num_faces=1, min_detection_confidence=MEDIAPIPE_DETECTION_CONFIDENCE)  # type: ignore[attr-defined]
        _face_mesh_local.instance = inst
        _face_mesh_local._generation = current_gen
        with _detector_instances_lock:
            _detector_instances.add(inst)
    return inst


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def detect_faces(
    photo_paths: list[str],
    progress_callback: Callable[[int, int, str], None] | None = None,
    cancel_event: threading.Event | None = None,
    workers: int | None = None,
) -> list[dict]:
    """Detect faces and extract embeddings for a batch of photos.

    Each photo is loaded once: detection and embedding extraction share
    the same decoded image array to avoid double I/O.

    Returns a list of per-photo dicts:
        [{"photo_path": str,
          "faces": [{"bbox": [x,y,w,h], "confidence": float,
                     "embedding": list[float]}]}]

    The progress_callback receives (current_index, total, message).
    If cancel_event is set, detection is aborted and partial results returned.
    """
    if len(photo_paths) > MAX_FACE_DETECTION_PHOTOS:
        raise ValueError(
            f"Too many photos for face detection: {len(photo_paths)}. Maximum is {MAX_FACE_DETECTION_PHOTOS}."
        )

    if workers is None:
        workers = min(_CPU_COUNT, MAX_ANALYSIS_WORKERS)
    workers = max(workers, 1)

    global _detector_generation

    results: list[dict] = []
    total = len(photo_paths)
    last_emit = 0.0

    try:
        if workers <= 1:
            for idx, path in enumerate(photo_paths):
                if cancel_event is not None and cancel_event.is_set():
                    break
                from shared.path_utils import validate_safe_path
                try:
                    path = validate_safe_path(path, allow_temp=True)
                except ValueError:
                    logger.warning("Skipping path outside allowed directories: %s", path)
                    results.append({"photo_path": path, "faces": []})
                    continue
                fname = os.path.basename(path)
                now = time.monotonic()
                if progress_callback and (now - last_emit >= 0.2 or idx == total - 1):
                    progress_callback(idx, total, f"Detecting faces: {fname}")
                    last_emit = now

                try:
                    photo_result = _process_and_encode_single_photo(path)
                except Exception as exc:
                    logger.warning("Failed to process image %s: %s", path, exc)
                    photo_result = {"photo_path": path, "faces": []}

                results.append(photo_result)
        else:
            executor = _get_worker_pool(workers)
            future_to_path = {executor.submit(_process_and_encode_single_photo, p): p for p in photo_paths}
            for done, future in enumerate(as_completed(future_to_path), 1):
                if cancel_event is not None and cancel_event.is_set():
                    for f in future_to_path:
                        f.cancel()
                    break
                path = future_to_path[future]
                fname = os.path.basename(path)
                now = time.monotonic()
                if progress_callback and (now - last_emit >= 0.2 or done == total):
                    progress_callback(done, total, f"Detecting faces: {fname}")
                    last_emit = now
                try:
                    photo_result = future.result()
                except Exception as exc:
                    logger.warning("Failed to process image %s: %s", path, exc)
                    photo_result = {"photo_path": path, "faces": []}
                results.append(photo_result)

            if progress_callback:
                progress_callback(total, total, "Detection complete.")
    finally:
        # Release all MediaPipe instances created by this invocation.
        # All detection is complete at this point (as_completed blocks until done),
        # so it is safe to close all tracked instances.
        to_close: list = []
        with _detector_instances_lock:
            to_close = list(_detector_instances)
            _detector_instances.clear()
            _detector_generation += 1
        for inst in to_close:
            try:
                inst.close()
            except Exception:  # noqa: PERF203
                logger.debug("Failed to close mediapipe instance", exc_info=True)

    return results


def cluster_faces(
    observations: list[dict],
    eps: float = 0.5,
    min_samples: int = 2,
) -> dict:
    """Cluster face embeddings into identity groups using DBSCAN.

    Each observation should have "faces" with "embedding" keys.
    Returns:
        {"clusters": [{"cluster_id": int, "members": [...], "size": int}],
         "noise": [...]}
    """
    _ensure_sklearn()
    if not _sklearn_available:
        raise RuntimeError("scikit-learn is required for clustering. Install with: pip install scikit-learn")

    # Collect all face embeddings and build index map
    all_faces: list[dict] = []
    for obs in observations:
        for face in obs.get("faces", []):
            embedding = face.get("embedding")
            if embedding and len(embedding) == EMBEDDING_DIM:
                all_faces.append(
                    {
                        "photo_path": obs["photo_path"],
                        "bbox": face["bbox"],
                        "confidence": face.get("confidence", 0.0),
                        "embedding": embedding,
                    }
                )

    if not all_faces:
        return {"clusters": [], "noise": []}

    # Build feature matrix
    x = np.array([f["embedding"] for f in all_faces], dtype=np.float64)

    # Run DBSCAN
    db = _DBSCAN(eps=eps, min_samples=min_samples, metric="euclidean")  # type: ignore[misc]
    labels = db.fit_predict(x)

    # Group by cluster label
    clusters_map: dict[int, list[dict]] = {}
    for i, label in enumerate(labels):
        clusters_map.setdefault(int(label), []).append(all_faces[i])

    # Build output
    clusters: list[dict] = []
    noise: list[dict] = []

    for label, members in sorted(clusters_map.items()):
        entry = {
            "cluster_id": label if label >= 0 else -1,
            "members": [
                {
                    "photo_path": m["photo_path"],
                    "bbox": m["bbox"],
                    "confidence": m["confidence"],
                }
                for m in members
            ],
            "size": len(members),
        }
        if label >= 0:
            clusters.append(entry)
        else:
            noise.extend(list(entry["members"]))  # type: ignore[call-overload]

    return {"clusters": clusters, "noise": noise}


def get_cluster_thumbnail(
    photo_path: str,
    bbox: list[float],
    size: int = 128,
) -> bytes | None:
    """Crop a face region from a photo and return a JPEG thumbnail.

    bbox is [x, y, w, h] in pixel coordinates.
    Returns JPEG bytes, or None on failure.
    """
    try:
        from shared.path_utils import validate_safe_path
        photo_path = validate_safe_path(photo_path, allow_temp=True)
        from PIL import Image, ImageOps

        fd = os.open(photo_path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as fh, Image.open(fh) as img:
            img.load()
            if img.mode not in ("RGB", "RGBA"):
                img = img.convert("RGB")  # type: ignore[assignment]  # type: ignore[assignment]
            orig_w, orig_h = img.size
            orig_long_edge = max(orig_w, orig_h)

            # Bbox coordinates come from the detection pipeline which operates on
            # images scaled to MAX_LONG_EDGE. Scale bbox to original-image coords
            # instead of resizing the full image, avoiding a full-image decode/resize.
            x, y, w, h = bbox
            if orig_long_edge > MAX_LONG_EDGE:
                scale = MAX_LONG_EDGE / orig_long_edge
                x, y, w, h = x / scale, y / scale, w / scale, h / scale

            pad_x = int(w * FACE_CROP_PADDING_RATIO)
            pad_y = int(h * FACE_CROP_PADDING_RATIO)
            left = max(0, int(x) - pad_x)
            top = max(0, int(y) - pad_y)
            right = min(orig_w, int(x + w) + pad_x)
            bottom = min(orig_h, int(y + h) + pad_y)

            if right <= left or bottom <= top:
                return None

            face_crop = img.crop((left, top, right, bottom))
            face_crop = ImageOps.fit(face_crop, (size, size), method=Image.Resampling.LANCZOS)

            buf = io.BytesIO()
            face_crop.save(buf, format="JPEG", quality=THUMBNAIL_JPEG_QUALITY)
            return buf.getvalue()

    except Exception:
        logger.warning("Failed to generate thumbnail for %s", photo_path, exc_info=True)
        return None


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _process_and_encode_single_photo(photo_path: str) -> dict:
    """Detect faces in a single photo and extract embeddings in one pass.

    Loads the image once, detects faces, then encodes embeddings from
    the same loaded array — avoiding a second disk read.
    Returns {photo_path, faces: [{bbox, confidence, embedding}]}.
    """
    _ensure_mediapipe()
    _ensure_face_recognition()
    from shared.path_utils import validate_safe_path
    try:
        photo_path = validate_safe_path(photo_path, allow_temp=True)
    except ValueError:
        return {"photo_path": photo_path, "faces": []}
    result: dict = {"photo_path": photo_path, "faces": []}

    from PIL import Image

    # Load and scale image
    try:
        fd = os.open(photo_path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        logger.warning("Failed to open image file: %s", photo_path)
        return result
    with os.fdopen(fd, 'rb') as fh, Image.open(fh) as img:
        img.load()
        if img.mode != "RGB":
            img = img.convert("RGB")  # type: ignore[assignment]

        # Scale to max long edge
        w, h = img.size
        long_edge = max(w, h)
        scale = 1.0
        if long_edge > MAX_LONG_EDGE:
            scale = MAX_LONG_EDGE / long_edge
            new_w = int(w * scale)
            new_h = int(h * scale)
            img = img.resize((new_w, new_h), Image.Resampling.LANCZOS)  # type: ignore[assignment]
            w, h = new_w, new_h

        img_array = np.array(img)

    bboxes: list[dict] = []
    detection_source: str | None = None

    if _mediapipe_available and _mp_face_detection is not None:
        bboxes = _detect_mediapipe(img_array, w, h)
        detection_source = "mediapipe"
    elif _face_recognition_available and _face_recognition is not None:
        bboxes = _detect_face_recognition(img_array)
        detection_source = "face_recognition"
    else:
        # Neither available; return empty
        pass

    # Extract embeddings for each detected face using the already-loaded img_array
    for face in bboxes:
        bbox = face["bbox"]
        x, y, bw, bh = bbox
        left = max(0, int(x))
        top = max(0, int(y))
        right = min(img_array.shape[1], int(x + bw))
        bottom = min(img_array.shape[0], int(y + bh))

        if right <= left or bottom <= top:
            face["embedding"] = []
            continue

        face_crop = img_array[top:bottom, left:right]
        embedding = _extract_embedding_from_crop(img_array, face_crop, bbox, detection_source)
        face["embedding"] = embedding

    result["faces"] = bboxes
    return result


def _extract_embedding_from_crop(
    full_img_array: np.ndarray,
    face_crop: np.ndarray,
    bbox: list[float],
    detection_source: str | None = None,
) -> list[float]:
    """Extract face embedding from a pre-loaded image crop.

    Tries face_recognition on the full image first, then on the crop,
    then falls back to mediapipe landmarks.  Returns a 128-d list.
    Skips the full-image step when detection came from MediaPipe
    (bbox format differs from dlib's expected format).
    """
    _ensure_face_recognition()
    # cv2 and mediapipe are deferred: only needed for fallback paths below.
    # Calling them up-front would load unused modules when face_recognition succeeds.
    from PIL import Image

    x, y, w, h = bbox
    top_i = max(0, int(y))
    right_i = min(full_img_array.shape[1], int(x + w))
    bottom_i = min(full_img_array.shape[0], int(y + h))
    left_i = max(0, int(x))

    skip_full_image = detection_source == "mediapipe"

    if not skip_full_image and _face_recognition_available and _face_recognition is not None:
        try:
            face_loc = (top_i, right_i, bottom_i, left_i)
            encodings = _face_recognition.face_encodings(full_img_array, [face_loc])
            if encodings:
                return list(encodings[0])
        except Exception as exc:
            logger.debug("face_recognition on full image failed: %s", exc)

    # Fallback: face_recognition on cropped face
    if _face_recognition_available and _face_recognition is not None:
        _ensure_cv2()
        try:
            if _cv2_available and _cv2 is not None:
                crop_array = _cv2.resize(face_crop, (128, 128), interpolation=_cv2.INTER_LANCZOS4)
            else:
                crop_img = Image.fromarray(face_crop)
                crop_img = crop_img.resize((128, 128), Image.Resampling.LANCZOS)
                crop_array = np.array(crop_img)
            encodings = _face_recognition.face_encodings(crop_array)
            if encodings:
                return list(encodings[0])
        except Exception as exc:
            logger.debug("face_recognition on crop failed: %s", exc)

    # Last resort: mediapipe landmarks as pseudo-embedding
    _ensure_mediapipe()
    if _mediapipe_available:
        logger.info(
            "Using mediapipe landmark embedding fallback; DBSCAN clustering quality may differ. "
            "Install face_recognition for better face embeddings."
        )
        lm_emb = _landmark_embedding(full_img_array, bbox)
        if lm_emb is not None:
            return lm_emb

    return []


def _detect_mediapipe(
    img_array: np.ndarray,
    img_w: int,
    img_h: int,
) -> list[dict]:
    """Detect faces using MediaPipe Face Detection (thread-local instance)."""
    detector = _get_thread_face_detector()
    if detector is None:
        return []
    results = detector.process(img_array)

    bboxes: list[dict] = []
    if results is not None and results.detections:
        for detection in results.detections:
            bbox_rel = detection.location_data.relative_bounding_box
            x = bbox_rel.xmin * img_w
            y = bbox_rel.ymin * img_h
            w = bbox_rel.width * img_w
            h = bbox_rel.height * img_h

            bboxes.append(
                {
                    "bbox": [round(x, 1), round(y, 1), round(w, 1), round(h, 1)],
                    "confidence": round(detection.score[0], 4),
                }
            )

    return bboxes


def _detect_face_recognition(
    img_array: np.ndarray,
) -> list[dict]:
    """Detect faces using face_recognition library."""
    _ensure_face_recognition()
    if not _face_recognition_available or _face_recognition is None:
        return []
    face_locations = _face_recognition.face_locations(img_array)

    bboxes: list[dict] = []
    for top, right, bottom, left in face_locations:
        x = float(left)
        y = float(top)
        w = float(right - left)
        h = float(bottom - top)

        bboxes.append(
            {
                "bbox": [round(x, 1), round(y, 1), round(w, 1), round(h, 1)],
                "confidence": 1.0,  # face_recognition doesn't provide confidence
            }
        )

    return bboxes


def _landmark_embedding(
    img_array: np.ndarray,
    bbox: list[float],
) -> list[float] | None:
    """Use MediaPipe face mesh landmarks as a pseudo-embedding vector.

    Extracts 468 landmarks (x,y,z each = 1404 values), reshapes to
    (468, 3), averages groups of landmarks to preserve spatial structure,
    and flattens to 128 dimensions for DBSCAN compatibility.
    """
    try:
        mesh = _get_thread_face_mesh()
        if mesh is None:
            return None

        if len(bbox) < 4:
            return None
        x, y, w, h = [round(bbox[i]) for i in range(4)]
        left = max(0, x)
        top = max(0, y)
        right = min(img_array.shape[1], x + w)
        bottom = min(img_array.shape[0], y + h)

        crop = img_array[top:bottom, left:right]
        if crop.size == 0:
            return None

        results = mesh.process(crop)

        if not results.multi_face_landmarks:
            return None

        landmarks = results.multi_face_landmarks[0]
        # Extract x, y, z coordinates
        coords: list[float] = []
        for lm in landmarks.landmark:
            coords.extend([lm.x, lm.y, lm.z])

        # Reshape to (468, 3) and average groups of landmarks to 128 dims
        arr = np.array(coords, dtype=np.float32).reshape(468, 3)
        n_groups = EMBEDDING_DIM // 3  # 42 groups
        step = max(1, 468 // n_groups)  # 11 landmarks per group
        # step * n_groups = 462, discarding the last 6 of 468 MediaPipe landmarks
        # (right-temple/forehead region). Empirical testing shows this has negligible
        # impact on clustering quality while keeping the output aligned to EMBEDDING_DIM.
        trimmed_len = step * n_groups
        trimmed = arr[:trimmed_len].reshape(n_groups, step, 3)
        reduced = trimmed.mean(axis=1).flatten().tolist()

        # Pad if needed
        while len(reduced) < EMBEDDING_DIM:
            reduced.append(0.0)

        # Normalize
        norm_vec = np.array(reduced, dtype=np.float64)
        norm = np.linalg.norm(norm_vec)
        if norm > 0:
            norm_vec = norm_vec / norm

        return list(norm_vec)

    except Exception as exc:
        logger.debug("Landmark embedding failed: %s", exc)
        return None


def cleanup_globals() -> None:
    """Release all MediaPipe resources across all threads."""
    global _detector_generation
    with _detector_instances_lock:
        instances = list(_detector_instances)
        _detector_instances.clear()
    for inst in instances:
        with contextlib.suppress(Exception):
            inst.close()
    with _detector_instances_lock:
        _detector_generation += 1
