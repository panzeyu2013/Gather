# similarity/__init__.py - Similarity grouping submodule.
# Provides the core service for detecting visually similar images
# and grouping them into clusters. Used by the engine layer (engine.py).
#
# Usage:
#   from similarity import SimilarityService
#   from shared.session_manager import SessionManager
#   manager = SessionManager()
#   service = SimilarityService(manager)

from .service import SimilarityService

__all__ = ["SimilarityService"]
