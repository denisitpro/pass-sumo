---
name: subagent-claims-need-first-hand-verification
description: Subagents invent external identifiers (a GHSA advisory ID that 404s) — verify every identifier and severity yourself with the one command that answers it, before relaying or acting.
metadata:
  type: feedback
---

A delegated agent will produce a **well-formed, plausible, nonexistent identifier** rather than say
it does not know. On 2026-09-10 the #116 dependency-currency agent reported
`GHSA-8q93-f6xh-4f6f` — "critical, double-free parsing a malformed RSA key, affected range
`>=3.2.0, <=4.5.0`, fixed in 4.5.1+, no 3.x backport" — and wrote it into
`docs/dependency-currency.md` and PR #119 as a reason to re-prioritise issue #23.
`gh api /advisories/GHSA-8q93-f6xh-4f6f` returns **404**; GitHub's database lists exactly one
advisory affecting `swift-crypto` (`GHSA-9m44-rr2w-ppp7`, `high` — the agent also called it
"medium", and it only covers 4.0.0–4.3.0). The severity, the range and the ID were all unsourced.

The underlying defect was real but was never an advisory: it is one line in the upstream 4.5.1
release notes ("Fix double-free when RSA key init from bytes fails"). That is the trap — a true
kernel wrapped in three fabricated attributes, which is far more convincing than a wholly invented
claim and had already reached a document and a roadmap argument.

**Why:** an identifier is the one class of value where a plausible shape is indistinguishable from a
correct answer until someone follows it, and following it costs the owner a 404 and a re-weighted
decision made on nothing.

**How to apply:**

- Verify every external identifier a subagent hands you — advisory/CVE IDs, version ranges,
  severities, commit shas, URLs — with the command that answers it, before relaying it in your own
  voice, quoting it to the owner, or letting it into a committed document. Same rule as
  [[pass-sumo-shared-checkout-git-state]], extended past git to anything sourced from outside.
- Advisories: `gh api '/advisories?ecosystem=swift&affects=<package>&per_page=100'` lists everything
  published for a package; `gh api /advisories/<GHSA-ID>` confirms one and 404s on a fake. Upstream
  release notes (`gh api /repos/<owner>/<repo>/releases`) are a *separate* source and carry no
  severity or affected range — never upgrade a release-note line into "a critical CVE".
- "No published advisory found" is a complete, correct answer. Require subagent briefs to say so
  instead of characterising an unpublished fix.
- Check what the agent *missed*, not only what it got wrong: this same audit skipped the one 4.5.1
  item that does touch our code (`AES-CBC` / constant-time PKCS#7 unpadding) while citing the one we
  never call. `Vendor/KDBXKit` links `_CryptoExtras` for AES-CBC and AES-KDF, but `AES256CBC.swift`
  routes through CommonCrypto under `#if canImport(CommonCrypto)` (swift-crypto's path is ~180x
  slower), so `AES._CBC` never executes on the platforms this app ships to — reachable only in a
  non-Apple build of the library.
