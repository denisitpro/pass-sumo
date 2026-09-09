# App icon — design notes

> Status: living · Last verified: 2026-09-09 · [AI - claude-opus-5]

## What ships

A procedural mark, drawn from geometry in `make-appicon.py` rather than traced from source art,
so every edge stays crisp at every exported size and a colour or proportion change is one command.

Two concepts are implemented; **C1 is the one wired into the asset catalog** (issue #58):

- **C1 "Keyhole P"** — a letter P whose counter *is* a keyhole: the bowl is a D, and the counter
  punched out of it is a circular bore concentric with the bowl plus a slot tapering down into
  the bowl's lower stroke, stopping short of its outer edge so the bowl stays closed. Chosen
  because it carries the product's initial *and* says "lock", and because it is distinctive —
  see C2's problem below.
- **C2 "Padlock"** — a symmetric solid padlock with the keyhole punched through, under a
  constant-width shackle arc. Renders and downscales flawlessly, and that is its whole problem:
  it is the system lock glyph in brand colours, indistinguishable from every other security app
  and from macOS's own lock badge. Kept renderable (`--concept c2`) as the safe fallback.

## Apple geometry used (verified, not guessed)

- **macOS `AppIcon.appiconset` image set**: idiom `mac`, sizes 16/32/128/256/512pt,
  each at scale 1x and 2x (10 images total: 16, 32, 32, 64, 128, 256, 256, 512,
  512, 1024 px). Source: Apple's Asset Catalog Format Reference, "App Icon Type"
  page —
  <https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/AppIconType.html>.
- **Canvas and icon shape**: the current HIG app-icons page —
  <https://developer.apple.com/design/human-interface-guidelines/app-icons> —
  gives a 1024×1024pt layout size for iOS/iPadOS/macOS icons, with the icon shape
  after masking being a rounded rectangle ("squircle"). That page's masking
  language (`"the system applies masking to produce rounded corners"`) describes
  the **modern Icon Composer pipeline**: you hand Icon Composer full-bleed square
  layers and *it* renders the rounded shape into the actual asset it produces.
  A **classic, non-Icon-Composer `AppIcon.appiconset`** — which is what this
  repo ships (see "Icon Composer" below) — is not re-masked by the
  system at build or render time: the PNG itself has to already contain the
  rounded-rect shape and its transparent margin, or the Dock/Launchpad render a
  hard-edged square. This is confirmed by a real-world regression report
  (a full-bleed square PNG rendering as a sharp-cornered icon in the Dock on
  current macOS) — <https://github.com/block/buzz/issues/3272> — which also
  documents Apple's classic geometry: an **~824×824 rounded-rectangle tile
  centered on the 1024×1024 canvas** (~100px transparent margin on each side),
  **corner radius ~185.4px** (≈22.5% of the 824 tile), the "Big Sur" icon
  template numbers that are still the operative ones for a flat asset catalog.
  `make-appicon.py` encodes exactly these numbers (`CANVAS = 1024`,
  `TILE = 824`, `CORNER_RADIUS_RATIO = 185.4 / 824`) — do not change them
  without re-checking this reasoning.

## Icon Composer / `.icon` — open, unresolved

Xcode 26 / macOS 26 ("Tahoe") introduces **Icon Composer**, a GUI tool that
produces a layered `.icon` package (background + up to 4 layers, with Liquid
Glass material properties) instead of flat PNGs, described on the same HIG page
above. It is **optional, not mandatory**:

- Existing flat `AppIcon.appiconset` assets keep working and keep rendering —
  Xcode auto-generates a static `.icns` from either source. Community guidance
  explicitly recommends keeping the classic asset-catalog icon around anyway,
  because Icon Composer icons currently "back-deploy to older OS versions with
  inconsistent rendering" —
  <https://useyourloaf.com/blog/adding-icon-composer-icons-to-xcode/>.
- This project generates its Xcode project from `project.yml` via XcodeGen, and
  XcodeGen does **not** yet treat `.icon` as an atomic package by default — it
  expands it into loose files (`icon.json`, layer SVGs), breaking Xcode's
  recognition of it, unless you add an explicit `fileTypes: { icon: { file:
  true } }` workaround to `project.yml` —
  <https://github.com/yonaskolb/XcodeGen/issues/1556>.
- Icon Composer itself is a GUI app; no documented, scriptable way to author or
  edit a `.icon` package headlessly was found during this research.

Given all three points, the repo ships the classic flat `AppIcon.appiconset`
and leaves Icon Composer as an open follow-up — worth its own decision (and,
per this repo's convention, its own GitHub issue) once XcodeGen's `.icon`
handling and Icon Composer's back-deploy rendering both mature. It does **not**
touch `project.yml`'s `fileTypes`/`ASSETCATALOG_COMPILER_APPICON_NAME` — the
latter has been set to `AppIcon` throughout.

## Colour tokens

Everything comes from the app's approved palette C ("Steel Cyan") accent ramp, plus **one**
sampled token. Nothing here is eyeballed; if a value the ramp lacks is needed, derive it from a
ramp step and name it here first.

| Token | Value | Where |
|---|---|---|
| `azure` | `#25C9ED` | the mark, and the whole flat mark at small sizes |
| accent-400 | `#3A96AB` | the mark gradient's dark end (shading only) |
| accent-200 | `#A4D4DF` | upper-left edge highlight on the mark |
| accent-800 | `#0B3E4C` | tile gradient, top |
| accent-900 | `#072C36` | tile gradient, bottom; tile edge; flat tile at small sizes |

**`azure` provenance — measured, not invented.** Sampled from the sibling app **finsumo**'s
1024px app icon, which is the blue the owner asked for by name. Method: of the 53 006 pixels with
HSV saturation > 0.45, value > 0.45 and hue in [0.50, 0.62], the single most frequent exact value
is `#25C9ED` (n = 299). Its hue is **0.530 — the same hue as palette C's accent ramp**
(accent-300/400/500 all land on 0.530–0.531), so it is not a foreign blue bolted on: it is the
brand's own hue at full chroma (s 0.84 vs accent-400's 0.66). That is why no ramp-wide shift was
needed to accommodate it.

## Colour decisions

- **The tile stays dark, and that reasoning is unchanged.** A pale tile reads washed-out in a
  contact-sheet comparison against both a light and a dark Dock; a fully opaque, richly saturated
  tile reads clearly against either, because the icon's own background occludes the Dock locally
  regardless of Dock theme. It also reads as more "vault-like" for a security product. The tile is
  a deep accent-800 → accent-900 gradient, top to bottom.
- **The tile's outer band is darkened, not lit.** A lighter rim (tried at accent-700) reads as a
  drawn outline around the icon and dates it; landing the band on the gradient's own dark end just
  deepens the edge. Compared as renders before choosing.
- **The mark's gradient is front-loaded, and only mildly.** A plain accent-400 → azure two-stop
  ramp left most of the mark's *area* mid-gradient, so the icon read as mid-teal rather than as
  the vivid azure it is meant to be. Ramping to full azure too early (accent-500 → azure by 22%
  of the axis) put a visible diagonal crease across the stem. Reaching azure at 55% along a long
  axis is the version with smooth shading and the upper two thirds at the azure itself.
- **Shadow and edge highlight are deliberately weak** (24% black, 40% accent-200). Heavier values
  were rendered and read as 2010-era skeuomorphism rather than as depth.

## Small sizes get different art, on purpose

Three tiers, and the cutovers were chosen by rendering the *same* pixel size from every tier side
by side and looking at them — not by assumption:

- **≥128px — full art**: tile gradient, mark gradient, drop shadow, edge highlight.
- **32–64px — simplified**: flat `#25C9ED` mark on a flat `#072C36` tile, no shadow or highlight.
  At **64px the full art is visibly washed**: the shadow greys the tile and the gradient dulls the
  mark's lower left, while the flat version is markedly crisper and more vivid. So the full-art
  cutover is 128px, not 64px.
- **<32px — minimal**: as simplified, plus thicker stem and bowl strokes, and the keyhole reduced
  to its circular bore. At **16px the keyhole slot smears into a blob** and takes the bowl's
  counter with it; the plain bore stays a clean, readable hole. At 32px the slot still reads, so
  the minimal cutover is 16px only.

This is normal, expected macOS icon practice — the asset catalog supports different art per size.

**One artifact worth not reintroducing.** The tile's rounded-corner alpha is drawn supersampled and
downsampled *on its own*, never as part of an RGBA master. Resizing an RGBA master makes LANCZOS
ring the four channels independently, so just outside the corners the alpha lands on 1–3 while the
colour channels undershoot to values the tile never contained (measured: `#00007F` at alpha 2).
Downsampling the mask alone cannot do that — the colour it reveals is always real tile colour.

## Regenerating

```
python3 design/logo/make-appicon.py --concept c1     # writes the asset catalog + previews
python3 design/logo/make-appicon.py --concept c2 --skip-appicon   # previews only
```

Requires Python 3 + Pillow (no numpy). Writes the full `.appiconset` (10 PNGs + `Contents.json`),
a full-resolution `appicon-<concept>-1024.png`, and `appicon-<concept>-preview.png` — a contact
sheet showing the 1024 render, every small size at **true pixel size on both a light and a dark
background**, and nearest-neighbour zooms of 16/32/64/128px so the actual pixels can be judged.

The old `--source` flag is gone: there is no longer source art to extract a mark from.

## Superseded source art

`grok-image-299e0343-*.jpg` (detailed cartoon mascot) and `grok-image-b89c2f82-*.jpg` (flat navy
padlock + sumo silhouette) are the generated concepts the **previous** icon was built from. The
mascot was always too detailed to read below 128px; the flat mark shipped until #58 replaced it,
its sumo reading as an ambiguous blob at every size below 512px. Both are retained as
marketing/store reference art only — nothing in the build reads them.

## If you would rather generate the art than draw it

Both previous icons came from generated images, so this is a live alternative. A ready-to-paste
prompt for the current direction:

> A premium macOS app icon for a password manager, 1024×1024, flat vector style, no text.
> Background: a deep near-black navy-teal rounded square, gradient `#0B3E4C` at the top to
> `#072C36` at the bottom, with an ~100px transparent margin around it and a corner radius of
> about 185px. Foreground: one bold geometric capital letter **P** in vivid azure `#25C9ED`,
> filling roughly 55% of the tile's width and 70% of its height, centred. The P's counter — the
> enclosed space in its bowl — is a **keyhole**: a circular bore with a short slot tapering
> downward from it, cut clean through to the navy background, and not breaking through the bowl's
> outer edge. Even stroke weight throughout. A very subtle darker shading in the mark's lower
> left, a very subtle light edge along its upper left, and a soft short drop shadow. No hairlines,
> no outlines, no gloss, no bevel, no highlights on the tile, no mascot, no photorealism.

Then check the result at 16px and 32px before believing it: a generated icon almost always needs
separate, simplified small-size art, which is what the three-tier scheme above exists for.

## Verification

`cd PassSumo && make generate && make debug` builds clean with the icon wired in via the asset
catalog's `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` setting. Review the rendered PNGs and the
contact sheet directly — at 16px and 32px specifically — rather than trusting the 1024 render.
Seeing it in the Dock and Launchpad is a separate, human step; it is not covered by a headless
build.
