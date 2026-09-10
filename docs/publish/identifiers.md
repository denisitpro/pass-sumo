# Publication identifiers — handover sheet

> Status: living · Last verified: 2026-09-10 · [AI - claude-opus-5]
> The fixed identity of this app, so nobody re-derives it. `TBD` means nobody has supplied the
> value yet — **never guess one of these.** Apple's platform requirements and their confidence
> labels: [`apple-facts.md`](apple-facts.md).

## Settled

| Item | Value |
|---|---|
| Bundle ID | `app.passsumo` |
| Unit-test bundle ID | `app.passsumo.unittests` |
| UI-test bundle ID | `app.passsumo.uitests` |
| Apple **Team ID** | `2ZZ7AW39AW` (team "Nico Jamieson", Individual, paid Apple Developer Program — same account ShotSumo ships from; see `apple-facts.md` § Account & signing) |
| Product name | `PassSumo` |
| `LSApplicationCategoryType` | `public.app-category.utilities` |
| Keychain access group | `$(AppIdentifierPrefix)app.passsumo` |
| Keychain service | `app.passsumo.vault-key` |

## Immutable once submitted

Per the research notes (`apple-facts.md` § Account & signing): **Bundle ID is immutable once a
build is submitted to a version record; SKU is immutable forever.** App name and primary language
remain changeable after the fact. Get the Bundle ID and SKU right before the first submission —
everything else here has more room to change later.

## Created 2026-09-10 — read back from the console, not from memory

The app record, its subscription group and both subscription products were created in App Store
Connect on 2026-09-10. Every value below was read back off the page after saving it, not recalled
from having typed it.

| Item | Value |
|---|---|
| App Store Connect SKU | `passsumo-macos-1` — **immutable forever.** Follows the owner's existing convention (ShotSumo `shotsumo-macos-1`, Finsumo `finsumo-ios-1`) |
| App Store Connect App ID (numeric Apple ID) | `6810565641` |
| Developer-portal App ID | `app.passsumo` (explicit), registered 2026-09-10. It did **not** exist before that day, which is what blocked the app record — the Bundle ID dropdown in ASC only lists identifiers already registered in Certificates, Identifiers & Profiles |
| App ID capabilities | none enabled, matching `app.shotsumo`. There is no "Keychain Sharing" capability in the portal's list at all, so `keychain-access-groups` needs no portal toggle — it lives only in the entitlements file |
| Primary category | Utilities — chosen to match `LSApplicationCategoryType` in the binary. This settles what `apple-facts.md` listed as an open question |
| Secondary category | Productivity |
| Subtitle | `Password manager for KDBX` (25 of 30 chars) |
| App price | Free. Monetisation is IAP-only, which guideline 2.4.5(vi)/3.1.1 requires on the Mac App Store: no licence keys, no paid-up-front-plus-trial, only a free app plus an IAP unlock |
| App availability | **174 of 175 territories — France deliberately excluded** (owner's decision, 2026-09-10). See below |

### Subscription

One group, two durations, one introductory offer.

| Item | Value |
|---|---|
| Subscription group ID | `22373577` |
| Subscription group display name | `PassSumo` (App Name Display Option: "Use App Name") |
| Yearly product ID | `app.passsumo.yearly` — **immutable once submitted** |
| Yearly Apple ID (numeric) | `6810566220` |
| Yearly price / duration | $19.99 (US) · 1 year · "1 Year Upfront" billing, not "Monthly with a 12-Month Commitment" |
| Monthly product ID | `app.passsumo.monthly` — **immutable once submitted** |
| Monthly Apple ID (numeric) | `6810569731` |
| Monthly price / duration | $2.49 (US) · 1 month |
| Level order | Yearly is level 1, Monthly is level 2, so monthly→yearly is an upgrade rather than a downgrade |
| Introductory offer | Free, **1 month**, on both products, from 2026-09-10 with no end date. One per Apple ID **per group**, ever — which is why it is on both products: without it the monthly tier would offer no trial at all |
| Localization (both) | `PassSumo Yearly` / "Full access to PassSumo, billed yearly." and `PassSumo Monthly` / "Full access to PassSumo, billed monthly." Limits are 35 chars for the display name and 55 for the description |
| Family Sharing | off (the ASC default) — an open decision, not a settled one |

Product IDs deliberately drop the `.pro.` segment ShotSumo uses (`app.shotsumo.pro.yearly`):
"Pro" implies a non-Pro tier, and there is none here. The unpaid state is read-only, not a lesser
edition. This follows Finsumo's `<bundle id>.<duration>` shape instead.

### France is excluded on purpose

France is switched off in **three** places — app availability, and each subscription's availability
— and the app-level setting is the one that legally matters. Reason: shipping to France with
`ITSAppUsesNonExemptEncryption = true` triggers an ANSSI declaration, which is weeks-to-months of
paperwork for a password manager (ANSSI's "Secure Storage" category). Excluding France collapses
Apple's export-documentation requirement to nothing and leaves only the annual BIS
self-classification report. Adding France later is a deliberate separate step, not a default.

Note that ASC warns "your app will also be made available in all future countries or regions" —
that applies to territories Apple adds later, and does not silently re-enable France.

### Not yet done in App Store Connect — owner's call, deliberately left blank

None of these were answered, because each is a declaration rather than a setting:

| Item | Why it was left |
|---|---|
| App Encryption Documentation | A legal declaration with BIS/ANSSI consequences. See issue #4 and `publish/export-compliance.md` |
| Digital Services Act trader status | A legal declaration; also affects EU availability |
| Age Ratings | A content declaration (expected to be 4+, but the owner should click it) |
| Content Rights | A declaration about third-party content |
| App Privacy ("Data Not Collected") | Required before submission; guideline 5.1.1(i) also wants a privacy-policy link reachable **inside** the app, which is app-side work |
| Notes for Review, Sign-In Information | Needs the demo-vault decision — see issue #76 |
| Screenshots | Deferred on purpose until the UI settles — issue #76 |
