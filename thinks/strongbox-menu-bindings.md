# Strongbox 1.65.2 — menu-bar keyboard-shortcut table (empirical)

> For GitHub issue #16. Private research note — not for `docs/`.

- **App**: `/Applications/Strongbox.app`
- **Version**: 1.65.2, build 5807 (read from `Info.plist`: `CFBundleShortVersionString` /
  `CFBundleVersion`)
- **Date captured**: 2026-09-10
- **Captured by**: Claude Code (Sonnet 5), driving the app read-only per the owner's explicit
  authorization for this task.

## Method

1. Verified Strongbox was **not already running** (`pgrep -fl Strongbox` — empty).
2. Launched it backgrounded, never stealing focus: `open -g -a Strongbox`.
3. Enumerated the menu bar via the macOS Accessibility API through
   `osascript`/System Events (`tell application "System Events" to tell process "Strongbox"`),
   walking every `menu bar item` → `menu` → `menu item` → (recursively) `menu` for submenus, to
   arbitrary depth (not just 2 levels — the deepest chain actually present is 3, e.g.
   `File > Import > 1Password > Import 1Pux...`).
4. For every menu item, read four AX attributes: `AXMenuItemCmdChar`, `AXMenuItemCmdModifiers`,
   `AXMenuItemCmdVirtualKey`, `AXMenuItemCmdGlyph`, plus `AXEnabled` and the item `name`.
5. **No menu was clicked, no item was clicked, nothing was typed, no database was opened or
   unlocked.** All data came from the AX attribute tree, which AppKit populates from the
   storyboard/menu XIB independent of window/selection state.
