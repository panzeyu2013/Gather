import os
import tempfile

import pytest

from face_keywording.service import FaceKeywordingService
from shared.db import Database
from shared.session_manager import SessionManager
from similarity.service import SimilarityService


@pytest.fixture(autouse=True)
def mock_checksums(monkeypatch):
    """Return a stable checksum for synthetic test paths (/tmp/*) used by most
    unit tests, while still allowing /nonexistent/ paths to exercise real failures.
    Tests that need real file checksums should pass real file paths."""
    def fake_checksum(path: str, *, partial_bytes: int | None = None):
        if "/nonexistent/" in path:
            return None
        base = f"checksum:{path}"
        return base[:partial_bytes] if partial_bytes is not None else base

    monkeypatch.setattr("shared.session_manager.file_checksum", fake_checksum)
    monkeypatch.setattr("shared.xmp_writer.file_checksum", fake_checksum)


@pytest.fixture
def db():
    with tempfile.TemporaryDirectory() as tmp:
        db_path = os.path.join(tmp, "test.db")
        db = Database(db_path)
        db.migrate()
        yield db
        db.close()


@pytest.fixture
def manager(db):
    return SessionManager(db=db)


@pytest.fixture
def session_with_photo(manager, tmp_path):
    session = manager.create_session(name="test-session")
    photo_path = tmp_path / "photo.jpg"
    photo_path.write_bytes(
        b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
        b"\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t\x08\n"
        b"\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a\x1d\xa0\xff\xd9"
    )
    manager.add_photos(session.id, [str(photo_path)])
    return session.id, str(photo_path)


@pytest.fixture
def fkw_service(manager):
    return FaceKeywordingService(manager)


@pytest.fixture
def sim_service(manager):
    return SimilarityService(manager)
