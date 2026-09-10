# App icon — design notes

> Status: living · Last verified: 2026-09-10 · [AI - claude-sonnet-5]

## What ships: the azure padlock+sumo mark, dual-tier (issue #18)

The shipped icon is `8ab8f02`'s original flat padlock+sumo silhouette (2026-08-30), recoloured
azure per the owner's instruction, with **two tiers of art**: the full mark (padlock + sumo,
`azure-shaded`) at 64px and above, and a simplified padlock-only glyph (no sumo) below that. This
is the owner's final decision on 2026-09-10, after reviewing 4 candidates and the 16px legibility
problem they raised in an earlier round of this same issue:

> по иконке бери azure shaded, для мелких просто нахуярь замочек или че там будет более-менее
> смотреться; на крупных — точь-в-точь как в примере, на мелких хуйня, [сделай] что более-менее
> рабочей выглядит

`design/logo/make-appicon.py` regenerates it (see "Regenerating" below); the mark's own shapes are
unchanged from `8ab8f02` throughout this issue — only colour, and how much of the mark survives at
small sizes, ever changed.

### Large tiers (64/128/256/512/1024px) — the full mark, unmodified

The **`azure-shaded`** candidate from the comparison round, exactly as rendered there: the
`8ab8f02` padlock+sumo silhouette recoloured with a diagonal gradient from `azure` (`#25C9ED`) to
`accent-400` (`#3A96AB`) across the mark's own bounding box, on a tile with a diagonal gradient
from `accent-800` (`#0B3E4C`) to `accent-900` (`#072C36`). Colour provenance and the palette-C
relationship are documented in full in "Colour candidates that were compared" below — nothing about
that reasoning changed when the owner picked this one.

### Small tiers (16/32px) — a simplified padlock, not the full mark

The owner explicitly accepted the 16px finding from the previous round of this issue (the full
mark turns to mush at small sizes) and asked for "просто... замочек" — just a padlock, whatever
reads. So small sizes drop the sumo figure entirely and reuse `8ab8f02`'s own procedural
padlock-only glyph (`draw_padlock_glyph` / `punch_keyhole`, its geometry untouched), flat `azure`
on a flat `accent-900` tile — no gradient, since a gradient buys nothing at this size and the
comparison round already established flat and shaded are pixel-identical below the full-art
cutover.

**Two sizes, two treatments, chosen by rendering and looking, not by assumption:**

