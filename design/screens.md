# Screen patterns

> Status: living · Last verified: 2026-09-12 · [AI - grok-4.6]

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
`monoCaption`/`text-3`, middle-truncated; a one-line instruction ("Enter password to unlock.") in
`body`/`text-2`; then the password field and the "Unlock" primary button **side by side** in one
row. At the foot of the card, the running version (`AppVersionInfo`, the same accessor Settings'
About row reads) in `caption2`/`text-3` — this is issue #107: the owner wants to see which build he
is running without leaving this screen.

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
- **List** — the filtered entries on `surface`, `.listStyle(.plain)`. The search field is not this
  column's: it is a centred toolbar item of the app's own (see `design/components-chrome.md`).
- **Inspector** — the detail pane on `surface`: a header (title in `title3` plus an Edit secondary
  button), the five standard field rows, the TOTP well, then Custom Fields, Attachments and Metadata,
  each behind a section heading — a `captionMedium` in `text-2` over a `border` hairline. Its width
  range is 400 / 480 / 640 (issue #86); the arithmetic behind those three is at the call site.
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

**Selection coupling.** The browser owns `selectedGroup`, `selectedEntryID` and `searchText`
because a group change has to clear the entry selection; a selection that no longer appears in the
visible list is cleared, so the inspector never shows an entry the user cannot see selected. The
sidebar selection is a `GroupSelection?`, where "All Entries" is a case of its own rather than the
`nil` it used to be — `nil` is what a macOS `List(selection:)` writes for "deselected", and sharing
one value between the two meanings is what made "All Entries" unpickable (issue #85).

## Generator sheet

**Purpose.** Produce one password, and edit the saved recipe. Opened from the toolbar, or from the
edit sheet's generator-settings gear — not from generate-now, which fills the password field
directly from the current recipe (issue #129).

**Assembly.** Title in `headline`; the result in `monoField` inside a `sunkenWell`, selectable; a
length slider with its value in the label above; five toggles; the entropy line in
`monoCaption2`/`text-3`; a `border` divider; then Regenerate on the left and Close / Copy / Use on
the right; and last, one line stating the live clipboard-clear interval.

**"Use" exists only where there is something to use it on.** From the edit sheet it fills the
password field; from the toolbar there is no field, so `onUse` is `nil` and the button is **hidden
entirely** rather than offered as a second button doing exactly what Copy does with nothing on
screen saying so (issue #45). Copy is therefore primary when it is alone and secondary when Use is
beside it.

**A recipe change is saved.** Any toggle or slider tick regenerates immediately *and* calls
`onRecipeChanged`, so Settings and the next generate-now use the new recipe. That supersedes issue
#106's one-off choice. This sheet still never writes `UserDefaults` itself.

**Error state.** An impossible recipe (no character class, or a length too short to include one of
each) replaces the result with a `caption`/`danger` sentence naming the fix.

**Where the mockup and the code differ:** the mockup puts a Regenerate glyph inside the result well,
labels the slider's ends, and renders strength as a segmented bar with a verdict word (issue #61).

## Entry edit sheet

**Purpose.** Edit one entry, or create one — the same form, distinguished only by its title and by
whether Save inserts.

**Assembly.** A leading-aligned `ScrollView` + `VStack`, not a grouped `Form` — labels sit above
fields, not as trailing `LabeledContent`. Header is the current icon (opens the picker) beside the
title field; no favourite star. Then Username, Password, URL, Group; then Notes, One-Time Password
(placeholder: "Authenticator secret"), Custom Fields and Attachments as titled blocks. Footer is
Cancel (quiet, Esc) on the left and Save (primary, ⌘S) on the right. Add Field and Add File… are
secondary. No approved mockup exists (issue #63).

**Password row.** The field, a reveal glyph, then two trailing glyphs: generate-now (`arrow.clockwise`,
identifier `edit.generate`) fills from the current recipe without opening a sheet; the gear
(`edit.generatorSettings`) opens the generator sheet. An impossible recipe shows the same
`caption`/`danger` sentence the sheet uses.

**The state that matters.** If the vault locks while this sheet is open, `VaultStore.upsert` would
silently no-op — the user would hit Save, watch the sheet close, and lose the entry. So the sheet
watches the store, and on leaving `.unlocked` shows a `danger` banner ("The vault locked while you
were editing. This entry was NOT saved.") and disables Save. It does not pretend to succeed, and it
does not yet recover the typed text into a new attempt — that needs an encrypted holding area, which
is a feature, not a UI tweak.

**Error states.** A refused attachment (too large, unreadable, batch too large) appends a `danger`
line naming the file and the limit; a failed export replaces it with its own sentence.

## Icon picker sheet

**Purpose.** Choose one of KeePass's 69 built-in icons, for a folder or for an entry (issue #89).
pass-sumo does not ship KeePass's artwork; it draws an SF Symbol per index, and the file still
carries the plain integer every other client reads.

**Assembly.** Title in `headline`; a ten-column `LazyVGrid` of `glyph-button-size` cells at radius
`xs`, `space-2` apart; then a single quiet Cancel. Fixed columns rather than adaptive, so the grid
has an intrinsic width and the sheet sizes itself off the token layer instead of a hardcoded frame.

**Clicking an icon is the commit.** There is no confirm button: a grid cell is not a field being
filled in, and a second step would make the user say the same thing twice. Cancel — and Esc, which
reaches it through `.cancelAction` — closes having changed nothing.

**What "commit" means differs by caller, and that is not the sheet's business.** A folder's pick goes
straight through `VaultStore.setGroupIcon`, the way "Move to" beside it in the same context menu
does; an entry's is parked in the edit form's own draft state and lands with Save, so Cancel on the
form discards it along with everything else typed there.

**Reached from** the sidebar's group context menu ("Change Icon…", beside Rename) and the edit
sheet's Icon row. Not from the entry list's row context menu: that menu is the pointer mirror of the
toolbar's copy/open/delete actions, and it opens the edit form anyway.

**States.** The index currently in effect is highlighted with `row-sel-bg` / `row-sel-text`. An index
outside 0…68 — another client's, a future KeePass's — highlights nothing rather than being snapped
to a default, because the file's value survives until the user actually picks something. Each cell's
symbol name reaches the tooltip and VoiceOver; nothing is captioned, because 69 labels is a wall of
text and KeePass's own names ("PaperQ", "WorldSocket") are 2003 Windows jargon.

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
