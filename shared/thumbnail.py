# shared/thumbnail.py - Shared thumbnail generation for all submodules.
#
# Provides a single generate_thumbnail() function that opens an image,
# optionally crops to a face bbox (detection-scale coords are
# automatically scaled to original-image coords), resizes, and returns
# a base64-encoded JPEG string.

from __future__ import annotations

import base64
import io
import logging
import os

from PIL import Image, ImageOps

from .constants import MAX_LONG_EDGE, THUMBNAIL_JPEG_QUALITY, THUMBNAIL_SIZE

logger = logging.getLogger("gather.thumbnail")

FACE_CROP_PADDING_RATIO = 0.2


def generate_thumbnail(
    path: str,
    size: int = THUMBNAIL_SIZE,
    quality: int = THUMBNAIL_JPEG_QUALITY,
    bbox: list[float] | None = None,
) -> str | None:
    """Generate a JPEG thumbnail, optionally cropping to a face bbox region first.

    - When *bbox* is None the full image is thumbnailed preserving aspect ratio.
    - When *bbox* is [x, y, w, h] in detection-scale coordinates (image was
      scaled so that its long edge ≤ MAX_LONG_EDGE), the coords are mapped
      back to original-image space, a padded face crop is extracted, and the
      result is resized to *size* × *size* square.

    Returns a base64-encoded JPEG string, or None on any failure.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as fh, Image.open(fh) as img:
            img.load()
            if img.mode == "RGBA":
                background = Image.new("RGB", img.size, (255, 255, 255))
                background.paste(img, mask=img.split()[3])
                img = background  # type: ignore[assignment]
            elif img.mode not in ("RGB", "L"):
                img = img.convert("RGB")  # type: ignore[assignment]

            if bbox and len(bbox) == 4:
                orig_w, orig_h = img.size
                orig_long_edge = max(orig_w, orig_h)
                x, y, w, h = bbox

                if orig_long_edge > MAX_LONG_EDGE:
                    downscale_ratio = MAX_LONG_EDGE / orig_long_edge
                    x, y, w, h = x / downscale_ratio, y / downscale_ratio, w / downscale_ratio, h / downscale_ratio

                pad_x = int(w * FACE_CROP_PADDING_RATIO)
                pad_y = int(h * FACE_CROP_PADDING_RATIO)
                left = max(0, int(x) - pad_x)
                top = max(0, int(y) - pad_y)
                right = min(orig_w, int(x + w) + pad_x)
                bottom = min(orig_h, int(y + h) + pad_y)

                if right > left and bottom > top:
                    face_crop = img.crop((left, top, right, bottom))
                    face_crop = ImageOps.fit(face_crop, (size, size), method=Image.Resampling.LANCZOS)
                else:
                    img.thumbnail((size, size), Image.Resampling.LANCZOS)
                    face_crop = img
            else:
                img.thumbnail((size, size), Image.Resampling.LANCZOS)
                face_crop = img

            with io.BytesIO() as buf:
                face_crop.save(buf, format="JPEG", quality=quality)
                return base64.b64encode(buf.getvalue()).decode()
    except Exception as exc:
        logger.debug("Failed to generate thumbnail for %s: %s", path, exc)
        return None
