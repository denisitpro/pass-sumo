# pass-sumo — repo context for AI agents

> Status: living · Last verified: 2026-08-30 · [AI - claude-opus-5]

## What this is

pass-sumo is a native Swift (SwiftUI/AppKit, App Store-distributed) password manager for the
KeePass KDBX 4.x format. macOS-first, possibly iOS later.

**Status: alpha.** The app builds and runs (placeholder-ish SwiftUI, no design pass yet — see
issue #3). `make test` currently passes 217 tests (1 skipped, 0 failures) and `make durability`
22 tests (1 skipped, 0 failures), both verified by running them in this repo. The unit suite's
single skip, `testRealKeychainIsNotExercisedByThisSuite`, is deliberate: reading
a `.biometryCurrentSet` keychain item always prompts for Touch ID, which cannot be satisfied
unattended. The v1 feature scope lives in GitHub issue #1.

## Positioning

pass-sumo does not compete with Apple Passwords. The target user deliberately wants a password
manager that is NOT integrated into the Apple ecosystem: privacy-focused users, people who have
been burned by account lockouts, and people who need the cross-platform KDBX format. Primary usage
is desktop/laptop, for users managing hundreds of passwords.

Anti-bloat is a core part of the positioning: the counter-positioning is "what Strongbox was
before the feature creep."

Pricing intent: undercut Strongbox ($24.99/yr, $124.99 lifetime).

## Key decisions (dated 2026-08-29)

- The `.kdbx` file is the single source of truth; sync = the file living in iCloud Drive or on
  local disk. No own cloud. P2P (PearPass-style) sync is deferred, not v1.
- No AutoFill and no browser extensions in v1 — this is an attack-surface positioning choice. A
  system Credential Provider may come later as an opt-in (v2), which is also the only technical
  path to passkeys.
- No passkeys in v1: they require the system Credential Provider (macOS 14+), and there is no
  clean cross-client KDBX storage convention. KeePassXC uses `KPEX_PASSKEY_*` custom attributes in
  separate entries; Strongbox stores passkeys in-entry; the two are documented as incompatible.
- **GPL code is prohibited** — GPLv3 is incompatible with App Store distribution. This rules out
  KeePassKit (GPLv3, Obj-C) and KeePassium's sources (GPLv3). Data-layer options: fork/adopt
  KDBXKit (BSD-2-Clause, github.com/shadone/KDBXKit, young — May 2026) or write our own
  permissive-licensed KDBX library (to be open-sourced separately). Writing our own must follow the
  KDBX spec and reference test vectors, never by porting GPL code.
- Interop is a hard requirement: round-trip CI against `keepassxc-cli`; databases must open in
  KeePassium/Strongbox and vice versa; always back up before the first save to an existing DB.

## Repo structure

The load-bearing convention: **everything under `PassSumo/` is meant to be publishable on its
own** — code, its own `README.md`/`CONTRIBUTING.md`/`THIRD-PARTY-NOTICES.md`, `project.yml`,
`Makefile`, tests, fixtures, scripts. It has no dependency on anything outside itself.

Everything else stays at the repo root and must never leak into `PassSumo/`:

- `docs/` — long-lived, public-ish docs (specs, ADRs, the `docs/publish/` Apple-submission
  handover sheets), English.
- `thinks/` — private planning/research notes, never published.
- `thinks/prompts/` — prompts written for other AIs.
- `design/` — the design system, design tokens, UX guidelines, mockups, reference screenshots,
  and logo/icon source art (see `design/README.md`).
- `claude-memory/` — per-repo AI memory (see Working rules below).
- `AGENTS.md` — symlink to `CLAUDE.md`.

When adding a file, decide which side of that line it falls on: source, tests, fixtures, and
anything a future open-source consumer of the app would need goes in `PassSumo/`; internal
planning, AI memory, and Apple-account-specific publishing notes stay at the root.

## Build & test

Work inside `PassSumo/` (`cd PassSumo`). The Xcode project is generated from `project.yml`, not
committed. `make help` lists every target; the ones that matter day to day:

- `make generate` — regenerate `PassSumo.xcodeproj` from `project.yml`.
- `make debug` — unsigned Debug build; a fast compile check, not the human workflow.
- `make release` — signed Release build, left in DerivedData (not installed).
- `make local` — regenerate + signed Release build + install to `/Applications` + launch;
  one-step "build it and let me test it".
- `make test` — the routine check: the hosted unit suite (`PassSumoUnitTests`), unsigned, no
  automation grant, no focus steal. Run this on every change.
- `make test-signed` — same suite, signed; only needed for Keychain/Touch ID behavior, which
  requires a real sandbox container and entitlements.
- `make durability` — the crash-safety suite (`PassSumoDurabilityTests`, issue #22): it spawns a
  helper executable that saves a database through the real `VaultStore`/codec/file-access stack,
  `SIGKILL`s it at controlled points (during the KDF, during the backup copy, inside the atomic
  write), and reopens whatever is on disk. Also covers KDBX 4.1 header conformance, inner
  random-stream key regeneration, and hostile input. Deliberately NOT part of `make test` — not
  mainly for its ~28 s, but because it kills subprocesses and depends on `keepassxc-cli` and
  `sandbox-exec`. Run it on any change to the save path, the codec, or `SandboxedVaultFileAccess`.
  What it does and does not prove — in particular the unsigned/no-sandbox caveat — is documented in
  `PassSumo/Sources/DurabilityTests/README.md`, which also records the two real defects it found.
- `make durability-signed` — the same suite with signing, so the real-App-Sandbox-container test
  stops skipping (22 tests, 4 skipped). Most kill tests still work — the helper carries no
  entitlements and stays unsandboxed — but four cases skip, because a sandboxed host cannot launch
  `sandbox-exec` (no nesting) and cannot poll a directory fast enough to catch the atomic write's
  temporary file. Neither run is a superset of the other.
- `make e2e` — the XCUITest suite (`PassSumoUITests`). Steals keyboard/mouse focus and needs a
  one-time system automation grant. Run only when asked, never as part of a routine edit loop.
- `make remove-app` / `make remove` — uninstall the built app, optionally wiping all persisted
  user state (sandbox container, Keychain-adjacent bookmarks, prefs) for a first-install test.

Sources are picked up by a directory glob in `project.yml` (`Sources/**`, excluding the test
directories from the app target), so a new `.swift` file needs no `project.yml` edit. A new
**test directory**, however, does: each one needs its own line under the relevant test target's
`sources`/`excludes`, or it silently doesn't compile in (or, for a fixtures folder, doesn't get
copied into the test bundle as a folder reference).

## Architecture

- `Sources/Model` — domain types, the `VaultCodec` protocol, `VaultStore` (also owns Recycle Bin
  moves/empty and Touch ID database-ID assignment), an in-memory fake codec for tests/previews.
- `Sources/KDBX` — the real `VaultCodec` implementation, wrapping KDBXKit, including attachment
  handling (`KDBXAttachments.swift`).
- `Sources/Security` — password generator, TOTP, clipboard handling, auto-lock, Keychain/Touch ID.
- `Sources/App` — composition root, menu commands.
- `Sources/UI` — SwiftUI views.

Entry attachments (view/add/export/remove) are backed by a vault-wide payload pool keyed by the
SHA-256 of the bytes, with entries carrying metadata references and a 25 MB per-attachment limit
checked against the declared file size before the bytes are read. Deleting an item moves it to a
lazily-created Recycle Bin group (the standard `Meta/RecycleBinEnabled` + `Meta/RecycleBinUUID` +
`Meta/RecycleBinChanged` convention); deleting again inside the bin is permanent; auto-purge is
deliberately not implemented (tracked as its own issue). Touch ID unlock now has an enrollment path
— a "Remember with Touch ID" opt-in on the unlock screen plus a Settings toggle — where previously
the unlock code existed but nothing stored a secret, so the feature was unreachable.

Dependency-inversion rule: the app depends on protocols (`VaultCodec`, `VaultFileAccess`,
`SecretStore`), never on their concrete implementations. That is what lets the whole UI run
against in-memory fakes in tests and previews, with the real KDBXKit-backed codec swapped in only
at the composition root.

The app supports a `-ui-testing 1` launch argument seam (checked in `Sources/App`) that the
`PassSumoUITests` e2e suite depends on to get the app into a testable, hermetic state.

## Data-layer decision

The KDBX 4.x codec is built on **KDBXKit, vendored into this repository** at
`PassSumo/Vendor/KDBXKit` via `git subtree`, from upstream `https://github.com/shadone/KDBXKit.git`
at revision `e9b8839f1226b82665e1e4b7f12f13635d189deb` (a commit on upstream's unreleased `develop`
branch) — never an upstream tag. `project.yml` consumes it as a local package (`path:
Vendor/KDBXKit`), not a remote SwiftPM pin. It is vendored rather than a remote fork so the library
can stay private and be patched in-tree while it is still being debugged; the intent is to publish
it as its own repo once it stabilises. Full mechanics — pulling upstream changes in
(`git subtree pull`), splitting the tree back out for publication (`git subtree split`), and the
local-patches log — live in `PassSumo/Vendor/KDBXKit-VENDORING.md`.

Every released tag (v1.3.0 and earlier) carries a real cryptographic defect (the inner
random-stream key is not regenerated on save, so two saves of the same vault XOR protected fields
with the same keystream) plus an uncatchable process trap on a malformed/corrupt file; both are
fixed only on `develop`. **Never move this pin to an upstream tag** — that would be a regression,
not an upgrade. Full reasoning and licensing verification: issue #5.

## Gotchas worth recording

- **Two open durability defects, found by `make durability` (issue #22), reported not fixed.**
  (1) `VaultStore.save()` has no mutual exclusion — it is `@MainActor` but its body is an awaited
  `Task.detached`, so two `save()` calls encode and write concurrently (measured overlap: 2). The
  file is never torn (each write is atomic, one rename wins) but the loser's edits are silently
  discarded while its `save()` reports success. (2) Under a sandbox grant covering only the vault
  FILE, the save fails — at the pre-save backup, which creates `<name>.kdbx.bak-<stamp>` in a
  directory the app was never granted. `Data.write(options: [.atomic])` itself is fine there:
  Foundation falls back to a temporary file outside the directory and still replaces by rename.
  Details and evidence in `PassSumo/Sources/DurabilityTests/README.md`.
- `FileManager.copyItem` on APFS issues `clonefile(2)` (1 GiB in ~2 ms, measured), so the pre-save
  backup is complete the instant it exists and cannot be observed half-written. That guarantee is
  the filesystem's, not ours — on a volume where `copyfile` falls back to a byte copy (network
  share, exFAT, disk image) a crash mid-copy would leave a truncated `.bak-` file.
- KDBX binary-pool slots are **append-only — never removed, never renumbered**. Entry *history*
  snapshots hold positional references into that pool, so compacting it would repoint them at the
  wrong payload or past the end. Consequence: removing the last reference to an attachment leaves
  an orphan payload in the pool — deliberate, and matches what KeePass and KeePassXC do.
- Enabling Touch ID **writes to the user's database file**: it has to assign the stable database
  UUID in `Meta/CustomData` under `PassSumo/DatabaseID`, because the identifier cannot come from
  the file path or from the KDBX master seed (the master seed is regenerated on every save by
  design — see below).
- `keepassxc-cli` 2.7.12 cannot create KDBX 4.x databases at all — it has no KDF/cipher/format
  flags, and every database it creates is KDBX 3.1 / AES-KDF / AES-256. It proves interop in the
  WRITE direction only (it reads KDBX 4 fine); it cannot produce KDBX 4 read fixtures.
- KeePassXC's TOTP convention is a single plain string field named `otp` holding a full
  `otpauth://totp/...` URI — not the older split `TOTP Seed` / `TOTP Settings` pair. Verified
  empirically against a real KeePassXC-written fixture.
- The KDBX 4 master seed is regenerated on every save by design, so it must never be used to
  derive a stable per-database identifier. The stable identity is a UUID in `Meta/CustomData`.
- `ITSAppUsesNonExemptEncryption` is `true` here, unlike the sibling app ShotSumo — pass-sumo
  implements its own confidentiality encryption (KDBX's AES-256/ChaCha20 payload cipher under an
  Argon2-derived key), which is not covered by the "authentication-only" exemption. This is a
  legal declaration with downstream self-classification obligations; see issue #4.
- `PassSumo/LICENSE` (decided 2026-08-30): PolyForm Noncommercial License 1.0.0, same as the
  sibling app ShotSumo. Source-available, not OSI open source. Permissive third-party components
  (KDBXKit and its transitive dependencies, see `THIRD-PARTY-NOTICES.md`) remain shippable inside
  it, provided their own copyright notices and license texts are retained.

## Open issues

- #1 — v1 feature scope (KDBX read/write, unlock, search, generator, TOTP, backups, auto-lock).
- #3 — design system + UX guideline (Strongbox as an information-architecture reference, not as
  scope) before the beta UI pass.
- #4 — export-compliance confirmation for `ITSAppUsesNonExemptEncryption = true` and its
  obligations, before first App Store submission.
- #5 — the KDBXKit vendoring decision and its fix list (Argon2 v1.0 key-derivation bug, interop CI
  wiring, Twofish decision, and others).
- #22 — the durability suite (`make durability`). Built; the two defects it found are listed under
  "Gotchas worth recording" above and are NOT fixed — each is its own decision.

## Acceptance criteria (owner's definition)

- **Alpha** is done when the app basically works.
- **Beta** is done when every feature in issue #1 works, and the owner has used it for several
  days to judge correctness.

## Working rules

- Chat with the user in Russian. Code, comments, commit messages, PR titles/descriptions, and all
  docs are in English.
- Non-trivial work goes through a GitHub issue first (labels: idea/feature/bug/docs); branch + PR
  reference the issue.
- AI never merges PRs and never commits to main directly.
- Commit/PR attribution: final line `[AI - <model-id>]`.
- Per-repo AI memory lives in `claude-memory/` (symlinked by a SessionStart hook — do not create or
  fix the symlink manually).
