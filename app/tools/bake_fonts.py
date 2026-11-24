#!/usr/bin/env python3
"""Pre-rasterize TrueType fonts into the app's .tfnt glyph packs (from Tome).

Kindle firmware does not reliably ship a FreeType we can link against from a
static binary, so Tome renders text from anti-aliased bitmaps baked here.

File format (whole file zlib-compressed):
  "TFNT" | u16 px_size | i16 ascent | i16 descent | u16 line_height | u32 nglyphs
  nglyphs x { u32 codepoint | i32 advance_26_6 | i16 left | i16 top | u16 w | u16 h | u32 offset }
  bitmap bytes (8-bit coverage, row-major)
"""
import os
import struct
import sys
import zlib

from PIL import Image, ImageDraw, ImageFont

CROSEXTRA = "/usr/share/fonts/truetype/crosextra"

# face-style -> font file (Debian/Ubuntu: fonts-crosextra-carlito, fonts-crosextra-caladea)
FACES = {
    # Carlito: the UI face
    "sans-regular": f"{CROSEXTRA}/Carlito-Regular.ttf",
    "sans-italic": f"{CROSEXTRA}/Carlito-Italic.ttf",
    "sans-bold": f"{CROSEXTRA}/Carlito-Bold.ttf",
    # Caladea: articles
    "serif-regular": f"{CROSEXTRA}/Caladea-Regular.ttf",
    "serif-italic": f"{CROSEXTRA}/Caladea-Italic.ttf",
    "serif-bold": f"{CROSEXTRA}/Caladea-Bold.ttf",
    "serif-bolditalic": f"{CROSEXTRA}/Caladea-BoldItalic.ttf",
}
SERIF_SIZES = [26, 30, 34, 40, 46, 54]
SANS_SIZES = [20, 22, 24, 26, 28, 30, 34, 40, 46, 54, 64]
BIG_SIZES = [96, 128]          # the clock and the temperature: digits and a few symbols only

RANGES = [(0x20, 0x7E), (0xA0, 0xFF), (0x100, 0x17F), (0x2010, 0x2027), (0x2030, 0x203A),
          (0x20AC, 0x20AC), (0x20B9, 0x20B9),                    # euro, rupee
          (0x2122, 0x2122), (0x2190, 0x2199),                    # arrows
          (0x25B2, 0x25C0), (0x25CB, 0x25CB), (0x25CF, 0x25CF),  # triangles, circles
          (0x2600, 0x2603), (0x2610, 0x2612), (0x2614, 0x2614),  # sun, cloud, umbrella, boxes
          (0x2630, 0x2630), (0x26A1, 0x26A1), (0x2713, 0x2713),  # menu, lightning, check
          (0x2744, 0x2744), (0x263D, 0x263E), (0x2248, 0x2248),  # snowflake, moon, haze
          (0xFFFD, 0xFFFD)]
BIG_RANGES = [(0x20, 0x3F), (0xB0, 0xB0), (0x2212, 0x2212)]   # digits, punctuation, degree, minus

FALLBACK = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def has_glyph(font, ch):
    """True if the font has a real glyph (not .notdef) for ch."""
    try:
        mask = font.getmask(ch)
    except Exception:
        return False
    notdef = font.getmask("\ue000")
    if mask.size == notdef.size and bytes(mask) == bytes(notdef):
        return ch.isspace()
    return mask.getbbox() is not None or ch.isspace() or ch in "\u00a0\u00ad"


def load_face(spec, size):
    if isinstance(spec, tuple):
        path, axes = spec
        font = ImageFont.truetype(path, size)
        values = []
        for axis in font.get_variation_axes():
            name = axis["name"].decode() if isinstance(axis["name"], bytes) else axis["name"]
            values.append(axes.get(name, axis["default"]))
        font.set_variation_by_axes(values)
        return font
    return ImageFont.truetype(spec, size)


def bake(spec, size, out_path, ranges=None):
    primary = load_face(spec, size)
    fallback = ImageFont.truetype(FALLBACK, size)
    ascent, descent = primary.getmetrics()
    glyphs = []
    blob = bytearray()
    for lo, hi in ranges or RANGES:
        for cp in range(lo, hi + 1):
            ch = chr(cp)
            # Code points the face lacks would render as .notdef boxes:
            # take them from DejaVu Sans, or skip them.
            if has_glyph(primary, ch):
                font = primary
            elif has_glyph(fallback, ch):
                font = fallback
            else:
                continue
            adv = font.getlength(ch)
            bbox = font.getbbox(ch, anchor="ls")
            l, t, r, b = bbox
            w, h = max(0, r - l), max(0, b - t)
            off = len(blob)
            if w > 0 and h > 0:
                img = Image.new("L", (w, h), 0)
                ImageDraw.Draw(img).text((-l, -t), ch, font=font, fill=255, anchor="ls")
                blob += img.tobytes()
            glyphs.append((cp, int(round(adv * 64)), l, -t, w, h, off))
    header = b"TFNT" + struct.pack("<HhhHI", size, ascent, descent, ascent + descent, len(glyphs))
    table = b"".join(struct.pack("<IihhHHI", *g) for g in glyphs)
    with open(out_path, "wb") as f:
        f.write(zlib.compress(header + table + bytes(blob), 9))
    return len(glyphs)


def main(out_dir, only=None):
    os.makedirs(out_dir, exist_ok=True)
    for face, file in FACES.items():
        if only and not face.startswith(only):
            continue
        jobs = [(size, None) for size in (SANS_SIZES if face.startswith("sans") else SERIF_SIZES)]
        if face == "sans-bold":
            jobs += [(size, BIG_RANGES) for size in BIG_SIZES]
        for size, ranges in jobs:
            out = os.path.join(out_dir, f"{face}-{size}.tfnt")
            n = bake(file, size, out, ranges)
            print(f"{out}: {n} glyphs, {os.path.getsize(out)} bytes")


if __name__ == "__main__":
    # optional second argument: bake only faces starting with this name
    main(sys.argv[1] if len(sys.argv) > 1 else "fonts", sys.argv[2] if len(sys.argv) > 2 else None)
