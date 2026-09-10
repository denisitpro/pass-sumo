---
name: pass-sumo-strongbox-is-the-reference
description: Strongbox is pass-sumo's explicit reference implementation — copy its behaviour by default, and say so when a decision comes from it.
metadata:
  type: project
---

Stated by the owner on 2026-09-10: **Strongbox (macOS) is the эталон for pass-sumo.** A large share
of the product's behaviour is taken from it deliberately, not by coincidence, and that is the
intended way to work — when a feature's shape is undecided, the first move is "how does Strongbox do
it?", not "invent something".

Where this bites hardest: **biometric / Touch ID unlock**, which the owner named as the priority
area to match Strongbox on. Their model, worth copying rather than re-deriving: a per-database
"convenience unlock" opt-in that stashes the master credential in the Keychain behind
LocalAuthentication; Touch ID offered automatically the moment the locked database is shown, not
behind an extra click; the master password always available as a fallback; and expiry policies that
force the real password again (after N days, after N convenience unlocks, on biometry change).

Two things this does NOT mean:

- It is not licence to copy code. Strongbox is GPL-family — see the repo CLAUDE.md's hard ban on GPL
  sources. Behaviour and UX are the reference; the implementation is ours.
- It is not licence to copy scope. The repo's positioning is explicitly "what Strongbox was before
  the feature creep" — so match its *core* behaviour, and treat its long tail of options as the
  anti-pattern the product is counter-positioned against.

**Why:** the owner does not want to re-litigate each small UX decision from scratch; naming a
reference implementation settles most of them cheaply.

**How to apply:** when writing an issue or a PR for behaviour that came from Strongbox, say so
explicitly in the text, so the provenance survives. See also [[touchid-cross-machine-context]] for
what cannot be verified on this machine, and [[pass-sumo-work-sequencing]] for what is gated.
