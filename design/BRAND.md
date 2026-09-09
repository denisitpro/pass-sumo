# pass-sumo — brand & design tokens

> Status: living · Last verified: 2026-09-09 · [AI - claude-opus-5]

This file owns the token VALUES. Nothing else in the repo restates them: the Swift mirror
(`PassSumo/Sources/UI/DesignTokens.swift`) is the only other place they are written down, and it is
a hand-maintained mirror of the tables below — a value change edits both in the same PR.

## Identity — the things an AI guesses wrong

- The product is **pass-sumo** (repo, docs, marketing); the app bundle, window title and
  `CFBundleName` are **PassSumo**. Never "PassSumo App", never "Pass Sumo".
- The palette is **deliberately light**. Every token has exactly one (light) value and the app pins
  itself to the light appearance until issue #57 lands a dark ramp. Do not add a dark variant, and
  do not "fix" the pin.
- **Blue is the colour of confidence** — the accent exists to say "this is safe, this is
  deliberate", not to decorate. It is spent on the one primary action per screen, on selection, and
  on focus. A screen with two accent-filled buttons is a bug.
- The chosen variant is **C — "Steel Cyan"**: blue pushed toward cyan, instrument-panel and
  technical. Approved by the owner on 2026-09-09 from the three candidates in
  `design/mockups/palette-variants.html` (#54, review of #3) — chosen over A ("Vault Navy", warm
  paper) and B ("Signal Blue", platform-native) because the product deliberately shows its
  machinery, and a technical instrument reading fits that better than a warm or a stock-blue one.
- The app is dense on purpose: the target user manages hundreds of entries. Row heights and the
  13px body size below are the density decision, not a starting point to be loosened.

## Accent ramp

| Token | Hex | Used for |
|---|---|---|
| `accent-50` | `#ECF6F9` | tinted hover ground on a bordered accent button |
| `accent-100` | `#D2E9EF` | (= selection ground, see below) |
| `accent-200` | `#A4D4DF` | focus glow around a focused field/button |
| `accent-300` | `#6CB7C8` | border of a hovered accent button |
| `accent-400` | `#3A96AB` | — |
| `accent-500` | `#1B7A90` | — |
| `accent-600` | `#14657A` | **the accent**: primary button fill, focus ring, caret, progress fill, tint |
| `accent-700` | `#0F5163` | primary button hover fill, link text, selected-row text |
| `accent-800` | `#0B3E4C` | — |
| `accent-900` | `#072C36` | — |

## Neutrals

| Token | Hex | Used for |
|---|---|---|
| `canvas` | `#F6FAFA` | the ground behind a centred card (Welcome, Unlock, sheet stage) |
| `surface` | `#FFFFFF` | cards, sheets, the entry list, the detail pane |
| `sunken` | `#EDF3F4` | inset wells: search field, OTP card, generator result, hover ground |
| `sidebar` | `#EFF5F5` | the group sidebar, the toolbar, the status bar |
| `border` | `#DAE4E6` | hairlines: pane dividers, row separators, card edges |
| `border-strong` | `#BFCED1` | control edges: field border, secondary button border, toolbar separator |

## Text

| Token | Hex | Role |
|---|---|---|
| `text` | `#10242A` | primary content |
| `text-2` | `#4E6169` | field labels, secondary metadata, quiet button labels |
| `text-3` | `#64777E` | placeholders, captions, sizes, byte counts, monospace detail |

**Accessibility rule, from the contrast audit:** `text-3` is legible on `surface` (4.69:1) but
marginally under AA on `canvas` (4.46:1) — **use it on surfaces only, never on the canvas ground.**
Re-measured 2026-09-09 while writing the Swift mirror, the same ceiling applies to the other two
grounds: `sidebar` 4.25:1 and `sunken` 4.18:1. So `text-3` is for captions and metadata **on
`surface`**; anything quiet on `canvas`, `sidebar` or `sunken` uses `text-2` (5.8–6.2:1) instead.
`text` and `text-2` clear AA on every ground.

`warning` is 4.41:1 on `sidebar`, so the status bar carries it as an **icon** tint only, with the
sentence itself in `text` — the same reason.

## Selection

| Token | Hex | Role |
|---|---|---|
| `row-sel-bg` | `#D2E9EF` | selected row ground (sidebar and entry list) |
| `row-sel-text` | `#0F5163` | selected row label, its icon and its count |

## Semantic — shared by all three candidate palettes

