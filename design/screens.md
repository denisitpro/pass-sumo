# Screen patterns

> Status: living · Last verified: 2026-09-09 · [AI - claude-opus-5]

How the real screens are assembled, and the empty and error states each one actually has.
Components are in `design/components-*.md`; token values in `design/BRAND.md`.

## The top-level switch

What is on screen is a **pure function of `VaultStore.state`** — there is no separate navigation flag
that could disagree with it:

| State | Screen |
|---|---|
| `.empty` | Welcome |
| `.locked(url)` | Unlock |
| `.unlocking` | the unlocking indicator |
| `.unlocked` | the browser |

A file the user just picked reaches `.locked` through `VaultStore.select(url:)`, so nothing is held
beside the store waiting to be reconciled with it. Settings is a separate scene, not a state.

The window's minimum is sized for the browser — the shell's steady state. Welcome and Unlock are
small and simply centre themselves in whatever that establishes.

## Welcome

**Purpose.** The first thing a user with no database open sees.

**Assembly.** One `cardSurface` centred on `canvas`, `space-10` padding: a `hero-glyph-size` lock
glyph in `accent-600`, the product name in `title2`, then **two buttons and nothing else** — "Open
Database…" (primary) and "Create New Database…" (secondary). Beneath them, when there are any, a
"Recent" caption and one `QuietButtonStyle` row per recent database, each a clock glyph and the
filename, capped at a readable column width.

**Restraint is the specification.** No onboarding carousel, no upsell banner, no third action. A
third action added here later is a decision that needs its own justification, not a natural
extension.

**Error state.** A picker failure renders as one `danger` line in `body` under the buttons.

**Empty state.** No recents section at all — the app does not draw an empty list.

**The create sheet.** Master password twice, a strength meter (only when the Settings toggle is on
and the field is non-empty), a mismatch line, an error line, an in-flight spinner, then Cancel /
"Choose Location & Create…". The password is collected **before** the save panel appears, so
cancelling out of the password step never has to also undo a file the user already named.

**Never a pre-set default path.** Both the open panel and the save panel always ask. A sibling app
was rejected under App Review Guideline 2.4.5(i) for shipping a file-access entitlement backed only
by a remembered path with no picker in the flow; a user-driven `NSOpenPanel` is what justifies this
app's file entitlement to a reviewer.

## Unlock

**Purpose.** Unlock one database, however the store got here — a file just picked, a wrong password,
or a lock.

**Assembly.** One `cardSurface` on `canvas`, capped at a fixed content width and centred: a
`hero-glyph-size` lock glyph in `text-3`; the filename in `headline`; **the full path** in
`monoCaption`/`text-3`, middle-truncated; then the password field and the "Unlock" primary button
**side by side** in one row.

