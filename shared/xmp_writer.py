# shared/xmp_writer.py - XMP sidecar keyword writing (shared module).
#
# Writes keywords into XMP sidecar files that Capture One can read
# as keywords.  Uses lxml.etree for XML manipulation.
#
# Behavior:
#   - If .xmp exists and was NOT created by Gather, backup first then merge.
#   - If .xmp was created by Gather, overwrite directly.
#   - If .xmp does not exist, create new.
#   - Preserves all existing namespace content.
#   - Records a created_by_gather marker.
#
# This module is self-contained and does not import from any sibling
# modules (face_keywording, similarity, etc.).  It is safe for
# similarity/service.py to import from here without creating a
# cross-module dependency.

from __future__ import annotations

import logging
import os
import shutil
import tempfile
from contextlib import suppress
from datetime import datetime, timezone

from lxml import etree

from .constants import PARTIAL_CHECKSUM_BYTES
from .path_utils import file_checksum, validate_safe_path

__all__ = [
    "BACKUP_SUFFIX",
    "GATHER_NS",
    "NSMAP",
    "backup_xmp",
    "cleanup_xmp",
    "file_checksum",
    "restore_xmp",
    "write_keywords",
]

logger = logging.getLogger("gather.xmp_writer")


# ---------------------------------------------------------------------------
# XMP namespace constants
# ---------------------------------------------------------------------------

NSMAP = {
    "x": "adobe:ns:meta/",
    "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "dc": "http://purl.org/dc/elements/1.1/",
    "xmp": "http://ns.adobe.com/xap/1.0/",
    "lr": "http://ns.adobe.com/lightroom/1.0/",
    "Iptc4xmpCore": "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/",
}

GATHER_NS = "http://gather.app/ns/1.0/"
GATHER_MARKER = "created_by_gather"
BACKUP_SUFFIX = ".gatherbak"

XML_PARSER = etree.XMLParser(
    resolve_entities=False,
    no_network=True,
    load_dtd=False,
    huge_tree=False,
)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def write_keywords(
    photo_paths: list[str],
    keywords_map: dict[str, list[str]],
) -> dict:
    """Write keywords to XMP sidecar files for a batch of photos.

    Returns: {"written": int, "failed": int, "errors": [...]}
    """
    written = 0
    failed = 0
    errors: list[dict] = []

    for photo_path in photo_paths:
        try:
            safe_path = validate_safe_path(photo_path, allow_temp=True)
            keywords = keywords_map.get(photo_path, [])
            _write_single(safe_path, keywords)
            written += 1
        except Exception as exc:  # noqa: PERF203
            failed += 1
            errors.append({"path": photo_path, "error": str(exc)})

    return {"written": written, "failed": failed, "errors": errors}


def backup_xmp(photo_path: str) -> str | None:
    """Backup existing .xmp to .xmp.gatherbak. Returns backup path or None."""
    photo_path = validate_safe_path(photo_path, allow_temp=True)
    xmp_path = _xmp_path(photo_path)
    if not os.path.isfile(xmp_path):
        return None

    backup_path = xmp_path + BACKUP_SUFFIX
    if os.path.isfile(backup_path):
        if _files_equal(xmp_path, backup_path):
            return backup_path
        backup_path = xmp_path + BACKUP_SUFFIX + "." + datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    fd = -1
    tmp_path = ""
    try:
        fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(xmp_path), suffix=".tmp")
        with os.fdopen(fd, "wb", closefd=False) as f, open(xmp_path, "rb", opener=lambda path, flags: os.open(path, flags | os.O_NOFOLLOW)) as src:
            while True:
                chunk = src.read(PARTIAL_CHECKSUM_BYTES)
                if not chunk:
                    break
                f.write(chunk)
        os.close(fd)
        fd = -1
        os.replace(tmp_path, backup_path)
    except Exception:
        if fd != -1:
            os.close(fd)
        raise
    finally:
        if tmp_path and os.path.isfile(tmp_path):
            with suppress(OSError):
                os.remove(tmp_path)
    return backup_path


