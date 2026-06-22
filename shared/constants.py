# shared/constants.py - Shared constants for the Gather project.
from __future__ import annotations

from typing import Final

# Cache
MAX_CACHED_SESSIONS: Final[int] = 50

# Thumbnail
THUMBNAIL_SIZE: Final[int] = 200
THUMBNAIL_JPEG_QUALITY: Final[int] = 85

# Checksum
PARTIAL_CHECKSUM_BYTES: Final[int] = 65536

# DB
DB_BUSY_TIMEOUT_MS: Final[int] = 5000

# MediaPipe
MEDIAPIPE_DETECTION_CONFIDENCE: Final[float] = 0.5

# Similarity analysis
SIMILARITY_THRESHOLD_MIN: Final[int] = 4
SIMILARITY_THRESHOLD_MAX: Final[int] = 20
SIMILARITY_MIN_GROUP_MIN: Final[int] = 1
SIMILARITY_MIN_GROUP_MAX: Final[int] = 10
SIMILARITY_THRESHOLD_DEFAULT: Final[int] = 12
SIMILARITY_MIN_GROUP_DEFAULT: Final[int] = 2

# Shutdown
SHUTDOWN_GRACE_PERIOD_MS: Final[int] = 2000
FORCE_KILL_TIMEOUT_MS: Final[int] = 2000

# Analysis polling
MAX_POLL_RETRIES: Final[int] = 150
POLL_INTERVAL_MS: Final[int] = 5000
POLL_SHORT_INTERVAL_MS: Final[int] = 200

# Face detection
MAX_FACE_DETECTION_PHOTOS: Final[int] = 5000
MAX_LONG_EDGE: Final[int] = 1024
EMBEDDING_DIM: Final[int] = 128

# Similarity
MAX_SIMILARITY_PHOTOS: Final[int] = 10000
HASH_SIZE: Final[int] = 8

# Worker / batch tuning
MAX_ANALYSIS_WORKERS: Final[int] = 8
SIMILARITY_HASH_PERSIST_BATCH_SIZE: Final[int] = 500
DB_RETRY_COUNT: Final[int] = 3
DB_RETRY_BACKOFF_MS: Final[int] = 500
