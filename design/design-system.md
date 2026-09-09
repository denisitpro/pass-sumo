# pass-sumo — design system

> Status: living · Last verified: 2026-09-09 · [AI - claude-opus-5]

The component contracts, screen patterns, UX rules, keyboard map, accessibility rules and tone of
voice for the macOS app. Written against the code in `PassSumo/Sources/UI/` and
`PassSumo/Sources/App/` as it stands, not against a target: where the code and the approved mockup
disagree, the disagreement is recorded with the file that shows it, never smoothed over.

## What owns what

- **`design/BRAND.md` owns every token VALUE** — hexes, sizes, the type scale, the spacing scale,
  radii, structural sizes, elevation, and the contrast measurements. Nothing in this system
  restates one. These documents name tokens (`accent-600`, `space-5`, `field-height`) and leave the
  reader to open `BRAND.md` for what they are.
- **`PassSumo/Sources/UI/DesignTokens.swift`** is the hand-written Swift mirror of those values and
  the only file in the app target allowed a literal. **`DesignStyles.swift`** is the component layer
  the contracts below describe.
- **`design/mockups/palette-variants.html`** (palette C) is the approved visual reference for four
  screens: Vault, Unlock, Generator, Tokens. It is frozen — a record of how the palette was chosen,
  not a token source.

## The invariant

One canonical token layer, hand-mirrored into Swift, no codegen. A value change edits `BRAND.md`
**and** `DesignTokens.swift` in the same PR. Views consume named tokens and never a raw value. A
token the spec needs but the scale lacks is **added to the scale**, never invented at a call site —
see `~/.claude/playbook/design.md`.

## The documents

| File | Answers |
|---|---|
| `design/components-controls.md` | The buttons, the text/password field, the reveal affordance: roles, states, tokens |
| `design/components-data.md` | The rows and readouts: field row, entry row, sidebar row, TOTP, strength meter, attachment row, empty states |
| `design/components-chrome.md` | The window's surfaces and bands: card, sunken well, toolbar, status bar, sheets |
| `design/screens.md` | How the real screens are assembled, and the empty/error states each one has |
| `design/ux-rules.md` | The decisions a contributor would otherwise re-litigate: reveal vs copy, clipboard, auto-lock, destructive confirmation, dirty/save, backup failure |
| `design/keyboard-map.md` | Every binding that exists in the source, and the gaps |
| `design/accessibility.md` | Contrast rules, the `accessibilityIdentifier` convention, keyboard reachability, what is not handled |
| `design/tone-of-voice.md` | How the app's own strings are worded, including the error rule |

**Why split, and why this cut.** The docs convention caps a living document at 200 lines, because
the cap bounds the blast radius of a diff: an edit to one subject should not land inside a file that
is 90% unrelated. The cut follows who edits what — a new button role touches only
`components-controls.md`; a new screen touches only `screens.md`; a shortcut audit (issue #16)
touches only `keyboard-map.md`. Components are three files rather than one because together they
are well over the cap, and they split cleanly by the layer of the window they live in: things the
user operates, things that display vault data, and the window's own chrome.

## Reading order

Start here, then open the one file the table points at. Read `BRAND.md` first only if you need a
value. `PassSumo/Sources/UI/DesignStyles.swift` is the shortest complete statement of what exists;
the contracts describe it, they do not replace it.

## Deliberately not here

- **A dark ramp.** Every token has exactly one, light value and the app pins itself to the light
  appearance. Issue #57 decides the dark set as a set.
- **Token values.** `BRAND.md`.
- **New mockups.** The approved mockup covers four screens; Welcome, the entry-edit sheet and
  Settings have no approved visual target (issue #63).

## Open questions, filed rather than guessed

| Question | Issue |
|---|---|
| What the disabled state actually looks like — `control-disabled-opacity` is the one invented token | #60 |
| The password-strength meter: the mockup's segmented bar vs the shipped `ProgressView`, and two different threshold sets | #61 |
| The unlock screen never says why the vault locked, though the reason is recorded | #62 |
| No approved mockup for Welcome, the entry-edit sheet, or Settings | #63 |
| Keyboard focus is invisible on every custom button style | #64 |
| Custom fields have no protected flag, so a secret custom field renders in plaintext | #65 |
| Two rendering assumptions from PR #59 are unverified and need an eyes-on pass | #66 |
