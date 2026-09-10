# App icon — design notes

> Status: living · Last verified: 2026-09-10 · [AI - claude-sonnet-5]

## Owner's verdict, 2026-09-10 (issue #18) — the monogram redraw is rejected

The "Keyhole P" monogram below (`b88fd32`, `b6a0e40`, both 2026-09-09) **is currently still what
`PassSumo/Resources/Assets.xcassets/AppIcon.appiconset` contains**, but the owner has rejected it:

> иконка которая была до вчера была нормальная кроме цвета, на хуй ее перерисовали я не понял,
> сказано было сделать лазурью, ушел получил говно блять какое то

The instruction that was actually given, before the redraw, was **"make it azure"** — a recolour
of the mark that shipped before, `8ab8f02` (2026-08-30, the flat padlock + sumo silhouette). The
monogram substituted a different mark entirely, which was never asked for.

**What this round (issue #18) did:** recovered `8ab8f02`'s own mark-extraction pipeline from git
(not redrawn from a description — see "Recolour candidates" below), produced colour + treatment
variants of *that* silhouette for the owner to pick from, and rendered them at the sizes that
actually matter (1024/128/32/16). **It deliberately did NOT touch `AppIcon.appiconset`** — the
monogram is still the compiled asset as of this commit. Swapping it is a follow-up, once the owner
picks a candidate from `appicon-variants-comparison.png`.

## What ships right now (rejected, not yet replaced)

A procedural mark, drawn from geometry in `make-appicon.py` rather than traced from source art, so
every edge stays crisp at every exported size and a colour or proportion change is one command.
Three concepts are implemented; **C1 is wired into the asset catalog** (issue #58) — **and is the
mark the owner rejected above.** Left in place, and `make-appicon.py` left as its reproducible
generator, only because #18 defers the actual asset-catalog swap to a follow-up commit:

- **C1 "Keyhole P"** — a bold monoline P whose counter *is* a keyhole: the bowl is a D, and the
  counter punched out of it is a circular bore concentric with the bowl plus a slot tapering into
  the bowl's lower stroke, stopping short of its outer edge so the bowl stays closed. Chosen: it
  carries the product's initial *and* says "lock", in one shape, at every size.
- **C3 "Thin P"** — the same idea in a thin constructed weight. **Rejected**, for a structural
  reason worth keeping: slot depth can only ever be `stroke - inset` while the bore radius is
  `bowl_r - stroke`, so a readable keyhole-as-counter needs `stroke ≈ bowl_r / 2` — a heavy
  weight. A thin P must therefore nest a small keyhole inside a large plain counter, which at
  128–256px reads as a separate dark disc stuck onto the letter. It also loses its identity below
  128px (stroke jumps 0.070 → 0.100 → 0.130 across the tiers, so the Dock and Finder would show
  visibly different letterforms); C1's tiers stay within 13%.
- **C2 "Padlock"** — a symmetric solid padlock with the keyhole punched through, under a
  constant-width shackle arc. Renders and downscales flawlessly, and that is its whole problem:
  it is the system lock glyph in brand colours, indistinguishable from every other security app
  and from macOS's own lock badge. Kept renderable as the safe fallback.

## The letterform

One construction (`letter_p`) serves every weight and tier, so proportion changes are parameters
rather than edits:

- **Stem width and bowl stroke are equal** — a true monoline, deliberate rather than incidental.
- **All terminals are flat and square, zero corner rounding anywhere.** One treatment everywhere.
  An earlier version rounded the stem's foot but left the bowl junctions sharp, and read careless.
- **The counter is concentric with the bowl disc at `bowl_r - stroke`.** That one choice keeps the
  bowl's weight even all the way round *and* puts the stem's right edge exactly tangent to the
  counter, which is where a P's stem belongs in type.
- **Bowl height is 64% of cap height**, leaving 36% of stem below it. It was 75%, which is what
  made the stem look stubby and the mark blobby.
- **Cap height is 65% of the tile** at the full-art sizes, so the tile keeps real margin (was 70%,
  and read as crowded).
- **Optical centring, horizontally only, measured not guessed.** The centre of ink is computed from
  the rendered mask and the mark nudged right by 55% of that offset — a P's empty lower-right
  quadrant otherwise makes a box-centred letter look shoved sideways, and the full offset
  overshoots. Vertically it stays box-centred: the eye places a letter by cap and baseline, not by
  mass, and correcting vertically too put the mark visibly low.

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
untouched and `ASSETCATALOG_COMPILER_APPICON_NAME` has been `AppIcon` throughout.

## Colour

Everything comes from palette C ("Steel Cyan"), plus **one** sampled token. Nothing here is
eyeballed; if a value the ramp lacks is needed, derive it from a ramp step and name it here first.

| Token | Value | Where |
|---|---|---|
| `azure` | `#25C9ED` | the mark, and the whole flat mark at small sizes |
| accent-400 | `#3A96AB` | the mark gradient's dark end (shading only) |
| accent-200 | `#A4D4DF` | upper-left edge highlight on the mark |
| accent-800 | `#0B3E4C` | tile gradient, top |
| accent-900 | `#072C36` | tile gradient, bottom; tile edge; flat tile at small sizes |

**`azure` provenance — measured, not invented.** Sampled from the sibling app **finsumo**'s 1024px
app icon, the blue the owner asked for by name. Method: of the 53 006 pixels with HSV saturation
> 0.45, value > 0.45 and hue in [0.50, 0.62], the most frequent exact value is `#25C9ED` (n = 299).
Its hue is **0.530 — the same hue as palette C's accent ramp** (accent-300/400/500 all land on
0.530–0.531), so it is not a foreign blue bolted on but the brand's own hue at full chroma (s 0.84
vs accent-400's 0.66). That is why no ramp-wide shift was needed.

Decisions, each compared as renders before choosing:

- **The tile stays dark, and that reasoning is unchanged.** A pale tile reads washed-out in a
  contact-sheet comparison against both a light and a dark Dock; a fully opaque, saturated tile
  reads clearly against either, because the icon's own background occludes the Dock locally
  regardless of Dock theme. It also reads as more "vault-like" for a security product.
- **The tile carries a diagonal gradient, not a flat fill**: accent-800 at the top-left corner into
  accent-900, which most of the tile sits at — material rather than slab, without inventing a hex
  darker than the ramp holds. Its outer band is **darkened, not lit**: a lighter rim (tried at
  accent-700) reads as a drawn outline around the icon and dates it.
- **The mark's gradient is spent across the mark's own bounding box**, corner to corner, rather
  than across the tile — otherwise most of the ramp lands on empty tile and the mark reads nearly
  flat, which is what the first attempt did. Dark end **accent-400**: compared at 256px against
  accent-500 and accent-300, accent-500 leaves the stem's lower half distinctly duller than the
  bowl so the mark reads two-tone, and accent-300 is barely a ramp at all.
- **There is no drop shadow.** It was the one element greying the tile; the edge highlight alone
  (40% accent-200, ~0.5% of the tile wide) carries the mark's dimension at no cost to the ground.

## Small sizes get different art, on purpose

Three tiers, cutovers chosen by rendering the *same* pixel size from every tier side by side and
looking at them — not by assumption. The small tiers are deliberately **larger and heavier** than
the full-art tier (cap height 0.65 → 0.68 → 0.70, stroke 0.115 → 0.122 → 0.130), which is what
lets the full-art mark shrink for air without costing 16px legibility.

- **≥128px — full art**: tile gradient, mark gradient, edge highlight.
- **32–64px — simplified**: flat `#25C9ED` mark on a flat `#072C36` tile, no highlight.
  **At 64px the full art is still visibly duller and softer than the flat version, even with the
  drop shadow removed.** Removing the shadow was expected to buy back this tier and did not: at
  64px it is the *gradient* that dulls the mark's lower half, and the simplified tier's larger,
  heavier glyph carries better besides. So the full-art cutover stays 128px.
- **<32px — minimal**: as simplified, plus thicker stem and bowl strokes, and the keyhole reduced
  to its circular bore. At **16px the keyhole slot smears into a blob** and takes the bowl's
  counter with it; the plain bore stays a clean, readable hole. At 32px the slot still reads, so
  the minimal cutover is 16px only.

Normal, expected macOS practice — the asset catalog supports different art per size.

**One artifact worth not reintroducing.** The tile's rounded-corner alpha is downsampled *on its
own*, never as part of an RGBA master: resizing RGBA makes LANCZOS ring the four channels
independently, so just outside the corners the alpha lands on 1–3 while the colour channels
undershoot to values the tile never contained (measured: `#00007F` at alpha 2).

## Regenerating

```
python3 design/logo/make-appicon.py --concept c1                 # asset catalog + previews
python3 design/logo/make-appicon.py --concept c3 --skip-appicon   # previews only (c2, c3)
```

Requires Python 3 + Pillow (no numpy). Writes the full `.appiconset` (10 PNGs + `Contents.json`),
a full-resolution `appicon-<concept>-1024.png`, and `appicon-<concept>-preview.png` — a contact
sheet showing the 1024 render, every small size at **true pixel size on both a light and a dark
background**, and nearest-neighbour zooms of 16/32/64/128px so the actual pixels can be judged.
The old `--source` flag is gone: there is no source art to extract a mark from any more.

## Recolour candidates (issue #18) — the padlock+sumo mark, restored

`make-icon-variants.py` recovers `8ab8f02`'s own mark-extraction pipeline — `sample_source_colors`,
`extract_mark_alpha`, `crop_to_content`, and the padlock-only small-size glyph
(`draw_padlock_glyph` / `punch_keyhole`) — **copied verbatim from that commit**, not re-derived from
a description. Run against the same source JPEG (`grok-image-b89c2f82-*.jpg`, unchanged since
`8ab8f02`), it produces the identical silhouette `8ab8f02` shipped. Only colour changes; no shape,
letterform, or composition edit was made.

**Colour directions (two):**

| Direction | Value | Relationship to palette C |
|---|---|---|
| `azure` | `#25C9ED` | Same token `design/BRAND.md`'s ramp already names in the "Colour" section above — measured from sibling app finsumo's icon, hue 0.530 (matches accent-300–900's 0.530–0.538). **Deliberately outside the ramp itself**: at value 0.929 it is far brighter than any ramp step (the closest, accent-300, sits at 0.784), and at saturation 0.844 it matches accent-600/700 rather than a paler step. It is the brand's own hue at a chroma/brightness combination the ramp doesn't otherwise reach — not a foreign blue, but not a ramp step either. This is the token the owner actually named ("сделать лазурью"). |
| `steel` | `accent-400` `#3A96AB` | The brightest ramp step that is still meaningfully saturated (sat 0.661, hue 0.531). **Strictly inside the published ramp** — no departure at all. Included so the choice sheet shows what "just stay inside the ramp" looks like next to what "azure" actually looks like, since those are visibly different brightness levels, not just different hues. |

**Silhouette treatments (two), full-art tiers only (≥64px, `8ab8f02`'s own cutover):**

- **flat** — a single flat recolour: the same `recolor()` treatment `8ab8f02` itself used, unchanged.
- **shaded** — a diagonal two-stop gradient across the mark's own bounding box (light corner to dark
  corner), plus a matching tile gradient (`accent-800` → `accent-900`, the same pairing the rejected
  monogram used for its tile). Colour distribution only; the mask is identical to the flat variant.

Below `8ab8f02`'s own 64px cutover, the full padlock+sumo mark degrades into a blob — its finding,
not a new one — so 32px and 16px always fall back to its procedural padlock-only glyph, flat-
recoloured per colour direction. **`flat` and `shaded` are therefore pixel-identical below 64px**
(verified: their 32px and 16px PNGs hash identically); shading is a full-art-tier enhancement only,
exactly matching `8ab8f02`'s own precedent of tiered art.

The tile stays a flat/gradient `accent-800`/`accent-900` navy in every variant — the owner never
objected to the dark tile in either the original or the rejected monogram, only to the mark being
redrawn, so the tile isn't a variable here. (`8ab8f02` itself derived its background from the source
JPEG's own navy, `#313943`; palette C didn't exist yet on 2026-08-30. Using the now-published ramp's
own darkest steps instead is a deliberate, in-scope alignment, not a silhouette change.)

**What looking at the renders actually shows.** At 128px and 1024px all four variants read cleanly —
padlock body, shackle, keyhole and the sumo figure all distinct; `shaded` adds visible material depth
over `flat` without costing any legibility. At 32px, all four still read as a clear padlock glyph with
an open keyhole. **At 16px the two colour directions diverge**: `azure`'s brightness (value 0.929)
holds a visibly crisper, higher-contrast silhouette against the dark tile, while `steel`
(`accent-400`, value 0.671) reads distinctly duller and softer at the same pixel size — still
legible, but azure is the stronger candidate at exactly the size issue #18 says is the point.

Renders (all under `design/logo/`, `AppIcon.appiconset` untouched):

- `appicon-variants-comparison.png` — the side-by-side sheet: all 4 variants × 1024/128/32/16px,
  16px/32px shown both at true pixel size and nearest-neighbour zoomed for legibility.
- `variants/<azure|steel>-<flat|shaded>-<1024|128|32|16>.png` — the 16 individual renders.

Regenerate with `python3 design/logo/make-icon-variants.py` (Pillow only, no numpy, no arguments).
Output paths are hardcoded to `design/logo/` and `design/logo/variants/` — deliberately: this
script has no flag that can point it at `AppIcon.appiconset`. Once the owner picks a variant, wiring
the chosen colour/treatment into `make-appicon.py`'s own `--concept` and asset-catalog output is
the follow-up commit.

## Superseded source art

`grok-image-299e0343-*.jpg` (cartoon mascot) is a generated concept that was never shipped — too
detailed to read below 128px. Retained as marketing/store reference art only; nothing in the build
reads it.

`grok-image-b89c2f82-*.jpg` (flat navy padlock + sumo silhouette) is **not superseded** — it is the
source `8ab8f02` extracted its mark from, and `make-icon-variants.py` (above) reads it again for
the issue #18 recolour candidates. Kept exactly as-is since `8ab8f02`; only the two smaller sizes'
sumo silhouette is an ambiguous blob (`8ab8f02`'s own finding, which is why those two sizes use the
procedural padlock-only glyph instead — see above).

## If you would rather generate the art than draw it

Both previous icons came from generated images, so this is a live alternative — a ready-to-paste
prompt for the current direction:

> A premium macOS app icon for a password manager, 1024×1024, flat vector style, no text.
> Background: a deep near-black navy-teal rounded square, diagonal gradient from `#0B3E4C` at the
> top-left into `#072C36`, with an ~100px transparent margin around it and a corner radius of
> about 185px. Foreground: one bold geometric monoline capital **P** in vivid azure `#25C9ED`,
> its cap height about 65% of the tile, centred with generous margin. Stem width and bowl stroke
> equal; all terminals flat and square; the bowl about 64% of the cap height so a third of the
> stem shows below it. The P's counter — the enclosed space in its bowl — is a **keyhole**: a
> circular bore concentric with the bowl, with a short slot tapering downward from it, cut clean
> through to the navy background and stopping short of the bowl's outer edge so the bowl stays
> closed. Subtle darker shading toward the mark's lower left, a fine light edge along its upper
> left. No drop shadow, no hairlines, no outlines, no gloss, no bevel, no mascot, no photorealism.

Then check the result at 16px and 32px before believing it: a generated icon almost always needs
separate, simplified small-size art, which is what the three-tier scheme above exists for.

## Verification

`cd PassSumo && make generate && make debug` builds clean with the icon wired in via the asset
catalog's `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` setting. Review the rendered PNGs and the
contact sheet directly — at 16px and 32px specifically — rather than trusting the 1024 render.
Seeing it in the Dock and Launchpad is a separate, human step, not covered by a headless build.
