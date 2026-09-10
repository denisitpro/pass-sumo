---
name: github-has-two-advisory-databases
description: "GitHub's global advisory DB lags repo-level advisories and rates them differently — a 404 from `gh api /advisories/<GHSA>` is not proof the advisory does not exist."
metadata:
  type: reference
---

GitHub exposes security advisories through **two** independent endpoints, and for `swift-crypto`
they disagree in both directions:

| Query | GHSA-8q93-f6xh-4f6f | GHSA-9m44-rr2w-ppp7 |
|---|---|---|
| `gh api /repos/apple/swift-crypto/security-advisories` (repo-level) | present, `critical`, `>= 3.2.0, <= 4.5.0`, patched 4.5.1 | present, `medium` |
| `gh api /advisories/<GHSA>` and `/advisories?ecosystem=swift&affects=swift-crypto` (global reviewed DB) | **404 / absent** | present, `high` |
| NVD (`services.nvd.nist.gov/rest/json/cves/2.0?cveId=…`) | `CVE-2026-43823`, Analyzed, CVSS 3.1 **7.5 HIGH** (`A:H` only — a crash, not a confidentiality or integrity break) | — |

So the global database can be **missing a published advisory entirely** (GHSA-8q93 was published
2026-07-16 and still was not there on 2026-09-10), and where both have an entry the severities differ.

**Why:** on 2026-09-10 the #116 audit reported GHSA-8q93-f6xh-4f6f. I checked it with
`gh api /advisories/GHSA-8q93-f6xh-4f6f`, got a 404, checked the ecosystem listing, saw only
GHSA-9m44 — and concluded the agent had fabricated the ID, severity and range. I said so to the
owner and opened a PR recording the "fabrication". The agent disagreed and produced the repo-level
query; the advisory is real, and so was its `critical` rating and its affected range. My 404 was a
true result from the wrong database. I also "corrected" its `medium` for GHSA-9m44 to `high`, which
was equally unfounded — both numbers are real, from different sources.

**How to apply:**

- Never conclude an advisory does not exist from `gh api /advisories/<GHSA>` alone. Check the
  repo-level list too: `gh api /repos/<owner>/<repo>/security-advisories`. Absence needs **both** to
  be silent, and even then say "not found in either", not "does not exist".
- Quote severity **with its source** — "critical per the repo advisory, 7.5 HIGH per NVD" — because
  there is no single answer to quote.
- A 404 is evidence about an endpoint, not about the world. The general rule that a subagent's claim
  must be verified first-hand ([[pass-sumo-shared-checkout-git-state]]) cuts both ways: verifying it
  against the wrong source and then contradicting the agent in the owner's ear is the more expensive
  failure, because it destroys a true finding instead of merely repeating a false one. When a
  subagent pushes back with a specific checkable citation, run its query before standing your ground.

**Live consequence for this repo:** `swift-crypto` 3.15.1 (the version `Vendor/KDBXKit` resolves) is
inside `>= 3.2.0, <= 4.5.0`. The fix exists only in 4.5.1+, and 3.x is a dead branch with no
backport — so issue #23's major bump is the only route to it. Not currently reachable: the defect is
in RSA **public-key** init from DER/PEM bytes, and nothing in the app or the vendored library ever
initialises an RSA key (one hit repo-wide, a doc comment in `Entry+Passkey.swift`). `_CryptoExtras`
*is* linked into the shipped `KDBXKit` target, so the honest phrasing is "linked but never called".
