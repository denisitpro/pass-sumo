# Keyboard map

> Status: living · Last verified: 2026-09-09 · [AI - claude-opus-5]

Every binding that exists in `PassSumo/Sources/`, read off the `keyboardShortcut` calls and the
`Commands` bodies. **Nothing here is aspirational.** Where a binding is missing it is listed as a
gap, not filled in with what another app does — matching Strongbox's bindings is issue #16, and that
audit needs the owner's go-ahead.

## The two surfaces

**`AppCommands` is the keyboard surface; the toolbar is the pointer surface.** The toolbar's buttons
carry no shortcuts except the two actions that have no menu item at all, because a shortcut declared
in both places is either a duplicate or — as ⌘N once was, meaning New Database in the menu and New
Entry in the toolbar — an outright conflict.

## Menu bar

| Keys | Action | Enabled when |
|---|---|---|
| ⌘N | New Database… | nothing is open (`.empty`) |
| ⌘O | Open Database… | nothing is open (`.empty`) |
| ⌘S | Save | unlocked |
| ⌘L | Lock Database | unlocked |
| ⌘W | Close window | always |
| ⌘⇧B | Copy Username | an entry is selected |
| ⌘⇧C | Copy Password | an entry is selected |
| ⌘⇧N | New Entry | unlocked |
| ⌘E | Edit Entry | an entry is selected |
| ⌫ | Delete Entry | an entry is selected |
| ⌘F | Focus Search | unlocked |
| — | Show Backups in Finder | a backup directory is known |
| — | Empty Recycle Bin… | the bin has content |
| ⌘, | Settings | system-provided by the `Settings` scene, not declared in source |

**⌘C is left alone.** The copy commands are added *after* the pasteboard group, never replacing it,
so the system copy stays exactly as it is. ⌘⇧B / ⌘⇧C are KeePassXC's own long-standing bindings,
chosen so muscle memory transfers.

**Two commands deliberately have no shortcut.** Show Backups in Finder is a disclosure command
reached a handful of times in a database's life. Empty Recycle Bin… is destructive, and an unassigned
destructive command cannot be hit by accident; the sidebar's context menu on the bin is its
discoverable path.

**⌫ is a known hazard, filed as issue #9.** AppKit evaluates menu key equivalents *before* the
responder chain, so a Backspace typed into the search field can fire Delete Entry. What the binding
now does is survivable — it moves the entry to the recycle bin, or asks first if it is already there
— but the hazard itself is not fixed.

## Window and sheets

| Keys | Action | Where |
|---|---|---|
| ⌘⇧G | Generator | browser toolbar — the generator has no menu item, so this is its only binding |
| ⌥⌘I | Show / Hide Detail | browser toolbar — the platform convention for an inspector; nothing else in the app binds `i` or uses ⌥ |
| Return | Open the selected entry for editing | entry list (`onKeyPress`) |
| ↑ ↓ | Move the selection | entry list and sidebar — from `List`'s own selection handling, not declared |
| Return | Unlock | unlock screen (default action, plus `onSubmit`) |
| Return | Choose Location & Create… | create-database sheet (default action) |
| ⌘R | Regenerate | generator sheet |
| Esc | Close | generator sheet (cancel action) |
| Return | Use | generator sheet — **only when opened from the edit sheet**, since Use does not exist when there is no field to fill |
| Esc | Cancel | entry edit sheet |
| ⌘S | Save | entry edit sheet |

The entry list's context menu displays ⌘E, ⌘⇧B, ⌘⇧C and ⌫ against its items. Those are the same
bindings the menu bar owns, wired to the same handlers, so the menu is showing the real shortcut
rather than declaring a second one. The detail pane's Edit button likewise re-declares ⌘E for the
same action.

## Known collisions and gaps

- **⌘S is declared twice** — by the menu bar (Save the database) and by the entry-edit sheet (Save
  the entry). Different actions, same keys. Which wins while the sheet is open has not been
  verified, and neither has whether the disabled menu item swallows it. Part of issue #16.
- **The generator sheet has no default action when opened from the toolbar.** Use is hidden there and
  Copy carries no shortcut, so Return does nothing on the sheet's most common path.
- **Nothing binds Reveal Password, Open URL, or Copy One-Time Password.** All three are
  pointer-only affordances today.
- **No binding moves focus between panes** (sidebar → list → inspector), and none collapses the
  sidebar; the sidebar's visibility has a toolbar control only via `NavigationSplitView`'s own
  chrome.
- **The mockup's tooltips name bindings that do not exist.** `palette-variants.html` annotates its
  toolbar and detail-pane buttons with ⌘N (New Entry), ⌘G (Generator), ⌘⌫ (Delete Entry), ⌘B (Copy
  Username), ⌘C (Copy Password), ⌘⇧R (Reveal Password), ⌘U (Open in Browser) and ⌘T (Copy One-Time
  Password). Of those, only ⌘F (Focus Search) matches the app; ⌘N, ⌘G, ⌘B, ⌘C and ⌘⌫ are bound to
  something else or bound differently, and ⌘⇧R, ⌘U and ⌘T are bound to nothing at all. The mockup was
  approved as a **palette** reference, so this is not a defect in it — but it must not be read as a
  keyboard specification. Settling the real set is issue #16.

## Rules for adding one

- **Every action gets a shortcut before it gets a button** (issue #3's positioning note). The target
  user drives hundreds of entries from a laptop keyboard.
- Declare it in `AppCommands`, once. A toolbar button gets its own shortcut only when there is no
  menu item to attach it to.
- A shortcut that could act on nothing is **disabled**, never left to silently no-op. Each command
  group states its own enablement, and those predicates are unit-tested without driving any UI.
- Check the new keys against this table and against `AppCommands.swift` before adding them, and
  record the check in the commit — the ⌘N collision reached the app precisely because two files each
  looked reasonable on their own.
