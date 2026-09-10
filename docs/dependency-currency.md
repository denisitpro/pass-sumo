# Platform and dependency currency

> Status: living · Last verified: 2026-09-10 · [AI - claude-sonnet-5]

Standing audit table for issue #116: what we build against and ship, what is current upstream, and
whether the gap is ours to close. Re-run this audit before each release (per #23's own standing-task
note) and diff against this file instead of re-deriving it. All facts below were read from the actual
source on 2026-09-10, not inferred from a naming pattern — see "How this was verified".

## Platform and toolchain

| Component | We are on | Current | Gap | Close it? |
|---|---|---|---|---|
| macOS deployment target | 26.0 (`PassSumo/project.yml`, all targets) | 26.0 is the newest shipping macOS | None | — |
| Swift language mode (app targets) | `SWIFT_VERSION: "6.0"` (`project.yml`) | Installed toolchain is Swift 6.3.3; vendored `KDBXKit/Package.swift` already declares `// swift-tools-version: 6.1` | App targets are pinned one language-mode step behind what the toolchain and the vendored library already use | **Owner decision** — see below |
| Xcode / Swift toolchain (this machine) | Xcode 26.6 (17F113), Swift 6.3.3 (`swift-driver` 1.148.6), target `arm64-apple-macosx26.0` | N/A — comes from the installed Xcode, not a repo pin | — | — |
| XcodeGen (`make generate`) | 2.46.0 | 2.46.0 (2026-07-16) | None | — |

## Vendored KDBXKit (subtree @ `Vendor/KDBXKit`)

| What | Value |
|---|---|
| Pinned revision | `e9b8839f1226b82665e1e4b7f12f13635d189deb` on upstream `develop` |
| Commits behind upstream `develop` HEAD | **0** — verified by fetching `github.com/shadone/KDBXKit` read-only and diffing; our pin *is* upstream `develop` HEAD |
| Newest upstream tag | `v1.3.0` (no tag newer exists) — pin deliberately stays off tags per CLAUDE.md/issue #5 (every tag through v1.3.0 carries the inner-random-stream-reuse defect and an uncatchable crash on malformed input, both fixed only on `develop`) |
| Local patches on top | 3 entries dated 2026-09-09 in `Vendor/KDBXKit-VENDORING.md` (inner-header key-length fix, issue #30) — untouched by this audit |

## Vendored Argon2 C reference (`KDBXKit/Sources/CArgon2`)

| What | Value |
|---|---|
| Vendored at | upstream `P-H-C/phc-winner-argon2` commit `f57e61e` (2021-06-25) |
| Commits behind upstream default branch | **0** — that commit is still upstream HEAD; the reference repo has had no commits and no advisories since |
| Note | "0 behind" here means upstream has been dormant since 2021, not that this was freshly re-audited for correctness — see issue #5's standing concern that nothing will ever flag this as stale on its own |

## SwiftPM dependencies of `Vendor/KDBXKit` (resolved in `Package.resolved`)

| Dependency | Before this PR | After this PR | Current release | Advisory in range | Reachable from us? |
|---|---|---|---|---|---|
| `apple/swift-crypto` | 3.15.1 | 3.15.1 (unchanged) | 4.5.2 | **GHSA-8q93-f6xh-4f6f**, critical, double-free parsing a malformed RSA key, range `>=3.2.0, <=4.5.0` — fixed only in **4.5.1+**, no 3.x backport exists. Also GHSA-9m44-rr2w-ppp7 (medium, X-Wing HPKE), range `4.0.0-4.3.0`, does not affect 3.15.1. | No — `grep -rn "_RSA" Vendor/KDBXKit/Sources PassSumo/Sources` returns zero matches; neither KDBXKit nor the app ever parses an RSA key. |
| `apple/swift-asn1` | 1.7.0 | **1.7.2** | 1.7.2 | GHSA-w8xv-rwgf-4fwh (low, malformed BER/DER crash), fixed in 1.3.1 — does not affect 1.7.0 or 1.7.2. | N/A (already patched) |
| `apple/swift-log` | 1.12.0 | **1.15.1** | 1.15.1 | None found | N/A |
| `apple/swift-argument-parser` | 1.5.0 | **1.8.2** | 1.8.2 | None found | Only linked into the vendored `kdbx-cli`/`KDBXCLICore` dev targets, never into the `KDBXKit` library product the app ships |
| `apple/swift-docc-plugin` | 1.5.0 | 1.5.0 (unchanged) | 1.5.0 | None found | Docs-generation only, not shipped |
| `swiftlang/swift-docc-symbolkit` | 1.0.0 | 1.0.0 (unchanged) | 1.0.0 is still the newest **semver** tag; upstream has since switched to toolchain-snapshot tags only (33 commits past our pin on that scheme, e.g. `swift-6.3.3-RELEASE`), so there is no newer version SwiftPM's resolver could select | 1.0.0 (semver) | None found | Docs-generation only, not shipped |

**How the bump was made and verified:** `swift package update` inside `Vendor/KDBXKit`, with no edit to
any `.package(... from:)` bound in `Package.swift` — every resolved version above stayed inside the
range the manifest already declared. Verified with `make generate`, `make test` (355/355, 1 deliberate
skip), and `make durability` (23/23, 1 expected skip on an unsigned host) — the latter's
`FormatConformanceTests` exercise the real `keepassxc-cli` round trip, so interop was checked, not just
our own tests.

## Decisions for the owner

1. **`swift-crypto` 3.15.1 → 4.x is a major bump — deliberately NOT done here.** It is #23's job (API
   changes expected in `_CryptoExtras`, needs its own dedicated verification pass and a
   `keepassxc-cli` round trip). New information for #23: **GHSA-8q93-f6xh-4f6f (critical) did not
   exist when #23 was written** and its fix landed only in 4.5.1+, with no patch on any 3.x release —
   so the gap is not just "a major version behind" any more, it is "the only fix for a critical CVE is
   on the other side of a major bump we're intentionally deferring." Currently not reachable (no RSA
   use anywhere in the app or the vendored library), but worth re-weighing #23's priority in light of
   this.
2. **App-target Swift language mode: bump `SWIFT_VERSION` from `"6.0"` to `"6.1"` (or higher)?** The
   vendored library already builds under swift-tools-version 6.1 and the installed toolchain is 6.3.3,
   so the app is one language-mode step behind what it already links against. Not applied here: a
   language-mode bump can surface new Swift 6.1+ strict-concurrency diagnostics across `Sources/App`,
   `Sources/UI`, etc., which needs its own build-and-fix pass, not a blind flip.
3. **Nothing to do on the macOS deployment target.** 26.0 is already the newest shipping macOS: no
   gap, and raising it further isn't possible yet. Recorded for completeness per the issue's DoD.
