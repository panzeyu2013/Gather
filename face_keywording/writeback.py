# face_keywording/writeback.py - XMP writeback compatibility re-export.
#
# Core XMP writeback functions now live in shared/xmp_writer.py so that
# both face_keywording and similarity modules can import them without
# creating a cross-module dependency.
#
# This module re-exports the public API for backward compatibility.
# All functions are delegated to shared.xmp_writer.

from __future__ import annotations

from shared.xmp_writer import (
    BACKUP_SUFFIX,
    GATHER_MARKER,
    GATHER_NS,
    NSMAP,
    _is_gather_xmp,
    backup_xmp,
    cleanup_xmp,
    restore_xmp,
    write_keywords,
)

__all__ = [
    "write_keywords",
    "backup_xmp",
    "restore_xmp",
    "cleanup_xmp",
    "_is_gather_xmp",
    "NSMAP",
    "GATHER_NS",
    "GATHER_MARKER",
    "BACKUP_SUFFIX",
]
