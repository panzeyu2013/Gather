# shared/models.py - Shared data models for the Gather application.
#
# Defines Session, Photo, face-keywording data models, and status enums
# using plain dataclasses with dict-based serialization.
# Used by the face_keywording and similarity services, and the engine layer.

from __future__ import annotations

import uuid
from dataclasses import asdict, dataclass, field, fields
from datetime import datetime, timezone
from enum import Enum
from typing import Any

# ---------------------------------------------------------------------------
# Session status lifecycle
# ---------------------------------------------------------------------------


class SessionStatus(str, Enum):
    DRAFT = "draft"
    PHOTOS_LOADED = "photos_loaded"
    ANALYZING = "analyzing"
    REVIEW = "review"
    COMPLETED = "completed"


# ---------------------------------------------------------------------------
# Internal status enums (not part of the user-facing lifecycle)
# ---------------------------------------------------------------------------


class AnalysisStatus(str, Enum):
    """Per-session analysis progress (face keywording or similarity)."""

    IDLE = "idle"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"
    CANCELLED = "cancelled"


class WritebackStatus(str, Enum):
    """Per-session XMP writeback progress."""

    IDLE = "idle"
    RUNNING = "running"
    DONE = "done"
    PARTIAL = "partial"
    CLEANED = "cleaned"


class PhotoStatus(str, Enum):
    """Processing status of a single photo."""

    PENDING = "pending"
    ANALYZING = "analyzing"
    ANALYZED = "analyzed"
    ERROR = "error"


class ClusterBindingStatus(str, Enum):
    """Binding state of a single face cluster."""

    UNBOUND = "unbound"
    BOUND = "bound"
    SKIPPED = "skipped"


# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------


@dataclass
class Session:
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    name: str = ""
    status: SessionStatus = SessionStatus.DRAFT
    event_date: str = ""  # ISO date string for performance date
    analysis_status: AnalysisStatus = AnalysisStatus.IDLE
    writeback_status: WritebackStatus = WritebackStatus.IDLE
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    updated_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["status"] = self.status.value
        d["analysis_status"] = self.analysis_status.value
        d["writeback_status"] = self.writeback_status.value
        return d

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Session:
        if "id" not in data:
            raise KeyError("Missing required field: id")
        data = dict(data)
        data["status"] = SessionStatus(data.get("status", "draft"))
        data["event_date"] = data.get("event_date", "")
        data["analysis_status"] = AnalysisStatus(data.get("analysis_status", "idle"))
        data["writeback_status"] = WritebackStatus(data.get("writeback_status", "idle"))
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in known})


# ---------------------------------------------------------------------------
# Photo
# ---------------------------------------------------------------------------


@dataclass
class Photo:
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    session_id: str = ""
    filepath: str = ""
    filename: str = ""
    status: PhotoStatus = PhotoStatus.PENDING
    metadata: dict[str, Any] = field(default_factory=dict)
    result: dict[str, Any] = field(default_factory=dict)
    checksum: str = ""  # SHA-256 first 16 hex chars for stable reference
    has_existing_xmp: bool = False
    face_count: int = 0
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    updated_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["status"] = self.status.value
        return d

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Photo:
        if "id" not in data:
            raise KeyError("Missing required field: id")
        if "session_id" not in data:
            raise KeyError("Missing required field: session_id")
        data = dict(data)
        data["status"] = PhotoStatus(data.get("status", "pending"))
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in known})


# ---------------------------------------------------------------------------
# Face keywording data models
# ---------------------------------------------------------------------------


@dataclass
class FaceObservation:
    """A single detected face in a photo."""

    id: int = 0  # auto-increment PK (0 means not yet persisted)
    photo_id: str = ""
    session_id: str = ""
    bbox_x: float = 0.0
    bbox_y: float = 0.0
    bbox_w: float = 0.0
    bbox_h: float = 0.0
    embedding: list[float] = field(default_factory=list)
    confidence: float = 0.0
    thumbnail_path: str = ""

    @property
    def bbox(self) -> list[float]:
        return [self.bbox_x, self.bbox_y, self.bbox_w, self.bbox_h]

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "photo_id": self.photo_id,
            "session_id": self.session_id,
            "bbox": self.bbox,
            "embedding": self.embedding,
            "confidence": self.confidence,
            "thumbnail_path": self.thumbnail_path,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> FaceObservation:
        d = dict(data)
        bbox = d.pop("bbox", [0, 0, 0, 0])
        return cls(
            id=d.get("id", 0),
            photo_id=d.get("photo_id", ""),
            session_id=d.get("session_id", ""),
            bbox_x=bbox[0] if bbox else 0,
            bbox_y=bbox[1] if len(bbox) > 1 else 0,
            bbox_w=bbox[2] if len(bbox) > 2 else 0,
            bbox_h=bbox[3] if len(bbox) > 3 else 0,
            embedding=d.get("embedding", []),
            confidence=d.get("confidence", 0.0),
            thumbnail_path=d.get("thumbnail_path", ""),
        )


@dataclass
class FaceCluster:
    """A group of face observations that likely belong to one person.

    NOTE: This dataclass serves as type documentation / reference for the
    cluster data shape.  In production code, cluster data passes as dicts.
    """

    id: int = 0
    session_id: str = ""
    label: str = ""
    representative_obs_id: int | None = None
    member_count: int = 0
    status: ClusterBindingStatus = ClusterBindingStatus.UNBOUND

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "session_id": self.session_id,
            "label": self.label,
            "representative_obs_id": self.representative_obs_id,
            "member_count": self.member_count,
            "status": self.status.value,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> FaceCluster:
        d = dict(data)
        d["status"] = ClusterBindingStatus(d.get("status", "unbound"))
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in d.items() if k in known})


@dataclass
class RoleBinding:
    """A user-assigned role (name + keywords) bound to a face cluster.

    NOTE: This dataclass serves as type documentation / reference for the
    role binding data shape.  In production code, bindings pass as dicts.
    """

    id: int = 0
    cluster_id: int = 0
    session_id: str = ""
    role_name: str = ""
    keywords: list[str] = field(default_factory=list)
    notes: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> RoleBinding:
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in known})


@dataclass
class WritebackItem:
    """Tracks an XMP writeback operation for a single photo.

    NOTE: This dataclass serves as type documentation / reference for the
    writeback item data shape.  In production code, items pass as dicts.
    """

    id: int = 0
    photo_id: str = ""
    session_id: str = ""
    keywords: list[str] = field(default_factory=list)
    xmp_path: str = ""
    backup_path: str = ""
    xmp_status: str = "pending"  # pending | written | failed | restored
    error_message: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> WritebackItem:
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in known})