6. Quit via `osascript -e 'tell application "Strongbox" to quit'` after capture (see "Incidental
   finding" below for one complication).

### A correction made mid-run (recorded for anyone re-running this)

The first enumeration pass asked AppleScript for `AXMenuItemCmdChar` `as string` directly and
joined all rows with linefeeds. Two failure modes showed up:

- For items whose command-char is a **control character** (Return = `\r`/`\n`, Delete = ASCII
  `\b` 0x08) or a **Unicode Private-Use-Area function-key code** (arrows, cross-checked below),
  the raw character embedded a literal newline or non-printing byte into the pipe-delimited output
  and either silently vanished from a terminal preview or split one row into two.
- Re-running with the **Unicode code point** of the char instead of the raw character
  (`id of (character 1 of s)`) fixed this and made every one of the 261 captured rows parse
  cleanly.

This is recorded because a naive re-run of "print `AXMenuItemCmdChar` as text" will look like
several items have no character at all (Delete Item, Copy Password and Launch Url, Pop Out/Pop &
Pin Item Details) when they actually do.

## Verified: storyboard menus exist fully, independent of window/database state

At capture time Strongbox had **no window open when the first menu pass ran**
(`count windows` → 0) and, separately, **no item selected** — every `Item >` command and every
`Database >` command came back `AXEnabled = false`, as expected. All of them still had their full
`name`, `AXMenuItemCmdChar`, `AXMenuItemCmdModifiers`, `AXMenuItemCmdVirtualKey` populated. This
confirms the task's premise: **AppKit menus are populated from the storyboard/XIB even while
disabled with no database open** — nothing had to be opened or unlocked to read the complete
table. No workaround was needed.

## Decode tables used

### Table 0 — modifier bitmask (given by the task, confirmed correct empirically)

`AXMenuItemCmdModifiers` is an additive bitmask over the low 4 bits:

| Bit | Value | Meaning |
|---|---|---|
| — | 0 | ⌘ (Command) present, no other modifier |
| 0 | 1 | ⇧ Shift |
| 1 | 2 | ⌥ Option |
| 2 | 4 | ⌃ Control |
| 3 | 8 | **NO** ⌘ (Command absent) |

Bits are additive, e.g. `3 = 1+2` = ⌘⇧⌥ (Shift+Option, Command still present since bit 3 is not
set). Decoding order used for display: ⌘ ⌃ ⌥ ⇧ + key.

**Empirical cross-check (high confidence):** the standard macOS Apple-menu items captured
alongside Strongbox's own items decode to their real, well-known system shortcuts under this exact
table — `Force Quit…` (mod 2) → ⌘⌥⎋, `Lock Screen` (mod 4) → ⌘⌃Q, `Log Out…` (mod 1) → ⌘⇧Q,
`Log Out` no-confirm (mod 3) → ⌘⇧⌥Q. All match Apple's documented defaults, which validates the
bit table above rather than just trusting the task's statement of it blindly.

**A found limitation — an undocumented 5th bit.** Six macOS-system-provided items (not Strongbox's
own: `Emoji & Symbols`, `Enter Full Screen`, and the `Window > Fill / Centre / Move & Resize > *`
submenu) reported modifier values of 24, 28, 29, 31 — i.e. bit 4 (value 16) set in addition to the
documented bits. The task's mapping only defines bits 0–3. I am **not guessing** what bit 4 means;
it is reported raw and flagged `⚠` in the tables below. (For what it's worth, these are all
AppKit/system-standard window-tiling and input-method items that Strongbox did not write — not
worth resolving for this issue, but flagging per the instruction not to guess.)

### Table A — `AXMenuItemCmdVirtualKey` (standard macOS/Carbon virtual keycodes)

The task gave three examples (`51 = ⌫`, `117 = ⌦`, `36 = ↩`); the rest of this table is the same
well-established, decades-stable Carbon `HIToolbox/Events.h` `kVK_*` constant table:

| vkey | Symbol | Constant | Source |
|---|---|---|---|
| 36 | ↩ | `kVK_Return` | given by task |
| 51 | ⌫ | `kVK_Delete` (Backspace) | given by task |
| 117 | ⌦ | `kVK_ForwardDelete` | given by task (not observed in this app) |
| 53 | ⎋ | `kVK_Escape` | standard table |
| 48 | ⇥ | `kVK_Tab` | standard table |
| 123 | ← | `kVK_LeftArrow` | standard table |
| 124 | → | `kVK_RightArrow` | standard table |
| 125 | ↓ | `kVK_DownArrow` | standard table |
| 126 | ↑ | `kVK_UpArrow` | standard table |

### Table B — `AXMenuItemCmdChar` raw code points that are not ordinary printable ASCII

The task did not supply this table; I built it because several items came back with a non-empty,
non-ASCII-letter `AXMenuItemCmdChar` instead of "missing value". Every entry below is
**cross-checked** against the same row's `AXMenuItemCmdVirtualKey` (Table A) — both attributes
independently name the same physical key, which is why these are listed as high-confidence rather
than guessed:

| Code point | Symbol | What it is | Cross-check |
|---|---|---|---|
| 8 (0x08) | ⌫ | ASCII Backspace | matches vkey 51 on `Item > Delete Item` |
| 9 (0x09) | ⇥ | ASCII Tab | matches vkey 48 on `Show Previous/Next Tab` |
| 13 (0x0D) | ↩ | ASCII CR (Return) | matches vkey 36 on `Pop Out/Pop & Pin Item Details` |
| 0x238B (9099) | ⎋ | Unicode "broken circle with NW arrow" — Apple's actual Escape glyph (not raw ASCII ESC 0x1B, which never appeared) | matches vkey 53 on `Force Quit…` |
| 0xF701 (63233) | ↓ | `NSDownArrowFunctionKey` (AppKit private-use-area function-key constant) | matches vkey 125 on `Item > Copy Password and Launch Url` |

No other private-use-area or control code points were observed in this app (no 0xF700/0xF702/0xF703/0xF728
rows occurred).

### `AXMenuItemCmdGlyph` — not decoded

This attribute was captured for every row but **not translated**. I do not have a verified public
table for Apple's internal glyph-ID enum, and Table A/B above already independently name the same
key from `AXMenuItemCmdChar`/`AXMenuItemCmdVirtualKey`, so glyph is redundant with what's already
decoded. Reporting it raw (see the "Raw" column) rather than guessing at names for it. Two values
recur often enough to *note* without asserting the underlying enum name: glyph `11` appears only on
the two Return-key items (`Pop Out/Pop & Pin Item Details`), glyph `27` appears only on the two
Escape-key items (`Force Quit…`) — consistent with, but not proof of, "Return glyph" / "Escape
glyph" respectively.

## Full table, by menu

⚠ = shortcut decode is only partial (undocumented modifier bit present, see Table 0's limitation
above). `—` = no keyboard shortcut assigned (both `AXMenuItemCmdChar` and `AXMenuItemCmdVirtualKey`
are "missing value").

### Strongbox menu

| Menu path | Shortcut | Enabled | Raw: char-code / mod / vkey / glyph |
|---|---|---|---|
| Strongbox > About Strongbox Pro 1.65.2 | — | true | missing / 8 / missing / missing |
| Strongbox > Settings... | `⌘,` | true | 44 / 0 / missing / missing |
| Strongbox > Change My License... | — | true | missing / 8 / missing / missing |
| Strongbox > Tip Jar | — | true | missing / 8 / missing / missing |
| Strongbox > Services (submenu — all standard macOS Services, no shortcuts) | — | true | — |
| Strongbox > Hide Strongbox | `⌘H` | true | 72 / 0 / missing / missing |
| Strongbox > Hide Others | `⌘⌥H` | true | 72 / 2 / missing / missing |
| Strongbox > Show All | — | false | missing / 8 / missing / missing |
| Strongbox > Quit Strongbox | `⌘Q` | true | 81 / 0 / missing / missing |

### File menu

| Menu path | Shortcut | Enabled | Raw: char-code / mod / vkey / glyph |
|---|---|---|---|
| File > New | — | true | missing / 8 / missing / missing |
| File > Open… | `⌘O` | true | 79 / 0 / missing / missing |
| File > Close | `⌘W` | false | 87 / 0 / missing / missing |
| File > Close All | `⌘⌥W` | true | 87 / 2 / missing / missing |
| File > Save… | `⌘S` | false | 83 / 0 / missing / missing |
| File > Save As... | — | false | missing / 8 / missing / missing |
| File > Compare & Merge (aka Synchronize)... | — | false | missing / 8 / missing / missing |
| File > Import (submenu: 1Password [Import 1Pux.../Import 1Pif...], Bitwarden (JSON), Enpass (JSON), LastPass (CSV), Apple/iCloud Keychain (CSV), Generic CSV, Proton Pass (JSON), Minimalist (JSON), mSecure (CSV), Secrets 4 (XML)) | — | true | none have shortcuts |
| File > Export Database... | — | false | missing / 8 / missing / missing |
| File > Export Selected... | — | false | missing / 8 / missing / missing |
| File > Key File Management > Create New Key File... | — | true | missing / 8 / missing / missing |
| File > Key File Management > Recover Key File... | — | true | missing / 8 / missing / missing |
| File > Print Selected Entries... | — | false | missing / 8 / missing / missing |
| File > Print Database... | `⌘P` | false | 80 / 0 / missing / missing |
| File > SFTP Connections Manager... | — | true | missing / 8 / missing / missing |
| File > WebDAV Connections Manager... | — | true | missing / 8 / missing / missing |
| File > Cloud Drive Sessions > Sign Out of OneDrive/Dropbox/Google Drive | — | true | none have shortcuts |

### Edit menu

| Menu path | Shortcut | Enabled | Raw: char-code / mod / vkey / glyph |
|---|---|---|---|
| Edit > Undo | `⌘Z` | false | 90 / 0 / missing / missing |
| Edit > Redo | `⌘⇧Z` | false | 90 / 1 / missing / missing |
| Edit > Cut | `⌘X` | false | 88 / 0 / missing / missing |
| Edit > Copy | `⌘C` | false | 67 / 0 / missing / missing |
| Edit > Paste | `⌘V` | false | 86 / 0 / missing / missing |
| Edit > Select All | `⌘A` | false | 65 / 0 / missing / missing |
| Edit > Find… | `⌘F` | false | 70 / 0 / missing / missing |
| Edit > AutoFill > Contact…/Passwords…/Credit Card… | — | false | none have shortcuts |
| Edit > Start Dictation… | — | true | missing / 8 / missing / missing |
| Edit > Emoji & Symbols | `E` ⚠ | true | 69 / 24 / missing / missing |

### View menu

| Menu path | Shortcut | Enabled | Raw: char-code / mod / vkey / glyph |
|---|---|---|---|
| View > Show Tab Bar | — | false | missing / 0 / missing / missing |
| View > Show All Tabs | `⌘⇧\` | false | 92 / 1 / missing / missing |
| View > Databases Manager | `⌘D` | true | 68 / 0 / missing / missing |
| View > Password Generator | `⌘⇧G` | true | 71 / 1 / missing / missing |
| View > Show Vertical Gridlines | — | false | missing / 8 / missing / missing |
| View > Show Horizontal Gridlines | — | false | missing / 8 / missing / missing |
| View > Show Alternating Grid Rows | — | false | missing / 8 / missing / missing |
| View > Show Popup Toast Notifications | — | false | missing / 8 / missing / missing |
| View > Show Toolbar | `⌘⌥T` | false | 84 / 2 / missing / missing |
| View > Customize Toolbar… | — | false | missing / 8 / missing / missing |
| View > Show Sidebar | `⌘⌃S` | false | 83 / 4 / missing / missing |
| View > Show Details Panel | `⌘/` | false | 47 / 0 / missing / missing |
| View > Enter Full Screen | `F` ⚠ | false | 70 / 24 / missing / missing |

### Database menu

| Menu path | Shortcut | Enabled | Raw: char-code / mod / vkey / glyph |
|---|---|---|---|
| Database > Create Entry | `⌘N` | false | 78 / 0 / missing / missing |
| Database > Create Credit Card | — | false | missing / 8 / missing / missing |
| Database > Create Group | `⌘G` | false | 71 / 0 / missing / missing |
| Database > Change Master Credentials... | `⌘⇧M` | false | 77 / 1 / missing / missing |
| Database > Lock Database | `⌘L` | false | 76 / 0 / missing / missing |
| Database > Find All FavIcons | — | false | missing / 8 / missing / missing |
| Database > Database Settings... | `⌘⇧,` | false | 44 / 1 / missing / missing |
| Database > AutoFill Settings... | — | false | missing / 8 / missing / missing |
| Database > Encryption Settings... | — | false | missing / 8 / missing / missing |
| Database > Touch ID & Watch Unlock Settings... | — | false | missing / 2 / missing / missing |
| Database > Start in Search Mode | — | false | missing / 8 / missing / missing |
| Database > Launch at Startup | — | false | missing / 8 / missing / missing |
| Database > Read Only | — | false | missing / 8 / missing / missing |

### Item menu

| Menu path | Shortcut | Enabled | Raw: char-code / mod / vkey / glyph |
|---|---|---|---|
| Item > Edit Item... | `⌘E` | false | 69 / 0 / missing / missing |
| Item > Pop Out Item Details | `⌘⇧↩` | false | 13 / 1 / 36 / 11 |
| Item > Pop & Pin Item Details | `⌘↩` | false | 13 / 0 / 36 / 11 |
| Item > Favourite | — | false | missing / 8 / missing / missing |
| Item > Copy Item to Clipboard | — | false | missing / 8 / missing / missing |
| Item > Duplicate | `⌘K` | false | 75 / 0 / missing / missing |
| Item > View History... | `⌘⇧H` | false | 72 / 1 / missing / missing |
| Item > Copy Title | `⌘⇧T` | false | 84 / 1 / missing / missing |
| **Item > Copy Username** | **`⌘B`** | false | 66 / 0 / missing / missing |
| Item > Copy Email | `⌘⇧E` | false | 69 / 1 / missing / missing |
| **Item > Copy Url** | **`⌘U`** | false | 85 / 0 / missing / missing |
| **Item > Copy Password** | **`⌘⇧C`** | false | 67 / 1 / missing / missing |
| **Item > Copy 2FA Code** (TOTP) | **`⌘T`** | false | 84 / 0 / missing / missing |
| Item > Copy Notes | `⌘⇧N` | false | 78 / 1 / missing / missing |
| Item > Copy All Fields | `⌘⇧F` | false | 70 / 1 / missing / missing |
| Item > Copy Username & Password | `⌘⇧P` | false | 80 / 1 / missing / missing |
| **Item > Launch Url** (open URL) | **`⌘⇧U`** | false | 85 / 1 / missing / missing |
| **Item > Copy Password and Launch Url** | **`⌘↓`** | false | 63233 / 0 / 125 / 106 |
| Item > Set Icon | `⌘⇧I` | false | 73 / 1 / missing / missing |
| Item > Find FavIcon(s) | — | false | missing / 8 / missing / missing |
| Item > Merge | — | false | missing / 8 / missing / missing |
| Item > Exclude from Audit | — | false | missing / 8 / missing / missing |
| **Item > Delete Item** | **`⌘⌫`** | false | 8 / 0 / 51 / 23 |

### Window menu

| Menu path | Shortcut | Enabled | Raw: char-code / mod / vkey / glyph |
|---|---|---|---|
| Window > Minimize | `⌘M` | false | 77 / 0 / missing / missing |
| Window > Minimise All | `⌘⌥M` | true | 77 / 2 / missing / missing |
| Window > Zoom | — | false | missing / 8 / missing / missing |
| Window > Zoom All | — | true | missing / 10 / missing / missing |
| Window > Fill | `⌃F` ⚠ | false | 70 / 28 / missing / missing |
| Window > Centre | `⌃C` ⚠ | false | 67 / 28 / missing / missing |
| Window > Move & Resize > Left | `⌃←` ⚠ | false | missing / 28 / 123 / missing |
| Window > Move & Resize > Right | `⌃→` ⚠ | false | missing / 28 / 124 / missing |
| Window > Move & Resize > Top | `⌃↑` ⚠ | false | missing / 28 / 126 / missing |
| Window > Move & Resize > Bottom | `⌃↓` ⚠ | false | missing / 28 / 125 / missing |
| Window > Move & Resize > Left & Right | `⌃⇧←` ⚠ | false | missing / 29 / 123 / missing |
| Window > Move & Resize > Left & Quarters | `⌃⌥⇧←` ⚠ | false | missing / 31 / 123 / missing |
| Window > Move & Resize > Right & Left | `⌃⇧→` ⚠ | false | missing / 29 / 124 / missing |
| Window > Move & Resize > Right & Quarters | `⌃⌥⇧→` ⚠ | false | missing / 31 / 124 / missing |
| Window > Move & Resize > Top & Bottom | `⌃⇧↑` ⚠ | false | missing / 29 / 126 / missing |
| Window > Move & Resize > Top & Quarters | `⌃⌥⇧↑` ⚠ | false | missing / 31 / 126 / missing |
| Window > Move & Resize > Bottom & Top | `⌃⇧↓` ⚠ | false | missing / 29 / 125 / missing |
| Window > Move & Resize > Bottom & Quarters | `⌃⌥⇧↓` ⚠ | false | missing / 31 / 125 / missing |
| Window > Move & Resize > Return to Previous Size | `⌃R` ⚠ | false | 82 / 28 / missing / missing |
| Window > Full-Screen Tile | — | false | missing / 0 / missing / missing |
| Window > Remove Window from Set | — | false | missing / 0 / missing / missing |
| Window > Bring All to Front | — | true | missing / 8 / missing / missing |
| Window > Arrange in Front | — | true | missing / 10 / missing / missing |
| Window > Show Previous Tab | `⌃⇧⇥` | false | 9 / 13 / 48 / 2 |
| Window > Show Next Tab | `⌃⇥` | false | 9 / 12 / 48 / 2 |
| Window > Move Tab to New Window | — | false | missing / 0 / missing / missing |
| Window > Merge All Windows | — | false | missing / 0 / missing / missing |
| Window > Float On Top | — | true | missing / 8 / missing / missing |

(Window menu also listed one open-database window entry at capture time — see "Incidental
finding" below; that row is intentionally omitted from this table since it names a personal file
path and carries no shortcut.)

### Help menu

| Menu path | Shortcut | Enabled | Raw |
|---|---|---|---|
| Help > FAQ & Support | — | true | missing / 8 / missing / missing |

## Requested lookups — summary

| Action | Menu item | Shortcut |
|---|---|---|
| New entry | `Database > Create Entry` | **⌘N** |
| New database | `File > New` | none assigned |
| New group | `Database > Create Group` | **⌘G** |
| Copy username | `Item > Copy Username` | **⌘B** |
| Copy password | `Item > Copy Password` | **⌘⇧C** |
| Copy URL | `Item > Copy Url` | **⌘U** |
| Copy TOTP/2FA code | `Item > Copy 2FA Code` | **⌘T** |
| Open URL (launch in browser) | `Item > Launch Url` | **⌘⇧U** |
| Lock (database) | `Database > Lock Database` | **⌘L** |
| Search | `Edit > Find…` | **⌘F** |
| Edit (item) | `Item > Edit Item...` | **⌘E** |
| Delete (item) | `Item > Delete Item` | **⌘⌫** (Cmd+Backspace) |
| Copy Password **and** Launch URL (combined) | `Item > Copy Password and Launch Url` | **⌘↓** (Cmd+Down Arrow) |

## Not observable this way

- **`AXMenuItemCmdGlyph`** — captured for every row (see "Raw" columns) but not translated to a
  human name. I have no verified public source for Apple's internal glyph-ID enum, and both
  `AXMenuItemCmdChar`/`AXMenuItemCmdVirtualKey` already independently identify the same key, so
  nothing is lost by leaving it raw rather than guessing.
- **The 5th modifier bit (value 16)** on 6 OS-standard items (`Emoji & Symbols`, `Enter Full
  Screen`, `Window > Fill/Centre/Move & Resize > *`) — not covered by the task's given 0/1/2/4/8
  mapping. Flagged `⚠` throughout rather than guessed. None of these are Strongbox's own commands.
- **The Apple (🍎) system menu** was deliberately excluded from the tables above. It is not part of
  Strongbox's own menu bar (it's the shared macOS menu present for every foreground app) and its
  `Recent Items` submenu incidentally listed unrelated personal filenames from *other* apps'
  recent-document history — irrelevant to this issue and not worth recording. (Its shortcuts were
  captured and used only as the cross-validation set for Table 0 above, e.g. Force Quit/Lock
  Screen/Log Out.)
- **Whether any shortcut actually fires while a database is unlocked and an item is selected** —
  not tested. Every `Item >`/`Database >` command was captured with `AXEnabled = false` (no
  selection, and per the incidental finding below, actually one window was open but not confirmed
  unlocked). The key-equivalent attributes are present and correct regardless of enabled state
  (this is exactly the storyboard-population behavior the task asked to verify), but nothing here
  proves the shortcut is *live* in a real editing session — only that it's *bound*.

## Incidental finding — please read

Partway through the second enumeration pass, the **Window menu** unexpectedly grew a
`test1 (~/Downloads/test1-db.kdbx)` entry, and a follow-up read-only check
(`count windows`, `get name of windows`) confirmed **one window was open**, titled
`test1 – ~/Downloads/test1-db.kdbx`. Strongbox was **never** frontmost at any point (`open -g`
kept it backgrounded throughout; a check of the frontmost process during capture showed iTerm2),
and I never clicked a menu item, typed, or opened/unlocked anything.

The most likely explanation is that this is Strongbox's own **window-restoration behavior on
launch** (a standard macOS document-app pattern: reopen previously-open document windows) —
triggered simply by `open -g -a Strongbox` launching the process, not by anything this session did
inside the app. I did not probe further: I did not check whether the window was showing an unlock
prompt or unlocked content, since either read risks crossing the "do not touch a database" line.
I only read the window's **title** (which is just the same filename already visible in the Window
menu text) via `get name of windows`.

Quitting Strongbox (step 2 of this task) closes that window along with the app; I did not close it
by any other means. **The owner should be aware Strongbox may auto-reopen `test1-db.kdbx` (and
possibly other recently-used databases) whenever it launches**, independent of any user action —
worth knowing if that's ever a concern (e.g. scripted/background launches of the real app).
