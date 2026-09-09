# design/mockups/

> Status: draft · Last verified: 2026-09-09 · [AI - claude-opus-5]

Self-contained HTML mockups, reviewed and signed off before any SwiftUI is written (see
`design/README.md` for how this folder fits the rest of `design/`).

## `palette-variants.html`

A **pre-approval palette review** for issue #3. It renders one set of screens three times over,
once per candidate palette, so the choice can be made on the real screen density rather than on
swatches:

- **Palette A — "Vault Navy"** · deep navy on warm paper, taken from the app icon.
- **Palette B — "Signal Blue"** · a true signal blue on cool white, closest to platform-native.
- **Palette C — "Steel Cyan"** · blue pushed toward cyan, instrument-panel and technical.

Four screens, switchable independently of the palette: **Vault** (the main three-pane window —
this is the screen that decides the palette), **Unlock** (default and wrong-password states side
by side), **Generator** (the sheet, with its open questions annotated), and **Tokens** (a live
reference sheet for whichever palette is selected, with contrast ratios computed in the page).

Light theme only. Dark mode is deliberately out of scope for this review.

### How to open it

Open the file directly in a browser — it needs no server:

```
open design/mockups/palette-variants.html
```

Zero network: all CSS, JS and SVG are inline, so it renders identically over `file://` and
offline. The selected palette and screen are remembered in `localStorage`, defaulting to
Palette A / Vault.

### Not yet a token source

**The palette is not decided.** Nothing — no SwiftUI colour set, no `design/tokens.json`, no
`design/design-system.md` — may consume the hex values in this file yet. It is a review artefact
for picking a direction; the picked palette becomes tokens in a separate, deliberate step once
issue #3 closes on a choice. The structural tokens (type scale, spacing, radii, hairline weights,
row heights, shadows) and the semantic colours are shared by all three variants and are the parts
least likely to change.

### Archive when

Issue #3 has settled on a palette and the decision has been written up as the design system. Keep
the file until then; after that it is history, not reference.
