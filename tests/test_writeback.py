import os
import sys
import time
from contextlib import suppress

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lxml import etree

from shared.xmp_writer import (
    GATHER_NS,
    NSMAP,
    backup_xmp,
    cleanup_xmp,
    restore_xmp,
    write_keywords,
)

# ---------------------------------------------------------------------------
# write_keywords creates new .xmp
# ---------------------------------------------------------------------------


def test_write_keywords_creates_new_xmp(tmp_path):
    photo = tmp_path / "photo1.jpg"
    photo.write_text("fake image")

    result = write_keywords(
        [str(photo)],
        {str(photo): ["tag1", "tag2"]},
    )
    assert result["written"] == 1
    assert result["failed"] == 0

    xmp_path = tmp_path / "photo1.jpg.xmp"
    assert xmp_path.exists()

    tree = etree.parse(str(xmp_path))
    root = tree.getroot()

    desc_tag = "{{{}}}Description".format(NSMAP["rdf"])
    gather_marker = f"{{{GATHER_NS}}}created_by_gather"
    desc = root.find(f".//{desc_tag}")
    assert desc is not None
    assert desc.get(gather_marker) == "true"

    dc_subj_tag = "{{{}}}subject".format(NSMAP["dc"])
    li_tag = "{{{}}}li".format(NSMAP["rdf"])
    subj = root.find(f".//{dc_subj_tag}")
    assert subj is not None
    items = [li.text for li in subj.findall(f".//{li_tag}") if li.text]
    assert "tag1" in items
    assert "tag2" in items


# ---------------------------------------------------------------------------
# write_keywords merges with existing .xmp
# ---------------------------------------------------------------------------


def test_write_keywords_merges_existing_xmp(tmp_path):
    photo = tmp_path / "photo2.jpg"
    photo.write_text("fake image")

    # Create a pre-existing XMP with a dc:creator element
    xmpmeta = etree.Element("xmpmeta", nsmap={"x": "adobe:ns:meta/"})
    rdf = etree.SubElement(xmpmeta, "{{{}}}RDF".format(NSMAP["rdf"]))
    desc = etree.SubElement(rdf, "{{{}}}Description".format(NSMAP["rdf"]))
    creator = etree.SubElement(desc, "{{{}}}creator".format(NSMAP["dc"]))
    creator.text = "Original Author"

    tree = etree.ElementTree(xmpmeta)
    tree.write(str(photo) + ".xmp", xml_declaration=True, encoding="UTF-8", pretty_print=True)

    result = write_keywords(
        [str(photo)],
        {str(photo): ["newtag"]},
    )
    assert result["written"] == 1

    xmp_path = tmp_path / "photo2.jpg.xmp"
    tree2 = etree.parse(str(xmp_path))
    root2 = tree2.getroot()

    # Original creator should be preserved
    dc_creator_tag = "{{{}}}creator".format(NSMAP["dc"])
    creator_el = root2.find(f".//{dc_creator_tag}")
    assert creator_el is not None
    assert creator_el.text == "Original Author"

    # New keyword should be present
    dc_subj_tag = "{{{}}}subject".format(NSMAP["dc"])
    li_tag = "{{{}}}li".format(NSMAP["rdf"])
    subj = root2.find(f".//{dc_subj_tag}")
    assert subj is not None
    items = [li.text for li in subj.findall(f".//{li_tag}") if li.text]
    assert "newtag" in items

    # Gather marker should be added
    gather_marker = f"{{{GATHER_NS}}}created_by_gather"
    desc2 = root2.find(".//{{{}}}Description".format(NSMAP["rdf"]))
    assert desc2 is not None
    assert desc2.get(gather_marker) == "true"

    # Backup should exist
    backup_path = tmp_path / "photo2.jpg.xmp.gatherbak"
    assert backup_path.exists()


# ---------------------------------------------------------------------------
# backup_xmp
# ---------------------------------------------------------------------------


def test_backup_xmp_creates_gatherbak(tmp_path):
    photo = tmp_path / "photo3.jpg"
    photo.write_text("fake image")
    xmp_path = tmp_path / "photo3.jpg.xmp"
    xmp_path.write_text("<xmpmeta></xmpmeta>")

    result = backup_xmp(str(photo))
    assert result is not None
    assert result.endswith(".gatherbak")

    backup_path = tmp_path / "photo3.jpg.xmp.gatherbak"
    assert backup_path.exists()
    assert backup_path.read_text() == "<xmpmeta></xmpmeta>"

    time.sleep(0.001)
    xmp_path.write_text("<xmpmeta>changed</xmpmeta>")
    # After XMP content changes, the old backup no longer matches (stale).
    # backup_xmp detects hash mismatch, removes stale backup, creates new timestamped one.
    result2 = backup_xmp(str(photo))
    assert result2 is not None
    assert ".gatherbak" in result2  # timestamped suffix: .gatherbak.YYYYMMDD_HHMMSS
    assert result2 != str(backup_path)  # new timestamped backup, not the stale one
    assert os.path.exists(result2)  # new backup exists
    assert backup_path.exists()  # old backup preserved (differs, kept as variant)
    with open(result2) as f:
        assert f.read() == "<xmpmeta>changed</xmpmeta>"

    # Backup when no XMP exists returns None
    photo2 = tmp_path / "photo4.jpg"
    photo2.write_text("fake image")
    assert backup_xmp(str(photo2)) is None


