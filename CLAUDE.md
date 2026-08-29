# pass-sumo — repo context for AI agents

> Status: living · Last verified: 2026-08-29 · [AI - claude-sonnet-5]

## What this is

pass-sumo is a native Swift (SwiftUI/AppKit, App Store-distributed) password manager for the
KeePass KDBX 4.x format. macOS-first, possibly iOS later.

Pre-development stage: no code yet. The v1 feature scope lives in GitHub issue #1.

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

- `docs/` — long-lived, public-ish docs (specs, ADRs), English.
- `thinks/` — private planning/research notes, never published.
- `thinks/prompts/` — prompts written for other AIs.
- `AGENTS.md` — symlink to `CLAUDE.md`.

## Working rules

- Chat with the user in Russian. Code, comments, commit messages, PR titles/descriptions, and all
  docs are in English.
- Non-trivial work goes through a GitHub issue first (labels: idea/feature/bug/docs); branch + PR
  reference the issue.
- AI never merges PRs and never commits to main directly.
- Commit/PR attribution: final line `[AI - <model-id>]`.
- Per-repo AI memory lives in `claude-memory/` (symlinked by a SessionStart hook — do not create or
  fix the symlink manually).
