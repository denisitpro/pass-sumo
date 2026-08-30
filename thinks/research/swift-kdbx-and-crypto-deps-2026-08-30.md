# Swift KDBX libraries and crypto-dependency currency — 2026-08-30 survey

> Status: final · Last verified: 2026-08-30

## Executive summary

1. No Swift (or Swift-usable) library beats `shadone/KDBXKit` for this project. Every GPL
   alternative (`KeePassKit`, `KeePassium`, `KeeForge`, `SwiftFastPass`) is disqualified outright by
   the App-Store licensing constraint; the only other permissively-licensed options
   (`jerikjakobsen/KDBX`, Apache-2.0) are far less mature and not interop-tested. VERIFIED.
2. Upstream `shadone/KDBXKit` has shipped nothing new since the pinned commit: `develop`'s HEAD
   *is* the pinned revision `e9b8839f...`, and the last tag remains `v1.3.0` (2026-06-11). No
   release yet contains either of the two documented safety fixes. VERIFIED.
3. The vendored `CArgon2` C sources are pinned to upstream `phc-winner-argon2` commit `f57e61e`
   (2021-06-25) — which is also still the tip of upstream's `master` today. Nothing to update; this
   is a genuinely dormant-but-current upstream, not a stale one. VERIFIED.
4. `swift-crypto`, pulled in transitively via KDBXKit's `Package.swift` (`from: "3.0.0"`), resolves
   today to **3.15.1** — one major version behind the current stable release **4.5.1**. The one
   security fix in the gap (CVE-2026-28815, X-Wing HPKE) affects only `>=4.0.0, <=4.3.0`, so it does
   **not** reach the resolved 3.15.1, and KDBXKit doesn't use HPKE/X-Wing anyway. No exploitable gap
   found, but the 3.x line appears frozen (no patch releases since 4.0 shipped). VERIFIED.
5. `zlib` is linked as the OS-provided system library (not vendored); the local macOS 26 SDK
   (Xcode 26.6 / SDK 26.5) reports `ZLIB_VERSION "1.2.12"`, past the fix line for the two
   historical zlib CVEs. This is Apple's responsibility to patch via OS updates, not the project's.
   VERIFIED (with a caveat on what the version macro proves — see Part 2).

**Recommendation: stay on KDBXKit, no dependency bump needed right now.** See Part 3.

6. A later pass (after vendoring KDBXKit locally, which made SwiftPM honour its own `Package.resolved` instead of re-resolving `from:` ranges to the newest release) found three resolved versions moved: `swift-asn1` 1.7.1→1.7.0, `swift-log` 1.15.0→1.12.0, `swift-argument-parser` 1.8.2→1.5.0 (`swift-crypto` stayed at 3.15.1). **None of these cross a known CVE** — see the Addendum at the end of this document for the per-package check.

---

## Part 1 — Survey of Swift KDBX libraries

### Method

Searched GitHub's REST API directly (`/search/repositories`, topic `kdbx`/`kdbx4`, language `Swift`,
`keepass`), cross-checked with web search, and read each repo's `LICENSE`/README `license` section
verbatim rather than trusting GitHub's license auto-detection (which mis-reports at least one of
these as `NOASSERTION` — see below). All dates/stars/licenses below are from the GitHub API
(`api.github.com/repos/...`) fetched today unless marked otherwise.

### shadone/KDBXKit (current dependency, via the `denisitpro/KDBXKit` fork)

- Repo: `github.com/shadone/KDBXKit` (consumed via `github.com/denisitpro/KDBXKit`, a fork —
  VERIFIED the fork contains the pinned commit and its `pushed_at` matches upstream exactly,
  `2026-06-12T08:22:43Z`).
- Licence: `BSD-2-Clause`. VERIFIED (github API `license.spdx_id`, and `Package.swift` header
  `SPDX-License-Identifier: BSD-2-Clause`).
- Stars: 0. VERIFIED (github API). This is a very young, single-maintainer project (`denis@ddenis.info`),
  not a widely-adopted library — worth knowing even though it's still the best option.
- Last commit / activity: `pushed_at 2026-06-12T08:22:43Z`; default branch `develop` (repo has no
  separate `main`). Tags: v1.0.0 (2026-05-19), v1.1.0 (2026-05-28), v1.2.0 (2026-05-29), v1.2.1 /
  v1.2.2 (2026-05-30), v1.3.0 (2026-06-11) — all VERIFIED via the GitHub tags+commits API.
