#!/usr/bin/env python3
"""Generate the PassSumo macOS AppIcon.appiconset from the flat logo mark.

Source art: a flat, two-color JPEG (dark navy padlock + sumo silhouette on a
pale blue-grey background) — see design/logo/README.md for which of the two
generated concepts this is and why.

What this script does:
  1. Samples the source's two flat colors (background, mark) via color
     quantization — no hardcoded pixel coordinates, so it keeps working if
     the source art is redrawn/replaced.
  2. Extracts an antialiased alpha mask of the mark by projecting every
     pixel's color onto the background->mark color axis (this cleanly drops
     the keyhole/background, which sit on the *light* side of that axis).
  3. Composes a macOS icon tile: a solid rounded-square field (deepened from
     the mark's own navy, for Dock contrast) with the mark recolored to a
     warm off-white on top, per Apple's HIG rounded-rectangle-icon geometry
     (see README.md for the exact numbers + source URL).
  4. For the two smallest sizes (32px, 16px) the full padlock+sumo mark
     degrades into a blob, so a procedurally-drawn, padlock-only glyph is
     used instead — this is normal macOS icon practice (the asset catalog
     supports different art per size).
  5. Writes a full AppIcon.appiconset (10 PNGs + Contents.json) and a
     labelled contact-sheet preview PNG.

Usage:
    python3 design/logo/make-appicon.py \\
        [--source design/logo/grok-image-b89c2f82-0acc-4776-b1ac-78ebd36e8f9d.jpg] \\
        [--out PassSumo/Resources/Assets.xcassets/AppIcon.appiconset] \\
        [--preview design/logo/appicon-preview.png]

Requires: Pillow (no numpy).
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = Path(__file__).resolve().parent / "grok-image-b89c2f82-0acc-4776-b1ac-78ebd36e8f9d.jpg"
DEFAULT_OUT = REPO_ROOT / "PassSumo/Resources/Assets.xcassets/AppIcon.appiconset"
DEFAULT_PREVIEW = Path(__file__).resolve().parent / "appicon-preview.png"

# --- Apple macOS app-icon geometry -----------------------------------------
# Canvas 1024x1024pt with the icon tile as an ~824x824 rounded rectangle
# centered on it (~100px transparent margin each side), corner radius ~185.4
# ("Big Sur" squircle template, still the operative shape for a classic,
# non-Icon-Composer AppIcon.appiconset). See design/logo/README.md for the
# verified source URLs — do not change these numbers without re-checking
# that doc.
CANVAS = 1024
TILE = 824
CORNER_RADIUS_RATIO = 185.4 / 824  # ~0.225

# Every macOS "mac" idiom (point size, scale) pair Xcode's asset catalog
# expects, and the exported filename Contents.json will point at. Some
# point-size/scale pairs land on the same pixel size (e.g. 16pt@2x and
# 32pt@1x are both 32px) — each still gets its own file, matching what
# Xcode itself generates when you drop a 1024px image into the icon well.
ICON_SPECS = [
    # (point_size, scale, filename)
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

# Pixel size below which the photographic padlock+sumo mark degrades into an
# unreadable blob and the procedurally-drawn padlock-only glyph is used
# instead. Verified by rendering both and looking at them (see README.md).
SIMPLIFIED_BELOW_PX = 64

# Supersampling factor for the mark extraction / tile composition, so every
# exported size downsamples (never upsamples past native quality) from a
# large, smooth master.
SUPERSAMPLE = 2048


def sample_source_colors(im: Image.Image) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    """Return (background_color, mark_color) sampled from the flat source art."""
    quant = im.convert("RGB").quantize(colors=6, method=Image.MEDIANCUT)
    colors = quant.convert("RGB").getcolors(maxcolors=1_000_000)
    if not colors:
        raise RuntimeError("could not quantize source colors")
    colors.sort(key=lambda c: -c[0])
    # Background = the single most common color (the page fill).
    bg = colors[0][1]

    def luma(rgb: tuple[int, int, int]) -> float:
        r, g, b = rgb
        return 0.2126 * r + 0.7152 * g + 0.0722 * b

    # Mark = the most common color that reads meaningfully darker than bg
    # (this is what makes it robust to JPEG chroma noise splitting the
    # near-uniform background into several near-identical clusters).
    bg_luma = luma(bg)
    candidates = [c for c in colors[1:] if bg_luma - luma(c[1]) > 40]
    if not candidates:
        raise RuntimeError("could not find a distinct mark color in source art")
    mark = candidates[0][1]
    return bg, mark


def extract_mark_alpha(im: Image.Image, bg: tuple[int, int, int], mark: tuple[int, int, int]) -> Image.Image:
    """Antialiased alpha mask of `mark`-colored pixels, by projecting each
    pixel onto the bg->mark color axis. Pixels on the *light* side of bg
    (the keyhole cutout, stray highlights) project to <=0 and drop out along
    with the background itself.
    """
    vx, vy, vz = (mark[0] - bg[0], mark[1] - bg[1], mark[2] - bg[2])
    denom = float(vx * vx + vy * vy + vz * vz) or 1.0
    px = im.convert("RGB").load()
    w, h = im.size
    alpha = Image.new("L", (w, h), 0)
    apx = alpha.load()
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            t = ((r - bg[0]) * vx + (g - bg[1]) * vy + (b - bg[2]) * vz) / denom
            if t <= 0:
                continue
            apx[x, y] = 255 if t >= 1 else int(round(t * 255))
    # Soften JPEG-edge jaggies slightly.
    return alpha.filter(ImageFilter.GaussianBlur(radius=1.2))


def crop_to_content(alpha: Image.Image, threshold: int = 12) -> tuple[Image.Image, tuple[int, int, int, int]]:
    bbox = alpha.point(lambda a: 255 if a >= threshold else 0).getbbox()
    if bbox is None:
        raise RuntimeError("extracted alpha mask is empty — check source colors")
    return alpha.crop(bbox), bbox


def recolor(alpha: Image.Image, color: tuple[int, int, int]) -> Image.Image:
    rgba = Image.new("RGBA", alpha.size, (*color, 0))
    rgba.putalpha(alpha)
    return rgba


def paste_centered(canvas: Image.Image, glyph: Image.Image, box_size: int, fill_ratio: float) -> None:
    """Scale `glyph` (RGBA, alpha already meaningful) to fit within
    `fill_ratio` of box_size (preserving aspect ratio) and paste it centered
    on `canvas` (in place)."""
    target = int(round(box_size * fill_ratio))
    gw, gh = glyph.size
    scale = target / max(gw, gh)
    new_size = (max(1, int(round(gw * scale))), max(1, int(round(gh * scale))))
    resized = glyph.resize(new_size, Image.LANCZOS)
    ox = (canvas.width - new_size[0]) // 2
    oy = (canvas.height - new_size[1]) // 2
    canvas.alpha_composite(resized, (ox, oy))


def rounded_tile(size: int, radius_ratio: float, fill: tuple[int, int, int]) -> Image.Image:
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tile)
    radius = int(round(size * radius_ratio))
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=(*fill, 255))
    return tile


def draw_padlock_glyph(size: int, color: tuple[int, int, int]) -> Image.Image:
    """Procedural, padlock-only glyph (no sumo) for the sizes where the full
    photographic mark stops reading. Proportions approximate the extracted
    mark's own padlock (body ~= a rounded square, shackle a thick arc, a
    round-plus-wedge keyhole), redrawn as flat shapes so it stays crisp all
    the way down to 16px.
    """
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(im)

    body_w = size * 0.62
    body_h = size * 0.50
    body_left = size * 0.19
    body_top = size * 0.42
    body_radius = body_w * 0.16
    draw.rounded_rectangle(
        [body_left, body_top, body_left + body_w, body_top + body_h],
        radius=body_radius,
        fill=(*color, 255),
    )

    shackle_outer = size * 0.34
    shackle_stroke = size * 0.12
    shackle_cx = body_left + body_w * 0.46
    shackle_top = size * 0.16
    bbox = [
        shackle_cx - shackle_outer,
        shackle_top,
        shackle_cx + shackle_outer,
        shackle_top + shackle_outer * 2,
    ]
    draw.arc(bbox, start=180, end=360, fill=(*color, 255), width=int(round(shackle_stroke)))
    # ImageDraw.arc has square line caps at the arc ends; square them off
    # cleanly against the lock body by drawing small rounded caps.
    cap_r = shackle_stroke / 2
    for cx in (bbox[0] + shackle_stroke / 2, bbox[2] - shackle_stroke / 2):
        draw.ellipse(
            [cx - cap_r, shackle_top + shackle_outer - cap_r, cx + cap_r, shackle_top + shackle_outer + cap_r],
            fill=(*color, 255),
        )

    # Keyhole: circle + trapezoid wedge, cut out of the body (drawn in the
    # tile's background color by the caller, since this glyph itself is
    # returned pre-composited over transparency — see draw_padlock_glyph
    # usage below where it is punched out post-hoc).
    return im


def punch_keyhole(glyph: Image.Image, hole_color: tuple[int, int, int]) -> Image.Image:
    size = glyph.width
    draw = ImageDraw.Draw(glyph)
    cx, cy = size * 0.50, size * 0.575
    r = size * 0.075
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(*hole_color, 255))
    wedge_top_w = r * 0.9
    wedge_bottom_w = r * 1.7
    wedge_top_y = cy + r * 0.35
    wedge_bottom_y = size * 0.80
    draw.polygon(
        [
            (cx - wedge_top_w, wedge_top_y),
            (cx + wedge_top_w, wedge_top_y),
            (cx + wedge_bottom_w, wedge_bottom_y),
            (cx - wedge_bottom_w, wedge_bottom_y),
        ],
        fill=(*hole_color, 255),
    )
    return glyph


def build_full_mark_tile(mark_glyph: Image.Image, tile_size: int, bg: tuple[int, int, int]) -> Image.Image:
    tile = rounded_tile(tile_size, CORNER_RADIUS_RATIO, bg)
    paste_centered(tile, mark_glyph, tile_size, fill_ratio=0.70)
    return tile


def build_simplified_tile(size: int, bg: tuple[int, int, int], glyph_color: tuple[int, int, int]) -> Image.Image:
    tile = rounded_tile(size, CORNER_RADIUS_RATIO, bg)
    glyph = draw_padlock_glyph(size, glyph_color)
    glyph = punch_keyhole(glyph, bg)
    tile.alpha_composite(glyph, (0, 0))
    return tile


def place_on_canvas(tile: Image.Image, canvas_size: int, tile_ratio: float) -> Image.Image:
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    target = int(round(canvas_size * tile_ratio))
    resized = tile.resize((target, target), Image.LANCZOS)
    offset = (canvas_size - target) // 2
    canvas.alpha_composite(resized, (offset, offset))
    return canvas


def darken(color: tuple[int, int, int], factor: float) -> tuple[int, int, int]:
    return tuple(max(0, min(255, int(round(c * factor)))) for c in color)  # type: ignore[return-value]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--preview", type=Path, default=DEFAULT_PREVIEW)
    args = parser.parse_args()

    im = Image.open(args.source)
    bg_source, mark_source = sample_source_colors(im)
    print(f"sampled background={bg_source} mark={mark_source}")

    # Design decision (see design/logo/README.md): the icon background is a
    # *deepened* shade of the mark's own navy — not the source's pale
    # blue-grey page color — for legible, consistent contrast against both
    # light and dark Docks. The glyph is recolored to a warm off-white.
    bg_field = darken(mark_source, 0.62)
    glyph_color = (244, 241, 234)

    alpha_full, _ = crop_to_content(extract_mark_alpha(im, bg_source, mark_source))
    full_mark = recolor(alpha_full, glyph_color)

    full_master = build_full_mark_tile(full_mark, SUPERSAMPLE, bg_field)
    simplified_master = build_simplified_tile(SUPERSAMPLE, bg_field, glyph_color)

    args.out.mkdir(parents=True, exist_ok=True)
    contents = {"images": [], "info": {"author": "xcode", "version": 1}}
    renders: dict[int, Image.Image] = {}

    for point_size, scale, filename in ICON_SPECS:
        px = point_size * scale
        if px not in renders:
            master = simplified_master if px < SIMPLIFIED_BELOW_PX else full_master
            renders[px] = place_on_canvas(master, CANVAS, TILE / CANVAS).resize((px, px), Image.LANCZOS)
        renders[px].save(args.out / filename)
        contents["images"].append(
            {"idiom": "mac", "scale": f"{scale}x", "size": f"{point_size}x{point_size}", "filename": filename}
        )

    (args.out / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"wrote {len(ICON_SPECS)} PNGs + Contents.json to {args.out}")

    build_contact_sheet(renders, args.preview)
    print(f"wrote preview contact sheet to {args.preview}")


def build_contact_sheet(renders: dict[int, Image.Image], out_path: Path) -> None:
    sizes = sorted(renders)
    pad = 24
    label_h = 20
    cell = max(sizes) if sizes else 64
    cols = len(sizes)
    sheet_w = cols * (cell + pad) + pad
    sheet_h = cell + pad * 2 + label_h
    sheet = Image.new("RGBA", (sheet_w, sheet_h), (235, 235, 235, 255))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
    except OSError:
        font = ImageFont.load_default()
    for i, size in enumerate(sizes):
        img = renders[size]
        x = pad + i * (cell + pad)
        y = pad
        # Checkerboard behind each render so transparent margins are visible.
        checker = Image.new("RGBA", (cell, cell), (255, 255, 255, 255))
        cdraw = ImageDraw.Draw(checker)
        step = 8
        for cy in range(0, cell, step):
            for cx in range(0, cell, step):
                if (cx // step + cy // step) % 2 == 0:
                    cdraw.rectangle([cx, cy, cx + step, cy + step], fill=(210, 210, 210, 255))
        sheet.alpha_composite(checker, (x, y))
        centered = (x + (cell - size) // 2, y + (cell - size) // 2)
        sheet.alpha_composite(img, centered)
        label = f"{size}px"
        tw = draw.textlength(label, font=font)
        draw.text((x + (cell - tw) / 2, y + cell + 2), label, fill=(40, 40, 40, 255), font=font)
    sheet.convert("RGB").save(out_path)


if __name__ == "__main__":
    main()
