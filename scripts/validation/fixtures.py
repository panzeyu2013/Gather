#!/usr/bin/env python3
"""Gather V1 夹具生成/校验（开发/验证工具，不参与 App 构建）。

依赖：Python 3.10+、Pillow 10+（brew install pillow 或 pip install pillow）。
基底图与 ICC 取系统 sRGB；XMP/APP13 由本脚本按 JPEG 段规范注入，不依赖 exiftool。

用法：
  python3 scripts/validation/fixtures.py generate --out /tmp/gather-fixtures
  python3 scripts/validation/fixtures.py verify   --dir /tmp/gather-fixtures
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

try:
    from PIL import Image, ImageDraw
except ImportError as exc:  # pragma: no cover
    raise SystemExit("需要 Pillow：pip install pillow") from exc

SOI = b"\xff\xd8"
XMP_ID = b"http://ns.adobe.com/xap/1.0/\x00"
PS_ID = b"Photoshop 3.0\x00"
ICC_CANDIDATES = [
    "/System/Library/ColorSync/Profiles/sRGB Profile.icc",
    "/System/Library/ColorSync/Profiles/Display P3.icc",
]


@dataclass
class Spec:
    name: str
    category: str
    xmp: bool
    iptc: bool
    fields: dict[str, object]
    iptc_chunks: int = 1
    note: str = ""


def split_jpeg(data: bytes) -> tuple[list[tuple[int, bytes]], bytes]:
    if not data.startswith(SOI):
        raise ValueError("not JPEG")
    out: list[tuple[int, bytes]] = []
    i = 2
    while i < len(data):
        if data[i] != 0xFF:
            raise ValueError(f"bad marker at {i}")
        marker = data[i + 1]
        if marker == 0xDA:
            return out, data[i:]
        if marker == 0xD8 or marker == 0x01 or 0xD0 <= marker <= 0xD7:
            out.append((marker, b""))
            i += 2
            continue
        length = int.from_bytes(data[i + 2 : i + 4], "big")
        payload = data[i + 4 : i + 2 + length]
        out.append((marker, payload))
        i += 2 + length
    raise ValueError("no SOS")


def build_jpeg(segments: list[tuple[int, bytes]], scan: bytes) -> bytes:
    out = bytearray(SOI)
    for marker, payload in segments:
        out += bytes((0xFF, marker)) + (len(payload) + 2).to_bytes(2, "big") + payload
    return bytes(out) + scan


def is_xmp(payload: bytes) -> bool:
    return payload.startswith(XMP_ID)


def is_photoshop(payload: bytes) -> bool:
    return payload.startswith(PS_ID)


def app13(iim: bytes) -> bytes:
    # IRB: 8BIM + id + Pascal 名（空）+ u32 size + data + 奇偶填充
    body = b"8BIM" + (0x0404).to_bytes(2, "big") + b"\x00\x00"
    body += len(iim).to_bytes(4, "big") + iim
    if len(iim) % 2:
        body += b"\x00"
    return PS_ID + body


def dataset(record: int, number: int, value: str | bytes) -> bytes:
    raw = value.encode("utf-8") if isinstance(value, str) else value
    if len(raw) > 0x7FFF:
        raise ValueError("dataset > 32767")
    return bytes((0x1C, record, number)) + len(raw).to_bytes(2, "big") + raw


def iim_blob(fields: dict[str, object], extra_keywords: int = 0) -> bytes:
    parts = [dataset(1, 90, b"\x1b%G")]
    parts.append(dataset(2, 5, str(fields["title"])))
    parts.append(dataset(2, 55, b"20261031"))
    parts.append(dataset(2, 60, b"100000+0800"))
    parts.append(dataset(2, 80, str(fields["byline"])))
    parts.append(dataset(2, 110, str(fields["credit"])))
    parts.append(dataset(2, 115, str(fields["source"])))
    parts.append(dataset(2, 116, str(fields["copyright"])))
    parts.append(dataset(2, 120, str(fields["caption"])))
    parts.append(dataset(2, 90, str(fields["city"])))
    parts.append(dataset(2, 101, str(fields["country"])))
    parts.append(dataset(2, 105, str(fields["headline"])))
    for keyword in fields["keywords"]:
        parts.append(dataset(2, 25, str(keyword)))
    for index in range(extra_keywords):
        parts.append(dataset(2, 25, f"bulk-{index:04d}-" + "x" * 120))
    return b"".join(parts)


def chunk_iim(blob: bytes, max_bytes: int) -> list[bytes]:
    """按 IIM dataset 边界切块（不切断单条 dataset）。"""
    chunks: list[bytes] = []
    current = bytearray()
    i = 0
    while i < len(blob):
        if blob[i] != 0x1C:
            raise ValueError("bad IIM")
        length = int.from_bytes(blob[i + 3 : i + 5], "big")
        end = i + 5 + length
        item = blob[i:end]
        if current and len(current) + len(item) > max_bytes:
            chunks.append(bytes(current))
            current = bytearray()
        current += item
        i = end
    if current:
        chunks.append(bytes(current))
    return chunks


def xmp_packet(fields: dict[str, object]) -> bytes:
    kw = "".join(f"<rdf:li>{escape(str(k))}</rdf:li>" for k in fields["keywords"])
    hier = "".join(
        f"<rdf:li>{escape(str(k))}</rdf:li>" for k in fields.get("hierarchical", [])
    )
    packet = f"""<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
    xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/"
    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
    photoshop:City={quoteattr(str(fields["city"]))}
    photoshop:Country={quoteattr(str(fields["country"]))}
    photoshop:Credit={quoteattr(str(fields["credit"]))}
    photoshop:Source={quoteattr(str(fields["source"]))}
    photoshop:Headline={quoteattr(str(fields["headline"]))}
    xmpRights:Marked="True"
    xmpRights:WebStatement="https://example.invalid/license">
   <dc:title><rdf:Alt><rdf:li xml:lang="x-default">{escape(str(fields["title"]))}</rdf:li></rdf:Alt></dc:title>
   <dc:description><rdf:Alt><rdf:li xml:lang="x-default">{escape(str(fields["caption"]))}</rdf:li></rdf:Alt></dc:description>
   <dc:creator><rdf:Seq><rdf:li>{escape(str(fields["byline"]))}</rdf:li></rdf:Seq></dc:creator>
   <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">{escape(str(fields["copyright"]))}</rdf:li></rdf:Alt></dc:rights>
   <dc:subject><rdf:Bag>{kw}</rdf:Bag></dc:subject>
   <lr:hierarchicalSubject><rdf:Bag>{hier}</rdf:Bag></lr:hierarchicalSubject>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"""
    return packet.encode("utf-8")


def load_icc() -> bytes | None:
    for path in ICC_CANDIDATES:
        p = Path(path)
        if p.is_file():
            return p.read_bytes()
    return None


def make_base(path: Path, icc: bytes | None, with_exif: bool) -> None:
    width, height = 640, 400
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)
    for y in range(height):
        draw.line([(0, y), (width, y)], fill=(y % 256, (y * 3) % 256, 160))
    draw.rectangle((40, 40, 200, 140), fill=(240, 200, 80))
    draw.rectangle((240, 180, 600, 360), fill=(30, 60, 120))
    kwargs: dict[str, object] = {"quality": 90}
    if with_exif:
        exif = Image.Exif()
        exif[0x010F] = "Gather"
        exif[0x0110] = "FixtureCam"
        exif[0x0112] = 1
        exif[0x0132] = "2026:10:31 10:00:00"
        exif[0x9003] = "2026:10:31 10:00:00"
        exif[0x013B] = "Gather QA"
        exif[0x8298] = "Copyright 2026 Gather"
        kwargs["exif"] = exif
    if icc:
        kwargs["icc_profile"] = icc
    image.save(path, "JPEG", **kwargs)


def inject(path: Path, spec: Spec) -> None:
    data = path.read_bytes()
    segments, scan = split_jpeg(data)
    segments = [(m, p) for m, p in segments if not is_xmp(p) and not is_photoshop(p)]
    insert_at = 0
    for index, (_, payload) in enumerate(segments):
        if payload.startswith(b"Exif\x00\x00"):
            insert_at = index + 1
    if insert_at == 0:
        for index, (marker, _) in enumerate(segments):
            if marker == 0xE0:
                insert_at = index + 1
    inserted: list[tuple[int, bytes]] = []
    if spec.xmp:
        inserted.append((0xE1, XMP_ID + xmp_packet(spec.fields)))
    if spec.iptc:
        blob = iim_blob(spec.fields, extra_keywords=600 if spec.category == "E-large" else 0)
        if spec.iptc_chunks > 1:
            chunks = chunk_iim(blob, 55_000)
            if len(chunks) < 2:
                raise ValueError("large fixture did not split")
            for chunk in chunks:
                inserted.append((0xED, app13(chunk)))
        else:
            inserted.append((0xED, app13(blob)))
    segments[insert_at:insert_at] = inserted
    path.write_bytes(build_jpeg(segments, scan))


def scan_sha256(data: bytes) -> str:
    _, scan = split_jpeg(data)
    return hashlib.sha256(scan).hexdigest()


CATEGORIES = {
    # category: (xmp, iptc, iptc_chunks)
    "A-full": (True, True, 1),
    "B-iptc": (False, True, 1),
    "C-xmp": (True, False, 0),
    "D-unicode": (True, True, 1),
    "E-large": (False, True, 2),
    "F-bare": (False, False, 0),
}

MATRIX = {"A-full": 30, "B-iptc": 20, "C-xmp": 20, "D-unicode": 10, "E-large": 10, "F-bare": 10}


def make_specs(counts: dict[str, int]) -> list[Spec]:
    base = {
        "title": "Gather Validation",
        "caption": "Fixture for writeback and interop checks.",
        "keywords": ["harbor", "night", "客户A"],
        "copyright": "Copyright 2026 Gather",
        "byline": "Gather QA",
        "credit": "Gather",
        "source": "fixture",
        "headline": "Harbor at night",
        "city": "Shanghai",
        "country": "China",
        "hierarchical": ["Places|Shanghai", "Clients|A"],
    }
    specs: list[Spec] = []
    for category, count in counts.items():
        xmp, iptc, chunks = CATEGORIES[category]
        for index in range(count):
            fields = dict(base)
            fields["title"] = f"Gather Validation {index + 1}"
            note = ""
            if category == "D-unicode":
                fields.update(
                    title="日本語タイトル",
                    caption="中文说明：海港夜景，客户 A。",
                    keywords=["夜景", "港湾", "クライアント"],
                    city="上海",
                    country="中国",
                )
            if category == "E-large":
                fields["caption"] = "Large IPTC: " + "y" * 4000
                note = "非标准大 IIM 拆分：ImageIO 只读其中一段、App 读首段；仅作负向样本，不作互操作基线"
            specs.append(
                Spec(
                    f"{category}-{index + 1:03d}.jpg",
                    category,
                    xmp,
                    iptc,
                    fields,
                    iptc_chunks=chunks,
                    note=note,
                )
            )
    return specs


def generate(out: Path, counts: dict[str, int]) -> int:
    out.mkdir(parents=True, exist_ok=True)
    icc = load_icc()
    if icc is None:
        print("warning: 未找到系统 ICC profile，A/B/C/D/E 不带 APP2", file=sys.stderr)
    manifest: dict[str, object] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "counts": counts,
        "icc": bool(icc),
        "files": [],
    }
    for spec in make_specs(counts):
        path = out / spec.name
        make_base(path, icc, with_exif=spec.category not in ("F-bare",))
        inject(path, spec)
        data = path.read_bytes()
        entry = {
            "name": spec.name,
            "category": spec.category,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "scan_sha256": scan_sha256(data),
            "xmp": spec.xmp,
            "iptc_chunks": spec.iptc_chunks if spec.iptc else 0,
            "expected": spec.fields,
            "note": spec.note,
        }
        manifest["files"].append(entry)
        print(f"{spec.name}\t{len(data)}\t{entry['sha256'][:12]}")
    (out / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (out / "SHA256SUMS").write_text(
        "".join(f"{e['sha256']}  {e['name']}\n" for e in manifest["files"]),
        encoding="utf-8",
    )
    print(f"wrote {len(manifest['files'])} files to {out}")
    return 0


def verify(directory: Path) -> int:
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    failures: list[str] = []
    for entry in manifest["files"]:
        before = len(failures)
        path = directory / entry["name"]
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            failures.append(f"{entry['name']}: sha256 mismatch")
        if scan_sha256(data) != entry["scan_sha256"]:
            failures.append(f"{entry['name']}: scan sha256 mismatch")
        segments, _ = split_jpeg(data)
        xmp_segments = [p for _, p in segments if is_xmp(p)]
        ps_segments = [p for _, p in segments if is_photoshop(p)]
        icc_segments = [p for m, p in segments if m == 0xE2 and p.startswith(b"ICC_PROFILE\x00")]
        expected_xmp = 1 if entry["xmp"] else 0
        expected_ps = entry["iptc_chunks"]
        if len(xmp_segments) != expected_xmp:
            failures.append(f"{entry['name']}: xmp segments {len(xmp_segments)} != {expected_xmp}")
        if len(ps_segments) != expected_ps:
            failures.append(f"{entry['name']}: app13 segments {len(ps_segments)} != {expected_ps}")
        if manifest.get("icc") and entry["category"] != "F-bare" and not icc_segments:
            failures.append(f"{entry['name']}: missing ICC APP2")
        with Image.open(path) as image:
            image.load()
            exif = image.getexif()
            if entry["category"] != "F-bare" and exif.get(0x0110) != "FixtureCam":
                failures.append(f"{entry['name']}: EXIF Model missing")
            if manifest.get("icc") and entry["category"] != "F-bare" and not image.info.get("icc_profile"):
                failures.append(f"{entry['name']}: Pillow ICC missing")
            if entry["xmp"]:
                packet = xmp_segments[0][len(XMP_ID) :]
                try:
                    root = ET.fromstring(packet)
                except ET.ParseError as exc:
                    failures.append(f"{entry['name']}: XMP XML invalid: {exc}")
                else:
                    text = "".join(root.itertext())
                    title = str(entry["expected"]["title"])
                    if title not in text:
                        failures.append(f"{entry['name']}: XMP title not found")
                    for keyword in entry["expected"]["keywords"]:
                        if str(keyword) not in text:
                            failures.append(f"{entry['name']}: XMP keyword missing: {keyword}")
        print(
            f"{entry['name']:<20} xmp={len(xmp_segments)} app13={len(ps_segments)} "
            f"icc={len(icc_segments)} ok={len(failures) == before}"
        )
    if failures:
        print("\nFAIL:", file=sys.stderr)
        for item in failures:
            print(" -", item, file=sys.stderr)
        return 1
    print(f"\nPASS: {len(manifest['files'])} fixtures verified")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--out", type=Path, required=True)
    gen.add_argument("--per-category", type=int, default=2)
    gen.add_argument("--matrix", action="store_true", help="100 张：A30 B20 C20 D10 E10 F10")
    ver = sub.add_parser("verify")
    ver.add_argument("--dir", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "generate":
        counts = MATRIX if args.matrix else {name: args.per_category for name in CATEGORIES}
        return generate(args.out, counts)
    return verify(args.dir)


if __name__ == "__main__":
    raise SystemExit(main())