- Read/write: reads KDBX 3.1 (read-only), 4.0, 4.1; writes 4.0/4.1. VERIFIED (README.md table:
  "Supported versions | KDBX 4.1, 4.0, KDBX 3.1 (read-only)"; also a test named
  `"FormatVersion.supported is exactly the readable set {3.1, 4.0, 4.1}"`).
- Platforms/Swift: `macOS(.v15)`, `iOS(.v18)` platform floor in `Package.swift`; `swift-tools-version:
  6.1`; builds in Swift 6 language mode with strict concurrency. VERIFIED (read `Package.swift`
  directly).
- Ciphers/KDFs: AES-256-CBC, ChaCha20 payload ciphers; AES-KDF, Argon2d, Argon2id KDFs; Salsa20/
  ChaCha20 inner stream. VERIFIED (README.md feature table).
- **Verdict: this is the library to use.** It is the only permissively-licensed, actively-developed,
  KeePassXC-interop-tested Swift KDBX 4.x codec that exists. Its only weaknesses are newness (created
  2026, 0 stars, single maintainer) and the fact that every released tag still carries the two safety
  defects the project's own CLAUDE.md documents — which is exactly why pass-sumo pins an unreleased
  `develop` commit instead of a tag.

### Upstream status check (the specific ask: has anything shipped since 2026-08-29?)

