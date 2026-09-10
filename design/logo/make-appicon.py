#!/usr/bin/env python3
"""Generate the PassSumo macOS AppIcon.appiconset -- the azure padlock+sumo mark (#18).

Decision history (full detail in design/logo/README.md):
  - `8ab8f02` (2026-08-30): the approved padlock+sumo mark, extracted from generated art.
  - `b88fd32` / `b6a0e40` (2026-09-09): replaced it with a "Keyhole P" monogram -- a redraw
    the owner never asked for. Rejected.
  - This script (#18): restores `8ab8f02`'s own mark-extraction pipeline (copied verbatim,
    not re-derived) and recolours it azure, per the owner's original instruction. The owner
    picked `azure-shaded` (of the 4 candidates in `make-icon-variants.py`) for the large
    tiers, and asked for a simplified drawing -- not the full mark -- at the sizes where the
    full mark stops reading.

What this script does:
  1. Extracts the padlock+sumo silhouette from the source art, exactly as `8ab8f02` did:
     `sample_source_colors` / `extract_mark_alpha` / `crop_to_content`, unchanged.
  2. Large tiers (>= LARGE_TIER_PX, currently 64) get the full mark: `azure` (#25C9ED)
     gradating to `accent-400`, on an `accent-800` -> `accent-900` gradient tile. This is
     the owner-approved `azure-shaded` candidate, unmodified.
  3. Small tiers get `8ab8f02`'s own procedural padlock-only glyph (no sumo -- it degrades
     into a blob below LARGE_TIER_PX, `8ab8f02`'s own finding, re-confirmed by this round's
     renders), flat `azure` on a flat `accent-900` tile:
       - 32px keeps the punched keyhole detail -- verified legible at that size.
       - 16px drops the keyhole punch entirely: at true 16x16 pixels the punch's circle+
         wedge collapses into a confusing blob rather than reading as a hole (verified by
         rendering both ways and comparing nearest-neighbour zooms -- see README.md). A
         solid body+shackle silhouette reads as "a padlock" at 16px; the punched version
         does not.
  4. Writes the full AppIcon.appiconset (10 PNGs + Contents.json), a full-resolution
     `appicon-1024.png`, and a labelled contact-sheet preview.

Usage:
    python3 design/logo/make-appicon.py

Requires: Pillow (no numpy).
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
SOURCE = HERE / "grok-image-b89c2f82-0acc-4776-b1ac-78ebd36e8f9d.jpg"
OUT_DIR = REPO_ROOT / "PassSumo/Resources/Assets.xcassets/AppIcon.appiconset"
HERO_1024 = HERE / "appicon-1024.png"
PREVIEW = HERE / "appicon-preview.png"

# --- Apple macOS app-icon geometry, unchanged since 8ab8f02 --------------------------
CANVAS = 1024
TILE = 824
CORNER_RADIUS_RATIO = 185.4 / 824  # ~0.225

# Every macOS "mac" idiom (point size, scale) pair Xcode's asset catalog expects.
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

# Pixel size below which the full padlock+sumo mark degrades into an unreadable blob --
# 8ab8f02's own cutover, re-confirmed this round by rendering azure-shaded at 96/72/64/
# 56/48/32px and looking: at 64px the padlock is crisp and the sumo figure still reads as
# a figure (soft, but a figure); at 48px the sumo starts fusing into the lock body; at 32
# it is mush. 64 is kept, not lowered -- the evidence doesn't support going smaller.
LARGE_TIER_PX = 64

# Pixel size below which even the simplified padlock's punched keyhole stops reading and
# is dropped, leaving a solid body+shackle silhouette. Verified by rendering the punched
# glyph at 16px and looking at the true, unsmoothed pixels (nearest-neighbour zoom): the
# circle+wedge punch collapses into a mask-like blob rather than a hole. At 32px the same
# punch is still legible, so only 16px drops it.
KEYHOLE_LEGIBLE_ABOVE_PX = 16

# Palette C (design/BRAND.md) tokens, plus the one measured token `azure` (see
# design/logo/README.md "Recolour candidates" for its provenance).
ACCENT_400 = (0x3A, 0x96, 0xAB)
ACCENT_800 = (0x0B, 0x3E, 0x4C)
ACCENT_900 = (0x07, 0x2C, 0x36)
AZURE = (0x25, 0xC9, 0xED)


# --- Mark extraction, copied verbatim from 8ab8f02 ------------------------------------


def sample_source_colors(im: Image.Image) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    """Return (background_color, mark_color) sampled from the flat source art."""
    quant = im.convert("RGB").quantize(colors=6, method=Image.MEDIANCUT)
    colors = quant.convert("RGB").getcolors(maxcolors=1_000_000)
    if not colors:
        raise RuntimeError("could not quantize source colors")
    colors.sort(key=lambda c: -c[0])
    bg = colors[0][1]

    def luma(rgb: tuple[int, int, int]) -> float:
        r, g, b = rgb
        return 0.2126 * r + 0.7152 * g + 0.0722 * b

    bg_luma = luma(bg)
    candidates = [c for c in colors[1:] if bg_luma - luma(c[1]) > 40]
    if not candidates:
        raise RuntimeError("could not find a distinct mark color in source art")
    mark = candidates[0][1]
    return bg, mark


def extract_mark_alpha(im: Image.Image, bg: tuple[int, int, int], mark: tuple[int, int, int]) -> Image.Image:
    """Antialiased alpha mask of `mark`-colored pixels, by projecting each pixel onto the
    bg->mark color axis."""
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
    return alpha.filter(ImageFilter.GaussianBlur(radius=1.2))


def crop_to_content(alpha: Image.Image, threshold: int = 12) -> Image.Image:
    bbox = alpha.point(lambda a: 255 if a >= threshold else 0).getbbox()
    if bbox is None:
        raise RuntimeError("extracted alpha mask is empty -- check source colors")
    return alpha.crop(bbox)


# --- Padlock-only small-size glyph, copied verbatim from 8ab8f02 ----------------------


def draw_padlock_glyph(size: int, color: tuple[int, int, int]) -> Image.Image:
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
    cap_r = shackle_stroke / 2
    for cx in (bbox[0] + shackle_stroke / 2, bbox[2] - shackle_stroke / 2):
        draw.ellipse(
            [cx - cap_r, shackle_top + shackle_outer - cap_r, cx + cap_r, shackle_top + shackle_outer + cap_r],
            fill=(*color, 255),
        )
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


# --- Colour treatments (azure-shaded, the owner-approved candidate) -------------------


def diagonal_gradient(size: tuple[int, int], color_a: tuple[int, int, int], color_b: tuple[int, int, int]) -> Image.Image:
    """A top-left -> bottom-right linear gradient, color_a to color_b, at `size`."""
    base = 256
    g = Image.linear_gradient("L")  # 0 (top) -> 255 (bottom), base x base
    g = g.rotate(-45, resample=Image.BICUBIC, expand=True)
    gw, gh = g.size
    left = (gw - base) // 2
    top = (gh - base) // 2
    g = g.crop((left, top, left + base, top + base)).resize(size, Image.BICUBIC)
    img_a = Image.new("RGB", size, color_a)
    img_b = Image.new("RGB", size, color_b)
    return Image.composite(img_b, img_a, g)


def recolor_flat(alpha: Image.Image, color: tuple[int, int, int]) -> Image.Image:
    rgba = Image.new("RGBA", alpha.size, (*color, 0))
    rgba.putalpha(alpha)
    return rgba


def recolor_gradient(alpha: Image.Image, color_a: tuple[int, int, int], color_b: tuple[int, int, int]) -> Image.Image:
    grad = diagonal_gradient(alpha.size, color_a, color_b).convert("RGBA")
    grad.putalpha(alpha)
    return grad


def rounded_tile(size: int, fill: Image.Image | tuple[int, int, int]) -> Image.Image:
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = Image.new("L", (size, size), 0)
    mdraw = ImageDraw.Draw(mask)
    radius = int(round(size * CORNER_RADIUS_RATIO))
    mdraw.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    field = Image.new("RGB", (size, size), fill) if isinstance(fill, tuple) else fill.convert("RGB")
    tile.paste(field, (0, 0))
    tile.putalpha(mask)
    return tile


def paste_centered(canvas: Image.Image, glyph: Image.Image, box_size: int, fill_ratio: float) -> None:
    target = int(round(box_size * fill_ratio))
    gw, gh = glyph.size
    scale = target / max(gw, gh)
    new_size = (max(1, int(round(gw * scale))), max(1, int(round(gh * scale))))
    resized = glyph.resize(new_size, Image.LANCZOS)
    ox = (canvas.width - new_size[0]) // 2
    oy = (canvas.height - new_size[1]) // 2
    canvas.alpha_composite(resized, (ox, oy))


def place_on_canvas(tile: Image.Image, canvas_size: int) -> Image.Image:
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    target = int(round(canvas_size * (TILE / CANVAS)))
    resized = tile.resize((target, target), Image.LANCZOS)
    offset = (canvas_size - target) // 2
    canvas.alpha_composite(resized, (offset, offset))
    return canvas


def render_large_tier(alpha_mark: Image.Image, px: int) -> Image.Image:
    mark = recolor_gradient(alpha_mark, AZURE, ACCENT_400)
    tile_field = diagonal_gradient((px, px), ACCENT_800, ACCENT_900)
    tile = rounded_tile(px, tile_field)
    paste_centered(tile, mark, px, fill_ratio=0.70)
    return place_on_canvas(tile, px)


def render_small_tier(px: int) -> Image.Image:
    tile = rounded_tile(px, ACCENT_900)
    glyph = draw_padlock_glyph(px, AZURE)
    if px > KEYHOLE_LEGIBLE_ABOVE_PX:
        glyph = punch_keyhole(glyph, ACCENT_900)
    tile.alpha_composite(glyph, (0, 0))
    return place_on_canvas(tile, px)


def render(alpha_mark: Image.Image, px: int) -> Image.Image:
    if px >= LARGE_TIER_PX:
        return render_large_tier(alpha_mark, px)
    return render_small_tier(px)


def main() -> None:
    im = Image.open(SOURCE)
    bg, mark = sample_source_colors(im)
    print(f"sampled source colors: background={bg} mark={mark}")
    alpha_mark = crop_to_content(extract_mark_alpha(im, bg, mark))
    print(f"extracted mark silhouette, cropped bbox size={alpha_mark.size}")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    contents = {"images": [], "info": {"author": "xcode", "version": 1}}
    renders: dict[int, Image.Image] = {}

    for point_size, scale, filename in ICON_SPECS:
        px = point_size * scale
        if px not in renders:
            renders[px] = render(alpha_mark, px)
            tier = "large (full mark)" if px >= LARGE_TIER_PX else (
                "small (padlock, keyhole)" if px > KEYHOLE_LEGIBLE_ABOVE_PX else "small (padlock, no keyhole)"
            )
            print(f"rendered {px}px -- {tier}")
        renders[px].save(OUT_DIR / filename)
        contents["images"].append(
            {"idiom": "mac", "scale": f"{scale}x", "size": f"{point_size}x{point_size}", "filename": filename}
        )

    (OUT_DIR / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"wrote {len(ICON_SPECS)} PNGs + Contents.json to {OUT_DIR}")

    hero = render_large_tier(alpha_mark, CANVAS)
    hero.save(HERO_1024)
    print(f"wrote hero render to {HERO_1024}")

    build_preview(renders, hero, PREVIEW)
    print(f"wrote preview contact sheet to {PREVIEW}")


def zoomed(img: Image.Image, display_size: int) -> Image.Image:
    return img.resize((display_size, display_size), Image.NEAREST)


def checkerboard(size: int, step: int = 8) -> Image.Image:
    board = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    draw = ImageDraw.Draw(board)
    for cy in range(0, size, step):
        for cx in range(0, size, step):
            if (cx // step + cy // step) % 2 == 0:
                draw.rectangle([cx, cy, cx + step, cy + step], fill=(210, 210, 210, 255))
    return board


def build_preview(renders: dict[int, Image.Image], hero: Image.Image, out_path: Path) -> None:
    """Two rows: true pixel size (on a checkerboard, so fidelity is honest), and a
    nearest-neighbour zoom of the small sizes so the actual pixels can be judged without
    a viewer's own smoothing making a bad render look plausible."""
    sizes = [1024] + sorted(s for s in renders if s != 1024)
    display = 200
    pad = 20
    label_h = 20
    cols = len(sizes)
    sheet_w = pad + cols * (display + pad)
    sheet_h = pad * 3 + (display + label_h) * 2

    sheet = Image.new("RGBA", (sheet_w, sheet_h), (235, 235, 235, 255))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 13)
    except OSError:
        font = ImageFont.load_default()

    all_renders = dict(renders)
    all_renders[1024] = hero

    for i, size in enumerate(sizes):
        x = pad + i * (display + pad)
        img = all_renders[size]

        y0 = pad
        native = img.resize((display, display), Image.LANCZOS) if img.width != display else img
        checker = checkerboard(display)
        checker.alpha_composite(native, (0, 0))
        sheet.alpha_composite(checker, (x, y0))
        draw.text((x, y0 + display + 2), f"{size}px true size", fill=(40, 40, 40, 255), font=font)

        y1 = pad * 2 + display + label_h
        z = zoomed(img, display)
        checker2 = checkerboard(display)
        checker2.alpha_composite(z, (0, 0))
        sheet.alpha_composite(checker2, (x, y1))
        draw.text((x, y1 + display + 2), f"{size}px nearest-neighbour zoom", fill=(40, 40, 40, 255), font=font)

    sheet.convert("RGB").save(out_path)


if __name__ == "__main__":
    main()