| Token | Hex | Token | Hex |
|---|---|---|---|
| `success` | `#157F4F` | `success-bg` | `#E6F4EC` |
| `warning` | `#A06400` | `warning-bg` | `#FBF1DE` |
| `danger` | `#B3261E` | `danger-bg` | `#FBE9E7` |
| `strength-weak` | `#C0392B` | `strength-fair` | `#C77D0A` |
| `strength-good` | `#2A7F62` | `strength-strong` | `#157F4F` |
| `totp-expiring` | `#C0392B` | `white` | `#FFFFFF` |

## Type scale

`--font-sans` is the system UI face (`-apple-system` / SwiftUI's default); `--font-mono` is the
system monospace face (`ui-monospace` / SF Mono). Weights in use: 400, 500, 600 — nothing bolder.

| Token | Size / line height | Role |
|---|---|---|
| `caption2` | 11 / 14 | byte counts, entropy, path in the status bar, sub-line of an entry row |
| `caption` | 12 / 16 | field labels, section headings, placeholders |
| `body` | 13 / 18 | the default; entry titles, button labels, field values |
| `field` | 15 / 20 | text a user types: the master-password field, the generated password |
| `headline` | 17 / 22 | sheet titles, the database name on the unlock screen |
| `title3` | 20 / 25 | the entry title in the detail pane, the OTP code |
| `title2` | 24 / 29 | the app name on the Welcome screen |

Line heights are recorded because the mockup sets them; SwiftUI's `Text` has no equivalent knob at
this level, so the Swift mirror carries the sizes only.

## Spacing

`2 · 4 · 6 · 8 · 12 · 16 · 20 · 24 · 32 · 40` — `space-1` … `space-10`, in that order. Nothing
between the steps, and nothing above 40.

## Radii

`xs` 4 · `sm` 6 · `md` 8 · `lg` 10 · `pill` 999.

`xs` for chips and thumbnails, `sm` for buttons and inset wells, `md` for text fields, `lg` for
cards/sheets/the window, `pill` for progress tracks.

## Structural sizes

| Token | Value |
|---|---|
| `hairline` | 1 |
| `border-focus-width` | 2 |
| `row-entry-h` | 34 |
| `row-sidebar-h` | 26 |
| `toolbar-h` | 44 |
| `statusbar-h` | 26 |

Entry-row separators are **inset**: the hairline starts at the row's leading padding
(`space-5` = 12), not at the pane edge.

Control sizes the mockup pins in its component CSS but does not name in its `:root` block. Named
here so the views never carry them as literals:

| Token | Value | From |
|---|---|---|
| `focus-glow-width` | 3 | `.btn:focus-visible` / `.pw-field.is-focused` box-shadow |
| `field-border-width` | 1.25 | `.pw-field` border |
| `field-height` | 38 | `.pw-field` |
| `field-glyph-inset` | 34 | `.pw-field` padding-right, room for the reveal glyph |
| `glyph-button-size` | 24 | `.icon-btn` |
| `field-label-width` | 90 | `.field` grid's first column |
| `hero-glyph-size` | 40 | `.big-lock`, the glyph heading a centred card |

**`control-disabled-opacity` = 0.4 has no counterpart in the mockup.** The mockup draws no disabled
state, and a custom SwiftUI `ButtonStyle` gets no automatic dimming, so a disabled primary action
would otherwise look pressable. It is the one invented value in the set; the full design system
(issue #3) should decide it properly.

## Elevation

All three are the same ink, `#101828`, at three opacities:

| Token | Value |
|---|---|
| `shadow-card` | `0 1px 2px` at 6% + `0 1px 3px` at 10% |
| `shadow-sheet` | `0 12px 32px` at 18% |
| `scrim` | flat fill at 16% |

CSS blur radius and SwiftUI's shadow `radius` are not the same quantity; the mirror keeps the same
numbers rather than inventing converted ones.

## Where these come from, and where they go

- Approved visual target: `design/mockups/palette-variants.html`, palette C — the merge of its
  shared `:root` block with `:root[data-palette="C"]`. That file stays as the three-way record; this
  file is the token source of truth.
- Swift mirror: `PassSumo/Sources/UI/DesignTokens.swift` (raw values, the only file in the app
  target allowed a colour or dimension literal) and `PassSumo/Sources/UI/DesignStyles.swift` (the
  button/surface/field/row styles that consume them).
- Still to come, deliberately not here: `design/design-system.md` — component contracts, UX rules,
  the keyboard map, and the full accessibility pass (issue #3).