- **32px keeps the punched keyhole.** Rendered and inspected at true pixel size (nearest-neighbour,
  not a viewer's smoothed upscale): body, shackle and keyhole all read clearly as a padlock.
- **16px drops the keyhole punch.** At true 16×16 pixels, the keyhole's circle-plus-wedge punch
  does **not** read as a hole — it collapses into a confusing mask-like blob that muddies the whole
  glyph (this is what "мелких хуйня" was pointing at, and it reproduces the same failure the
  simplified glyph had in the previous round's `azure-flat`/`azure-shaded` renders, which used the
  punched glyph unconditionally below 64px). Dropping the punch and shipping a solid body+shackle
  silhouette instead reads unambiguously as "a padlock" at 16px. Verified by rendering both ways
  (`design/logo/appicon-preview.png`'s nearest-neighbour row) and comparing — this is a genuine,
  evidence-based simplification of the same padlock, not a new icon and not the sumo mark
  reappearing in a different form.

**Cutover between full mark and simplified glyph: 64px, unchanged from `8ab8f02`.** Re-tested this
round rather than assumed: rendered `azure-shaded`'s full mark at 96/72/64/56/48/32px and looked —
at 64px the padlock body is crisp and the sumo figure still reads as a figure (soft, but a figure);
at 48px the sumo starts fusing into the lock body; at 32px it is mush. The evidence supports keeping
`8ab8f02`'s own 64px line, not lowering it.

**Honest result at the sizes that matter.** 32px reads cleanly as a padlock with a keyhole. 16px,
with the keyhole dropped, reads cleanly as a padlock silhouette — plain, no interior detail, but
unambiguous. Neither size shows the sumo figure; that is intentional per the owner's instruction,
not a limitation being glossed over.

## History: how this was decided

### 2026-09-10, first pass — the monogram redraw was rejected

The "Keyhole P" monogram (`b88fd32`, `b6a0e40`, both 2026-09-09) briefly shipped in
`AppIcon.appiconset`. The owner rejected it:

> иконка которая была до вчера была нормальная кроме цвета, на хуй ее перерисовали я не понял,
> сказано было сделать лазурью, ушел получил говно блять какое то

The instruction that was actually given, before the redraw, was **"make it azure"** — a recolour of
the mark that shipped before those two commits, `8ab8f02` (2026-08-30, the flat padlock + sumo
silhouette). The monogram substituted a different mark entirely, which was never asked for. See
"Superseded: the rejected monogram" below for what it was and why it's kept (not deleted) as
reference.

That pass recovered `8ab8f02`'s own mark-extraction pipeline from git (not redrawn from a
description), and rendered 4 azure/steel × flat/shaded candidates of the restored silhouette for
the owner to pick from, without touching `AppIcon.appiconset` yet. See "Colour candidates that were
compared" below for the full matrix and reasoning — still accurate; nothing about the colour
decision changed in the second pass.

### 2026-09-10, second pass — variant picked, small sizes simplified, appiconset regenerated

The owner picked `azure-shaded` for the large tiers and asked for a simplified drawing (not the
full mark) at small sizes, accepting the 16px legibility finding from the first pass. This is the
pass documented under "What ships" above; `AppIcon.appiconset` now contains it.

## Colour candidates that were compared

`make-icon-variants.py` (kept, for the record) recovers `8ab8f02`'s own mark-extraction pipeline —
`sample_source_colors`, `extract_mark_alpha`, `crop_to_content`, and the padlock-only small-size
glyph (`draw_padlock_glyph` / `punch_keyhole`) — **copied verbatim from that commit**, not
re-derived from a description. Run against the same source JPEG (`grok-image-b89c2f82-*.jpg`,
unchanged since `8ab8f02`), it produces the identical silhouette `8ab8f02` shipped. Only colour
changed; no shape, letterform, or composition edit was made, in either pass.

**Colour directions compared (two):**

| Direction | Value | Relationship to palette C |
|---|---|---|
| `azure` (**picked**) | `#25C9ED` | Measured from sibling app finsumo's icon, hue 0.530 (matches `design/BRAND.md`'s accent-300–900, hue 0.530–0.538). **Deliberately outside the ramp itself**: at value 0.929 it is far brighter than any ramp step (the closest, accent-300, sits at 0.784), and at saturation 0.844 it matches accent-600/700 rather than a paler step. It is the brand's own hue at a chroma/brightness combination the ramp doesn't otherwise reach — not a foreign blue, but not a ramp step either. This is the token the owner actually named ("сделать лазурью"). |
| `steel` (not picked) | `accent-400` `#3A96AB` | The brightest ramp step that is still meaningfully saturated (sat 0.661, hue 0.531). Strictly inside the published ramp — no departure at all. Included so the choice sheet showed what "just stay inside the ramp" looks like next to azure; at 16px it read distinctly duller. |

**Silhouette treatments compared (two), full-art tiers only (≥64px, `8ab8f02`'s own cutover):**

- **flat** — a single flat recolour: the same `recolor()` treatment `8ab8f02` itself used, unchanged.
- **shaded** (**picked**) — a diagonal two-stop gradient across the mark's own bounding box (light
  corner to dark corner), plus a matching tile gradient (`accent-800` → `accent-900`, the same
  pairing the rejected monogram used for its tile). Colour distribution only; the mask is identical
  to the flat variant.

The tile stays a flat/gradient `accent-800`/`accent-900` navy in every variant — the owner never
objected to the dark tile in either the original or the rejected monogram, only to the mark being
redrawn, so the tile wasn't a variable. (`8ab8f02` itself derived its background from the source
JPEG's own navy, `#313943`; palette C didn't exist yet on 2026-08-30. Using the now-published ramp's
own darkest steps instead was a deliberate, in-scope alignment, not a silhouette change.)

**What looking at the first-pass renders showed** (this is what the 16px finding above is based on):
at 128px and 1024px all four candidates read cleanly — padlock body, shackle, keyhole and the sumo
figure all distinct; `shaded` added visible material depth over `flat` without costing legibility.
At 32px, all four still read as a clear padlock glyph with an open keyhole. At 16px the two colour
directions diverged: `azure`'s brightness held a visibly crisper silhouette than `steel`, which read
duller — and *both*, at that first pass, used the full punched-keyhole simplified glyph
unconditionally below 64px, which is the render that led to the second-pass keyhole-drop at 16px
described under "What ships" above.

