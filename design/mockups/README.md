# design/mockups/

> Status: frozen · Last verified: 2026-09-09 · [AI - claude-opus-5]

> **Decided 2026-09-09: palette C — "Steel Cyan" — is approved (issue #56).** The token values now
> live in `design/BRAND.md`, mirrored in `PassSumo/Sources/UI/DesignTokens.swift`. This folder is
> the record of how the choice was made, not a place to read a value from.

Self-contained HTML mockups, reviewed and signed off before any SwiftUI is written (see
`design/README.md` for how this folder fits the rest of `design/`).

## `palette-variants.html`

A **pre-approval palette review** for issue #3. It renders one set of screens three times over,
once per candidate palette, so the choice can be made on the real screen density rather than on
swatches:

- **Palette A — "Vault Navy"** · deep navy on warm paper, taken from the app icon.
- **Palette B — "Signal Blue"** · a true signal blue on cool white, closest to platform-native.
- **Palette C — "Steel Cyan"** · blue pushed toward cyan, instrument-panel and technical.
  **← approved.**

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
**Palette C** (the approved one) / Vault.

### Not a token source

The palette IS decided now, but this file is still not where a value is read from. `design/BRAND.md`
owns the token values — the merge of this file's shared `:root` block with its
`:root[data-palette="C"]` override — and `PassSumo/Sources/UI/DesignTokens.swift` is the
hand-written Swift mirror of that. Copying a hex out of the CSS below instead would create a second
owner for the same fact, which is the one thing the token layer exists to prevent.

The page defaults to palette C for the same reason, and carries a banner saying so.

### Contrast

The Tokens screen computes every contrast ratio live in the page. `--warning` and `--text-3` were adjusted on 2026-09-09 to clear WCAG AA 4.5:1 for normal text after the first render measured them at 4.4:1 and ~3.1:1 respectively. `--text-3` is therefore safe for captions and metadata rather than only for placeholder text.

### Archive when

`design/design-system.md` exists (issue #3) and documents the components this page prototypes. The
palette question itself is closed; what keeps the file alive until then is that it is currently the
only rendering of the target screens. After that it is history, not reference.