# ---------------------------------------------------------------------------
# restore_xmp
# ---------------------------------------------------------------------------


def test_restore_xmp(tmp_path):
    photo = tmp_path / "photo5.jpg"
    photo.write_text("fake image")
    xmp_path = tmp_path / "photo5.jpg.xmp"
    xmp_path.write_text("<xmpmeta>original content</xmpmeta>")

    backup = backup_xmp(str(photo))
    assert backup is not None

    # Corrupt the current XMP
    xmp_path.write_text("<xmpmeta>modified content</xmpmeta>")

    # Restore from backup
    restored = restore_xmp(str(photo), backup)
    assert restored is True
    assert xmp_path.read_text() == "<xmpmeta>original content</xmpmeta>"

    # Backup file should be gone after restore
    backup_path = tmp_path / "photo5.jpg.xmp.gatherbak"
    assert not backup_path.exists()


# ---------------------------------------------------------------------------
# cleanup_xmp
# ---------------------------------------------------------------------------


def test_cleanup_xmp_gather_created_files_deleted(tmp_path):
    photo = tmp_path / "photo6.jpg"
    photo.write_text("fake image")

    write_keywords([str(photo)], {str(photo): ["test"]})

    result = cleanup_xmp([str(photo)])
    assert result["deleted"] == 1
    assert result["restored"] == 0

    xmp_path = tmp_path / "photo6.jpg.xmp"
    assert not xmp_path.exists()


def test_cleanup_xmp_backed_up_files_restored(tmp_path):

    photo = tmp_path / "photo7.jpg"
    photo.write_text("fake image")
    xmp_path = tmp_path / "photo7.jpg.xmp"
    xmp_path.write_text("<xmpmeta>pre-gather content</xmpmeta>")

    backup = backup_xmp(str(photo))
    assert backup is not None

    write_keywords([str(photo)], {str(photo): ["gather-tag"]})

    result = cleanup_xmp([str(photo)])
    assert result["restored"] == 1

    assert xmp_path.exists()
    assert xmp_path.read_text() == "<xmpmeta>pre-gather content</xmpmeta>"
    assert not (tmp_path / "photo7.jpg.xmp.gatherbak.modified").exists()


def test_cleanup_xmp_preserves_unmarked_current_xmp_before_restore(tmp_path):
    photo = tmp_path / "photo7b.jpg"
    photo.write_text("fake image")
    xmp_path = tmp_path / "photo7b.jpg.xmp"
    xmp_path.write_text("<xmpmeta>pre-gather content</xmpmeta>")

    backup = backup_xmp(str(photo))
    assert backup is not None

    write_keywords([str(photo)], {str(photo): ["gather-tag"]})
    xmp_path.write_text("<xmpmeta>external replacement</xmpmeta>")

    result = cleanup_xmp([str(photo)])
    assert result["restored"] == 1
    assert xmp_path.read_text() == "<xmpmeta>pre-gather content</xmpmeta>"
    assert (tmp_path / "photo7b.jpg.xmp.gatherbak.modified").read_text() == "<xmpmeta>external replacement</xmpmeta>"


# ---------------------------------------------------------------------------
# Unicode keywords
# ---------------------------------------------------------------------------


def test_write_keywords_unicode(tmp_path):
    photo = tmp_path / "photo8.jpg"
    photo.write_text("fake image")

    keywords_map = {
        str(photo): ["\u4e2d\u6587\u6807\u7b7e", "\u65e5\u672c\u8a9e\u30bf\u30b0"],
    }
    result = write_keywords([str(photo)], keywords_map)
    assert result["written"] == 1

    xmp_path = tmp_path / "photo8.jpg.xmp"
    tree = etree.parse(str(xmp_path))
    root = tree.getroot()

    li_tag = "{{{}}}li".format(NSMAP["rdf"])
    items = [li.text for li in root.findall(f".//{li_tag}") if li.text]
    assert "\u4e2d\u6587\u6807\u7b7e" in items
    assert "\u65e5\u672c\u8a9e\u30bf\u30b0" in items


# ---------------------------------------------------------------------------
# Nonexistent photo path
# ---------------------------------------------------------------------------


def test_write_keywords_nonexistent_photo(tmp_path):
    result = write_keywords(
        ["/nonexistent/photo.jpg"],
        {"/nonexistent/photo.jpg": ["tag"]},
    )
    assert result["written"] == 0
    assert result["failed"] == 1
    assert len(result["errors"]) == 1
    assert result["errors"][0]["path"] == "/nonexistent/photo.jpg"
    assert "error" in result["errors"][0]


# ---------------------------------------------------------------------------
# Empty keywords
# ---------------------------------------------------------------------------


