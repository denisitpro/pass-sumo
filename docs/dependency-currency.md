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
| `apple/swift-crypto` | 3.15.1 | 3.15.1 (unchanged) | 4.5.2 | Two items, see notes below the table — GHSA-9m44-rr2w-ppp7 (**high**, X-Wing HPKE) does not affect 3.15.1; GHSA-8q93-f6xh-4f6f / CVE-2026-43823 (RSA double-free) does, fixed only in 4.5.1+. | RSA: no — see notes. AES-CBC (`_CryptoExtras.AES._CBC`): no on Apple platforms — see notes. |
| `apple/swift-asn1` | 1.7.0 | **1.7.2** | 1.7.2 | GHSA-w8xv-rwgf-4fwh (low, malformed BER/DER crash), fixed in 1.3.1 — does not affect 1.7.0 or 1.7.2. | N/A (already patched) |
| `apple/swift-log` | 1.12.0 | **1.15.1** | 1.15.1 | None found | N/A |
| `apple/swift-argument-parser` | 1.5.0 | **1.8.2** | 1.8.2 | None found | Only linked into the vendored `kdbx-cli`/`KDBXCLICore` dev targets, never into the `KDBXKit` library product the app ships |
| `apple/swift-docc-plugin` | 1.5.0 | 1.5.0 (unchanged) | 1.5.0 | None found | Docs-generation only, not shipped |
| `swiftlang/swift-docc-symbolkit` | 1.0.0 | 1.0.0 (unchanged) | 1.0.0 is still the newest **semver** tag; upstream has since switched to toolchain-snapshot tags only (33 commits past our pin on that scheme, e.g. `swift-6.3.3-RELEASE`), so there is no newer version SwiftPM's resolver could select | 1.0.0 (semver) | None found | Docs-generation only, not shipped |

