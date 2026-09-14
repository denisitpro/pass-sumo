# Feature inventory

> Status: living · Last verified: 2026-09-15 · [AI - claude-sonnet-5]

This is the single inventory of what pass-sumo actually does, kept in one place so it serves two
different readers without being written twice:

- **Audit**: every "shipped" line below was checked against the current code, not against an
  issue's description of intent. Each line points at a source area (a directory or type name, not
  a line number — those rot) so the claim can be re-checked at any time.
- **Landing page**: each line also carries one plain-English sentence of user-facing benefit, in
  the product's own vocabulary, usable close to verbatim on the marketing site.

Positioning, the KDBX/licensing/vendoring decisions, and the full reasoning behind everything in
the "Deliberately not doing" section live in `../CLAUDE.md` — this file links to it rather than
re-arguing it. Where a decision has its own issue, the issue number is the reference.

**Where this gets updated:** in the same PR as the change, same as any other anchor doc (see
`~/.claude/playbook/docs.md`'s same-PR rule). A PR that ships a feature, finishes a partial one, or
changes an anti-feature decision updates the matching line here. A stale line here is worse than no
line — if you land a feature and don't update this file, the next audit will catch it.

**Path note:** this file lives at `docs/feature.md` rather than `docs/reference/` — a deliberate
exception to this repo's normal doc placement, per the owner's explicit instruction in issue #100.

## Shipped

Verified against the code at commit `752b2d1` (branch `docs/180`, off `main`).

| Feature | User benefit | Source area |
|---|---|---|
| Open, create and save KDBX 4.x databases | Your existing KeePass-format vault opens here, and a new one is readable by any other KDBX 4 client. A database pass-sumo creates uses a deliberately strong KDF (Argon2id, t=120/m=64 MiB/p=4 — measured ~0.9 s per derivation on Apple Silicon), so every open and save of it costs a bit more time in exchange for real brute-force resistance. | `Sources/KDBX/KDBXKitCodec.swift` (`productionKDF`), `Sources/Model/VaultStore.swift` |
| Non-destructive save — unknown data round-trips | Fields another KDBX client wrote (custom icons, tags, `CustomData`, entry history, AutoType) survive a save from pass-sumo untouched. | `Sources/KDBX/KDBXContentMerge.swift` |
| Save refuses to overwrite a file changed elsewhere | If the database file on disk changed since pass-sumo opened it (edited on another Mac, restored from iCloud, touched by another app), saving stops and asks Overwrite, Reload, or Cancel instead of silently clobbering whichever copy loses. | `Sources/Model/VaultStore.swift` (`.externallyModified`), `Sources/UI/RootView.swift` (issue #173) |
| Search across all fields, including passwords | One search box finds an entry by title, username, URL, notes, or the password itself. | `Vault.search` in `Sources/Model/Domain.swift`, `Sources/UI/EntryListView.swift` |
| Groups and entries, with drag/organize | Folders and entries organize the way they do in KeePass, KeePassXC or Strongbox. | `Sources/Model/VaultStore.swift`, `Sources/UI/GroupSidebar.swift` |
| Multiple databases open at once, as tabs | Open more than one KDBX file in the same window. Each tab keeps its own lock state and idle clock, so a background tab still locks itself on schedule instead of staying decrypted forever, and closing or locking a tab with unsaved edits asks before dropping them. | `Sources/App/VaultSession.swift` (`VaultSessionList`), `Sources/UI/DatabaseTabBar.swift` (issue #47 / #165) |
| Recycle Bin (soft delete, permanent delete, empty) | Deleting an entry doesn't lose it outright — it goes to a bin you can still recover from, until you empty it. A brand-new entry or folder can never be filed directly into the bin; it falls back to the top level instead. | `Sources/Model/VaultStore.swift`, `Sources/Model/Domain.swift` (`Vault.moveToRecycleBin`), `Sources/UI/VaultBrowserView.swift` (`newItemParentID`, issue #174) |
| File attachments (add, view, export, remove) | Attach a file to an entry — a recovery-code PDF, a certificate — and get it back out later. | `Sources/KDBX/KDBXAttachments.swift`, `Sources/UI/EntryDetailView.swift`, `Sources/UI/EntryEditView.swift` |
| Custom fields, with per-field protection | Add your own fields to an entry (a PIN, a security answer), and choose per field whether it's masked/encrypted like a password. A name that collides with a reserved field, or duplicates another custom field on the same entry, is refused inline before save rather than silently overwriting one of them. | `Sources/KDBX/KDBXFieldKeys.swift`, `Sources/UI/EntryEditView.swift` (issue #174) |
| Password generator with a saved default recipe | Generate a strong password from the recipe in Settings — generate-now uses it immediately, the gear opens the same controls to change it, and a tweak there is saved for next time. | `Sources/Security/PasswordGenerator.swift`, `Sources/UI/GeneratorSheet.swift`, `Sources/UI/EntryEditView.swift`, `AppSettings.generatorRecipe` in `Sources/UI/SettingsView.swift` |
| TOTP (one-time codes) | See an entry's current two-factor code next to its password, refreshed every second, no separate authenticator app. Stored as KeePassXC's `otp` field holding an `otpauth://totp/...` URI (or a bare base32 secret the parser also accepts), so other clients round-trip — that storage fact is for the feature page / FAQ; the edit field itself asks for an authenticator secret, not the jargon. An invalid secret is caught inline before save instead of being written unusable. | `Sources/Security/TOTPGenerator.swift`, `Sources/KDBX/KDBXTOTP.swift`, `Sources/UI/TOTPView.swift`, `Sources/UI/EntryEditView.swift` (issue #174) |
| "Password last changed" derived from entry history | See at a glance how old a saved password actually is, not just when the entry was last touched. | `Sources/KDBX/KDBXPasswordHistory.swift` (issue #33) |
| Built-in KDBX icon set rendered as SF Symbols | Entries and folders show a recognizable icon, matching what the file's icon index means in any other KeePass client. | `Sources/Icons/StandardIconCatalog.swift`, `Sources/UI/IconPickerSheet.swift` (issue #89) |
| Touch ID unlock, opt-in | Unlock with your fingerprint instead of typing the master password every time, once you turn it on. If the stored password stops working (changed in another client) the stale enrollment is cleared instead of failing forever, and the "wrong password" message no longer wrongly blames a key file. Not verified in this branch: the keychain-item hardening in `BiometricUnlock.swift` (issue #179) needs a signed run on Touch ID hardware to confirm end to end. | `Sources/Security/BiometricUnlock.swift`, `Sources/Security/AutomaticBiometricUnlockPolicy.swift`, `Sources/UI/UnlockView.swift` (`BiometricUnlockRecovery`, issue #175), `Sources/App/AppEnvironment.swift` (`VaultError.displayMessage`), `Sources/UI/SettingsView.swift` |
| Auto-lock on idle, sleep, screen lock, fast user switching, lock request, or quit | The vault locks itself when you step away — on an idle timer, or when the Mac actually sleeps or the screen locks — saving any unsaved edits first so a lock never silently drops them; if that save fails, the vault stays open (with the failure on screen) rather than losing the edits. Locking or quitting yourself (⌘L, ⌘Q, the toolbar Lock button) while a vault is dirty asks Save, Discard, or Cancel instead of guessing. | `Sources/Security/AutoLockController.swift`, `Sources/App/VaultSession.swift` (`SessionLockPolicy`, `VaultSessionList`), `Sources/UI/RootView.swift`, `Sources/App/AppCommands.swift` (issue #172) |
| Clipboard auto-clear with sensitivity markers | A copied password clears itself off the clipboard after a short interval on its own, and is marked so third-party clipboard managers don't keep a history of it. It is also cleared immediately — not just left to the timer — when the vault locks for any reason, when a database tab closes, and when the app quits. | `Sources/Security/ClipboardService.swift`, `Sources/App/VaultSession.swift` (`SessionLockPolicy.handleLock`/`lockNow`, `VaultSessionList.prepareToQuit`, issue #172) |
| Handles a database still downloading from iCloud | Opening a file iCloud Drive hasn't finished downloading gets its own message instead of a generic I/O error, and starts the download. | `Sources/Model/VaultFileAccess.swift` (`.iCloudNotDownloaded`, `startDownloadingUbiquitousItem`), `Sources/App/AppEnvironment.swift` (issue #177) |
| Automatic pre-save backups, with retention and a visible failure state | Every save is backed up first, so a bad save can't be the only copy of your vault — and if a backup ever fails, you're told, instead of it failing silently. | `Sources/Model/VaultBackupStore.swift`, `Sources/UI/StatusBar.swift`, `Sources/App/AppCommands.swift` ("Show Backups in Finder") (issue #26) |
| Crash-safe save path | A save that's interrupted (crash, forced quit, kill) during encryption or writing can't corrupt the vault or silently lose the edit. | `Sources/Model/VaultStore.swift`, `Sources/Model/VaultFileAccess.swift` — proven by `Sources/DurabilityTests` (issue #22), not part of the routine test run (see `../CLAUDE.md`) |
| Keyboard-first command surface | Every action (new/open/save, copy username/password, lock, delete, search) has a menu item and a shortcut. | `Sources/App/AppCommands.swift` |

No dialog listed above (the lock/quit prompt, the external-change prompt) was confirmed on screen this pass — each is verified against the SwiftUI source only, no GUI run was made.

## Partial

| Feature | Actual state | Source area |
|---|---|---|
| Default handler for `.kdbx` in Finder | File ▸ Open, Open With, and a Dock drop still work (`DocumentOpenReceiver`, issue #84). The app no longer claims `LSHandlerRank: Owner` or **exports** the KDBX UTI — a local unsigned build that owned the type made Gatekeeper treat PassSumo-created files as malware when Strongbox opened them (issue #131). Rank is `Alternate`; the UTI is imported. Restoring Owner is issue #132, after notarization. | `Resources/Info.plist`, `project.yml` (`UTImportedTypeDeclarations`, `LSHandlerRank`) |
| Password strength meter | Shown only when choosing a **new** database's master password, at creation (`CreateDatabaseSheet`, gated by `AppSettings.showPasswordStrength`). Not shown next to entry passwords or in the generator's own "Use this on an entry" flow beyond its entropy-bits line. pass-sumo has no flow to change an existing database's master password at all, so there is nothing for the meter to appear in there. | `Sources/UI/CreateDatabaseSheet.swift` (`PasswordStrengthMeter`), `Sources/UI/GeneratorSheet.swift` (entropy line only) |

## Deliberately not doing

Reasons and full context live in `../CLAUDE.md` ("Key decisions", dated 2026-08-29) — linked here,
not repeated:

- **No AutoFill, no browser extension.** Attack-surface positioning choice for v1.
- **No passkeys.** Requires the system Credential Provider (macOS 14+), which doesn't exist in
  this app yet, and there is no cross-client KDBX storage convention for passkeys to interoperate
  against (KeePassXC and Strongbox use incompatible schemes).
- **No own cloud sync.** The `.kdbx` file is the single source of truth; sync means the file
  living in iCloud Drive or on local disk. P2P sync is deferred, not ruled out, and not v1.
- **No network access.** Confirmed against `Resources/PassSumo.entitlements`: no network client
  entitlement, and no networking code exists in `Sources/`. The app does not phone home and has no
  telemetry.
- **Dark mode: parked, not planned (issue #57).** `Sources/UI/DesignTokens.swift` states every
  design token as one light-only value, and `Sources/App/PassSumoApp.swift` pins both scenes to
  `.light` (with an env-var escape hatch for visual verification only). Per the owner's verdict on
  issue #57: App Store review does not require a dark appearance, so there is no submission
  blocker forcing this work, and it stays unscheduled rather than half-built.
- **Recycle Bin auto-purge.** Emptying the bin is manual; nothing purges it automatically. Tracked
  as its own issue, not implemented.
