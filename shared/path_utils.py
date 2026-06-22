# shared/path_utils.py - Path validation utilities for the Gather project.

from __future__ import annotations

import hashlib
import logging
import os
import sys

from .constants import PARTIAL_CHECKSUM_BYTES

logger = logging.getLogger("gather.path_utils")

PHOTO_BASE_DIR = os.path.expanduser("~")

_SAFE_PREFIXES_LIST = [
    os.path.expanduser("~/Pictures"),
    os.path.expanduser("~/Desktop"),
    os.path.expanduser("~/Documents"),
]

if sys.platform == "darwin":
    _SAFE_PREFIXES_LIST.append("/Volumes")

if sys.platform == "win32":
    _SAFE_PREFIXES_LIST.extend([
        os.path.expandvars("%USERPROFILE%\\Pictures"),
        os.path.expandvars("%USERPROFILE%\\Desktop"),
        os.path.expandvars("%USERPROFILE%\\Documents"),
    ])

SAFE_PREFIXES = frozenset(_SAFE_PREFIXES_LIST)


def validate_safe_path(filepath: str, *, allow_temp: bool = False) -> str:
    """Resolve and validate filepath is within allowed directories.

    NOTE: There is a TOCTOU window between path validation and subsequent
    file operations. Callers performing security-sensitive operations should
    use os.O_NOFOLLOW when opening files to prevent symlink-based attacks.
    """
    if not filepath or not filepath.strip():
        raise ValueError("Filepath must not be empty or whitespace")
    real = os.path.realpath(os.path.expanduser(filepath))
    for prefix in SAFE_PREFIXES:
        if real.startswith(prefix + os.sep) or real == prefix:
            return real
    if allow_temp:
        temp_prefixes = ["/tmp", "/var/folders", "/private/var/folders"]
        for prefix in temp_prefixes:
            resolved_prefix = os.path.realpath(prefix)
            if real.startswith(resolved_prefix + os.sep) or real == resolved_prefix:
                return real
    raise ValueError(f"Access denied: path outside allowed directories: {filepath}")



def file_checksum(path: str, *, partial_bytes: int | None = None) -> str | None:
    """Compute a lightweight fingerprint using SHA-256 of the first 64KB + file size.

    This avoids reading large files entirely. The combination of first-N-bytes
    hash + file_size is sufficient as a fingerprint for deduplication.
    """
    try:
        sha = hashlib.sha256()
        file_size = os.path.getsize(path)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            with os.fdopen(fd, "rb", closefd=False) as fh:
                chunk = fh.read(PARTIAL_CHECKSUM_BYTES)
                sha.update(chunk)
                sha.update(str(file_size).encode())
        finally:
            os.close(fd)
        digest = sha.hexdigest()
        if partial_bytes is not None:
            return digest[:partial_bytes]
        return digest
    except OSError as exc:
        logger.debug("checksum failed for %s: %s", path, exc)
        return None