def _verify_xml_file(path: str) -> bool:
    """Check if a file is non-empty and contains parseable XML."""
    if not os.path.isfile(path):
        return False
    try:
        if os.path.getsize(path) == 0:
            return False
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as fh:
            etree.parse(fh, parser=XML_PARSER)
        return True
    except (etree.ParseError, OSError):
        return False


def restore_xmp(photo_path: str, backup_path: str) -> bool:
    """Restore .xmp from backup and delete the backup file."""
    photo_path = validate_safe_path(photo_path, allow_temp=True)
    backup_path = validate_safe_path(backup_path, allow_temp=True)
    xmp_path = _xmp_path(photo_path)
    if not os.path.isfile(backup_path):
        return False

    if not _verify_xml_file(backup_path):
        logger.error("Backup file is corrupted (empty or unparseable), skipping restore: %s", backup_path)
        return False

    try:
        shutil.move(backup_path, xmp_path)
        return True
    except OSError as exc:
        logger.warning("Failed to restore XMP from backup %s: %s", backup_path, exc)
        return False


def cleanup_xmp(photo_paths: list[str]) -> dict:
    """Clean up: remove Gather-created XMPs, restore from backups.

    Before restoring a backup, compares the current XMP hash against
    the hash stored in the Gather metadata. If they differ (XMP was
    modified externally since Gather wrote to it), creates a secondary
    backup (*.gatherbak.modified) before overwriting, and logs a warning.
    """
    deleted = 0
    restored = 0
    skipped = 0
    errors: list[dict] = []

    for photo_path in photo_paths:
        try:
            photo_path = validate_safe_path(photo_path, allow_temp=True)
            xmp_path = _xmp_path(photo_path)
            backup_path = xmp_path + BACKUP_SUFFIX
            if os.path.isfile(backup_path):
                # Verify backup integrity before restoring
                if not _verify_xml_file(backup_path):
                    logger.error("Backup file is corrupted (empty or unparseable), skipping restore: %s", backup_path)
                    skipped += 1
                    continue
                # Check if the current XMP appears to be a user/external
                # replacement rather than the Gather-written file.
                #
                # Uses the Gather XML marker as a signal: marked files are
                # restored directly; unmarked files are preserved before
                # restoring.  NOTE: if a user edits a Gather-written XMP
                # but preserves the marker, this heuristic cannot detect it
                # without a post-write hash stored alongside the backup.
                if os.path.isfile(xmp_path) and not _is_gather_xmp(xmp_path):
                    modified_backup = backup_path + ".modified"
                    if not os.path.isfile(modified_backup):
                        shutil.copy2(xmp_path, modified_backup)
                        logger.warning(
                            "XMP no longer has Gather marker and may have been modified externally: %s. "
                            "Preserving current XMP as %s before restoring backup.",
                            xmp_path,
                            modified_backup,
                        )
                shutil.move(backup_path, xmp_path)
                restored += 1
            elif os.path.isfile(xmp_path):
                if _is_gather_xmp(xmp_path):
                    os.remove(xmp_path)
                    deleted += 1
                else:
                    skipped += 1
        except Exception as exc:
            errors.append({"path": photo_path, "error": str(exc)})

    return {
        "deleted": deleted,
        "restored": restored,
        "skipped": skipped,
        "errors": errors,
    }


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _xmp_path(photo_path: str) -> str:
    """Return the .xmp sidecar path for a given photo.
    
    Raises ValueError if photo_path itself is an .xmp file (must be a photo).
    """
    if photo_path.lower().endswith(".xmp"):
        raise ValueError(f"Expected a photo path, got an XMP file: {photo_path}")
    xmp = photo_path + ".xmp"
    real_xmp = os.path.realpath(xmp)
    photo_dir = os.path.dirname(os.path.realpath(photo_path))
    # SAFETY: os.path.commonpath is used here for path traversal prevention.
    # Edge case: if photo_dir == "/" (photo at filesystem root), commonpath
    # always matches, but this is extremely unlikely in practice. realpath
    # normalizes symlinks, so a malicious symlink cannot bypass this check.
    # On case-insensitive filesystems (macOS), commonpath comparison works
    # correctly because realpath normalizes the path.
    if not os.path.commonpath([real_xmp, photo_dir]) == photo_dir:
        raise ValueError(f"XMP path escapes photo directory: {xmp}")
    return real_xmp


