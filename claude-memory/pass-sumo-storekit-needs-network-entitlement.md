---
name: pass-sumo-storekit-needs-network-entitlement
description: StoreKit requires com.apple.security.network.client, which makes the "no network entitlement" claim on the site false — verified from ShotSumo, not inferred.
metadata:
  type: project
---

Adding StoreKit to PassSumo **will require `com.apple.security.network.client`** in
`PassSumo/Resources/PassSumo.entitlements`, which does not carry it today (Release currently has
only app-sandbox, `files.user-selected.read-write`, `bookmarks.app-scope` and
`keychain-access-groups`).

This is **verified, not inferred**: `shotsumo/ShotSumo/Resources/ShotSumo.entitlements` carries the
entitlement with a comment recording that it was dropped for 1.x (when the purchase surface was
compiled out) and restored for 2.0 solely for "StoreKit's outbound calls to Apple's purchase
infrastructure". Same account, same platform, shipping.

The consequence that actually bit: the /passsumo privacy policy and landing page claimed PassSumo
"does not carry the network-client entitlement macOS requires" and "could not send anything
anywhere even if it tried". True of the current tree, **false the moment StoreKit ships** — and an
inaccurate privacy claim is a 5.1.1 problem. ShotSumo hit the identical paragraph and rewrote it
(its issue #227, and `shotsumo/docs/archive/2026-09-04-store-copy-corrections.md`).

Fixed on 2026-09-10 on branch `legal-pass-subscription` in `heaven8-landing` (committed, **not
pushed** — that repo needs the owner's key): the technically-unable claim is gone from all three
places it lived (privacy body, privacy meta description, landing "system facts" block), replaced
with what stays true regardless — nothing from the vault leaves the Mac, no analytics, no
telemetry, no account — plus a plain statement that the one network destination is Apple's purchase
infrastructure.

**Why:** absolute claims about what an app *cannot* do age badly across a monetisation change, and
this class of claim is exactly what Apple checks against the binary. Finsumo has a standing issue
(#91) for auditing the same kind of copy before its paywall ships.

**How to apply:** when the StoreKit work lands, the entitlement goes in and the App Privacy answers
and Sandbox Information in ASC need re-checking against it. Do not add a test that pins the current
entitlement set — it would fail by construction when this lands. See
[[pass-sumo-asc-record-created]].
