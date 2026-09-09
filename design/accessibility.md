# Accessibility

> Status: living · Last verified: 2026-09-09 · [AI - claude-opus-5]

What the design guarantees, what the code already does, and what is honestly not handled yet.

## Contrast

**The rule, not the numbers.** `design/BRAND.md` owns every measured ratio; this file states the rule
those measurements produced and does not repeat a figure.

- `text` and `text-2` clear WCAG AA for normal text on **all four** grounds — `canvas`, `surface`,
  `sunken`, `sidebar`.
- **`text-3` clears AA on `surface` only.** It falls under AA on the other three. So `text-3` is for
  placeholders, captions and byte counts **on `surface`**; anything quiet on `canvas`, `sidebar` or
  `sunken` steps up to `text-2`.
- That is why two places deviate from the mockup on purpose: the sidebar row's entry count uses
  `text-2` where the mockup uses `text-3`, and the status bar's backup warning tints **only its
  icon** with `warning`, keeping the sentence in `text`. Both grounds are `sidebar`.
- Before using a semantic colour as *text*, check it against the ground it lands on. `warning` in
  particular does not clear AA on `sidebar`; `danger` is used for text on `surface` and `canvas`.
- **Colour is never the only signal.** The dirty flag pairs its dot with the words "Unsaved changes";
  the backup warning pairs its triangle with a sentence; the TOTP countdown has digits beside the
  bar; the strength meter has a bits caption beside the fill. A user who cannot distinguish the
  strength ramp still reads the number.
- The whole palette is light-only and the app pins itself to the light appearance, so no ratio in
  `BRAND.md` has a dark counterpart yet. Issue #57 decides the dark set — including re-measuring.

## Identifier convention

Every view that a test or an assistive technology needs to find carries an
`accessibilityIdentifier`, in a dotted namespace: **`<screen-or-area>.<element>`**, with the element
extended by a stable key when there are many.

| Prefix | Area |
|---|---|
| `root.*` | which top-level screen is mounted (`root.welcome`, `root.unlock`, `root.unlocking`, `root.browser`, `root.settings`) |
| `welcome.*` | Welcome and its create sheet, including `welcome.create.*` |
| `unlock.*` | the unlock screen |
| `browser.*` | the browser's panes, toolbar buttons and confirmation dialogs |
| `sidebar.*` | sidebar rows — `sidebar.allEntries`, `sidebar.recycleBin`, `sidebar.group.<uuid>` |
| `list.entry.<uuid>` | one entry row |
| `detail.*` | the detail pane, including `detail.attachment.<name>` |
| `edit.*` | the entry edit sheet, including `edit.removeAttachment.<name>` |
| `generator.*` | the generator sheet |
| `statusbar.*` | each status-bar slot |
| `settings.*` | Settings, including `settings.touchID.*` |

**Two rules about the key.** Entries and groups are keyed by UUID. Attachments are keyed by their
**name** — which KDBX already requires to be unique within an entry — and deliberately **never** by
the blob hash: putting a fingerprint of secret bytes into the accessibility tree would let anything
able to read that tree correlate the same file across vaults.

An identifier is part of the contract, not decoration: `SecretHandlingTests` finds the reveal
control by identifier, which is why PR #59 could change that control's *type* without touching its
identifier.

## VoiceOver

- **A field row is one element covering label and value.** Its label is the field's name; its value
  is the field's value — except that a concealed secret reports the literal word **"hidden"**, never
  the value and **never even its length**, and an empty field reports "empty". Getting that one line
  wrong reads a stored password aloud to anyone standing near the user.
- **The reveal and copy buttons stay outside that element**, so each remains individually reachable
  by its own identifier. Folding everything into a single element would swallow them.
- A glyph-only button names the **action**, never the content: "Reveal Password" / "Hide Password",
  "Copy Username", "Open URL", "Save attachment", "Remove attachment", "Copy one-time code". The
  reveal label flips with the state so it always describes what pressing it will do.
- The entry row's TOTP glyph is labelled "Has a one-time code"; without it, the row would announce a
  bare symbol.
- Every glyph button also carries `.help`, so the pointer user gets the same sentence as the
  VoiceOver user, from one string.

## Keyboard reachability

Full map in `design/keyboard-map.md`. What matters here:

- Every action has a menu-bar item, and every command that could act on nothing is **disabled**
  rather than left to no-op — so a keyboard user is never told an action is available when it is not.
- Arrow-key movement through the entry list and the sidebar comes from `List`'s own selection
  handling; Return opens the selected entry.
- Esc dismisses each sheet, via an explicit `.cancelAction` button — SwiftUI does not do it on macOS
  by itself.

## Not handled yet

Stated plainly rather than left to be discovered:

- **No focus indicator on any custom button.** The mockup defines a focus ring for `.btn` and
  `.icon-btn`; only the text field implements one. A keyboard user cannot see where focus is
  (issue #64).
- **No focus movement between panes.** Nothing takes focus from the sidebar to the list to the
  inspector.
- **Text does not scale.** The whole type scale is `.system(size:)`, so it ignores the system text
  size; and several layout widths are still fixed literals in views rather than tokens — the two
  sheet widths, the unlock card's content cap, the field-label column, the attachment preview box.
  Larger text would truncate rather than reflow. Making the app respond to text size is a real
  piece of work, not a modifier.
- **No heading semantics.** The detail pane's section headings and the sheet titles are plain `Text`;
  no `.accessibilityAddTraits(.isHeader)` anywhere, so VoiceOver's heading rotor cannot navigate a
  long entry.
- **No hints.** No `accessibilityHint` is set anywhere; labels carry the whole burden.
- **Two controls have no accessible name at all**: the entry-edit sheet's password reveal glyph
  (it carries `.help` but no `accessibilityLabel`) and its custom-field remove glyph (neither label
  nor identifier). Both are in the one screen that has had no design pass (issue #63).
- **No reduced-motion or increased-contrast handling** — the app declares no animations at all today,
  so there is nothing to reduce, but neither is `.accessibilityReduceTransparency` or the increased
  contrast setting consulted anywhere.
- **English only.** Every string is a literal in a view; localization is issue #46.
- **Not audited with VoiceOver.** The rules above are what the code declares. Nobody has driven the
  app with the screen reader on, and the e2e suite has never run (issue #6).