**How advisories were checked** (re-run these, don't re-derive): `gh api
/advisories?ecosystem=swift&affects=<package>` lists what's in GitHub's global, reviewed Advisory
Database for that package; `gh api /repos/<owner>/<repo>/security-advisories` separately lists every
advisory *published on that repo*, which can be a superset of the global database — see the
`swift-crypto` notes below, where one real advisory is missing from the global list entirely.

**`swift-crypto` advisory notes (checked 2026-09-10):**

- **GHSA-9m44-rr2w-ppp7** (X-Wing HPKE malformed-ciphertext-length decapsulation, CVE-2026-28815):
  severity is **high**, range `4.0.0–4.3.0`, patched `4.3.1` — all confirmed against
  `gh api /advisories/GHSA-9m44-rr2w-ppp7`. Does not affect 3.15.1.
- **GHSA-8q93-f6xh-4f6f** (double-free when an RSA public key fails to parse, CVE-2026-43823): **not
  returned by** `gh api /advisories?ecosystem=swift&affects=swift-crypto` or
  `gh api /advisories/GHSA-8q93-f6xh-4f6f` (404) — that call only reaches GitHub's global, reviewed
  Advisory Database, and this one is not (yet) in it, which is why a first pass can miss it. It is
  real: published on the repo itself
  (`gh api /repos/apple/swift-crypto/security-advisories` → `state: published`,
  `severity: critical`, range `>=3.2.0, <=4.5.0`, `patched_versions: 4.5.1`;
  `https://github.com/apple/swift-crypto/security/advisories/GHSA-8q93-f6xh-4f6f` → HTTP 200), and
  independently confirmed via NVD (`CVE-2026-43823`, analyzed, published 2026-07-23, CVSS v3.1 base
  score 7.5 / **HIGH**, description: "addressed in swift-crypto version 4.5.1", citing that exact GHSA
  URL as the vendor advisory). So: real, has a CVE, fixed only in 4.5.1+ (no 3.x release ever received
  the fix — 3.15.1 is the latest 3.x tag that exists), but a dependency scan that only queries the
  global Advisory Database will not surface it.
  - **Reachability — RSA:** not reachable. `grep -rn --include='*.swift' -E '_RSA|\bRSA\b'` across
    `PassSumo/Sources` and `Vendor/KDBXKit/Sources` returns exactly one hit, a doc comment in
    `KDBX/Entry+Passkey.swift:22` ("PKCS#8 PEM-encoded private key (EC or RSA depending on the
    algorithm)") — no RSA key is ever initialized anywhere in the tree. Note the precise phrasing:
    `_CryptoExtras` (the module the vulnerable RSA types live in) **is linked** into the shipped
    `KDBXKit` target (`Package.swift`'s `KDBXKit` target depends on
    `.product(name: "_CryptoExtras", package: "swift-crypto")`) — the vulnerable code is linked but
    never called, not simply absent from the binary.
- **Also in the 4.5.1 release notes, not an advisory but relevant to us:** "Back AES-CBC with
  BoringSSL and constant-time PKCS#7 unpadding" (PR #448). `Vendor/KDBXKit` does use `_CryptoExtras`
  for AES-CBC (`AES256CBC.swift`) and AES-KDF (`KDF/AESKDF.swift`). Checked both: `AES256CBC.swift`
  routes through CommonCrypto under `#if canImport(CommonCrypto)` — on Apple platforms (what we ship)
  `_CryptoExtras.AES._CBC` is never called (the file's own comment: swift-crypto's path is ~180x
  slower, which is why CommonCrypto is used instead); the `_CryptoExtras` path only compiles in the
  `#else` (non-Apple) branch. `AESKDF.swift` uses `AES.permute`, a single-block ECB permutation with
  no padding involved, unrelated to this fix. Net: not reachable on the platforms this app ships to;
  would only matter for a non-Apple build of the vendored library (its CLI/CI lane).

**How the bump was made and verified:** `swift package update` inside `Vendor/KDBXKit`, with no edit to
any `.package(... from:)` bound in `Package.swift` — every resolved version above stayed inside the
range the manifest already declared. Verified with `make generate`, `make test` (355/355, 1 deliberate
skip), and `make durability` (23/23, 1 expected skip on an unsigned host) — the latter's
`FormatConformanceTests` exercise the real `keepassxc-cli` round trip, so interop was checked, not just
our own tests. This follow-up correction (advisory wording only) was **not** re-verified with
`make test` / `make durability` — no code or dependency version changed, only prose, so re-running the
suites would add nothing.

## Decisions for the owner

1. **`swift-crypto` 3.15.1 → 4.x is a major bump — deliberately NOT done here.** It is #23's job (API
   changes expected in `_CryptoExtras`, needs its own dedicated verification pass and a
   `keepassxc-cli` round trip). The defensible, verifiable argument for re-weighing #23's priority is
   not "a critical CVE" by itself — it's that **3.x is a dead branch receiving no fixes at all**:
   3.15.1 is the newest 3.x tag that exists, and GHSA-8q93-f6xh-4f6f's fix (see notes above) landed
   only in 4.5.1 with no 3.x backport, so any future defect in this dependency will ship a fix only on
   a major line we are not on. Not reachable today (no RSA key parsing anywhere in the app or the
   vendored library; the AES-CBC 4.5.1 fix is also unreachable — see notes above), so there is no
   live exposure to point at, but the branch being unmaintained is true on its own.
2. **App-target Swift language mode: bump `SWIFT_VERSION` from `"6.0"` to `"6.1"` (or higher)?** The
   vendored library already builds under swift-tools-version 6.1 and the installed toolchain is 6.3.3,
   so the app is one language-mode step behind what it already links against. Not applied here: a
   language-mode bump can surface new Swift 6.1+ strict-concurrency diagnostics across `Sources/App`,
   `Sources/UI`, etc., which needs its own build-and-fix pass, not a blind flip.
3. **Nothing to do on the macOS deployment target.** 26.0 is already the newest shipping macOS: no
   gap, and raising it further isn't possible yet. Recorded for completeness per the issue's DoD.
