import os

# Add repo root to path so we can import shared
import sys

import pytest

_repo_root = os.path.join(os.path.dirname(__file__), "..")
if _repo_root not in sys.path:
    sys.path.insert(0, _repo_root)

from shared.path_utils import validate_safe_path

# ---------------------------------------------------------------------------
# Allowed paths
# ---------------------------------------------------------------------------


def test_allows_path_under_pictures():
    path = os.path.expanduser("~/Pictures/photo.jpg")
    result = validate_safe_path(path)
    assert result == os.path.realpath(path)


def test_allows_path_under_desktop():
    path = os.path.expanduser("~/Desktop/file.txt")
    result = validate_safe_path(path)
    assert result == os.path.realpath(path)


def test_allows_path_under_documents():
    path = os.path.expanduser("~/Documents/notes.md")
    result = validate_safe_path(path)
    assert result == os.path.realpath(path)


def test_allows_path_under_volumes(tmp_path):
    result = validate_safe_path("/Volumes/ExternalDisk/data")
    # On APFS macOS, /Volumes may be a symlink, so check the resolved path
    assert result == os.path.realpath("/Volumes/ExternalDisk/data")


def test_allows_path_exactly_equal_to_prefix():
    result = validate_safe_path(os.path.expanduser("~/Pictures"))
    assert result == os.path.realpath(os.path.expanduser("~/Pictures"))


def test_allows_path_with_double_slash():
    path = os.path.expanduser("~/Desktop") + "//test.jpg"
    result = validate_safe_path(path)
    assert result == os.path.expanduser("~/Desktop/test.jpg")


def test_allows_volumes_root():
    result = validate_safe_path("/Volumes")
    assert result == os.path.realpath("/Volumes")


# ---------------------------------------------------------------------------
# Path traversal rejection
# ---------------------------------------------------------------------------


def test_rejects_parent_directory_traversal():
    with pytest.raises(ValueError, match="Access denied"):
        validate_safe_path("~/Pictures/../../../etc/passwd")


def test_rejects_relative_traversal_from_allowed_prefix():
    with pytest.raises(ValueError, match="Access denied"):
        validate_safe_path(os.path.expanduser("~/Desktop/../etc/passwd"))


def test_rejects_traversal_with_encoded_dots():
    with pytest.raises(ValueError, match="Access denied"):
        validate_safe_path(os.path.expanduser("~/Pictures/subdir/../../.ssh/id_rsa"))


# ---------------------------------------------------------------------------
# Symlink bypass rejection
# ---------------------------------------------------------------------------


def test_rejects_symlink_to_disallowed_path(tmp_path):
    link_path = os.path.join(tmp_path, "symlink")
    target = "/etc/passwd"
    os.symlink(target, link_path)

    with pytest.raises(ValueError, match="Access denied"):
        validate_safe_path(link_path)


def test_rejects_symlink_inside_allowed_prefix_pointing_outside(tmp_path):
    pics = os.path.expanduser("~/Pictures")
    os.makedirs(pics, exist_ok=True)

    link_path = os.path.join(pics, "escape_link")
    try:
        os.symlink(tmp_path, link_path)
    except PermissionError:
        pytest.skip("Symlink creation is not permitted in this environment")

    try:
        with pytest.raises(ValueError, match="Access denied"):
            validate_safe_path(link_path)
    finally:
        if os.path.islink(link_path):
            os.unlink(link_path)


def test_allows_symlink_inside_allowed_prefix_pointing_inside():
    pics = os.path.expanduser("~/Pictures")
    desks = os.path.expanduser("~/Desktop")

    link_path = os.path.join(pics, "symlink_to_desktop")

    try:
        os.makedirs(pics, exist_ok=True)
        os.symlink(desks, link_path)
    except PermissionError:
        pytest.skip("Symlink creation is not permitted in this environment")

    try:
        result = validate_safe_path(link_path)
        assert result == os.path.realpath(desks)
    finally:
        if os.path.islink(link_path):
            os.unlink(link_path)


# ---------------------------------------------------------------------------
# Non-allowed prefix rejection
# ---------------------------------------------------------------------------


def test_rejects_regular_path_outside_allowed_prefixes():
    with pytest.raises(ValueError, match="Access denied"):
        validate_safe_path("/tmp/somefile.txt")


def test_rejects_home_root():
    with pytest.raises(ValueError, match="Access denied"):
        validate_safe_path(os.path.expanduser("~/.bashrc"))


def test_rejects_etc_directory():
    with pytest.raises(ValueError, match="Access denied"):
        validate_safe_path("/etc/hosts")


def test_rejects_var_directory():
    with pytest.raises(ValueError, match="Access denied"):
        validate_safe_path("/var/log/system.log")


def test_rejects_empty_string():
    with pytest.raises(ValueError, match="Filepath must not be empty"):
        validate_safe_path("")
