# UX rules

> Status: living · Last verified: 2026-09-10 · [AI - claude-opus-5]

The decisions a contributor would otherwise re-litigate. Every rule here is what the code does, with
the reason it does it — not what a password manager conventionally does.

## Reveal versus copy

**Copy is the default action; reveal is the exception.** The overwhelmingly common thing a user does
with a stored password is paste it somewhere, never read it. Defaulting to concealed with a copy
button up front means the normal path never puts plaintext on screen at all, and reveal exists only
for the rarer "I have to type this by hand" case.

- A concealed field shows a **fixed** run of dots, never one per character: a password's length is
  itself information worth not leaking to someone standing behind the user.
- **Reveal is never sticky.** In the detail pane it resets on every selection change and on every
  lock, so a revealed password from entry A cannot bleed into the view of entry B and a lock always
  leaves the screen in its safe default. In the master-password field it resets when the app
  deactivates or the window loses key status.
- The reset rules are pure functions — `RevealPolicy` and `PasswordRevealState` — kept out of the
  view bodies specifically so they are testable without driving real SwiftUI or a real `NSWindow`.
- **A protected custom field is concealed exactly like the password** (issue #65). The view never
  guesses which ones those are: `VaultFieldValue.isProtected` carries the file's own
  `Protected="True"` marking, or the user's choice from the edit sheet's per-field lock. Reveal is
  per field, the reset rules above are shared, and every custom row carries the copy glyph —
  copy-first is not conditional on secrecy.
- Attachment payloads are secret material and are never revealed by default either: the only inline
  rendering is a thumbnail, and only for a PNG or JPEG whose extension and magic number agree, under
  a size ceiling. Everything else is listed, sized and exportable with no picture.

## Clipboard

**A copied secret is taken back off the pasteboard on a timer, and the countdown is visible.** The
interval is `ClipboardService.clearInterval`, seeded from `AppSettings.clipboardClearTimeout` and
changeable in Settings; the remaining seconds appear in the status bar, and the generator sheet
states the live interval in words rather than restating a constant.

- **Only what is still ours is cleared.** The service records the pasteboard's `changeCount` when it
  writes and refuses to clear if anything else has taken ownership since — otherwise the app would
  wipe something the user copied from another app in the meantime.
- Copying again **restarts** the countdown rather than stacking a second timer, which is the one bug
  the `changeCount` check cannot catch: both copies are ours, and the first timer would wipe the
  second copy early.
- Two sensitivity markers go on every item: `org.nspasteboard.ConcealedType`, a community convention
  that clipboard-history utilities honour, and `com.apple.is-sensitive`, Apple's own undocumented
  key that keeps an item out of Universal Clipboard. **Neither may ever be described to a user as
  protection.** Nothing in macOS enforces the first and the second is not in the published SDK.
- The countdown slot disappears when nothing of ours is on the pasteboard. It never shows a zero.

## Auto-lock

Two mechanisms, answering two different threats:

- **The idle timer** covers "walked away from an unlocked Mac". Its default is
  `AutoLockController.idleTimeout`, overridable in Settings, and the remaining time is shown in the
  status bar as `m:ss` — a bare second count reads as a much more alarming number than it is.
- **System events** lock immediately: `NSWorkspace.willSleepNotification` (lid close, sleep),
  `com.apple.screenIsLocked` (the lock-screen hotkey), and
  `NSWorkspace.sessionDidResignActiveNotification` (fast user switching). Waiting out a
  minutes-long timeout in a session the user has visibly left is the case these close.

**Activity is reported by views, and there is deliberately no global event monitor.**
`NSEvent.addGlobalMonitorForEvents` needs Accessibility trust — a password manager asking to observe
every keystroke is precisely what a malicious password manager would ask for — it is an App Review
problem, and it does not work for keyboard events under App Sandbox at all. Views call
`noteActivity()` instead: moving through the entry list and typing in the search field. What matters
is whether the user is using *the vault*, not whether some other app is receiving keys.

Corollary: window blur does **not** lock the vault. It only hides a revealed password.

**Unsaved edits must survive a lock, visibly.** `VaultStore.upsert` no-ops against a locked store, so
the edit sheet watches the store and, on a lock, shows a banner saying the entry was **not** saved and
disables Save. It never reports success it did not have. Recovering the typed text into a new attempt
after the next unlock is a real feature and is not implemented — it would need an encrypted holding
area, since a plaintext secret may never be written to `UserDefaults`.

The reason for the lock is recorded and currently never shown (issue #62).

## Destructive actions

**Three tiers, and the tier is decided in one place** — `VaultStore.plannedDeletion` — so no caller
re-derives it:

| Action | Confirmation |
|---|---|
| Delete an entry that is not in the bin | **None.** It moves to the recycle bin; nothing is lost, so asking would be ceremony for an undoable act |
| Delete an entry already in the bin | A `confirmationDialog` naming the entry, whose message says there is no undo |
| Empty the recycle bin | A `confirmationDialog` whose message says everything in it goes for good |

- The confirming button carries `role: .destructive`; Cancel carries `role: .cancel`.
- **A view that can destroy something must not also be the view that decides to.** The sidebar asks
  for the bin to be emptied through a closure; it holds no `VaultStore` reference, because a sidebar
  that could call `emptyRecycleBin()` directly is one refactor away from doing it without asking.
- Auto-purge of the bin is deliberately not implemented; it is its own issue.
- The bare ⌫ binding is a known hazard — AppKit evaluates menu key equivalents before the responder
  chain, so Backspace in the search field can fire it (issue #9). It is not made worse here: the
  keystroke now moves an entry to the bin or asks, and can no longer silently take a password with
  it.

## Dirty state and saving

**Saving is explicit.** There is no autosave (issue #12). `VaultStore.isDirty` drives two things and
nothing else: the "Unsaved changes" flag in the status bar, and whether Save is enabled in the
toolbar and the File menu.

- `isDirty` is cleared **only when nothing was edited after the snapshot the save actually wrote**, so
  an edit that lands during key derivation is never reported as being on disk.
- Saves are serialised by a task chain, and a queued save is never coalesced into the in-flight one —
  it encodes the vault as of when it *runs*. This is the fix for issue #27, where two racing saves
  silently discarded one set of edits while both reported success. Do not "simplify" it into a flag.
- There is no save-progress UI. A save is fast enough not to need one, and the dirty flag going away
  is the confirmation.

## Backup failures

**A failed pre-save backup never blocks the save, and is never swallowed** (issue #26).

- `write` returns an outcome, `VaultStore.lastBackupError` holds the reason, and the status bar shows
  it as a **persistent** line, not an alert. The condition persists — an unwritable container fails
  the next save too — and an alert dismissed once would leave the app quietly saving without backups
  thereafter.
- The sentence says both halves: the data is safe, and it went to disk without the previous version
  being kept.
- Backups live inside the app's own container, which is invisible to users, so "Show Backups in
  Finder" in the File menu is what reaches them. That command creates the directory on demand rather
  than being disabled when it is absent: an empty folder answers the user's actual question, a greyed
  out menu item answers nothing and looks like a bug.
- **Never "fix" a backup-location problem by adding a file-access entitlement.** An entitlement with
  no user-chosen functionality behind it is what got the sibling app rejected under Guideline
  2.4.5(i). A user-picked backup folder with its own persisted bookmark is the sanctioned
  alternative (issue #36).

## Showing the machinery

A positioning rule with UI consequences: this product shows how the database is built instead of
hiding it. Concretely, and each of these is a deliberate choice rather than an unpolished detail —
the full database path on the unlock screen and in the status bar; monospace wherever the content is
data rather than prose; the entry's raw UUID and timestamps in the detail pane with no "advanced"
disclosure; the generator's entropy in bits; both countdowns as live numbers.

The counterweight is the anti-bloat rule, which is just as binding: no nagging, no purchase or rating
prompts, no banners in the vault UI, and trial or subscription state in exactly one place if it ever
exists. Showing the machinery is not a licence to add panels.