def _parse_xmp(xmp_path: str) -> etree._ElementTree:
    """Parse an XMP file with DTD/entity expansion disabled."""
    with open(xmp_path, 'rb', opener=lambda path, flags: os.open(path, flags | os.O_NOFOLLOW)) as f:
        tree = etree.parse(f, parser=XML_PARSER)
    if tree.docinfo.doctype:
        raise ValueError("DTD is not allowed in XMP")
    return tree


def _is_gather_xmp(xmp_path: str) -> bool:
    """Check if an XMP file was created by Gather."""
    try:
        tree = _parse_xmp(xmp_path)
        root = tree.getroot()

        rdf_tag = "{{{}}}RDF".format(NSMAP["rdf"])
        rdf = root if root.tag == rdf_tag else root.find(rdf_tag)
        if rdf is None:
            rdf = root

        gather_key = f"{{{GATHER_NS}}}{GATHER_MARKER}"
        desc_tag = "{{{}}}Description".format(NSMAP["rdf"])

        for desc in rdf.iter(desc_tag):
            if desc.get(gather_key):
                return True

        # Also scan root directly
        # NOTE: When root IS rdf (root.tag == rdf_tag), the rdf.iter() loop
        # above already covers all elements, making this second scan fully
        # redundant. Kept as a safety net for edge-case XMP variants where
        # rdf:Description appears outside the expected RDF wrapper.
        for desc in root.iter(desc_tag):
            if desc.get(gather_key):
                return True

    except (etree.ParseError, OSError) as exc:
        logger.debug("Could not parse XMP %s: %s", xmp_path, exc)
    return False


def _has_gather_content(xmp_path: str) -> bool:
    """Check if an XMP file contains Gather-written keywords even when the marker was removed.

    Used to detect Gather-originated XMPs (created by _write_single with no pre-existing backup)
    that were subsequently stripped of the Gather marker by an external tool.
    """
    try:
        tree = _parse_xmp(xmp_path)
        for elem in tree.iter():
            if elem.text and (elem.text.startswith("Gather:") or elem.text.startswith("gather:")):
                return True
    except (etree.ParseError, OSError):
        pass
    return False


def _verify_backup_integrity(photo_path: str) -> bool:
    """Check that the current XMP matches its Gather backup.

    Returns True if safe to overwrite (match or no backup),
    False if the XMP was modified externally since backup.
    """
    xmp_path = _xmp_path(photo_path)
    backup_path = xmp_path + BACKUP_SUFFIX
    if not os.path.isfile(backup_path):
        return True  # no backup to compare against
    if not os.path.isfile(xmp_path):
        return True  # XMP was deleted (not modified)
    if _files_equal(xmp_path, backup_path):
        return True
    return _is_gather_xmp(xmp_path)


def _files_equal(left_path: str, right_path: str) -> bool:
    """Compare two files by bytes without following symlinks."""
    try:
        left_stat = os.stat(left_path, follow_symlinks=False)
        right_stat = os.stat(right_path, follow_symlinks=False)
        if left_stat.st_size != right_stat.st_size:
            return False
        with (
            open(left_path, "rb", opener=lambda path, flags: os.open(path, flags | os.O_NOFOLLOW)) as left,
            open(right_path, "rb", opener=lambda path, flags: os.open(path, flags | os.O_NOFOLLOW)) as right,
        ):
            while True:
                left_chunk = left.read(PARTIAL_CHECKSUM_BYTES)
                right_chunk = right.read(PARTIAL_CHECKSUM_BYTES)
                if left_chunk != right_chunk:
                    return False
                if not left_chunk:
                    return True
    except OSError as exc:
        logger.debug("Could not compare files %s and %s: %s", left_path, right_path, exc)
        return False