The path is deliberate: this user wants to know exactly which file on disk they are about to
decrypt, not have it hidden behind a friendly display name. The field sits next to the button that
submits it because a `Spacer()` used to pin "Unlock" to the far edge of a wide window, metres from
the field (issue #32).

**Error state, two lines.** The message in `body`/`danger` — a sentence the user can act on — and,
separately, the library's own words in `monoCaption2`/`text-3`, selectable so they can be pasted into
a bug report. A wrong password **never clears the field**.

**Touch ID.** Two mutually exclusive affordances:

- **"Remember with Touch ID"**, a checkbox, shown only when the hardware is available and this
  database has no stored secret. A checkbox rather than a post-unlock prompt because `submit()`
  already has the typed password in scope, so the secret never has to cross a view boundary; and
  because a checkbox is non-blocking by construction.
- **"Unlock with Touch ID"**, a secondary full-width button, shown only when a secret *is* stored for
  this database.

The mockup draws both at once. The code shows exactly one, because the conditions are complements.

**In-flight.** A small spinner; the field and both Touch ID controls disable.

**Not shown:** why the vault locked. The reason is recorded and never read (issue #62).

## The browser

**Purpose.** The screen the user lives in. Everything else is a doorway into or out of it.

**Assembly. Two `NavigationSplitView` columns plus an inspector, not three columns.**
`columnVisibility` on macOS only ever controls the *leading* columns, so a third `detail:` column had
no first-class show/hide — which was exactly the owner's complaint ("the sidebar collapses, why
doesn't the right pane?"). Entry detail is `.inspector(isPresented:)` instead, which brings a
system-provided toggle, a place to hang it in the toolbar, and a shortcut (issue #49).

- **Sidebar** — "All Entries" plus the group outline, on `sidebar`. `List(selection:)` with
  `.listStyle(.sidebar)` and the scroll background hidden so the band's tone shows.
- **List** — the filtered entries on `surface`, `.listStyle(.plain)`. The search field is
  `.searchable(placement: .toolbar)`.
- **Inspector** — the detail pane on `surface`: a header (title in `title3` plus an Edit secondary
  button), the five standard field rows, the TOTP well, then Custom Fields, Attachments and Metadata,
  each behind a section heading — a `captionMedium` in `text-2` over a `border` hairline.
- **Status bar** — a bottom `safeAreaInset`.

**Filtering.** The group filter and the search query compose as an **intersection**, never
"search wins". Search deliberately matches the password field too. The list hides the recycle bin
unless the bin itself is what is selected. Order is alphabetical by title, case-insensitive,
tie-broken by id — a dense list scanned by eye needs a stable order far more than a recency one.

**Empty states.** "No Entries" for an empty group, "No Results" naming the query, "No Entry Selected"
in the inspector. All three are `ContentUnavailableView`s.

**Error states.** The browser itself surfaces none inline: a backup failure goes to the status bar, a
failed attachment export to a `danger` line inside the Attachments section, and a lock that arrives
mid-render degrades to an empty vault rather than a crash.

**Selection coupling.** The browser owns `selectedGroupID`, `selectedEntryID` and `searchText`
because a group change has to clear the entry selection; a selection that no longer appears in the
visible list is cleared, so the inspector never shows an entry the user cannot see selected.

## Generator sheet

**Purpose.** Produce one password. Opened from the toolbar, or from the edit sheet's "Generate…".

**Assembly.** Title in `headline`; the result in `monoField` inside a `sunkenWell`, selectable; a
length slider with its value in the label above; five toggles; the entropy line in
`monoCaption2`/`text-3`; a `border` divider; then Regenerate on the left and Close / Copy / Use on
the right; and last, one line stating the live clipboard-clear interval.

**"Use" exists only where there is something to use it on.** From the edit sheet it fills the
password field; from the toolbar there is no field, so `onUse` is `nil` and the button is **hidden
entirely** rather than offered as a second button doing exactly what Copy does with nothing on
screen saying so (issue #45). Copy is therefore primary when it is alone and secondary when Use is
beside it.

**Regeneration is automatic.** Any recipe change redraws the password immediately — a stale result no
longer matching the controls is worse than an extra regeneration.

**Error state.** An impossible recipe (no character class, or a length too short to include one of
each) replaces the result with a `caption`/`danger` sentence naming the fix.

**Where the mockup and the code differ:** the mockup puts a Regenerate glyph inside the result well,
labels the slider's ends, and renders strength as a segmented bar with a verdict word (issue #61).

## Entry edit sheet

**Purpose.** Edit one entry, or create one — the same form, distinguished only by its title and by
whether Save inserts.

**Assembly.** A `Form(.grouped)` with a native cancel/confirm toolbar: identity fields, then Notes,
One-Time Password, Custom Fields and Attachments as titled sections. It consumes the token layer for
type, colour and its glyph buttons, but not the field chrome or the worded button roles, so it is the
one screen that does not yet look like the rest of the app. No approved mockup exists (issue #63).

**The state that matters.** If the vault locks while this sheet is open, `VaultStore.upsert` would
silently no-op — the user would hit Save, watch the sheet close, and lose the entry. So the sheet
watches the store, and on leaving `.unlocked` shows a `danger` banner ("The vault locked while you
were editing. This entry was NOT saved.") and disables Save. It does not pretend to succeed, and it
does not yet recover the typed text into a new attempt — that needs an encrypted holding area, which
is a feature, not a UI tweak.

**Error states.** A refused attachment (too large, unreadable, batch too large) appends a `danger`
line naming the file and the limit; a failed export replaces it with its own sentence.

## Settings

**Purpose.** Four knobs, no more. This screen is itself part of the positioning: there is no
accounts, cloud or purchases section, because v1 has none of those, and adding one "just in case"
would be the feature creep the product is positioned against.

**Assembly.** A `Form(.grouped)` on `canvas` at a fixed size: Touch ID, Locking, Clipboard, Password
Generator, and a bare section for the strength-meter toggle.

**Touch ID has three mutually exclusive states, in precedence order:** no database open ("Open a
database to set up Touch ID unlock."), hardware unavailable (the system's own reason), or the real
toggle — plus a busy spinner and a `danger` error line. Each of the first two **explains itself**
rather than silently doing nothing.

**Edits apply live.** Changing a timeout pushes into the running `AutoLockController` /
`ClipboardService` immediately, not only on the next launch.

**Not surfaced here:** whether the detail inspector is visible. That is window chrome the toolbar
toggle drives; it is persisted the same way as every setting, but a user does not go looking for it
in Settings.
