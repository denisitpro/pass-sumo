# pass-sumo — repo context for AI agents

> Status: living · Last verified: 2026-08-30 · [AI - claude-sonnet-5]

## What this is

pass-sumo is a native Swift (SwiftUI/AppKit, App Store-distributed) password manager for the
KeePass KDBX 4.x format. macOS-first, possibly iOS later.

**Status: alpha.** The app builds and runs (placeholder-ish SwiftUI, no design pass yet — see
issue #3). `make test` currently passes 156 of 156 unit tests (1 skipped), verified by running it
in this repo. The v1 feature scope lives in GitHub issue #1.

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

- `Sources/Model` — domain types, the `VaultCodec` protocol, `VaultStore`, an in-memory fake
  codec for tests/previews.
- `Sources/KDBX` — the real `VaultCodec` implementation, wrapping KDBXKit.
- `Sources/Security` — password generator, TOTP, clipboard handling, auto-lock, Keychain/Touch ID.
- `Sources/App` — composition root, menu commands.
- `Sources/UI` — SwiftUI views.

Dependency-inversion rule: the app depends on protocols (`VaultCodec`, `VaultFileAccess`,
`SecretStore`), never on their concrete implementations. That is what lets the whole UI run
against in-memory fakes in tests and previews, with the real KDBXKit-backed codec swapped in only
at the composition root.

The app supports a `-ui-testing 1` launch argument seam (checked in `Sources/App`) that the
`PassSumoUITests` e2e suite depends on to get the app into a testable, hermetic state.

## Data-layer decision

The KDBX 4.x codec is built on **our fork**, `github.com/denisitpro/KDBXKit`, pinned in
`project.yml` to the exact revision `e9b8839f1226b82665e1e4b7f12f13635d189deb` (a commit on
upstream `shadone/KDBXKit`'s unreleased `develop` branch) — never an upstream tag. Every released
tag (v1.3.0 and earlier) carries a real cryptographic defect (the inner random-stream key is not
regenerated on save, so two saves of the same vault XOR protected fields with the same keystream)
plus an uncatchable process trap on a malformed/corrupt file; both are fixed only on `develop`.
**Never move this pin to an upstream tag** — that would be a regression, not an upgrade. Full
reasoning, the fork's fix list, and licensing verification: issue #5.

## Gotchas worth recording

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
- #5 — the KDBXKit fork decision and its fix list (Argon2 v1.0 key-derivation bug, interop CI
  wiring, Twofish decision, and others).

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
