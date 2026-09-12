# Feature inventory

> Status: living · Last verified: 2026-09-12 · [AI - grok-4.6]

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

Verified against the code at commit `2712fea` (branch `docs/100-feature-inventory`, off `main`).

| Feature | User benefit | Source area |
|---|---|---|
| Open, create and save KDBX 4.x databases | Your existing KeePass-format vault opens here, and a new one is readable by any other KDBX 4 client. | `Sources/KDBX/KDBXKitCodec.swift`, `Sources/Model/VaultStore.swift` |
| Non-destructive save — unknown data round-trips | Fields another KDBX client wrote (custom icons, tags, `CustomData`, entry history, AutoType) survive a save from pass-sumo untouched. | `Sources/KDBX/KDBXContentMerge.swift` |
| Search across all fields, including passwords | One search box finds an entry by title, username, URL, notes, or the password itself. | `Vault.search` in `Sources/Model/Domain.swift`, `Sources/UI/EntryListView.swift` |
| Groups and entries, with drag/organize | Folders and entries organize the way they do in KeePass, KeePassXC or Strongbox. | `Sources/Model/VaultStore.swift`, `Sources/UI/GroupSidebar.swift` |
| Recycle Bin (soft delete, permanent delete, empty) | Deleting an entry doesn't lose it outright — it goes to a bin you can still recover from, until you empty it. | `Sources/Model/VaultStore.swift`, `Sources/Model/Domain.swift` (`Vault.moveToRecycleBin`) |
| File attachments (add, view, export, remove) | Attach a file to an entry — a recovery-code PDF, a certificate — and get it back out later. | `Sources/KDBX/KDBXAttachments.swift`, `Sources/UI/EntryDetailView.swift`, `Sources/UI/EntryEditView.swift` |
| Custom fields, with per-field protection | Add your own fields to an entry (a PIN, a security answer), and choose per field whether it's masked/encrypted like a password. | `Sources/KDBX/KDBXFieldKeys.swift`, `Sources/UI/EntryEditView.swift` |
| Password generator with a saved default recipe | Generate a strong password from the recipe in Settings — generate-now uses it immediately, the gear opens the same controls to change it, and a tweak there is saved for next time. | `Sources/Security/PasswordGenerator.swift`, `Sources/UI/GeneratorSheet.swift`, `Sources/UI/EntryEditView.swift`, `AppSettings.generatorRecipe` in `Sources/UI/SettingsView.swift` |
| TOTP (one-time codes) | See an entry's current two-factor code next to its password, refreshed every second, no separate authenticator app. Stored as KeePassXC's `otp` field holding an `otpauth://totp/...` URI (or a bare base32 secret the parser also accepts), so other clients round-trip — that storage fact is for the feature page / FAQ; the edit field itself asks for an authenticator secret, not the jargon. | `Sources/Security/TOTPGenerator.swift`, `Sources/KDBX/KDBXTOTP.swift`, `Sources/UI/TOTPView.swift`, `Sources/UI/EntryEditView.swift` |
| "Password last changed" derived from entry history | See at a glance how old a saved password actually is, not just when the entry was last touched. | `Sources/KDBX/KDBXPasswordHistory.swift` (issue #33) |
| Built-in KDBX icon set rendered as SF Symbols | Entries and folders show a recognizable icon, matching what the file's icon index means in any other KeePass client. | `Sources/Icons/StandardIconCatalog.swift`, `Sources/UI/IconPickerSheet.swift` (issue #89) |
| Touch ID unlock, opt-in | Unlock with your fingerprint instead of typing the master password every time, once you turn it on. | `Sources/Security/BiometricUnlock.swift`, `Sources/Security/AutomaticBiometricUnlockPolicy.swift`, `Sources/UI/UnlockView.swift`, `Sources/UI/SettingsView.swift` |
| Auto-lock on idle, sleep, screen lock, fast user switching, or on request | The vault locks itself when you step away — not just on a timer, but when the Mac actually goes idle, sleeps, or the screen locks. | `Sources/Security/AutoLockController.swift` |
| Clipboard auto-clear with sensitivity markers | A copied password clears itself off the clipboard after a short interval, and is marked so third-party clipboard managers don't keep a history of it. | `Sources/Security/ClipboardService.swift` |
| Automatic pre-save backups, with retention and a visible failure state | Every save is backed up first, so a bad save can't be the only copy of your vault — and if a backup ever fails, you're told, instead of it failing silently. | `Sources/Model/VaultBackupStore.swift`, `Sources/UI/StatusBar.swift`, `Sources/App/AppCommands.swift` ("Show Backups in Finder") (issue #26) |
| Crash-safe save path | A save that's interrupted (crash, forced quit, kill) during encryption or writing can't corrupt the vault or silently lose the edit. | `Sources/Model/VaultStore.swift`, `Sources/Model/VaultFileAccess.swift` — proven by `Sources/DurabilityTests` (issue #22), not part of the routine test run (see `../CLAUDE.md`) |
| Opens `.kdbx` files from Finder / double-click / `open(1)`, with a save prompt if one is already open | pass-sumo behaves like a normal Mac document-based app for `.kdbx` files. | `Sources/App/DocumentOpenReceiver.swift`, `Sources/App/VaultOpenRouter.swift` (issue #84) |
| Keyboard-first command surface | Every action (new/open/save, copy username/password, lock, delete, search) has a menu item and a shortcut. | `Sources/App/AppCommands.swift` |

## Partial

| Feature | Actual state | Source area |
|---|---|---|
| Password strength meter | Shown only when setting or changing the **master password**, at database creation (`WelcomeView`). Not shown next to entry passwords or in the generator's own "Use this on an entry" flow beyond its entropy-bits line. | `Sources/UI/WelcomeView.swift` (`PasswordStrengthMeter`), `Sources/UI/GeneratorSheet.swift` (entropy line only) |

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
