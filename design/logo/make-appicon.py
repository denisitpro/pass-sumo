#!/usr/bin/env python3
"""Generate the PassSumo macOS AppIcon.appiconset — procedural mark, palette C.

The mark is drawn from geometry in this file, not extracted from source art, so
every edge stays crisp at every exported size and the whole icon is one command
away from being re-rendered in a different colour or proportion.

Three concepts are implemented; pick one with --concept:

  c1  "Keyhole P" — a bold monoline capital P whose counter *is* a keyhole:
      a bore concentric with the bowl, plus a slot tapering into the bowl's
      lower stroke and stopping short of its outer edge, so the bowl stays
      closed and the letter stays a letter. Shipped.

  c3  "Thin P" — the same idea in a thin constructed weight. A thin stroke
      cannot carry a keyhole as its counter (see `letter_p`), so the counter
      is a plain circle with a small keyhole nested inside it.

  c2  "Padlock" — no letter. A symmetric solid padlock with the keyhole
      punched through, under a constant-width shackle arc. Kept as the safe
      fallback; it is the system lock glyph in brand colours.

All sit on a deep navy tile (palette C accent-800 -> accent-900) with the mark
in an azure gradient and a light upper-left edge highlight. There is no drop
shadow: it greyed the tile and cost a whole art tier. See design/logo/README.md
for the colour tokens and their provenance, and for the verified Apple geometry
the CANVAS/TILE/CORNER_RADIUS numbers encode.

Small sizes get different, simpler art on purpose (normal macOS practice — the
asset catalog supports per-size art), and that art is deliberately larger and
heavier than the full-art mark, so shrinking the large mark for air costs
nothing at 16px.

Usage:
    python3 design/logo/make-appicon.py --concept c1
    python3 design/logo/make-appicon.py --concept c3 --out /tmp/c3-appiconset

    # preview only, no asset catalog written:
    python3 design/logo/make-appicon.py --concept c3 --skip-appicon

Requires: Pillow (no numpy).
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

REPO_ROOT = Path(__file__).resolve().parents[2]
LOGO_DIR = Path(__file__).resolve().parent
DEFAULT_OUT = REPO_ROOT / "PassSumo/Resources/Assets.xcassets/AppIcon.appiconset"

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

# Art tiers, by exported pixel size. Chosen by rendering all three and looking
# at them — see design/logo/README.md.
FULL_FROM_PX = 128      # >= this: gradient + shadow + edge highlight
MINIMAL_BELOW_PX = 32   # <  this: flat art with no keyhole

# The master tile is drawn at 3x the 824pt tile and downsampled, which is what
# antialiases the mitres and the arc (ImageDraw itself does not antialias).
SUPERSAMPLE = 824 * 3

# --- Colour ----------------------------------------------------------------
# Palette C ("Steel Cyan"), the app's approved accent ramp, plus one sampled
# token. Never invent a hex here; see design/logo/README.md.
A = {
    50: "#ECF6F9", 100: "#D2E9EF", 200: "#A4D4DF", 300: "#6CB7C8", 400: "#3A96AB",
    500: "#1B7A90", 600: "#14657A", 700: "#0F5163", 800: "#0B3E4C", 900: "#072C36",
}
# Sampled, not invented: the most frequent saturated-blue pixel value in the
# sibling app finsumo's AppIcon-1024.png (n=299). Its hue (0.530) is the same
# hue as palette C's accent ramp — it is that hue at full chroma, which is why
# it sits inside the brand rather than beside it. Provenance in README.md.
AZURE = "#25C9ED"

# Tile: a diagonal from a light top-left corner into the ramp's darkest step,
# which most of the tile sits at. Deep enough to read as material rather than
# as a slab, without inventing a hex darker than the ramp holds.
TILE_STOPS = [(0.0, A[800]), (0.62, A[900]), (1.0, A[900])]
TILE_AXIS = ((0.0, 0.0), (1.0, 1.0))

# Mark: the full ramp, accent-500 at the mark's bottom-left corner to the
# measured azure at its top-right. Spent across the mark's own bounding box
# (see render_master), so it is visible at 256px instead of nearly flat.
# accent-500 rather than the darker accent-700 the ramp offers: at accent-700
# the stem's foot sinks into the tile it sits on.
MARK_STOPS = [(0.0, A[500]), (1.0, AZURE)]
# The tile's outermost band, darkened rather than lit: a lighter rim (tried at
# accent-700) reads as a drawn outline around the icon, which dates it. Landing
# on the gradient's own dark end instead just deepens the edge.
TILE_EDGE = A[900]
EDGE_HIGHLIGHT = A[200]
FLAT_TILE = A[900]
FLAT_MARK = AZURE


def rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


# --- Gradients -------------------------------------------------------------


def _sample_stops(stops: list[tuple[float, str]], t: float) -> tuple[int, int, int]:
    if t <= stops[0][0]:
        return rgb(stops[0][1])
    if t >= stops[-1][0]:
        return rgb(stops[-1][1])
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t0 <= t <= t1:
            f = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
            a, b = rgb(c0), rgb(c1)
            return tuple(int(round(a[i] + (b[i] - a[i]) * f)) for i in range(3))  # type: ignore[return-value]
    return rgb(stops[-1][1])


def linear_gradient(
    size: int,
    stops: list[tuple[float, str]],
    p0: tuple[float, float],
    p1: tuple[float, float],
) -> Image.Image:
    """RGB image of `size`^2 holding a linear gradient. p0/p1 are in tile-
    normalised [0,1] coordinates (y down). Generated small and scaled up — a
    linear ramp survives bicubic resampling exactly."""
    small = 320
    im = Image.new("RGB", (small, small))
    px = im.load()
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    denom = dx * dx + dy * dy or 1.0
    for y in range(small):
        v = (y + 0.5) / small
        for x in range(small):
            u = (x + 0.5) / small
            t = ((u - p0[0]) * dx + (v - p0[1]) * dy) / denom
            px[x, y] = _sample_stops(stops, t)
    return im.resize((size, size), Image.BICUBIC)


# --- Ribbon strokes with mitred corners ------------------------------------


def _unit(v: tuple[float, float]) -> tuple[float, float]:
    length = math.hypot(v[0], v[1])
    return (v[0] / length, v[1] / length) if length else (0.0, 0.0)


def stroke_path(
    draw: ImageDraw.ImageDraw,
    pts: list[tuple[float, float]],
    half: float,
    closed: bool = False,
) -> None:
    """Fill a constant-width ribbon along `pts` with mitred joins.

    Drawn as a union of per-segment quads plus a mitre patch at every joint,
    rather than as one offset outline polygon: a single polygon would be
    self-intersecting wherever the path doubles back, and ImageDraw's scanline
    fill would punch holes in it.
    """
    if closed and pts[0] == pts[-1]:
        pts = pts[:-1]
    n = len(pts)
    if n < 2:
        return
    seg_count = n if closed else n - 1
    dirs = []
    for k in range(seg_count):
        a, b = pts[k], pts[(k + 1) % n]
        dirs.append(_unit((b[0] - a[0], b[1] - a[1])))

    for k in range(seg_count):
        a, b = pts[k], pts[(k + 1) % n]
        dx, dy = dirs[k]
        nx, ny = -dy, dx
        draw.polygon(
            [
                (a[0] + nx * half, a[1] + ny * half),
                (b[0] + nx * half, b[1] + ny * half),
                (b[0] - nx * half, b[1] - ny * half),
                (a[0] - nx * half, a[1] - ny * half),
            ],
            fill=255,
        )

    joints = range(n) if closed else range(1, n - 1)
    for j in joints:
        k_in = (j - 1) % seg_count
        k_out = j % seg_count
        d1, d2 = dirs[k_in], dirs[k_out]
        n1 = (-d1[1], d1[0])
        n2 = (-d2[1], d2[0])
        m = _unit((n1[0] + n2[0], n1[1] + n2[1]))
        dot = m[0] * n1[0] + m[1] * n1[1]
        if abs(dot) < 1e-6:
            continue
        length = min(half / dot, half * 4.0)  # mitre limit
        p = pts[j]
        # Both sides: the outer patch fills the wedge the butt quads leave
        # open; the inner one lands exactly on the quads' shared boundary, so
        # drawing it is a no-op rather than an overshoot.
        for s in (1.0, -1.0):
            draw.polygon(
                [
                    p,
                    (p[0] + s * n1[0] * half, p[1] + s * n1[1] * half),
                    (p[0] + s * m[0] * length, p[1] + s * m[1] * length),
                    (p[0] + s * n2[0] * half, p[1] + s * n2[1] * half),
                ],
                fill=255,
            )


def arc_points(
    cx: float, cy: float, r: float, a0_deg: float, a1_deg: float, steps: int = 96
) -> list[tuple[float, float]]:
    """Polyline along a circular arc, in y-down coordinates. 180deg -> 0deg
    traces the upper half from the left end, over the apex, to the right end."""
    out = []
    for i in range(steps + 1):
        a = math.radians(a0_deg + (a1_deg - a0_deg) * i / steps)
        out.append((cx + r * math.cos(a), cy - r * math.sin(a)))
    return out


# --- Concept geometry ------------------------------------------------------
# All coordinates are tile-normalised [0,1], y down. Primitives:
#   ("rect", x0, y0, x1, y1, corner_radius)
#   ("stroke", points, closed, width)
#   ("keyhole", cx, cy, r, slot_bottom)
# `add` is unioned into the mark mask, `punch` is subtracted from it.

CONCEPTS = {
    "c1": "Keyhole P",
    "c2": "Padlock",
    "c3": "Thin P",
}


# Keyhole slot half-widths, as a fraction of the bore radius: where it leaves
# the bore, and where it ends. Kept slim — a wide flare eats into whatever the
# keyhole is cut from and reads as damage rather than as a keyhole.
SLOT_TOP, SLOT_BOTTOM = 0.46, 0.68


def keyhole_shapes(cx: float, cy: float, r: float, slot_bottom: float) -> list:
    """A keyhole as a circular bore plus a slot that widens downward."""
    return [
        ("ellipse", cx - r, cy - r, cx + r, cy + r),
        (
            "polygon",
            [
                (cx - r * SLOT_TOP, cy),
                (cx + r * SLOT_TOP, cy),
                (cx + r * SLOT_BOTTOM, slot_bottom),
                (cx - r * SLOT_BOTTOM, slot_bottom),
            ],
        ),
    ]


def letter_p(
    cap_h: float,
    stroke: float,
    bowl_ratio: float,
    slot_inset: float | None = None,
    nested: tuple[float, float, float] | None = None,
) -> tuple[list, float]:
    """A monoline capital P, laid out with the stem's left edge at x=0 and the
    cap line at y=0. Returns (ops, width).

    One construction serves every weight. `stroke` is both the stem width and
    the bowl's stroke — equal by design, which is what makes the letterform
    read as deliberate rather than drawn. The bowl is a D: the disc plus the
    block bridging it to the stem. All terminals are flat and square; there is
    exactly one terminal treatment and no corner rounding anywhere.

    The counter is concentric with the bowl disc at `bowl_r - stroke`. That
    single choice keeps the bowl's weight even all the way round *and* puts the
    stem's right edge exactly tangent to the counter, which is where a P's stem
    belongs in type.

    Two ways to get the keyhole into it:

    `slot_inset` — the counter itself is punched as a keyhole: bore plus a slot
    tapering into the bowl's lower stroke, ending `slot_inset` above its outer
    edge so the bowl stays closed. This needs a heavy stroke to work at all:
    slot depth is only ever `stroke - slot_inset`, while the bore radius is
    `bowl_r - stroke`, so a readable keyhole requires stroke ~= half the bowl
    radius. A thin letterform structurally cannot carry a keyhole as its
    counter — hence the second mode.

    `nested` — (bore_r, slot_len, dy): the counter is a plain circle and a
    small solid keyhole is placed inside it, offset by `dy`. This is the thin
    weight's only option.
    """
    bowl_h = cap_h * bowl_ratio
    bowl_r = bowl_h / 2
    counter_r = bowl_r - stroke
    if counter_r <= 0:
        raise ValueError("stroke is too heavy for this bowl — counter would vanish")
    bowl_cx = stroke + counter_r
    bowl_cy = bowl_r
    width = bowl_cx + bowl_r

    ops: list[tuple[str, list]] = [
        (
            "add",
            [
                ("rect", 0.0, 0.0, stroke, cap_h, 0.0),
                ("ellipse", bowl_cx - bowl_r, 0.0, bowl_cx + bowl_r, bowl_h),
                ("rect", 0.0, 0.0, bowl_cx, bowl_h, 0.0),
            ],
        )
    ]
    if slot_inset is not None:
        ops.append(("punch", [("keyhole", bowl_cx, bowl_cy, counter_r, bowl_h - slot_inset)]))
    else:
        ops.append(
            (
                "punch",
                [("ellipse", bowl_cx - counter_r, bowl_cy - counter_r,
                  bowl_cx + counter_r, bowl_cy + counter_r)],
            )
        )
        if nested is not None:
            bore_r, slot_len, dy = nested
            cy = bowl_cy + dy
            ops.append(("add", [("keyhole", bowl_cx, cy, bore_r, cy + slot_len)]))
    return ops, width


# Per-tier letterform parameters. The small tiers are deliberately *larger and
# heavier* than the full-art tier — standard practice, and what lets the
# large-size mark shrink for air without costing 16px legibility.
P_PARAMS = {
    "c1": {
        "full": dict(cap_h=0.650, stroke=0.115, bowl_ratio=0.64, slot_inset=0.045),
        "simplified": dict(cap_h=0.680, stroke=0.122, bowl_ratio=0.66, slot_inset=0.040),
        "minimal": dict(cap_h=0.700, stroke=0.130, bowl_ratio=0.70),
    },
    # C3's identity — the thin constructed line — exists only at the full-art
    # sizes. Below that the stroke and the nested keyhole both fall under a
    # pixel, so its small tiers converge on C1's. That is a real cost of the
    # thin direction, not a shortcut.
    "c3": {
        "full": dict(cap_h=0.660, stroke=0.070, bowl_ratio=0.62,
                     nested=(0.048, 0.105, -0.030)),
        "simplified": dict(cap_h=0.680, stroke=0.100, bowl_ratio=0.64, slot_inset=0.035),
        "minimal": dict(cap_h=0.700, stroke=0.130, bowl_ratio=0.70),
    },
}


def geometry_p(concept: str, tier: str) -> list[tuple[str, list]]:
    ops, width = letter_p(**P_PARAMS[concept][tier])
    cap_h = P_PARAMS[concept][tier]["cap_h"]
    ops = translate_ops(ops, (1.0 - width) / 2, (1.0 - cap_h) / 2)
    dx, dy = optical_correction(ops)
    return translate_ops(ops, dx, dy)


def geometry_c2(tier: str) -> list[tuple[str, list]]:
    """A padlock, symmetric and solid: a rounded body with the keyhole punched
    clean through to the tile, under a constant-width shackle arc."""
    width = 0.145 if tier == "minimal" else 0.125
    arc_cx, arc_cy, arc_r = 0.500, 0.290, 0.170
    shackle = (
        [(arc_cx - arc_r, 0.500)]
        + arc_points(arc_cx, arc_cy, arc_r, 180, 0)
        + [(arc_cx + arc_r, 0.500)]
    )
    ops = [
        ("add", [("rect", 0.175, 0.470, 0.825, 0.870, 0.075),
                 ("stroke", shackle, False, width)]),
    ]
    if tier != "minimal":
        ops.append(("punch", [("keyhole", 0.500, 0.612, 0.072, 0.782)]))
    return ops


GEOMETRY = {
    "c1": lambda tier: geometry_p("c1", tier),
    "c2": geometry_c2,
    "c3": lambda tier: geometry_p("c3", tier),
}


# --- Placement -------------------------------------------------------------

# A P is left-heavy: the stem is full-height ink on the left, the bowl mass is
# upper-right, and the lower-right quadrant is empty. Centring its bounding box
# therefore puts its centre of *ink* left of the tile's centre and the mark
# looks shoved sideways, so it is nudged right by part of that offset (the full
# offset overshoots — the classic optical-centring overcorrection).
#
# Horizontally only. A P is also top-heavy, but the eye places a letter
# vertically by its cap and baseline, not by its mass: correcting vertically
# too pushed the mark visibly low in the tile (bottom margin measurably
# smaller than the top). Cap height and baseline stay box-centred.
OPTICAL_CORRECTION_X = 0.55


def translate_ops(ops: list[tuple[str, list]], dx: float, dy: float) -> list[tuple[str, list]]:
    def move(prim):
        kind = prim[0]
        if kind == "rect":
            return (kind, prim[1] + dx, prim[2] + dy, prim[3] + dx, prim[4] + dy, prim[5])
        if kind == "ellipse":
            return (kind, prim[1] + dx, prim[2] + dy, prim[3] + dx, prim[4] + dy)
        if kind == "keyhole":
            return (kind, prim[1] + dx, prim[2] + dy, prim[3], prim[4] + dy)
        if kind == "stroke":
            return (kind, [(x + dx, y + dy) for x, y in prim[1]], prim[2], prim[3])
        raise ValueError(f"unknown primitive {kind!r}")

    return [(mode, [move(p) for p in prims]) for mode, prims in ops]


def optical_correction(ops: list[tuple[str, list]], ss: int = 320) -> tuple[float, float]:
    """How far to move an already box-centred mark so its centre of ink lands
    nearer the tile centre. Measured from the rendered mask, not guessed."""
    mask = compose_mask(ops, ss)
    px = mask.load()
    weight = mx = 0
    for y in range(ss):
        for x in range(ss):
            a = px[x, y]
            if a:
                weight += a
                mx += a * x
    if not weight:
        raise RuntimeError("mark mask is empty — check the geometry parameters")
    cx = (mx / weight + 0.5) / ss
    return OPTICAL_CORRECTION_X * (0.5 - cx), 0.0


# --- Mask assembly ---------------------------------------------------------


def _draw_primitives(draw: ImageDraw.ImageDraw, prims: list, ss: int) -> None:
    for prim in prims:
        kind = prim[0]
        if kind == "rect":
            _, x0, y0, x1, y1, r = prim
            draw.rounded_rectangle(
                [x0 * ss, y0 * ss, x1 * ss, y1 * ss], radius=r * ss, fill=255
            )
        elif kind == "ellipse":
            draw.ellipse([c * ss for c in prim[1:]], fill=255)
        elif kind == "stroke":
            _, pts, closed, w = prim
            stroke_path(draw, [(x * ss, y * ss) for x, y in pts], w * ss / 2, closed)
        elif kind == "keyhole":
            _, cx, cy, r, sb = prim
            for shape in keyhole_shapes(cx, cy, r, sb):
                if shape[0] == "ellipse":
                    draw.ellipse([c * ss for c in shape[1:]], fill=255)
                else:
                    draw.polygon([(x * ss, y * ss) for x, y in shape[1]], fill=255)
        else:  # pragma: no cover - guards a typo in the geometry tables
            raise ValueError(f"unknown primitive {kind!r}")


def compose_mask(ops: list[tuple[str, list]], ss: int) -> Image.Image:
    """Apply add/punch layers in order. Order matters: C3 punches its counter
    and then adds a keyhole inside it, which a single add-then-punch pass would
    erase."""
    mask = Image.new("L", (ss, ss), 0)
    for mode, prims in ops:
        layer = Image.new("L", (ss, ss), 0)
        _draw_primitives(ImageDraw.Draw(layer), prims, ss)
        mask = ImageChops.lighter(mask, layer) if mode == "add" else ImageChops.subtract(mask, layer)
    return mask


def mark_mask(concept: str, tier: str, ss: int) -> Image.Image:
    return compose_mask(GEOMETRY[concept](tier), ss)


# --- Tile composition ------------------------------------------------------


def rounded_tile_alpha(size: int, ss: int = SUPERSAMPLE) -> Image.Image:
    """The tile's rounded-rectangle alpha, drawn supersampled and downsampled
    to `size` on its own.

    It is kept out of the master deliberately. Resizing an RGBA master makes
    LANCZOS ring the four channels independently, so just outside the corners
    the alpha lands on 1-3 while the colour channels undershoot to values the
    tile never contained (measured: #00007F at alpha 2). Downsampling the mask
    alone cannot do that — the colour it reveals is always real tile colour.
    """
    mask = Image.new("L", (ss, ss), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, ss - 1, ss - 1], radius=int(round(ss * CORNER_RADIUS_RATIO)), fill=255
    )
    return mask.resize((size, size), Image.LANCZOS)


def render_master(concept: str, tier: str, ss: int = SUPERSAMPLE) -> Image.Image:
    """One tile at supersampled resolution, opaque RGB — the rounded corners
    are applied by `render_size` after downsampling."""
    radius = int(round(ss * CORNER_RADIUS_RATIO))
    full = tier == "full"
    if full:
        layer = linear_gradient(ss, TILE_STOPS, *TILE_AXIS)
    else:
        layer = Image.new("RGB", (ss, ss), rgb(FLAT_TILE))

    edge_w = max(1, int(round(ss * 0.0040)))
    ImageDraw.Draw(layer).rounded_rectangle(
        [edge_w / 2, edge_w / 2, ss - 1 - edge_w / 2, ss - 1 - edge_w / 2],
        radius=radius,
        outline=rgb(TILE_EDGE),
        width=edge_w,
    )

    mask = mark_mask(concept, tier, ss)

    # No drop shadow. It was the one thing greying the tile, and it is what
    # pushed the full-art cutover up to 128px; without it the full art holds
    # at 64px (verified by rendering both). The edge highlight below is the
    # only dimensional cue, and it costs the tile nothing.
    if full:
        # The gradient axis is taken from the mark's own bounding box, corner
        # to corner, so the whole ramp is spent on the mark instead of on empty
        # tile. That is what makes the gradient actually visible at 256px.
        x0, y0, x1, y1 = (v / ss for v in mask.getbbox())
        fill = linear_gradient(ss, MARK_STOPS, (x0, y1), (x1, y0))
    else:
        fill = Image.new("RGB", (ss, ss), rgb(FLAT_MARK))
    layer.paste(fill, (0, 0), mask)

    if full:
        # Upper-left edge highlight: the mark minus itself shifted down-right,
        # which leaves a band along exactly the contours a light from the
        # top-left would catch. Kept narrow and soft — a sheen, not a stroke.
        off = max(1, int(round(ss * 0.0045)))
        band = ImageChops.subtract(mask, ImageChops.offset(mask, off, off))
        band = band.filter(ImageFilter.GaussianBlur(ss * 0.0022))
        band = band.point(lambda a: int(a * 0.40))
        layer.paste(Image.new("RGB", (ss, ss), rgb(EDGE_HIGHLIGHT)), (0, 0), band)

    return layer


def tier_for(px: int) -> str:
    if px < MINIMAL_BELOW_PX:
        return "minimal"
    if px < FULL_FROM_PX:
        return "simplified"
    return "full"


def render_size(masters: dict[str, Image.Image], px: int) -> Image.Image:
    """Place the tier's master tile on the transparent 1024-proportion canvas
    and downsample to `px`."""
    master = masters[tier_for(px)]
    tile_px = max(1, int(round(px * TILE / CANVAS)))
    tile = master.resize((tile_px, tile_px), Image.LANCZOS).convert("RGBA")
    tile.putalpha(rounded_tile_alpha(tile_px))
    canvas = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    canvas.alpha_composite(tile, ((px - tile_px) // 2, (px - tile_px) // 2))
    return canvas


# --- Contact sheet ---------------------------------------------------------

SHEET_W = 1360
TRUE_SIZES = [256, 128, 64, 32, 16]
ZOOMS = [(16, 8), (32, 5), (64, 3), (128, 2)]


def _font(size: int) -> ImageFont.ImageFont:
    for path in ("/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Geneva.ttf"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def _checker(w: int, h: int, step: int = 16) -> Image.Image:
    im = Image.new("RGBA", (w, h), (255, 255, 255, 255))
    d = ImageDraw.Draw(im)
    for y in range(0, h, step):
        for x in range(0, w, step):
            if (x // step + y // step) % 2 == 0:
                d.rectangle([x, y, x + step, y + step], fill=(214, 214, 214, 255))
    return im


def build_contact_sheet(
    concept: str, renders: dict[int, Image.Image], out_path: Path
) -> None:
    f_title = _font(20)
    f_label = _font(13)
    f_head = _font(14)

    hero = 384
    rows_y = [64, 372]
    row_bg = [(232, 232, 234, 255), (38, 40, 42, 255)]
    row_txt = [(40, 40, 44, 255), (216, 216, 220, 255)]
    row_head = ["true pixel size, light background", "true pixel size, dark background"]
    zoom_y = 700
    sheet_h = zoom_y + 300

    sheet = Image.new("RGBA", (SHEET_W, sheet_h), (248, 248, 249, 255))
    d = ImageDraw.Draw(sheet)
    d.text(
        (32, 20),
        f"PassSumo app icon — concept {concept.upper()} “{CONCEPTS[concept]}”",
        fill=(24, 24, 28, 255),
        font=f_title,
    )

    # Hero: the 1024 render, scaled down, on a checkerboard so the transparent
    # margin around the tile is visible.
    sheet.alpha_composite(_checker(hero, hero), (32, rows_y[0]))
    sheet.alpha_composite(renders[1024].resize((hero, hero), Image.LANCZOS), (32, rows_y[0]))
    d.text((32, rows_y[0] + hero + 6), "1024px (shown at 384)", fill=(60, 60, 64, 255), font=f_label)

    x_right = 32 + hero + 40
    panel_w = SHEET_W - x_right - 32
    for row in range(2):
        panel_h = 276
        d.rectangle(
            [x_right, rows_y[row], x_right + panel_w, rows_y[row] + panel_h],
            fill=row_bg[row],
        )
        d.text(
            (x_right + 12, rows_y[row] + 8), row_head[row], fill=row_txt[row], font=f_head
        )
        x = x_right + 16
        for size in TRUE_SIZES:
            top = rows_y[row] + 34
            sheet.alpha_composite(renders[size], (x, top))
            d.text((x, top + 258), f"{size}px", fill=row_txt[row], font=f_label)
            x += size + 26

    d.text(
        (32, zoom_y - 26),
        "nearest-neighbour zoom — what pixels are actually there at the small sizes",
        fill=(40, 40, 44, 255),
        font=f_head,
    )
    x = 32
    for size, factor in ZOOMS:
        w = size * factor
        d.rectangle([x, zoom_y, x + w, zoom_y + w], fill=(38, 40, 42, 255))
        sheet.alpha_composite(renders[size].resize((w, w), Image.NEAREST), (x, zoom_y))
        d.text((x, zoom_y + w + 6), f"{size}px @{factor}x", fill=(40, 40, 44, 255), font=f_label)
        x += w + 26

    sheet.convert("RGB").save(out_path)


# --- Entry point -----------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--concept", choices=sorted(CONCEPTS), default="c1")
    parser.add_argument("--out", type=Path, default=None, help="AppIcon.appiconset directory")
    parser.add_argument("--preview", type=Path, default=None, help="contact-sheet PNG")
    parser.add_argument("--hero", type=Path, default=None, help="full-resolution 1024 PNG")
    parser.add_argument(
        "--skip-appicon", action="store_true", help="render previews only, write no asset catalog"
    )
    args = parser.parse_args()

    concept = args.concept
    out_dir = args.out or DEFAULT_OUT
    preview = args.preview or LOGO_DIR / f"appicon-{concept}-preview.png"
    hero = args.hero or LOGO_DIR / f"appicon-{concept}-1024.png"

    masters = {tier: render_master(concept, tier) for tier in ("full", "simplified", "minimal")}
    print(f"concept {concept} ({CONCEPTS[concept]}): rendered {len(masters)} master tiles")

    renders: dict[int, Image.Image] = {}
    for px in sorted({p * s for p, s, _ in ICON_SPECS} | {1024}):
        renders[px] = render_size(masters, px)

    if not args.skip_appicon:
        out_dir.mkdir(parents=True, exist_ok=True)
        contents: dict = {"images": [], "info": {"author": "xcode", "version": 1}}
        for point_size, scale, filename in ICON_SPECS:
            renders[point_size * scale].save(out_dir / filename)
            contents["images"].append(
                {
                    "idiom": "mac",
                    "scale": f"{scale}x",
                    "size": f"{point_size}x{point_size}",
                    "filename": filename,
                }
            )
        (out_dir / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
        print(f"wrote {len(ICON_SPECS)} PNGs + Contents.json to {out_dir}")

    renders[1024].save(hero)
    build_contact_sheet(concept, renders, preview)
    print(f"wrote {hero}\nwrote {preview}")
    print("tiers: " + ", ".join(f"{px}={tier_for(px)}" for px in sorted(renders)))


if __name__ == "__main__":
    main()
