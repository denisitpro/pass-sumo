#!/usr/bin/env python3
"""Render azure-recolour candidates of the original padlock+sumo mark (#18).

Context: `8ab8f02` (2026-08-30) is the flat padlock+sumo mark the owner approved. Two
later commits, `b88fd32` and `b6a0e40` (2026-09-09), replaced that art outright with a
"Keyhole P" monogram — a redraw the owner never asked for. What he actually asked for
was a recolour to azure. This script recovers `8ab8f02`'s own mark-extraction pipeline
(`sample_source_colors` / `extract_mark_alpha` / `crop_to_content`, copied verbatim from
that commit, not re-derived) and reuses it unchanged: the silhouette this script
produces is pixel-for-pixel the same shape `8ab8f02` shipped. Only colour changes.

It renders a small matrix of candidates — two colour directions x two silhouette
treatments — at the four sizes where an icon actually lives or dies (1024, 128, 32, 16),
plus one side-by-side comparison sheet. It does NOT touch
`PassSumo/Resources/Assets.xcassets/AppIcon.appiconset` — regenerating the shipped icon
is a separate, deliberate step for after a variant is picked (see design/logo/README.md).

Colour directions:
  - azure  -- `azure` #25C9ED, the token already measured in this repo (from the
    sibling app finsumo's icon) and named by the owner. Same hue as palette C's ramp
    (0.530) but well outside the ramp itself in value/saturation -- a deliberate
    departure, not a ramp step.
  - steel  -- `accent-400` #3A96AB, the brightest ramp step that is still meaningfully
    saturated. Same hue family, but strictly inside design/BRAND.md's published ramp,
    for comparison against the azure departure.

Silhouette treatments (of the SAME mark, full-art tiers only -- see below):
  - flat   -- a single flat recolour, the same treatment `8ab8f02` itself used
    (`recolor()`, unchanged).
  - shaded -- a diagonal two-stop gradient across the mark's own bounding box, plus a
    matching tile gradient. No shape change; colour distribution only.

Below the 8ab8f02 cutover (64px) the full mark degrades into a blob -- 8ab8f02's own
finding, not new -- so 32px and 16px reuse its procedurally-drawn padlock-only glyph
(`draw_padlock_glyph` / `punch_keyhole`, copied verbatim, geometry untouched), flat-
recoloured per colour direction. This is why "shaded" and "flat" converge below 64px:
shading is a full-art-tier enhancement only, exactly as in 8ab8f02's own scheme.

Usage:
    python3 design/logo/make-icon-variants.py

Requires: Pillow (no numpy).
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "grok-image-b89c2f82-0acc-4776-b1ac-78ebd36e8f9d.jpg"
VARIANTS_DIR = HERE / "variants"
COMPARISON_SHEET = HERE / "appicon-variants-comparison.png"

# --- Apple macOS app-icon geometry, copied from 8ab8f02's make-appicon.py -----------
# Unchanged: this is the same rounded-rectangle tile geometry the approved icon used.
CANVAS = 1024
TILE = 824
CORNER_RADIUS_RATIO = 185.4 / 824  # ~0.225

# Sizes to render and compare -- exactly the sizes named in issue #18: the two where
# everything looks fine, and the two where icons actually fail.
SIZES = [1024, 128, 32, 16]

# Below this pixel size the full padlock+sumo mark degrades into an unreadable blob
# (8ab8f02's own finding) and the simplified padlock-only glyph is used instead.
SIMPLIFIED_BELOW_PX = 64

# design/BRAND.md palette C ("Steel Cyan") tokens this script draws from. Values copied
# from that file -- do not hand-tune a hex here; if a needed value is missing, add it to
# BRAND.md first.
ACCENT_400 = (0x3A, 0x96, 0xAB)
ACCENT_700 = (0x0F, 0x51, 0x63)
ACCENT_800 = (0x0B, 0x3E, 0x4C)
ACCENT_900 = (0x07, 0x2C, 0x36)
# Measured token (design/logo/README.md "Colour"), not a ramp step -- see module
# docstring.
AZURE = (0x25, 0xC9, 0xED)


# --- Mark extraction, copied verbatim from 8ab8f02's make-appicon.py ----------------
# Do not "improve" this -- these three functions are what makes the silhouette below
# 8ab8f02's own shape rather than a redraw from description.


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
    """Antialiased alpha mask of `mark`-colored pixels, by projecting each pixel onto
    the bg->mark color axis."""
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


# --- Padlock-only small-size glyph, copied verbatim from 8ab8f02 --------------------
# Same geometry as 8ab8f02 shipped; only the fill colours passed in change.


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


# --- New for this round: colour treatments -------------------------------------------


def diagonal_gradient(size: tuple[int, int], color_a: tuple[int, int, int], color_b: tuple[int, int, int]) -> Image.Image:
    """A top-left -> bottom-right linear gradient, color_a to color_b, at `size`."""
    base = 256
    g = Image.linear_gradient("L")  # 0 (top) -> 255 (bottom), base x base
    g = g.rotate(-45, resample=Image.BICUBIC, expand=True)
    gw, gh = g.size
    # Center-crop back to a `base`-sized square so the diagonal band is centered.
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
    if isinstance(fill, tuple):
        field = Image.new("RGB", (size, size), fill)
    else:
        field = fill.convert("RGB")
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


# --- Variant matrix --------------------------------------------------------------


class Variant:
    def __init__(self, id_: str, label: str, mark_flat: tuple[int, int, int], mark_grad: tuple[tuple, tuple] | None,
                 tile_flat: tuple[int, int, int], tile_grad: tuple[tuple, tuple] | None):
        self.id = id_
        self.label = label
        self.mark_flat = mark_flat
        self.mark_grad = mark_grad  # (light, dark) or None for flat-only variants
        self.tile_flat = tile_flat
        self.tile_grad = tile_grad  # (light, dark) or None


VARIANTS = [
    Variant(
        "azure-flat", "Azure / flat",
        mark_flat=AZURE, mark_grad=None,
        tile_flat=ACCENT_900, tile_grad=None,
    ),
    Variant(
        "azure-shaded", "Azure / shaded",
        mark_flat=AZURE, mark_grad=(AZURE, ACCENT_400),
        tile_flat=ACCENT_900, tile_grad=(ACCENT_800, ACCENT_900),
    ),
    Variant(
        "steel-flat", "Steel (accent-400) / flat",
        mark_flat=ACCENT_400, mark_grad=None,
        tile_flat=ACCENT_900, tile_grad=None,
    ),
    Variant(
        "steel-shaded", "Steel (accent-400) / shaded",
        mark_flat=ACCENT_400, mark_grad=(ACCENT_400, ACCENT_700),
        tile_flat=ACCENT_900, tile_grad=(ACCENT_800, ACCENT_900),
    ),
]


def render_full_art(variant: Variant, alpha_mark: Image.Image, px: int) -> Image.Image:
    if variant.mark_grad is not None:
        mark = recolor_gradient(alpha_mark, *variant.mark_grad)
    else:
        mark = recolor_flat(alpha_mark, variant.mark_flat)

    tile_field: Image.Image | tuple[int, int, int]
    if variant.tile_grad is not None:
        tile_field = diagonal_gradient((px, px), *variant.tile_grad)
    else:
        tile_field = variant.tile_flat

    tile = rounded_tile(px, tile_field)
    paste_centered(tile, mark, px, fill_ratio=0.70)
    return place_on_canvas(tile, px)


def render_simplified(variant: Variant, px: int) -> Image.Image:
    tile = rounded_tile(px, variant.tile_flat)
    glyph = draw_padlock_glyph(px, variant.mark_flat)
    glyph = punch_keyhole(glyph, variant.tile_flat)
    tile.alpha_composite(glyph, (0, 0))
    return place_on_canvas(tile, px)


def render_variant(variant: Variant, alpha_mark: Image.Image, px: int) -> Image.Image:
    if px < SIMPLIFIED_BELOW_PX:
        return render_simplified(variant, px)
    return render_full_art(variant, alpha_mark, px)


def zoomed(img: Image.Image, display_size: int) -> Image.Image:
    """Nearest-neighbour upscale so small-size pixels can actually be judged."""
    return img.resize((display_size, display_size), Image.NEAREST)


def checkerboard(size: int, step: int = 8) -> Image.Image:
    board = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    draw = ImageDraw.Draw(board)
    for cy in range(0, size, step):
        for cx in range(0, size, step):
            if (cx // step + cy // step) % 2 == 0:
                draw.rectangle([cx, cy, cx + step, cy + step], fill=(210, 210, 210, 255))
    return board


def build_comparison_sheet(renders: dict[str, dict[int, Image.Image]], out_path: Path) -> None:
    """Rows = variants, columns = sizes. Each cell shows the render at native pixel
    size on a checkerboard (so exact fidelity is visible) PLUS, for the two sizes that
    are the actual point of this round (32/16), a nearest-neighbour zoom so a human
    doesn't have to squint at 16 real pixels to judge it."""
    display_size = 200
    zoom_sizes = {32, 16}
    label_h = 22
    pad = 20
    row_label_w = 190

    cols = len(SIZES)
    rows = len(renders)
    cell_w = display_size
    cell_h = display_size + label_h

    sheet_w = row_label_w + cols * (cell_w + pad) + pad
    sheet_h = pad + rows * (cell_h + pad) + label_h

    sheet = Image.new("RGBA", (sheet_w, sheet_h), (235, 235, 235, 255))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 15)
        font_small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 12)
        font_head = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 17)
    except OSError:
        font = font_small = font_head = ImageFont.load_default()

    # Column headers (sizes).
    for c, size in enumerate(SIZES):
        x = row_label_w + c * (cell_w + pad) + pad
        header = f"{size}px" + ("  (zoomed for legibility)" if size in zoom_sizes else "  (true size)")
        draw.text((x, pad // 2), header, fill=(30, 30, 30, 255), font=font_head)

    for r, (variant_id, by_size) in enumerate(renders.items()):
        y = label_h + pad + r * (cell_h + pad)
        draw.text((10, y + cell_h // 2 - 10), variant_id, fill=(20, 20, 20, 255), font=font)
        for c, size in enumerate(SIZES):
            x = row_label_w + c * (cell_w + pad) + pad
            img = by_size[size]
            shown = zoomed(img, display_size) if size in zoom_sizes else img
            if shown.width != display_size:
                # 128px and 1024px: scale down to the shared display cell.
                shown = img.resize((display_size, display_size), Image.LANCZOS)
            checker = checkerboard(display_size)
            checker.alpha_composite(shown, (0, 0))
            sheet.alpha_composite(checker, (x, y))
            label = f"{size}px native" if size not in zoom_sizes else f"{size}px, shown at {display_size}px"
            draw.text((x, y + display_size + 2), label, fill=(60, 60, 60, 255), font=font_small)

    sheet.convert("RGB").save(out_path)


def main() -> None:
    im = Image.open(SOURCE)
    bg, mark = sample_source_colors(im)
    print(f"sampled source colors: background={bg} mark={mark}")
    alpha_mark = crop_to_content(extract_mark_alpha(im, bg, mark))
    print(f"extracted mark silhouette, cropped bbox size={alpha_mark.size}")

    VARIANTS_DIR.mkdir(parents=True, exist_ok=True)
    all_renders: dict[str, dict[int, Image.Image]] = {}

    for variant in VARIANTS:
        by_size: dict[int, Image.Image] = {}
        for px in SIZES:
            img = render_variant(variant, alpha_mark, px)
            by_size[px] = img
            out = VARIANTS_DIR / f"{variant.id}-{px}.png"
            img.save(out)
        all_renders[variant.id] = by_size
        print(f"rendered {variant.id}: {', '.join(str(s) for s in SIZES)}px -> {VARIANTS_DIR}")

    build_comparison_sheet(all_renders, COMPARISON_SHEET)
    print(f"wrote comparison sheet to {COMPARISON_SHEET}")


if __name__ == "__main__":
    main()
