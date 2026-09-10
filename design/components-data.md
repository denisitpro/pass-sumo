# Components — data display

> Status: living · Last verified: 2026-09-10 · [AI - claude-opus-5]

The rows and readouts that show vault contents. Token values are in `design/BRAND.md`.

## Field row (`FieldRow`)

**Purpose.** Every "label / value / actions" line in the detail pane is one of these, so the reveal
and VoiceOver rules are enforced once instead of once per field.

**Anatomy.** Three columns, baseline-aligned, `space-5` apart: the label in `caption`/`text-2` at a
fixed `field-label-width`; the value filling the rest; then the reveal glyph (if the field is a
secret) and the copy glyph (if the field is copyable), in that order.

**States.**

| State | Treatment |
|---|---|
| default | value in `body` (`monoBody` when `isMonospaced`), colour `text` |
| link | value in `accent-700`. Presentation only — the row is not clickable; the button that opens the URL sits beside the row in `EntryDetailView` |
| concealed | a **fixed** run of dots in the value's own face — never `value.count` dots, because a password's length is itself worth not leaking to a shoulder-surfer |
| revealed | the real value, `textSelection` enabled, wrapping allowed |
| empty | an em dash in `text-3` |

`hover`, `pressed`, `selected`, `error` and `loading` do not apply — the row is not a control; its
buttons are, and they carry their own states.

**Rules.**

- A field is a secret exactly when `isRevealed` is non-nil. There is no other switch.
- Label + value form **one** accessibility element; the glyph buttons stay outside it so each stays
  individually reachable by identifier. See `design/accessibility.md`.
- Where the mockup and the code differ: the mockup's Metadata UUID row overrides the value to
  `caption2`/`text-2`; the code renders it at `monoBody`/`text` like any other monospaced field.

## Entry list row (`entryRowSurface` + `EntryListView.row`)

**Purpose.** One entry in the middle column. Dense on purpose: hundreds of entries is the expected
scale.

**Anatomy.** Fixed `row-entry-h` height, `space-5` horizontal padding. A two-line stack — title in
`body`, username beneath in `caption2` — then a trailing "has a one-time code" clock glyph when the
entry carries an `otpAuthURL`. The username line is omitted entirely when empty rather than left as
blank space.

**States.**

| State | Treatment |
|---|---|
| default | `surface` ground, title `text`, sub-line `text-2`, glyph `text-3` |
| hover | `sunken` ground |
| selected | `row-sel-bg` ground; title, sub-line and glyph all take `row-sel-text`, and the title steps to `bodyMedium` |
| separator | a `border` hairline on the bottom edge, **inset** to the row's leading padding and run to the pane's trailing edge; suppressed on the last row |
| empty (the list, not the row) | see Empty states below |

`pressed`, `disabled`, `error` and `loading` do not apply.

**Rules.**

- The row draws its own ground, height, padding and hairline, so `List` must contribute none of them
  — pair it with `.listRowInsets(EdgeInsets())`, `.listRowSeparator(.hidden)` and
  `.listRowBackground(Color.clear)`.
- The double-click that opens an entry must be a `.simultaneousGesture`. `List(selection:)` already
  owns a click gesture on macOS, and an exclusive gesture competes with it and can silently swallow
  the double-click. Verified empirically.
- Settled: `List(selection:)` does not paint its native highlight over the custom selected ground —
  the row's own `row-sel-bg` is what renders, for `.plain` and `.sidebar` alike. Verified empirically;
  see `claude-memory/pass-sumo-list-and-toolbar-verified.md`.

## Sidebar row (`sidebarRowSurface` + `GroupSidebar.sidebarRow`)

**Purpose.** "All Entries" and each group, with its own entry count.

**Anatomy.** Fixed `row-sidebar-h` height, `space-3` horizontal padding, radius `sm`. Icon in
`caption`, label in `body`, then the count in `monoCaption2` pushed to the trailing edge.

**States.**

| State | Treatment |
|---|---|
| default | transparent ground, label `text`, icon and count `text-2` |
| hover | `sunken` ground |
| selected | `row-sel-bg` pill; label, icon and count all `row-sel-text`, label in `bodyMedium` |
| muted | the recycle bin only: label `text-2`, icon and count `text-3` |

