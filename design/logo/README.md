# App icon — design notes

> Status: living · Last verified: 2026-08-30

## Source concepts

The owner generated two logo concepts (both JPEGs in this folder, untracked in the
main working tree until now):

- `grok-image-299e0343-3c21-4068-9819-d4f5185cda2e.jpg` — a detailed cartoon mascot
  (muscular sumo wrestler + tan padlock + grey ring, dark blue-grey gradient
  background). Rich, but too detailed to read at 32px/16px. **Kept as reference art
  for marketing/store use, not used as the icon source.**
- `grok-image-b89c2f82-0acc-4776-b1ac-78ebd36e8f9d.jpg` — a flat, two-color mark: a
  dark navy padlock (rounded-square body, arc shackle, keyhole) with a dark navy
  sumo silhouette braced against its right side, on a pale blue-grey background.
  **This is the one the app icon is built from** — it is a strong, simple
  silhouette that survives downscaling, unlike the mascot.

## Apple geometry used (verified, not guessed)

- **macOS `AppIcon.appiconset` image set**: idiom `mac`, sizes 16/32/128/256/512pt,
  each at scale 1x and 2x (10 images total: 16, 32, 32, 64, 128, 256, 256, 512,
  512, 1024 px). Source: Apple's Asset Catalog Format Reference, "App Icon Type"
  page —
  <https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/AppIconType.html>.
  This matches the `Contents.json` that already existed in this asset catalog
  before this change; only `filename` keys and the PNGs were added.
- **Canvas and icon shape**: the current HIG app-icons page —
  <https://developer.apple.com/design/human-interface-guidelines/app-icons> —
  gives a 1024×1024pt layout size for iOS/iPadOS/macOS icons, with the icon shape
  after masking being a rounded rectangle ("squircle"). That page's masking
  language (`"the system applies masking to produce rounded corners"`) describes
  the **modern Icon Composer pipeline**: you hand Icon Composer full-bleed square
  layers and *it* renders the rounded shape into the actual asset it produces.
  A **classic, non-Icon-Composer `AppIcon.appiconset`** — which is what this
  change ships (see "Icon Composer" section below) — is not re-masked by the
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

Given all three points, **this change ships the classic flat `AppIcon.appiconset`**
and leaves Icon Composer as an open follow-up — worth its own decision (and,
per this repo's convention, its own GitHub issue) once XcodeGen's `.icon`
handling and Icon Composer's back-deploy rendering both mature. It does **not**
touch `project.yml`'s `fileTypes`/`ASSETCATALOG_COMPILER_APPICON_NAME` — the
latter was already set to `AppIcon` before this change, so nothing there needed
editing.

## Colour decisions

- **Background**: the tile uses a **deepened shade of the mark's own navy**
  (sampled from the source art, then darkened ~38%), not the source's pale
  blue-grey page color. The pale background reads as weak/washed-out in a
  contact-sheet comparison against both a light Dock and a dark Dock — a fully
  opaque, richly saturated tile reads clearly against either, since the icon's
  own background occludes the Dock locally regardless of Dock theme. This also
  reads as more "vault-like" / confident for a security product.
- **Glyph**: the padlock + sumo mark is recolored to a warm off-white
  (`#F4F1EA`) rather than pure white, to avoid a clinical/sterile look and keep
  a faint tie to the tan tones of the mascot reference art.
- **Small sizes get different art, on purpose.** The full photographic mark
  (padlock + sumo) was rendered at 16/32/64px and looked at directly:
  - At **16px** it is an unreadable blob — the sumo silhouette and the lock's
    keyhole/shackle detail all collapse into noise.
  - At **32px** it is legible but visually congested — the sumo's raised arm
    reads as an ambiguous triangular notch next to the lock.
  - At **64px** it holds up reasonably well — lock and sumo are both
    recognizable, if a little busy.

  So sizes below 64px (`icon_16x16.png`, `icon_16x16@2x.png`, `icon_32x32.png`)
  use a **procedurally-drawn, padlock-only glyph** (`draw_padlock_glyph` in the
  script) instead of the photographic extraction — a simplified body + shackle
  + keyhole, redrawn as flat shapes so it stays crisp at 16px. This is normal,
  expected macOS icon practice (the asset catalog supports different art per
  size) — dropping the sumo at the smallest sizes is a deliberate simplification,
  not a bug.

## Regenerating

```
python3 design/logo/make-appicon.py \
    --source design/logo/grok-image-b89c2f82-0acc-4776-b1ac-78ebd36e8f9d.jpg \
    --out PassSumo/Resources/Assets.xcassets/AppIcon.appiconset \
    --preview design/logo/appicon-preview.png
```

Requires Python 3 + Pillow (no numpy). The script re-samples the source art's
two flat colors by quantization (no hardcoded pixel coordinates), so it keeps
working if the source JPEG is redrawn/replaced with a similarly flat,
two-color mark. It writes the full `.appiconset` (10 PNGs + `Contents.json`)
and a labelled contact-sheet preview PNG for quick visual review without
opening Xcode.

## Verification

`cd PassSumo && make generate && make debug` builds clean with the new icon
wired in via the asset catalog's existing `ASSETCATALOG_COMPILER_APPICON_NAME:
AppIcon` setting (already present in `project.yml` before this change). The
rendered icon was extracted from the built app and viewed directly (including
the 16px and 32px sizes specifically) to confirm it is centered, not clipped,
and legible — see this change's commit/PR description for what was observed.
