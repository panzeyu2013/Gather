# face_keywording/__init__.py - Face keywording submodule.
# Provides the core service for face detection, clustering, role binding,
# and XMP writeback. Used by the engine layer (engine.py).
#
# Usage:
#   from face_keywording import FaceKeywordingService
#   service = FaceKeywordingService(manager, progress_callback=...)

from .service import FaceKeywordingService

__all__ = ["FaceKeywordingService"]
