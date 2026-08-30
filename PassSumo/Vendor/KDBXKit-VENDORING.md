# Vendoring KDBXKit

`Vendor/KDBXKit/` is a **`git subtree` copy** of the KDBX 4.x library
[`shadone/KDBXKit`](https://github.com/shadone/KDBXKit), licensed **BSD-2-Clause**. It is not a
submodule and not a SwiftPM checkout: its files are ordinary tracked files in this repository, and
`project.yml` consumes it as a local package (`packages: KDBXKit: path: Vendor/KDBXKit`).

This file lives at `Vendor/`, deliberately **outside** the vendored tree. Everything under
`Vendor/KDBXKit/` is kept byte-for-byte identical to upstream so that future `git subtree pull`
merges stay clean; adding our own file inside it would create a conflict surface for no reason.

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

**None.** The vendored tree is currently byte-for-byte identical to upstream
`e9b8839f1226b82665e1e4b7f12f13635d189deb` (verified: identical git tree object).

Every local change to `Vendor/KDBXKit/` must be appended here as one line — what changed and why —
so that a conflict during a future `git subtree pull` is explicable rather than mysterious. If
this section still says "None", any conflict is an upstream-vs-upstream problem, not ours.

| Date | Path | What / why |
| --- | --- | --- |
| — | — | (no local patches yet) |
