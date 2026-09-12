# Components — chrome

> Status: living · Last verified: 2026-09-12 · [AI - grok-4.6]

The window's own surfaces and bands: what content sits on, and what frames it. Token values are in
`design/BRAND.md`.

## Grounds

Four, and a view never invents a fifth:

| Token | What sits on it |
|---|---|
| `canvas` | behind a centred card — Welcome, Unlock, the Settings window, a sheet's stage |
| `surface` | cards, sheets, the entry list, the detail pane |
| `sunken` | inset wells and hover grounds |
| `sidebar` | the group sidebar, the toolbar and the status bar — one tone for all three |

`RootView` paints `canvas` once for the whole window, which is what stops the system window
background showing through; the browser's panes paint their own `surface` over it. `RootView` also
sets the app-wide `.tint` to `accent-600`, so the controls this design pass does not hand-draw — a
`Slider`'s fill, a `Toggle`'s knob, a `ProgressView`'s bar — follow palette C instead of system blue.

## Card surface (`.cardSurface`)

**Purpose.** A raised panel centred on the canvas: the unlock card, the welcome card.

**Anatomy.** `surface` fill, radius `lg` by default, a `border` hairline, and `shadow-card` (two
stacked layers).

**Variant.** `isFloating: true` swaps in `shadow-sheet` and **drops the hairline** — for something
presented over a scrim, where the shadow alone carries the separation.

No states: it is not interactive.

## Sunken well (`.sunkenWell`)

**Purpose.** An inset region on a surface — the generator's result, the TOTP readout, the search
field in the mockup.

**Anatomy.** `sunken` fill, radius `sm` by default, a `border` hairline.

No states.

## Toolbar

**Purpose.** The pointer surface for the browser. **Not the keyboard surface** — that is the menu
bar; see `design/keyboard-map.md`.