def test_write_keywords_empty(tmp_path):
    photo = tmp_path / "photo9.jpg"
    photo.write_text("fake image")

    result = write_keywords([str(photo)], {str(photo): []})
    assert result["written"] == 1

    xmp_path = tmp_path / "photo9.jpg.xmp"
    tree = etree.parse(str(xmp_path))
    root = tree.getroot()

    dc_subj_tag = "{{{}}}subject".format(NSMAP["dc"])
    subj = root.find(f".//{dc_subj_tag}")
    assert subj is None


def test_hierarchical_subject_uses_plain_keywords(tmp_path):
    photo = tmp_path / "photo10.jpg"
    photo.write_text("fake image")

    result = write_keywords([str(photo)], {str(photo): ["person", "family"]})
    assert result["written"] == 1

    tree = etree.parse(str(photo) + ".xmp")
    root = tree.getroot()
    lr_subj_tag = "{{{}}}hierarchicalSubject".format(NSMAP["lr"])
    li_tag = "{{{}}}li".format(NSMAP["rdf"])
    lr_subj = root.find(f".//{lr_subj_tag}")
    assert lr_subj is not None
    items = [li.text for li in lr_subj.findall(f".//{li_tag}") if li.text]
    assert items == ["person", "family"]
    assert all(not item.startswith("Gather|") for item in items)


def test_write_keywords_rejects_dtd_entities(tmp_path):
    photo = tmp_path / "photo11.jpg"
    photo.write_text("fake image")
    xmp_path = tmp_path / "photo11.jpg.xmp"
    xmp_path.write_text(
        """<?xml version="1.0"?>
<!DOCTYPE xmpmeta [
<!ENTITY xxe SYSTEM "file:///etc/passwd">
]>
<xmpmeta><RDF xmlns="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><Description>&xxe;</Description></RDF></xmpmeta>
"""
    )

    result = write_keywords([str(photo)], {str(photo): ["safe"]})
    assert result["written"] == 0
    assert result["failed"] == 1
    assert "DTD is not allowed" in result["errors"][0]["error"]


# ---------------------------------------------------------------------------
# Corruption tests: XMP backup/restore integrity
# ---------------------------------------------------------------------------


def test_restore_xmp_from_empty_backup(tmp_path):
    photo = tmp_path / "corrupt_empty.jpg"
    photo.write_text("fake image")
    xmp_path = tmp_path / "corrupt_empty.jpg.xmp"
    xmp_path.write_text("current xmp content")
    backup_path = tmp_path / "corrupt_empty.jpg.xmp.gatherbak"
    backup_path.write_text("")

    restored = restore_xmp(str(photo), str(backup_path))
    assert restored is False
    assert xmp_path.read_text() == "current xmp content"


def test_restore_xmp_from_invalid_xml_backup(tmp_path):
    photo = tmp_path / "corrupt_xml.jpg"
    photo.write_text("fake image")
    xmp_path = tmp_path / "corrupt_xml.jpg.xmp"
    xmp_path.write_text("current xmp content")
    backup_path = tmp_path / "corrupt_xml.jpg.xmp.gatherbak"
    backup_path.write_text("this is not valid XML at all")

    restored = restore_xmp(str(photo), str(backup_path))
    assert restored is False
    assert xmp_path.read_text() == "current xmp content"


def test_restore_xmp_when_current_xmp_is_deleted(tmp_path):
    photo = tmp_path / "current_deleted.jpg"
    photo.write_text("fake image")
    xmp_path = tmp_path / "current_deleted.jpg.xmp"
    xmp_path.write_text("<xmpmeta>original content</xmpmeta>")
    backup_path = tmp_path / "current_deleted.jpg.xmp.gatherbak"
    backup_path.write_text("<xmpmeta>original content</xmpmeta>")

    # Delete current XMP
    os.remove(str(xmp_path))
    assert not xmp_path.exists()

    restored = restore_xmp(str(photo), str(backup_path))
    assert restored is True
    assert xmp_path.exists()
    assert xmp_path.read_text() == "<xmpmeta>original content</xmpmeta>"
    assert not backup_path.exists()


def test_backup_xmp_copy_failure_safety(tmp_path, monkeypatch):
    photo = tmp_path / "backup_safe.jpg"
    photo.write_text("fake image")
    xmp_path = tmp_path / "backup_safe.jpg.xmp"
    xmp_path.write_text("original xmp content")

    old_backup = tmp_path / "backup_safe.jpg.xmp.gatherbak"
    old_backup.write_text("old backup content")

    def fail_copy(*args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(os, "replace", fail_copy)

    with suppress(OSError):
        backup_xmp(str(photo))

    assert xmp_path.read_text() == "original xmp content"


def test_cleanup_xmp_skips_corrupted_backup(tmp_path):
    photo = tmp_path / "skip_corrupt.jpg"
    photo.write_text("fake image")
    xmp_path = tmp_path / "skip_corrupt.jpg.xmp"
    xmp_path.write_text("current content")
    backup_path = tmp_path / "skip_corrupt.jpg.xmp.gatherbak"
    backup_path.write_text("")

    result = cleanup_xmp([str(photo)])
    assert result["restored"] == 0
    assert xmp_path.exists()
    assert xmp_path.read_text() == "current content"
