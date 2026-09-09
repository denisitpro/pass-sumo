# design/

> Status: living · Last verified: 2026-09-09 · [AI - claude-opus-5]

Single home for everything design-related: the design system, design tokens, UX guidelines,
mockups, competitor reference screenshots, and logo/icon source art. Add subfolders as needed;
this file tracks what exists.

Layout convention follows `~/.claude/playbook/design.md` (this owner's cross-repo method): a
`design/BRAND.md` quick-ref, a `design/design-system.md` full spec, a `design/tokens.json` if/when a
second platform needs to consume the tokens, and a `design/mockups/` of self-contained HTML screens
signed off before any SwiftUI is written.

**One divergence from that method, per its non-blocking clause:** the full spec is not one
`design-system.md` but an index plus focused siblings, because a single document would be several
times the docs convention's 200-line cap. `design/design-system.md` is the entry point and owns the
justification for the cut.

## Files

| File | What it owns |
|---|---|
| `BRAND.md` | **Every token VALUE** — palette, type scale, spacing, radii, structural sizes, elevation, contrast measurements, and the identity notes an agent guesses wrong. Nothing else in the repo restates one |
| `design-system.md` | The index of the design system: what each document below answers, the token invariant, the reading order, and the open questions with their issue numbers |
| `components-controls.md` | Buttons, the text and password fields, the reveal affordance |
| `components-data.md` | Field row, entry list row, sidebar row, TOTP readout, strength meter, attachment row, empty states |
| `components-chrome.md` | Grounds, card surface, sunken well, toolbar, status bar, sheets, progress states |
| `screens.md` | How Welcome, Unlock, the browser, the generator, the edit sheet and Settings are assembled, with their empty and error states |
| `ux-rules.md` | Reveal vs copy, clipboard clearing, auto-lock, destructive confirmation, dirty/save, backup failure |
| `keyboard-map.md` | Every binding that exists in the source, plus the gaps and collisions |
| `accessibility.md` | Contrast rules, the `accessibilityIdentifier` convention, VoiceOver rules, keyboard reachability, what is not handled |
| `tone-of-voice.md` | How the app's own strings are worded, including the error-message rule |

## Subfolders

- `design/mockups/` — self-contained HTML screens. Holds `palette-variants.html`, the palette review
  that produced the approved variant C, now frozen as a record; see its own `README.md`.
- `design/logo/` — logo and app-icon source art, with its own `README.md`. Already in use.
- `design/reference/strongbox/` — competitor (Strongbox) reference screenshots, requested in
  issue #3, for information-architecture comparison only — not visual style or scope. Not yet
  populated; the owner captures these by hand (Strongbox is a native app with no UI-automation
  path).

## Boundary with `PassSumo/`

`design/` is a **repo-root** directory — the internal side of the line CLAUDE.md draws around
`PassSumo/` (the load-bearing rule: everything under `PassSumo/` must be publishable on its own).
Source art, working files, and UX/reference notes stay here. Only the assets the app actually
compiles from — e.g. the generated `AppIcon.appiconset` — live under `PassSumo/Resources/`. When
in doubt: if a future open-source consumer of just `PassSumo/` would need the file to build or run
the app, it belongs under `PassSumo/`; if it's source material, planning, or reference for
producing those assets, it belongs under `design/`.
