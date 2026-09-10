# Components — controls

> Status: living · Last verified: 2026-09-10 · [AI - claude-opus-5]

The things the user operates. Implemented in `PassSumo/Sources/UI/DesignStyles.swift` and
`MasterPasswordField.swift`; token values are in `design/BRAND.md`.

## Buttons

**Purpose.** Five roles, distinguished by weight, not by colour alone. A role is chosen by what the
button *does*, never by where it sits.

**Anatomy.** Label (a `Text`, or a `Label` with an SF Symbol) inside a continuous rounded rectangle:
`space-5` horizontal padding, `space-2` vertical, radius `sm`, a `hairline` border in every role
(`.clear` where the role has no visible edge), the `bodyMedium` face.

**States.** All five share one surface, `TokenButtonSurface`, so no role can drift:

| State | Treatment |
|---|---|
| default | role's fill / border / label |
| hover | role's hover fill / border / label |
| pressed | **the same as hover** — deliberate: the mockup defines a hover treatment and no pressed one, and reusing hover avoids inventing a third appearance |
| disabled | the whole surface at `control-disabled-opacity`, hover suppressed |
| focus | the same `accent-200` ring at `focus-glow-width` the text field draws on focus, via the shared `focusRing` modifier; orthogonal to hover/pressed, so a focused-and-hovered control shows both |

`loading`, `selected`, `error` and `empty` do not apply: no button in the app carries a spinner (a
`ProgressView` is placed beside it instead — see `design/screens.md`), and none is a toggle.

**Roles and tokens.**

| Role | Fill → hover | Border → hover | Label → hover | Use |
|---|---|---|---|---|
| `PrimaryActionButtonStyle` | `accent-600` → `accent-700` | same as fill | `white` | The one committing action on a screen |
| `SecondaryActionButtonStyle` | `surface` → `sunken` | `border-strong` | `text` | A real action that is not *the* action: Cancel, Copy, Regenerate, Edit, Unlock with Touch ID |
| `QuietButtonStyle` | `.clear` → `sunken` | none | `text-2` → `text` | Dismisses or navigates: Close, a recent-database row |
| `DestructiveActionButtonStyle` | `surface` → `danger-bg` | `border-strong` → `danger` | `danger` | A delete stated in words |
| `GlyphButtonStyle` | `.clear` → `sunken` | none | `text-2` → `text` | Every glyph-only control: copy, reveal, export, open URL |
| `GlyphButtonStyle(isDestructive:)` | `.clear` → `danger-bg` | none | `text-2` → `danger` | A glyph that removes something |

**Rules.**

- **One accent-filled button per screen.** `BRAND.md`'s identity note: blue is the colour of
  confidence, spent on the single primary action, on selection, and on focus. Two primaries on one
  screen is a bug.
- **A destructive action is bordered, never filled.** A filled red button is the most clickable
  thing on screen, which is the opposite of what a delete should be.
- **Weight is relative, so it can be conditional.** `.actionButtonStyle(isPrimary:)` picks primary or
  secondary for a control whose importance depends on what sits beside it — the generator's Copy is
  the committing action when there is no Use, and secondary when there is.
- A glyph button is a square hit target of `glyph-button-size` at radius `xs`, so it stays a
  consistent size whatever symbol it carries.
- **A cell of the icon picker's grid is not one of the five roles**, and deliberately so: it needs a
  *selected* state, which no role has, because "which icon is in effect" is the one thing that grid
  has to show at rest. It borrows the glyph button's square and radius so it still measures like the
  rest of the app, and paints selection with `row-sel-bg` / `row-sel-text` — the same pair a
  selected row uses, rather than a sixth appearance invented for it. See `design/screens.md`.
- Adding a role means adding a `ButtonAppearance` value plus a two-line `ButtonStyle`. It never
  means editing the shared drawing code.

## Text field

**Purpose.** The chrome for text a user types. Applied through `.fieldChrome(isFocused:isError:)`.

**Why it is hand-drawn.** `.textFieldStyle(.roundedBorder)` renders a near-invisible hairline, which
was the owner's complaint in issue #32 — "the field is ugly, barely visible". The field owns its
ground, border and focus ring instead.

**Anatomy.** `surface` ground, radius `md`, `field-height` tall, `field` type in `text`, placeholder
in `text-3` supplied as a custom `prompt` (the system's default placeholder grey reads as a whisper).
A field with an inline trailing glyph reserves `field-glyph-inset` on that edge so typed text never
runs underneath it.

**States.**

| State | Treatment |
|---|---|
| default | `border-strong` border at `field-border-width` |
| focus | `accent-600` border at `border-focus-width`, plus an `accent-200` ring of `focus-glow-width` drawn outside the shape |
| error | `danger` border, at the resting weight |
| disabled | the control is `.disabled`; the chrome itself does not change |
| empty | placeholder in `text-3` |

The focus ring is an **inset stroke**, where the mockup writes a CSS spread shadow. Same intent,
different mechanism, unverified geometry (issue #66).

`MasterPasswordField`'s leading padding is `space-4`; the mockup's `.pw-field` uses 10, which is not
a step on the spacing scale. Honouring the scale won over matching the mockup exactly — recorded in
PR #59.

## Password field

**Purpose.** A master-password entry with a reveal toggle. Used on the unlock screen and for both
fields of the create-database sheet.

**Anatomy.** A `ZStack` of the field chrome above, plus the reveal glyph pinned inside the trailing
edge at `space-3`. `SecureField` and `TextField` are bound to the **same** string; revealing swaps
which control renders it and copies the password nowhere — `PasswordRevealState` holds a `Bool` and
nothing else.

**States.** The field's own states, plus concealed / revealed. In revealed mode
`.autocorrectionDisabled(true)` and `.textContentType(.password)` are set so no text-substitution
feature can silently rewrite a plaintext password; SwiftUI on macOS exposes no other knob for this.

**Rules.**

- Reveal is **per attempt and never sticky.** It resets to hidden when the app deactivates or the
  window loses key status — both, deliberately: over-hiding on an unrelated window's resign-key is a
  harmless false positive, under-hiding is the real risk.
- `PasswordRevealState` is a separate value type precisely so that rule is unit-testable without
  driving a real `NSWindow`.

## Reveal affordance

There are two, with the same visual treatment and different owners.

| Where | Control | Reset rule |
|---|---|---|
| `MasterPasswordField` | glyph button inside the field's trailing edge | on app deactivate or window resign-key |
| `FieldRow` | glyph button beside the value, after it and before Copy | on selection change and on lock, via `RevealPolicy` |

Both use the eye / eye-slash pair, `GlyphButtonStyle`, a `help` tooltip, and an
`accessibilityLabel` that names the action ("Reveal Password" / "Hide Password") — never the secret.

**Both were `Toggle(.button)` and are now plain `Button`s.** A button-styled toggle renders as a
filled, tinted control once on, which reads as an action of equal weight to the Copy button beside
it and, next to Unlock's primary styling, invites a misclick on the control that submits nothing.
`PasswordRevealState` and every accessibility identifier survived the change unaltered, which is why
`SecretHandlingTests` still finds them.