**As implemented.** A native SwiftUI `.toolbar` tinted to the `sidebar` tone via
`.toolbarBackground(_:for: .windowToolbar)`, under `.windowToolbarStyle(.unified)`. Search is a
centred `ToolbarItem(placement: .principal)` of this app's own — see below. Lock is its own
`ToolbarItem(placement: .primaryAction)` so the centred search field cannot overflow it (issue
#129). The rest — New Entry, New Group, Delete Entry, Generator, Save, Hide/Show Detail — sit in
one `ToolbarItemGroup`. Each is a `Label` with an SF Symbol, rendered by the system — the toolbar
deliberately does **not** use `GlyphButtonStyle`.

**States.** Delete Entry is disabled with no selection; Save is disabled when nothing is dirty. The
detail toggle's label flips between "Hide Detail" and "Show Detail". Everything else is always
enabled while unlocked.

**Where the mockup and the code differ** — recorded, not resolved:

- The mockup groups its buttons into two `.toolbar-group`s split by `.toolbar-sep` separators, opens
  with a sidebar-collapse glyph and a `.toolbar-title` showing the database filename, and ends with
  the search well. The code has one flat group plus Lock in `.primaryAction`, no separators, and no
  title item (the filename reaches the window title through `navigationTitle` on the sidebar
  instead). The search well is built, but centred rather than trailing — see the next section.
- The mockup has an **Edit Entry** toolbar button. The code has none; Edit lives in the detail
  pane's header and in the Entry menu.
- The mockup's toolbar glyphs are `.icon-btn`s with a `.is-danger` variant for delete; the code's are
  system-rendered toolbar items with `Button(role: .destructive)`.
- The mockup annotates each button with a shortcut in its tooltip. Several of those bindings do not
  exist — see `design/keyboard-map.md`.
- Settled: the `sidebar` tint does apply under the unified toolbar style. Verified empirically; see
  `claude-memory/pass-sumo-list-and-toolbar-verified.md`.

## Search field (`.searchFieldChrome`)

**Purpose.** Filter the entry list. One field, in the browser, and nowhere else.

**Where.** Centred in the window toolbar, in its own `ToolbarItem(placement: .principal)` —
Strongbox's position, and the owner's ask in issue #87.

**Why it is hand-rolled.** `.searchable`'s placement cannot be steered to the centre: on macOS its
`.toolbar` placement renders the system's field at the trailing edge, after every other item. So the
field is this app's own `TextField`, and the four things the system field supplied are supplied
explicitly instead:

| Behaviour | How |
|---|---|
| ⌘F focuses it | unchanged — `AppCommands`' "Focus Search" raises `.focusSearch`, which the browser turns into `isSearchFocused = true`. The field declares no shortcut of its own |
| Escape clears and unfocuses | `.onExitCommand`, i.e. AppKit's `cancelOperation(_:)` — the hook Escape actually reaches a focused text control on |
| Focus ring | the shared `FocusRing`, through `.searchFieldChrome` — never a second ring of its own |
| Ground | `sunken`, per the mockup's `.search` |

**Anatomy.** `search-field-width` × `search-field-height`, `space-3` of horizontal padding and
`space-3` between a leading `magnifyingglass` glyph and the field, on a `sunken` fill with a `border`
hairline at radius `sm`. Text and placeholder are `caption`.

**Where the mockup and the code differ:** the mockup colours the placeholder `text-3`; the code uses
`text-2`, because `text-3` on `sunken` measures 4.18:1 and misses AA — the contrast rule in
`design/BRAND.md` scopes `text-3` to `surface`. Neither has a clear (✕) button: Escape is the way
out.

## Status bar (`.statusBarBand` + `StatusBar`)

**Purpose.** The machinery the product shows on purpose: which file is open, whether it is saved, and
both live countdowns.

**Anatomy.** A fixed `statusbar-h` band on `sidebar`, a `border` hairline along its top edge,
`space-5` horizontal padding, `caption` in `text-2`. Left to right: the database path in
`monoCaption2`, middle-truncated behind a lock glyph; the backup warning, if any; the dirty flag; a
spacer; the clipboard countdown; the auto-lock countdown.

**States.**

| Slot | Shown when | Treatment |
|---|---|---|
| path | always | monospaced, middle-truncated — the filename is the half worth keeping |
| backup warning | the last save's pre-save backup failed | `warning` tints the **icon only**; the sentence stays `text` (contrast — see `design/accessibility.md`), full text in a tooltip |
| dirty | `VaultStore.isDirty` | "Unsaved changes" behind a `warning` dot |
| clipboard countdown | something of ours is on the pasteboard | seconds, monospaced |
| auto-lock countdown | the idle timer is running | `m:ss`, monospaced |

Both countdowns are live values, ticked by `ClipboardService` and `AutoLockController`; `nil` means
"not counting" and the slot disappears rather than showing a zero.

**Rules.**

- The bar takes plain values, never the services themselves, so the embedder owns the observation
  and the bar stays previewable.
- The backup warning is **persistent, not an alert.** The condition persists — an unwritable
  container fails the next save too — and an alert dismissed once would leave the app quietly saving
  without backups thereafter.
- Where the mockup and the code differ: the mockup has no backup-warning slot, and formats the
  clipboard countdown as `m:ss` where the code prints bare seconds.

## Sheets

**Purpose.** A modal task with its own commit: create database, generate password, edit entry.

**Anatomy.** A SwiftUI `.sheet` on a `surface` ground, `space-7` padding, a `headline` title in
`text`, a fixed width, and a trailing action row separated by `space-5` or a `border` divider. The
`scrim` and `shadow-sheet` tokens describe the mockup's backdrop; on macOS the system draws a
sheet's own shadow and dimming, so **no view passes `isFloating: true` and `scrim` is used nowhere**
— both wait for an overlay the system does not present for us.

**Action-row order.** Quiet dismissal on the left of the trailing group, then the secondary action,
then the primary on the far right. Cancel/Close is `QuietButtonStyle` and carries
`.keyboardShortcut(.cancelAction)`; the committing button is `PrimaryActionButtonStyle` with
`.keyboardShortcut(.defaultAction)`. **SwiftUI does not dismiss a macOS sheet on Esc by itself** — a
button bound to `.cancelAction` is what makes Esc work.

**States.** The committing button is disabled until the sheet's precondition holds (passwords match;
a result exists). In-flight work shows a small `ProgressView` in the body, not inside the button.

`EntryEditView` is the exception to all of this: it is a `Form(.grouped)` with a native
cancel/confirm toolbar, not a token-styled sheet. It has no approved mockup (issue #63).

## Progress and busy states

There are exactly three, all `ProgressView`:

- **Unlocking.** Its own top-level screen with the label "Unlocking…" in `body`/`text-2`, because
  Argon2 key derivation is about a second of real work and a blank window would read as frozen.
- **In-sheet busy.** A small spinner beside the disabled action — creating a database, enabling
  Touch ID.
- **A bar, not a spinner** — the TOTP countdown and the strength meters, which measure something.

There is no skeleton state and no loading placeholder anywhere: the vault is fully in memory once
unlocked, so nothing else in the UI ever waits.
