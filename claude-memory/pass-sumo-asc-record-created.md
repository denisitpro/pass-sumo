---
name: pass-sumo-asc-record-created
description: The App Store Connect record, subscription products and prices exist as of 2026-09-10 — what is immutable, and what was left blank on purpose.
metadata:
  type: project
---

The App Store Connect app record for PassSumo was created on **2026-09-10**, together with its
subscription group and both products. Before that day none of it existed, and the developer-portal
App ID `app.passsumo` did not exist either — registering it was the prerequisite that unblocked
everything (ASC's Bundle ID dropdown only lists identifiers already registered in Certificates,
Identifiers & Profiles).

Every settled value now lives in `docs/publish/identifiers.md`, and the listing copy in
`docs/publish/store-listing.md`. **Read those rather than re-deriving anything**, especially:

- SKU `passsumo-macos-1` is **immutable forever**; the two product IDs
  (`app.passsumo.yearly`, `app.passsumo.monthly`) are immutable once submitted.
- Prices: **$2.49/month, $19.99/year**, no lifetime tier. Free app, IAP-only monetisation.
- Introductory offer: **free 1 month**, on both products, because eligibility is once per Apple ID
  *per group* — putting it on only one product would leave the other tier with no trial.
- Lapse behaviour is **read-only**: reading and copying passwords keeps working permanently, only
  editing needs a subscription. This is in the ToS and the App Store Description as a feature.

**France is excluded from availability on purpose**, in three places (app + both subscriptions).
The app-level setting is the one that legally matters. Reason: an ANSSI declaration would otherwise
be required. Do not "fix" this by re-enabling France.

Deliberately **not** answered in ASC, because each is a declaration and not a setting: App
Encryption Documentation, Digital Services Act trader status, Age Ratings, Content Rights, App
Privacy, Notes for Review, screenshots. These are the owner's to click.

**Why:** the immutable fields are the expensive ones to get wrong, and the values were read back
off the console rather than recalled — so the docs are the source of truth, not anyone's memory of
having typed them.

**How to apply:** before touching anything Apple-facing in this repo, read
`docs/publish/identifiers.md` first. See also [[pass-sumo-storekit-needs-network-entitlement]] and
[[pass-sumo-memory-lives-in-repo]].