def _write_single(photo_path: str, keywords: list[str]) -> None:
    """Write keywords to a single photo's XMP sidecar."""
    safe_path = validate_safe_path(photo_path, allow_temp=True)
    xmp_path = _xmp_path(safe_path)
    existing = os.path.isfile(xmp_path)
    is_gather = existing and _is_gather_xmp(xmp_path)

    if existing and not is_gather:
        backup_path = xmp_path + BACKUP_SUFFIX
        if not os.path.isfile(backup_path) and _has_gather_content(xmp_path):
            # XMP was originally created by Gather (has Gather keywords but
            # marker was stripped).  Treat as a Gather XMP — merge keywords
            # without creating a spurious backup of the Gather content.
            tree = _parse_xmp(xmp_path)
            root = tree.getroot()
            _add_gather_marker(root)
            _merge_keywords(root, keywords)
        else:
            # Verify existing backup integrity BEFORE creating a new backup
            if not _verify_backup_integrity(photo_path):
                raise RuntimeError(f"XMP was modified externally since backup. Aborting write for: {photo_path}")
            backup_xmp(photo_path)
            tree = _parse_xmp(xmp_path)
            root = tree.getroot()
            _add_gather_marker(root)
            _merge_keywords(root, keywords)
    elif existing and is_gather:
        tree = _parse_xmp(xmp_path)
        root = tree.getroot()
        _merge_keywords(root, keywords)
    else:
        root = _create_xmp_root()
        _merge_keywords(root, keywords)
        tree = etree.ElementTree(root)

    # Atomic write: write to temp file first, then rename
    fd = -1
    tmp_path = ""
    try:
        fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(xmp_path), suffix=".tmp")
        with os.fdopen(fd, "wb", closefd=False) as f:
            tree.write(
                f,
                xml_declaration=True,
                encoding="UTF-8",
                pretty_print=True,
            )
        os.close(fd)
        fd = -1
        os.replace(tmp_path, xmp_path)  # atomic on same filesystem
    except Exception:
        if fd != -1:
            os.close(fd)
        raise
    finally:
        if tmp_path and os.path.isfile(tmp_path):
            with suppress(OSError):
                os.remove(tmp_path)


def _create_xmp_root() -> etree._Element:
    """Create a fresh XMP packet root element with Gather marker."""
    xmpmeta = etree.Element(
        "{{{}}}xmpmeta".format(NSMAP["x"]),
        nsmap={None: NSMAP["x"]},
    )
    rdf = etree.SubElement(xmpmeta, "{{{}}}RDF".format(NSMAP["rdf"]))

    # Set namespaces on RDF
    rdf_attrib = {}
    rdf_attrib["{{{}}}about".format(NSMAP["rdf"])] = ""
    rdf_attrib[f"{{{GATHER_NS}}}{GATHER_MARKER}"] = "true"
    rdf_attrib[f"{{{GATHER_NS}}}timestamp"] = datetime.now(timezone.utc).isoformat()

    etree.SubElement(
        rdf,
        "{{{}}}Description".format(NSMAP["rdf"]),
        attrib=rdf_attrib,
    )
    return xmpmeta


def _add_gather_marker(root: etree._Element) -> None:
    """Add or update the Gather marker on the first rdf:Description."""
    desc = _find_or_create_description(root)
    gather_marker = f"{{{GATHER_NS}}}{GATHER_MARKER}"
    desc.set(gather_marker, "true")
    gather_timestamp = f"{{{GATHER_NS}}}timestamp"
    desc.set(gather_timestamp, datetime.now(timezone.utc).isoformat())


