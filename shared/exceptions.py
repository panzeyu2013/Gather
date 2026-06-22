# shared/exceptions.py
# Custom exception hierarchy for Gather domain errors.
# The `type` field in protocol.serialise_error() uses type(exc).__name__
# so these class names flow through to the TypeScript error handler.

class GatherError(Exception):
    """Base exception for all Gather domain errors."""


class SessionError(GatherError):
    """Base exception for session-related errors."""


class SessionNotFoundError(SessionError):
    """Raised when a requested session does not exist in the database."""


class AnalysisInProgressError(GatherError):
    """Raised when an operation conflicts with a running analysis."""


class MissingLibraryError(GatherError):
    """Raised when a required Python library is not installed."""


class InvalidPhotoError(GatherError):
    """Raised when a photo file is invalid or cannot be processed."""


class PathValidationError(GatherError):
    """Raised when a file path fails security validation."""


class XmpWriteError(GatherError):
    """Raised when an XMP sidecar write operation fails."""