- **No new tags.** `v1.3.0` (2026-06-11) is still the latest tag as of today. VERIFIED (GitHub tags
  API, `pushed_at` on the repo matches the v1.3.0+following commits' dates, nothing newer).
- **`develop`'s HEAD is the pinned commit itself.** `git rev-parse origin/develop` ==
  `e9b8839f1226b82665e1e4b7f12f13635d189deb`, dated `2026-06-12 01:44:27 +0200`. VERIFIED by cloning
  the repo and checking directly — there is no commit after the one pass-sumo is pinned to.
- **Both documented fixes are present only post-v1.3.0, i.e. only on this unreleased commit:**
  - `fcd20f9 fix: regenerate the inner random-stream key on every save` — VERIFIED present in the
    41-commit range between `v1.3.0` and `origin/develop` (`git log v1.3.0..origin/develop`), i.e.
    **not** in any tagged release.
  - `e4ff0e9 fix: reject negative/empty length fields instead of trapping the process` — VERIFIED,
    same range, same conclusion.
  - Earlier, cruder versions of both fixes exist even further back in history (`6cbad6c KDBXWriter:
    auto-regenerate salts on every save`, `5ab571e crypto: convert input-reachable fatalErrors to
    typed throws`) — these predate v1.0.0 itself, meaning the *regression* that reintroduced both
    defects in the tagged releases is a separate, already-resolved question; what matters for
    pass-sumo is simply that no *current* tag has both fixes, which is confirmed.
- **Conclusion: the pin is still correct and still necessary.** Nothing has changed since
  2026-08-29 that would let pass-sumo move to a tagged release.

### Other Swift-usable KDBX libraries found

| Library | Licence | Verdict |
|---|---|---|
| **`MacPass/KeePassKit`** (Obj-C) | **GPL-3.0**, confirmed by reading the raw `LICENSE` file directly (not just GitHub's badge) — full GPLv3 text, copyright HicknHack Software GmbH. VERIFIED. GitHub's own license-detector reports `NOASSERTION` for this repo (a detector quirk, not a license fact) — do not trust the API `license` field alone; read the file. | **Unusable.** Disqualified by the hard filter. Confirms the brief. |
| **`keepassium/KeePassium`** | **GPLv3**, confirmed in `README.md`'s own "License" section: *"KeePassium is a commercial open-source app, available under the GPLv3 license."* VERIFIED. Same GitHub detector quirk (`NOASSERTION` in the API) applies here too — no root `LICENSE` file at that path, license text lives in the README instead. 1,679 stars, actively pushed (`2026-05-23`). | **Unusable, and irrelevant anyway** — KeePassium is an app, not a redistributable codec library (its KDBX parsing isn't packaged as an SPM library). Confirms the brief. |
| **`KeeForge/KeeForge`** | **GPL-3.0** (GitHub API confirms cleanly this time). 87 stars, iOS/macOS, Swift, pushed **today** (`2026-08-30T05:12:14Z`) — this is a new, actively-developed, App-Store-distributed (per its README badges) GPLv3 KeePass client that I hadn't previously been aware of. | **Unusable** under the hard filter regardless of its apparent App Store presence — GPLv3 + App Store distribution is the exact conflict this project avoids; the fact another app appears to be doing it anyway is not evidence it's safe (Apple doesn't enforce license compatibility at review time; the legal exposure is the developer's, not Apple's — see FSF's own writeup on this). Not a reusable library either way (no separate SPM package). |
| **`HuChengzhen/SwiftFastPass`** | **GPL-3.0**, built explicitly on top of `KeePassKit`. | **Unusable**, doubly so (inherits KeePassKit's GPLv3). |
| **`jerikjakobsen/KDBX`** | **Apache-2.0**. VERIFIED (GitHub API `license.spdx_id`). | Real from-scratch Swift KDBX parser (`Sources/KDBX`, `Sources/Encryption`, `Sources/StreamCiphers`, `Sources/XML`), permissively licensed. But: 1 star, `swift-tools-version: 5.8` (older toolchain target), last pushed `2025-09-23` (~11 months stale as of today), no format-version support matrix documented, no visible interop/fuzz testing, and it depends on several third-party crypto/XML packages of unknown currency itself (`Argon2Swift` pinned to `branch: "main"` — a non-reproducible floating pin, exactly the anti-pattern pass-sumo's own CLAUDE.md flags KDBXKit's `develop` pin as *not* being; `CryptoSwift`; `GzipSwift`; `SWXMLHash`). **Verdict: complementary at best, not competitive** — an interesting existence-proof that a clean-room permissive Swift KDBX parser is possible, but not production-ready and not something to switch to. |
| **`tooming/keebridge`** | MIT. | Not a competing library — it's an app (a macOS Credential Provider extension) that itself **depends on KDBXKit** (its own README: *"KDBX parsing (via KDBXKit)"*). Notable only as external validation that KDBXKit has at least one other real-world consumer besides pass-sumo. |
| **`LEMG-lab/citadel`** | MIT. "Rust crypto core + SwiftUI. KDBX 4.x." | Not a Swift KDBX library — the codec is a Rust crate, Swift is only the UI layer. Out of scope for "Swift library" but noted for completeness. |
| Everything else found under GitHub topics `kdbx`/`kdbx4` and searches for "keepass swift" | Various (`MiKeePass/MiKee` GPL-3.0, `authpass/authpass` GPL-3.0/Dart, `libkeepass/pykeepass` GPL-3.0/Python, several Rust/Go/TypeScript/Dart tools) | Wrong language or GPL or both; not Swift-usable candidates. |

No other GPL/AGPL/LGPL Swift KDBX project was found beyond the ones the brief already named plus
`KeeForge` and `SwiftFastPass` (both newly surfaced by this survey).

---

## Part 2 — Currency and safety of the crypto dependencies

### Dependency graph as declared

Read directly from `/Users/gamma/git/personal/pass-sumo/PassSumo/project.yml` (pass-sumo's own
manifest) and from `denisitpro/KDBXKit`'s `Package.swift` at the pinned revision
`e9b8839f1226b82665e1e4b7f12f13635d189deb` (cloned read-only to `/tmp/kdbxkit-survey`). VERIFIED by
reading both files directly.

- `PassSumo/project.yml` declares exactly one package dependency: `KDBXKit`
  (`github.com/denisitpro/KDBXKit`, pinned to the exact commit). No other third-party package is
  linked by the app target.
- `KDBXKit`'s `Package.swift` declares:
  - `.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")` — crypto-relevant.
  - `.package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")` — logging, not crypto.
  - `.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")` — CLI only
    (`kdbx-cli` target), not linked into the library product pass-sumo actually uses; not crypto.
  - `.package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0")` — documentation
    build plugin, not shipped in the binary at all; not crypto.
  - A vendored C target `argon2` (`Sources/CArgon2`) — crypto-relevant, not a Swift package
    dependency, a source copy.
  - A `systemLibrary` target `CZlib` (`pkgConfig: "zlib"`) — crypto-adjacent (used for KDBX payload
    decompression), OS-provided, not vendored.

The user's ask ("все либы по крипте... проверяй что самые актуальные версии") maps to exactly three
things worth deep-checking: `swift-crypto`+`_CryptoExtras`, the vendored `CArgon2`, and `zlib`. All
three below.

### apple/swift-crypto (+ `_CryptoExtras`)

- **Third-party dependency the project (via KDBXKit) is responsible for**, despite being an Apple
  repo: `swift-crypto` is Apple's *portable, source-shipped* reimplementation of CryptoKit for
  non-Apple platforms / as a library dependency — it is **not** the CryptoKit framework built into
  the OS. It ships as source, gets compiled into the app, and gets whatever version SwiftPM resolves
  at build time, not whatever the OS happens to have. This is the key distinction the owner's
  question is about: CryptoKit itself (used directly, not through this package) would be
  Apple-native and OS-patched; `swift-crypto` as a linked *package* is not — it only gets updated
  when someone bumps the Package.swift constraint and rebuilds. VERIFIED (package name/purpose from
  its own README: "APIs similar to Apple CryptoKit for platforms other than Apple's").
- **Declared constraint**: `from: "3.0.0"`, i.e. SwiftPM's `.upToNextMajor(from: "3.0.0")` — allowed
  range is `>=3.0.0, <4.0.0`. VERIFIED (read `Package.swift` directly).
- **Version that resolves today**: **3.15.1** — the highest tag under 4.0.0. VERIFIED: fetched the
  complete tag list from the GitHub API (100+ tags, paginated in full) and confirmed `3.15.1` is the
  newest tag `< 4.0.0`; there is no committed `Package.resolved` in the pass-sumo repo overriding
  this (project.yml/Xcode project are generated, not committed, so nothing pins it lower).
- **Current latest upstream release**: **4.5.1** (stable, published `2026-07-16T12:31:33Z`).
  VERIFIED via the GitHub Releases API. There is also a `5.0.0-beta.6` prerelease
  (`2026-08-28T09:58:32Z`), explicitly tracking **Xcode 27 beta 6** per its own release notes ("Align
  with CryptoKit from Xcode 27 beta 6") — i.e. a future toolchain, not the current Xcode 26.6 this
  machine has installed. The 5.x beta line is irrelevant to pass-sumo today.
- **Is the resolved version behind, and does anything security-relevant sit in the gap?**
  Yes, one major version behind (3.15.1 vs. 4.5.1). Read every release's notes between 3.15.1 and
  4.5.1 via the GitHub Releases API (bodies fetched directly, not summarized):
  - `4.0.0` (2025-10-06): "Update to WWDC25 release" — a major API-alignment release (Swift 6 mode,
    `FoundationEssentials`, `_CryptoExtras` renamed to `CryptoExtras`). No security content.
  - `4.1.0`, `4.2.0`: feature additions (PEM/DER Curve25519 APIs, RSA PKCSv1.5 legacy padding). No
    security content.
  - **`4.3.1` (2026-04-01) — security fix.** Its release notes state: *"This version contains a fix
    for CVE-2026-28815: X-Wing HPKE Decapsulation Accepts Malformed Ciphertext Length... We
    recommend updating to this release as soon as possible."* VERIFIED directly from the release
    body.
  - `4.4.0`, `4.5.0`, `4.5.1`: further feature/maintenance releases (SHA-512/256, BoringSSL-backed
    AES-CBC, an RSA double-free fix in 4.5.1's own BoringSSL AES-CBC backport — this one is *in*
    4.5.1, not a reason to want 4.5.1 over 3.15.1 since it doesn't apply to code paths 3.x ever had).
- **CVE detail — is it exploitable for pass-sumo?**
  Pulled the full GitHub Security Advisory `GHSA-9m44-rr2w-ppp7` (= CVE-2026-28815) via the API.
  **`vulnerable_version_range: ">= 4.0.0, <= 4.3.0"`, `first_patched_version: "4.3.1"`, severity
  `high`.** VERIFIED directly from the advisory JSON. The resolved version for pass-sumo, **3.15.1,
  falls entirely outside this range** — the X-Wing HPKE KEM path the CVE describes was added as part
  of the 4.0 "WWDC25" API rework and doesn't exist in the 3.x line at all. Additionally, grepped
  KDBXKit's own source for any HPKE/X-Wing usage: **zero matches** — KDBXKit's only swift-crypto
  usage is `AES` (93 references), `HMAC` (86), `SHA256` (17), `SHA512` (1), `RSA` (1); no
  `Curve25519`, no `HPKE`. So even hypothetically on 4.x, this specific CVE's code path is never
  reached by anything KDBXKit calls. **No exploitable CVE found for the resolved dependency.**
- **The structural concern, not a CVE**: the 3.x line's last tag (`3.15.1`, 2025-09-22) landed two
  weeks before 4.0.0 shipped (2025-10-06), and no 3.x tag has appeared since — i.e. the 3.x branch
  looks end-of-lifed the moment 4.0 released, receiving no further backports (the X-Wing CVE fix
  itself only ever landed in 4.3.1, never as a 3.x point release — though as established, 3.x never
  had the vulnerable code to begin with, so that's not itself evidence of an abandoned backport
  policy, just of there having been nothing to backport). Read swift-crypto's own `SECURITY.md`:
  disclosure goes through Apple directly and *"Fixes to Swift Crypto will be released simultaneously
  with any changes that need to be made in CryptoKit"* — no stated version-support policy either way
  for older majors. **INFERRED**, not proven: if a future vulnerability is found in code that exists
  in *both* the 3.x and 4.x lines (e.g. AES-CBC, HMAC — the actual APIs KDBXKit uses), there is no
  evidence one way or the other whether Apple would backport a fix to a 3.15.x patch release, since
  no such case has occurred yet to observe.

### Vendored CArgon2 (`Sources/CArgon2` in KDBXKit)

- **Third-party code the project is fully responsible for** — this is a byte-for-byte vendored copy
  of upstream C source, not a package dependency; nobody bumps it automatically. Read
  `Sources/CArgon2/UPSTREAM.md` directly: *"phc-winner-argon2 vendored at upstream commit
  `f57e61e19229e23c4445b85494dbf7c07de721cb` (2021-06-25)"*. VERIFIED.
- **Checked the actual upstream repo, `P-H-C/phc-winner-argon2`, today**: its `master` branch's tip
  commit is **`f57e61e19229e23c4445b85494dbf7c07de721cb`, dated `2021-06-25T08:21:15Z`** — i.e. the
  exact same commit KDBXKit vendors. VERIFIED via the GitHub Commits API (`?sha=master`), listing
  the 20 most recent commits on `master` and confirming `f57e61e` is the tip, with nothing after it.
  The repo's own metadata: `pushed_at: 2024-08-06T13:28:45Z` — the last *push* activity (likely a
  metadata-only change, e.g. topics/settings) postdates the last actual *commit* by three years, and
  it is not archived (`archived: false`) — it is simply dormant, not dead.
  - Latest release *tag* on that repo is even older: `20190702`. VERIFIED (tags API). The library's
    own `CHANGELOG.md` (vendored copy, read directly) stops at the `20171227` entry and every entry
    back to `20151206` explicitly says *"Minor bug and warning fixes (no security issue)"* — i.e. the
    changelog itself has never recorded a security fix in this codebase's history.
- **Conclusion: this is the "no newer release" case the brief anticipated, confirmed rather than
  assumed.** The vendored commit **is** the current upstream tip. There is nothing to bump.
- Licence: dual CC0-1.0 / Apache-2.0 (read `Sources/CArgon2/LICENSE` directly: *"You may use this
  work under the terms of a Creative Commons CC0 1.0 License/Waiver or the Apache Public License
  2.0, at your option"*). VERIFIED, permissive either way.
- **CVE search**: searched GitHub's advisory database for `argon2`/`phc-winner-argon2` (both a
  filtered `/advisories` query and a general web search) — found no CVE or GHSA entry naming this
  specific reference implementation. **Could not verify a definitive "zero CVEs ever" claim** — that
  would require a negative-result guarantee no database search can fully provide — but no evidence
  of one was found anywhere searched. UNVERIFIED (absence of evidence, not evidence of absence) that
  no CVE exists at all; VERIFIED that no CVE turned up in this search.

### zlib (via the `CZlib` systemLibrary target)

- **Apple-native / OS-provided, not the project's responsibility to patch** — `CZlib` is declared as
  a SwiftPM `systemLibrary` target (`pkgConfig: "zlib"`), meaning KDBXKit links against whatever
  `libz` the build platform provides; nothing is vendored or compiled from source. On macOS this
  resolves against the Xcode SDK's `zlib.h`/`libz.tbd`, which stub-links the actual system dylib
  (`/usr/lib/libz.1.dylib`) supplied and patched by the OS itself, updated via ordinary macOS
  software updates — completely independent of pass-sumo's build or release cycle.
- **Verified directly on this machine** (running Xcode 26.6, SDK version `26.5`, build `25F70` —
  the closest available real signal to "what the macOS 26 SDK provides", since this project targets
  `deploymentTarget: macOS 26.0`): `MacOSX.sdk/usr/include/zlib.h` declares
  `#define ZLIB_VERSION "1.2.12"`. VERIFIED by reading the header directly on disk.
- **Historical CVEs and their relevance**: `CVE-2018-25032` (deflate-side memory corruption on
  certain inputs, fixed in 1.2.12) and `CVE-2022-37434` (heap buffer over-read in
  `inflate()`/`inflateGetHeader()` on a crafted gzip header, fixed in 1.2.12). Both fixed-version
  boundaries are `1.2.12`. VERIFIED via web search (Debian/Oracle/IBM security trackers agree on
  1.2.12 as the fix line for both).
- **Caveat on what the header string actually proves**: `ZLIB_VERSION` is a compatibility/API
  identifier baked into the zlib source itself; vendors (including Apple, and every major Linux
  distro) are known to backport security patches onto an older-numbered `zlib.h` without bumping
  that string, since it's an ABI/API version marker rather than a build serial number. So "the SDK
  header says 1.2.12" is **not**, by itself, proof that Apple's actual shipped `libz.1.dylib` carries
  every CVE fix ever issued against zlib upstream — it is proof that the baseline is at least the
  version where both CVE-2018-25032 and CVE-2022-37434's fixes originally landed, combined with the
  general expectation (not independently verified against Apple's internal patch tracking, which
  isn't public) that Apple keeps system libraries patched via routine OS security updates. **VERIFIED**
  the header value and the CVE fix-versions; **INFERRED** (reasonably, but not from a Apple-published
  security changelog) that the actual shipped binary carries any patches issued after that baseline.
  Practically: since `zlib` here is never vendored or pinned by the app, this is Apple's ongoing
  obligation, not a version pass-sumo can or should "bump" — there is no constraint to edit.

---

## Part 3 — Recommendation

**Stay on KDBXKit. No dependency bump is needed right now.**

- The KDBXKit pin itself is correct and current: it already points at the newest commit that exists
  upstream (`develop`'s HEAD), and no tagged release yet contains the two safety fixes the project
  depends on. There is nothing to move to — re-check this the day upstream cuts a new tag, not
  before.
- `swift-crypto` resolves one major version behind (3.15.1 vs. 4.5.1 stable), but the one CVE that
  shipped in the gap (CVE-2026-28815, `>=4.0.0, <=4.3.0`) doesn't reach 3.15.1 and isn't in a code
  path KDBXKit calls anyway. **No urgent action.** If the KDBXKit fork maintainer (the repo owner,
  `denisitpro/KDBXKit`) wants to future-proof this at some point, the one-line change would be
  bumping `Package.swift`'s constraint from `.package(url: "https://github.com/apple/swift-crypto.git",
  from: "3.0.0")` to `from: "4.0.0")`, which would resolve to `4.5.1` today — but this is a
  discretionary hygiene improvement in someone else's package, not a fix for a real vulnerability
  pass-sumo currently has, and per the repo's own scope discipline, not something to do without
  being asked.
- `CArgon2` is already pinned to the literal tip of a dormant-but-live upstream. Nothing to do.
- `zlib` is OS-provided and outside pass-sumo's control entirely. Nothing to do.

Do not manufacture a PR for this — every actionable finding here resolves to "already current" or
"gap exists but isn't reachable." The one open item worth tracking (not fixing) is upstream
`shadone/KDBXKit` shipping a tagged release that includes both documented fixes — that is the
trigger condition, already written into `project.yml`'s own comment, for revisiting the pin.

---

## Open questions

- Whether Apple's actual shipped `libz.1.dylib` on macOS 26 carries every zlib security fix beyond
  the 1.2.12 baseline the SDK header string reports — not independently verifiable without access
  to Apple's internal security-patch changelog (not public). Treated as a reasonable assumption, not
  a verified fact.
- Whether `swift-crypto`'s 3.x line would receive a backport if a future CVE were found in code that
  exists in both the 3.x and 4.x lines (e.g. AES-CBC/HMAC, which is what KDBXKit actually uses) — no
  such case has occurred yet, so there's no precedent to check either way. `SECURITY.md` states no
  explicit multi-version support policy.
- Whether `KeeForge`'s apparent live App Store presence (its README links an App Store page) despite
  being GPL-3.0 reflects an actual approved listing or something else (a since-pulled/rejected
  listing, a stale badge, etc.) — not checked against the App Store itself; irrelevant to pass-sumo's
  decision either way since the licence alone disqualifies it, but flagged in case the owner is
  curious how another team is (or isn't) getting away with it.
- No absolute guarantee that `phc-winner-argon2`'s reference implementation has *never* had a CVE
  filed anywhere, only that none turned up in the searches run today (GitHub Advisory Database +
  general web search). A dedicated NVD/CVE-Details lookup by the exact commit hash was not performed
  beyond what these searches covered.

---

## Addendum (2026-08-30, later) — resolved-version shift after vendoring KDBXKit locally

Vendoring KDBXKit as a local SwiftPM package makes SwiftPM honour KDBXKit's own committed
`Package.resolved` instead of re-resolving each `from:` range to the newest available release. That
moved three resolved versions. Answering the three specific questions:

**(a) Is swift-crypto 3.15.1 the current latest? No.**
Already established above: current latest **stable** is **4.5.1** (published 2026-07-16). VERIFIED
(`https://github.com/apple/swift-crypto/releases`). 3.15.1 stayed unchanged by the vendoring switch
because it was already the resolved version before. The one security fix in the 3.15.1→4.5.1 gap,
CVE-2026-28815, is scoped to `>=4.0.0, <=4.3.0` (VERIFIED,
`https://github.com/apple/swift-crypto/security/advisories/GHSA-9m44-rr2w-ppp7`) and does not reach
3.15.1. **No action needed for swift-crypto.**

**(b) swift-asn1 1.7.1 → 1.7.0 — does this cross a security fix? No.**
Checked every swift-asn1 release between these two tags and the full GitHub Security Advisory
Database for the package (VERIFIED,
`https://api.github.com/repos/apple/swift-asn1/releases` and
`https://api.github.com/advisories?ecosystem=swift`):
- The only advisory ever filed against swift-asn1 is **CVE-2025-0343** ("crash when parsing
  maliciously formed BER/DER"), fixed in **1.3.1** (2025-01-14) —
  `https://github.com/apple/swift-asn1/security/advisories/GHSA-w8xv-rwgf-4fwh`. Both 1.7.0 and
  1.7.1 are far above 1.3.1, so **both sides of this downgrade already contain that fix**.
- 1.7.1's own release notes (the only change versus 1.7.0) list exactly one patch: "Encode signed
  integers correctly" (`https://github.com/apple/swift-asn1/releases/tag/1.7.1`) — a correctness fix
  in DER/BER *encoding* of signed integers, not flagged as security by the maintainers, and not the
  subject of any advisory found.
- **Verdict: harmless.** The 1.7.1→1.7.0 step does not cross any known CVE. It does lose one
  non-security encoding-correctness bugfix, which is worth picking up whenever the constraint is
  next touched, but it is not a security regression.

**(c) swift-log 1.15.0 → 1.12.0 and swift-argument-parser 1.8.2 → 1.5.0 — any known CVE crossed? No.**
Searched the GitHub Advisory Database (`ecosystem=swift`, full listing pulled and grepped) for both
package names — **zero advisories found for either `swift-log` or `swift-argument-parser`, at any
version.** Neither is crypto-adjacent (`swift-log` is a logging facade; `swift-argument-parser`
parses trusted argv, not attacker-controlled network/file input, and per KDBXKit's own
`Package.swift` it's only linked into the `kdbx-cli` CLI target, not the `KDBXKit` library product
pass-sumo actually links). **Verdict: harmless**, no further action.

**Bottom line for all three: these downgrades are harmless.** No known CVE is crossed by any of
swift-crypto (unchanged), swift-asn1 (1.7.1→1.7.0), swift-log, or swift-argument-parser. The only
non-security item worth remembering is that 1.7.0 is missing swift-asn1's one signed-integer
encoding correctness fix from 1.7.1 — immaterial today, cheap to pick up next time the constraint is
touched anyway.