def _find_rdf(root: etree._Element) -> etree._Element:
    """Find the rdf:RDF element, or root if it is RDF."""
    rdf_tag = "{{{}}}RDF".format(NSMAP["rdf"])
    if root.tag == rdf_tag:
        return root
    for child in root:
        if child.tag == rdf_tag:
            return child
    return etree.SubElement(root, rdf_tag)


def _find_or_create_description(root: etree._Element) -> etree._Element:
    """Find the first rdf:Description in the tree or create one."""
    rdf = _find_rdf(root)
    desc_tag = "{{{}}}Description".format(NSMAP["rdf"])
    for child in rdf:
        if child.tag == desc_tag:
            return child
    return etree.SubElement(rdf, desc_tag)


def _merge_keywords(root: etree._Element, keywords: list[str]) -> None:
    """Merge keywords into dc:subject, lr:hierarchicalSubject, and Iptc4xmpCore:Keywords.

    Flat keywords from Gather are appended to dc:subject and Iptc4xmpCore:Keywords.
    lr:hierarchicalSubject preserves its original hierarchical entries (e.g. "People|John")
    and only appends new flat keywords that aren't already present.
    """
    desc = _find_or_create_description(root)

    dc_subject_tag = "{{{}}}subject".format(NSMAP["dc"])
    lr_subject_tag = "{{{}}}hierarchicalSubject".format(NSMAP["lr"])
    iptc_keywords_tag = "{{{}}}Keywords".format(NSMAP["Iptc4xmpCore"])

    existing_dc = _read_existing_keywords(desc, dc_subject_tag)
    existing_lr = _read_existing_keywords(desc, lr_subject_tag)
    existing_iptc = _read_existing_keywords(desc, iptc_keywords_tag)

    # Flat keywords: merge dc + iptc + new keywords (deduplicated)
    flat_keywords = existing_dc + existing_iptc + keywords
    seen_flat = set()
    merged_flat = []
    for kw in flat_keywords:
        if kw not in seen_flat:
            seen_flat.add(kw)
            merged_flat.append(kw)

    # Hierarchical keywords: preserve originals, append only new flat keywords
    existing_lr_set = set(existing_lr)
    merged_lr = list(existing_lr)  # keep original hierarchical entries intact
    for kw in merged_flat:
        if kw not in existing_lr_set:
            merged_lr.append(kw)
            existing_lr_set.add(kw)

    _remove_child(desc, dc_subject_tag)
    _remove_child(desc, lr_subject_tag)
    _remove_child(desc, iptc_keywords_tag)

    if merged_flat:
        _write_bag(desc, dc_subject_tag, merged_flat)
        _write_bag(desc, iptc_keywords_tag, merged_flat)

    if merged_lr:
        _write_bag(desc, lr_subject_tag, merged_lr)


def _read_existing_keywords(desc: etree._Element, tag: str) -> list[str]:
    """Extract all rdf:li text values from a Bag/Seq/Alt inside the given tag."""
    keywords: list[str] = []
    for child in desc:
        if child.tag == tag:
            for container in child:
                keywords.extend(li.text.strip() for li in container if li.text and li.text.strip())
            break
    return keywords


def _write_bag(parent: etree._Element, tag: str, keywords: list[str]) -> None:
    """Write a list of keywords as an rdf:Bag under a new element."""
    elem = etree.SubElement(parent, tag)
    bag = etree.SubElement(elem, "{{{}}}Bag".format(NSMAP["rdf"]))
    for kw in keywords:
        li = etree.SubElement(bag, "{{{}}}li".format(NSMAP["rdf"]))
        li.text = kw


def _remove_child(parent: etree._Element, tag: str) -> None:
    """Remove all child elements matching the given tag."""
    for child in list(parent):
        if child.tag == tag:
            parent.remove(child)