First-pass renders, kept under `design/logo/` for the record:

- `appicon-variants-comparison.png` — all 4 candidates × 1024/128/32/16px
- `variants/<azure|steel>-<flat|shaded>-<1024|128|32|16>.png` — the 16 individual renders

Regenerate with `python3 design/logo/make-icon-variants.py` (Pillow only, no arguments; writes only
under `design/logo/`, never touches `AppIcon.appiconset`) if the colour/treatment decision is ever
revisited.

## Apple geometry used (verified, not guessed)

- **macOS `AppIcon.appiconset` image set**: idiom `mac`, sizes 16/32/128/256/512pt, each at scale
  1x and 2x (10 images total: 16, 32, 32, 64, 128, 256, 256, 512, 512, 1024 px). Source: Apple's
  Asset Catalog Format Reference, "App Icon Type" page —
  <https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/AppIconType.html>.
- **Canvas and icon shape**: the current HIG app-icons page —
  <https://developer.apple.com/design/human-interface-guidelines/app-icons> — gives a 1024×1024pt
  layout size for iOS/iPadOS/macOS icons, with the icon shape after masking being a rounded
  rectangle ("squircle"). That page's masking language (`"the system applies masking to produce
  rounded corners"`) describes the **modern Icon Composer pipeline**: you hand Icon Composer
  full-bleed square layers and *it* renders the rounded shape into the actual asset it produces.
  A **classic, non-Icon-Composer `AppIcon.appiconset`** — which is what this repo ships (see "Icon
  Composer" below) — is not re-masked by the system at build or render time: the PNG itself has to
  already contain the rounded-rect shape and its transparent margin, or the Dock/Launchpad render
  a hard-edged square. This is confirmed by a real-world regression report (a full-bleed square PNG
  rendering as a sharp-cornered icon in the Dock on current macOS) —
  <https://github.com/block/buzz/issues/3272> — which also documents Apple's classic geometry: an
  **~824×824 rounded-rectangle tile centered on the 1024×1024 canvas** (~100px transparent margin
  on each side), **corner radius ~185.4px** (≈22.5% of the 824 tile), the "Big Sur" icon template
  numbers that are still the operative ones for a flat asset catalog. `make-appicon.py` encodes
  exactly these numbers (`CANVAS = 1024`, `TILE = 824`, `CORNER_RADIUS_RATIO = 185.4 / 824`) — do
  not change them without re-checking this reasoning.

## Icon Composer / `.icon` — open, unresolved

Xcode 26 / macOS 26 ("Tahoe") introduces **Icon Composer**, a GUI tool producing a layered `.icon`
package (background + up to 4 layers, Liquid Glass materials) instead of flat PNGs — same HIG page
as above. It is **optional, not mandatory**, and three findings say "not yet":

- Flat `AppIcon.appiconset` assets keep working; Xcode auto-generates a static `.icns` from either
  source. Community guidance recommends keeping the classic asset-catalog icon anyway, because
  Icon Composer icons currently "back-deploy to older OS versions with inconsistent rendering" —
  <https://useyourloaf.com/blog/adding-icon-composer-icons-to-xcode/>.
- XcodeGen (which generates this project from `project.yml`) does **not** treat `.icon` as an
  atomic package by default — it expands it into loose files, breaking Xcode's recognition of it,
  without an explicit `fileTypes: { icon: { file: true } }` workaround —
  <https://github.com/yonaskolb/XcodeGen/issues/1556>.
- Icon Composer is GUI-only; no documented headless way to author a `.icon` package was found.

So the repo ships the classic flat `AppIcon.appiconset` and leaves Icon Composer as an open
follow-up, worth its own issue once both of the above mature. `project.yml`'s `fileTypes` is
untouched and `ASSETCATALOG_COMPILER_APPICON_NAME` has been `AppIcon` throughout. **Unchanged by
issue #18** — out of scope for the recolour, per the owner.

## Superseded: the rejected monogram (historical, kept not deleted)

A procedural mark, drawn from geometry rather than traced from source art. Three concepts were
implemented; C1 was briefly wired into the asset catalog (issue #58) before the owner rejected it
on 2026-09-10 (see "History" above). **None of this ships any more** — kept here and as static PNGs
(`appicon-c1/c2/c3-*.png`) purely as a historical record, per the owner's instruction not to delete
rejected work.

- **C1 "Keyhole P"** — a bold monoline P whose counter *is* a keyhole: the bowl is a D, and the
  counter punched out of it is a circular bore concentric with the bowl plus a slot tapering into
  the bowl's lower stroke, stopping short of its outer edge so the bowl stays closed. This was the
  one wired into the asset catalog, then rejected.
- **C3 "Thin P"** — the same idea in a thin constructed weight. Rejected on its own structural
  terms (independent of the owner's later redraw rejection): slot depth can only ever be
  `stroke - inset` while the bore radius is `bowl_r - stroke`, so a readable keyhole-as-counter
  needs `stroke ≈ bowl_r / 2` — a heavy weight. A thin P must therefore nest a small keyhole inside
  a large plain counter, which at 128–256px reads as a separate dark disc stuck onto the letter. It
  also loses its identity below 128px (stroke jumps 0.070 → 0.100 → 0.130 across the tiers).
- **C2 "Padlock"** — a symmetric solid padlock with the keyhole punched through. Renders and
  downscales flawlessly, and that was its whole problem: indistinguishable from every other
  security app and from macOS's own lock badge.

The monogram's letterform construction, its small-size tiering (128/64/32/16px cutovers with
stroke/cap-height ramping), and its own colour table are no longer relevant to what ships and are
not repeated here in full — see git history (`b88fd32`, `b6a0e40`) if the construction details are
ever needed again. The one thing worth carrying forward: its tile gradient pairing
(`accent-800` → `accent-900`) is what the shipped padlock+sumo mark's large tiers reuse.

A ready-to-paste "generate this instead of drawing it" prompt for the monogram direction also
existed here; removed along with the rest of the monogram's now-irrelevant construction detail — it
described a letterform that no longer ships, and the current mark is extracted from existing art,
not generated.

## Superseded source art

`grok-image-299e0343-*.jpg` (cartoon mascot) is a generated concept that was never shipped — too
detailed to read below 128px. Retained as marketing/store reference art only; nothing in the build
reads it.

`grok-image-b89c2f82-*.jpg` (flat navy padlock + sumo silhouette) is **not superseded** — it is the
source `8ab8f02` extracted its mark from, and it's what `make-appicon.py` and `make-icon-variants.py`
both still read to produce the shipped icon. Kept exactly as-is since `8ab8f02`; only its sumo
silhouette is unreadable below 64px (`8ab8f02`'s own finding, re-confirmed this round), which is
why small sizes use the procedural padlock-only glyph instead.

## Regenerating

```
python3 design/logo/make-appicon.py
```

No arguments, no concept flags — there is exactly one shipped design now. Requires Python 3 +
Pillow (no numpy). Extracts the mark from `grok-image-b89c2f82-*.jpg`, writes the full
`AppIcon.appiconset` (10 PNGs + `Contents.json`) directly into
`PassSumo/Resources/Assets.xcassets/AppIcon.appiconset`, plus a full-resolution `appicon-1024.png`
and `appicon-preview.png` — a contact sheet with every size at true pixel size **and** a
nearest-neighbour zoom row, so small-size pixel content can be judged without a viewer's own
smoothing making a bad render look better than it is.

`make-icon-variants.py` (no arguments, writes only under `design/logo/` and `design/logo/variants/`,
never touches `AppIcon.appiconset`) regenerates the historical colour/treatment comparison in
"Colour candidates that were compared" above, if that decision is ever revisited.

## Verification

`cd PassSumo && make generate && make debug` builds clean: `actool` compiles the asset catalog with
no notices or warnings, and `AppIcon.icns` is produced. This round, the compiled `.icns` was also
extracted back out (`iconutil -c iconset`) and its 16px/32px PNGs viewed directly — not just the
source renders — confirming the built artifact matches what `make-appicon.py` wrote. Seeing it in
the Dock and Launchpad is a separate, human step, not covered by a headless build.
