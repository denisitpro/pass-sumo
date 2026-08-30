---
name: touchid-cross-machine-context
description: Touch ID in pass-sumo cannot be verified on the Mac mini — what a future session on the MacBook needs to know before touching it
metadata: 
  node_type: memory
  type: project
  originSessionId: 3743f4a3-edf2-4c67-9244-5505e180e8bd
  modified: 2026-08-30T08:02:03.164Z
---

pass-sumo's Touch ID unlock was designed and unit-tested on `gamma@m4q1` (Mac mini), which has **no
Touch ID sensor**. Every biometric path is therefore unverified against real hardware. Validation
happens on `beta@m4a4` (MacBook) in a live session with the owner — tracked as GitHub issue #21.

Facts a session on the MacBook must not re-derive or guess:

- `make test` builds **unsigned**, so it has no entitlements and no App Sandbox, and can never reach
  the real keychain path. `make test-signed` is the target that can. One test in the suite is
  deliberately skipped for exactly this reason — leave it skipped on the mini.
- The keychain item uses `.biometryCurrentSet` (not `.biometryAny`) and
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, non-synchronisable. All three are deliberate
  security choices with the reasoning written into the doc comments of
  `PassSumo/Sources/Security/BiometricUnlock.swift`. Do not weaken any of them to make a test pass.
- The stable per-database identifier is a UUID the app writes into the KDBX `Meta/CustomData` under
  `PassSumo/DatabaseID`. It is **not** derived from the file path and **not** from the KDBX master
  seed — the master seed is regenerated on every save by design, so an identifier derived from it
  would change on the user's first edit and orphan the keychain item.
- `.invalidatedByBiometryChange` is an **expected** state, not a bug: it fires whenever the Mac's
  enrolled fingerprint set changes, which is the whole point of `.biometryCurrentSet`.

Separate problem, do not conflate: unlocking on a second Mac driven over Screen Sharing. Touch ID is
unavailable over Screen Sharing by design, so nothing in the above helps there — that is issue #13.

**Why:** the owner works across two machines and does not want context lost between them.

**How to apply:** read issue #21's checklist before starting; run `make test-signed` on the MacBook;
report what the hardware actually did rather than what the unit tests assert.

Related: [[pass-sumo-memory-lives-in-repo]]