**Rules.**

- **The recycle bin is deliberately not styled like the folders around it** — it is the one group
  whose contents are not live credentials, and a user who cannot tell it apart at a glance is
  exactly the user who copies a password out of it. It gets the trash icon, the muted treatment, and
  is the only row offering "Empty Recycle Bin".
- The count is direct membership only, matching what selecting the row actually reveals; "All
  Entries" counts live entries, excluding the bin, so a delete visibly changes the number.
- The mockup uses `text-3` for `.side-row .count`; the code uses `text-2`, because `text-3` does not
  clear WCAG AA on the `sidebar` ground. See `design/accessibility.md`.

## TOTP readout (`TOTPView`)

**Purpose.** The current one-time code for an entry, refreshed once a second.

**Anatomy.** An inset well (`sunkenWell`) rather than another field row — the code is the only value
on the screen that expires, and the well plus the countdown is what says so. In one row: a
"One-time" label in `caption`/`text-2`; the code in `monoTitle3`/`text`, digit-grouped at the
midpoint with `space-1` tracking; a linear progress bar `space-10` wide; the remaining seconds in
`monoCaption`/`text-2`; a copy glyph.

**States.**

| State | Treatment |
|---|---|
| running | progress tinted `accent-600` |
| expiring | at 5 seconds or fewer, progress tinted `totp-expiring` |
| unavailable for one tick | the code renders as six middle dots rather than crashing |
| parse failure | an "Invalid one-time code" label with a warning triangle, tinted `warning`; the well is not drawn |

**Rules.**

- `TimelineView(.periodic)`, never a hand-rolled `Timer`: SwiftUI already suspends its scheduling for
  occluded and inactive windows, so the HMAC stops being recomputed for a code nobody can see, with
  no lifecycle code of our own to get wrong.
- Copy puts the value **already computed for this tick** on the clipboard, so the copied string
  always matches what is on screen even if the click lands on a period boundary.
- Where the mockup and the code differ: the mockup's well carries a second line, `.otp-meta`
  ("SHA1 · 6 digits · 30s"), which the app does not render — machinery the mockup shows and the code
  hides. The label is also "One-Time Password" over two lines in the mockup, "One-time" in the code.

## Password-strength meter

**Purpose.** A rough, honest indicator beside a password the user typed.

**As implemented:** a continuous `ProgressView` tinted from the strength ramp, plus a monospaced
`caption2`/`text-3` caption that always qualifies the number ("rough guide"). Two private copies
exist, in `WelcomeView` and in `EntryEditView`, and their thresholds disagree.

**As drawn in the mockup:** a four-segment bar plus a one-word verdict plus a separate entropy line.

This is the largest open component decision in the system, including which thresholds are right and
why `strength-good` is currently unused. Do not resolve it in prose — issue #61.

## Attachment row

**Purpose.** One attachment of an entry: what it is, how big, and the ways out.

**Anatomy.** Paperclip glyph in `caption`/`text-2`, name in `body`/`text`, byte count in
`monoCaption2`/`text-3`, then the export glyph and — in the edit sheet only — the destructive remove
glyph. Export always precedes remove: the destructive control must not be the first thing under the
cursor on a row whose other action is harmless.

**States.** Export is disabled when the payload cannot be resolved from the pool. A PNG or JPEG under
the preview ceiling renders an inline thumbnail beneath the row, clipped at radius `xs`; anything
else simply gets no picture and is still listed, sized and exportable. A failed export appends a
`danger` line under the section.

Which payloads are decoded at all is `AttachmentPreviewPolicy`'s security decision, not a
presentation one — read it before widening anything.

## Empty states

Every empty state in the app is a `ContentUnavailableView` in `text-2` on `surface`: a title, an SF
Symbol, and one sentence.

| Where | Title | Sentence |
|---|---|---|
| No entry selected (inspector) | "No Entry Selected" | "Choose an entry from the list." |
| Group has no entries | "No Entries" | "This group has no entries yet." |
| Search matched nothing | "No Results" | names the query |

An empty field inside a row is an em dash, not an empty state.
