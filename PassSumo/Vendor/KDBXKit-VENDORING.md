# Vendoring KDBXKit

`Vendor/KDBXKit/` is a **`git subtree` copy** of the KDBX 4.x library
[`shadone/KDBXKit`](https://github.com/shadone/KDBXKit), licensed **BSD-2-Clause**. It is not a
submodule and not a SwiftPM checkout: its files are ordinary tracked files in this repository, and
`project.yml` consumes it as a local package (`packages: KDBXKit: path: Vendor/KDBXKit`).

This file lives at `Vendor/`, deliberately **outside** the vendored tree. The tree is kept as close
to upstream as the app allows so that future `git subtree pull` merges stay clean — local changes
are only ever targeted fixes, each one logged under "Local patches" below — and adding our own
*new* files inside it would create a conflict surface for no reason.

## Upstream and pinned revision

- Upstream: `https://github.com/shadone/KDBXKit.git`
- Vendored revision: **`e9b8839f1226b82665e1e4b7f12f13635d189deb`**
- That revision is a commit on upstream's **unreleased `develop` branch — never a released tag.**

**Do not "upgrade" this to a tag.** Every upstream release up to and including `v1.3.0` carries
two defects that matter to a password manager:

1. **The inner random-stream key is not regenerated on save.** Two consecutive saves of the same
   vault therefore XOR their protected fields (passwords, TOTP seeds) with the *same* keystream.
   An attacker holding both files recovers plaintext by XORing them together — no key needed.
2. **An uncatchable process trap on a malformed file.** A negative length field hits a Swift
   runtime trap, i.e. a crash the app cannot defend against, on nothing worse than a corrupt
   download.

Both are fixed only on `develop`. Moving this pin back to a released tag would be a **regression,
not an upgrade** — the moment to revisit is when a release exists that contains both fixes, and
not before.

## Why vendored rather than an SPM dependency

The library is still being actively debugged for this app's needs. Vendoring buys two things a
remote SPM pin cannot:

- **Privacy while we work.** No public fork has to exist, and no half-finished fix has to be
  pushed to a public repository, just to make the app build.
- **In-tree patching.** A local fix is a normal commit in this repo, reviewable in this repo's own
  diffs and CI, instead of a cross-repo dance of "push a fork commit, then bump the pin".

The tree is a subtree rather than a plain file copy precisely so that neither of those becomes a
one-way door: upstream changes can still be merged in, and our copy can still be split back out
into a real, publishable repository. See both commands below.

## Pulling upstream changes in

```sh
git subtree pull --prefix=PassSumo/Vendor/KDBXKit https://github.com/shadone/KDBXKit.git develop --squash
```

Run it from the repository root, on a clean working tree. Resolve any conflict against the "Local
patches" list at the bottom of this file — that list is the only reason a conflict should be
surprising. After the merge, re-run `cd PassSumo && make generate && make test`.

## Splitting our copy back out for publication

When we decide to open-source the library:

```sh
git subtree split --prefix=PassSumo/Vendor/KDBXKit -b kdbxkit-publish
git push git@github.com:<org>/<new-repo>.git kdbxkit-publish:main
```

`git subtree split` rewrites the history of `PassSumo/Vendor/KDBXKit/` into a standalone branch
whose commits contain **only that directory**, rooted at its own top level (`Package.swift` at the
branch root, not at `PassSumo/Vendor/KDBXKit/Package.swift`). Nothing else from this repository —
no app source, no private notes, no root-level history — is reachable from that branch, so it is
**safe to publish as-is**.

## Local patches

The vendored tree is no longer byte-for-byte identical to upstream
`e9b8839f1226b82665e1e4b7f12f13635d189deb`. Every local change to `Vendor/KDBXKit/` must be
appended below as one line — what changed and why — so that a conflict during a future
`git subtree pull` is explicable rather than mysterious. A conflict outside these paths is an
upstream-vs-upstream problem, not ours.

Everything listed here **should be reported upstream to `shadone/KDBXKit`** so the fork does not
have to carry it forever. Reporting is a separate, deliberate act; do not open an upstream PR as a
side effect of a local fix.

| Date | Path | What / why |
| --- | --- | --- |
| 2026-09-09 | `Sources/KDBXKit/InnerHeader/InnerHeader+cryptor.swift` | Reader accepts an inner random-stream key `K` of **any non-empty length**, instead of requiring exactly 64 bytes (ChaCha20) / 32 (Salsa20). `K` is hashed before use (`SHA-512(K)` → key ‖ nonce for ChaCha20, `SHA-256(K)` for Salsa20), so any non-empty length derives a valid cipher key; the fixed lengths are a *writer* convention, not a readable-file constraint. Upstream's over-strict guard made a real, intact 5.7 MB KDBX 4.0 database with a 32-byte `K` completely unopenable. `CryptorError.invalidKeyLength(algorithm:expected:got:)` is replaced by `CryptorError.emptyKey(algorithm:)` — an empty `K` is the only genuinely broken case. Doc comment corrected: it previously asserted the opposite premise (and additionally claimed `InnerHeaderReader` rejects mismatches, which it does not). Issue #30. **Report upstream.** |
| 2026-09-09 | `Sources/KDBXKit/InnerHeader/InnerHeader+validate.swift` | Same defect in the advisory validator: an unconventional `K` length was reported as `.error`. Now `.error` only for an empty key, `.warning` for an unconventional length, with the wording explaining that the key is hashed. Also fixes a copy-paste bug in the Salsa20 branch, which said "expected 64 bytes" for a 32-byte convention. **Report upstream.** |
| 2026-09-09 | `Sources/KDBXKit/InnerHeader/InnerHeader.swift`, `Sources/KDBXKit/KDBXWriter.swift`, `Sources/KDBXKit/KDBXContent+Factory.swift` | Comments only, no behaviour change. Each stated or implied that the inner-stream key length is fixed by the format. Reworded to say it is a writer convention that this library's writer deliberately keeps (64 / 32 bytes, matching KeePass and KeePassXC) while the reader tolerates any non-empty length. **Report upstream** alongside the two entries above. |
