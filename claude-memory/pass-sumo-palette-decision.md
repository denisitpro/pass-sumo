---
name: pass-sumo-palette-decision
description: Palette C ("Steel Cyan") is the approved palette; design/BRAND.md owns the token values, the ramp is light-only pending #57, and the mockup is no longer a token source.
metadata:
  type: project
---

Decided 2026-09-09 (issue #56, from the review in #54). None of this is visible from the code
alone, and the wrong half of it is very easy to guess.

- **Palette C — "Steel Cyan" — is approved.** The owner picked it from the three candidates in
  `design/mockups/palette-variants.html` over A ("Vault Navy", deep navy on warm paper, taken from
  the app icon) and B ("Signal Blue", closest to platform-native). Reason: the product deliberately
  shows its machinery, and a cyan-leaning instrument reading fits that better than a warm paper or
  a stock system blue. The choice is closed — do not re-open it or offer alternatives.
- **`design/BRAND.md` owns the token values.** Palette C is the merge of the mockup's shared
  `:root` block with its `:root[data-palette="C"]` override — BRAND.md is that merge written out,
  and `PassSumo/Sources/UI/DesignTokens.swift` is the hand-written Swift mirror of BRAND.md.
  `DesignStyles.swift` holds the button/surface/field/row styles. **Never read a hex out of the
  mockup**, and never put one in a view: the token file is the only place in the app target where a
  colour or dimension literal may live.
- **The ramp is light-only, on purpose.** Every token has exactly one value, so `PassSumoApp` pins
  both scenes to `.light`. Issue **#57** tracks the dark set and the removal of that pin. Do not
  "fix" the pin, and do not add a dark branch token by token — the dark values are meant to be
  decided as a set.
- **`text-3` (`#64777E`) is only safe on `surface`.** Measured: 4.69:1 on `surface`, but 4.46:1 on
  `canvas`, 4.25:1 on `sidebar`, 4.18:1 on `sunken` — all under WCAG AA. Anything quiet on those
  grounds uses `text-2`. Same reason the status bar tints only the warning ICON with `warning`
  (4.41:1 on `sidebar`) and keeps the sentence in `text`.
- **Still open: `design/design-system.md`** (component contracts, UX rules, keyboard map, the full
  accessibility pass) — issue #3. #56 deliberately did not write it.

**How to apply:** before any UI work in this repo, read `design/BRAND.md`, then consume
`Palette`/`Typography`/`Spacing`/`Radius`/`Metrics`/`Elevation` and the styles in
`DesignStyles.swift`. If a value you need is missing, add it to BRAND.md as a named token with a
stated role and flag it for the owner — never inline it. See also
[[pass-sumo-work-sequencing]] for what else was gated on this decision.
