# Apple requirements — verified facts (Mac App Store)

> Status: living · Last verified: 2026-08-29 · [AI - claude-sonnet-5]

Every claim below carries a confidence label, inherited from the 2026-08-29 research pass:
**VERIFIED (url)** = read directly on an Apple (or BIS/government) primary source; **INFERRED** =
reasoned from verified facts but not itself read on a primary source; **UNVERIFIED** = found in
secondary sources (blogs, forums, aggregators) only, not confirmed on a primary page. A few facts
are carried over verbatim from ShotSumo's own `apple-facts.md`, which uses its own label set
(`CONFIRMED`, `LIKELY`) — those are kept in brackets exactly as ShotSumo wrote them, not translated.

**Do not upgrade a label from memory or convenience.** Every INFERRED and UNVERIFIED item below
must be re-checked against a live Apple page before the first submission — treat this file as a
starting point for that check, not a substitute for it.

Several developer.apple.com pages relevant to this app — the export-compliance-for-encryption
help page, the Required Reason API reference, the security-scoped-bookmark guide — render their
body text client-side; this research pass could only confirm their titles/topics via search, not
fetch the body text directly. That is the reason a number of items below are labelled INFERRED or
UNVERIFIED rather than VERIFIED even though the underlying Apple page plainly exists. Re-read those
pages live, in a browser, before relying on them at submission time.

---

## Account & signing

Ships from the same publishing account as ShotSumo (same developer, SumoApps / Nico Jamieson) —
not something to re-derive.

| Fact | Confidence |
|---|---|
| Team ID `2ZZ7AW39AW`, team "Nico Jamieson", **Individual** enrolment, Apple Developer Program, registered in New Zealand | VERIFIED (read directly in developer.apple.com / ASC by the ShotSumo owner, 2026-08-27) |
| An **Individual enrolment cannot trade under a brand name** for the public *developer name* on the product page — that's always the account holder's legal name. A trade name (e.g. "SumoApps") can still be used in the Copyright field and legal pages, not as the developer name | `[CONFIRMED in ShotSumo's own research]` |
| Two distribution certificates are required and easy to confuse in Xcode: `Apple Distribution` (signs the `.app`) and `Mac Installer Distribution` / `3rd Party Mac Developer Installer` (signs the `.pkg` uploaded to ASC). A free/Personal Team has neither and cannot sign an MAS upload | `[CONFIRMED]` |
| **Bundle ID and SKU are immutable** once a build is submitted to a version record (Bundle ID) / forever (SKU). App name and primary language are changeable after the fact | `[CONFIRMED]` |

See [`identifiers.md`](identifiers.md) for the actual values.

## Bundle identity & category

| Fact | Confidence |
|---|---|
| `LSApplicationCategoryType` **must be set inside the shipped `Info.plist`** (e.g. `public.app-category.utilities`) — the primary category picked in App Store Connect's listing metadata is a *separate* field and is **not** inherited by the binary. Missing it fails upload validation with **error 90242** | VERIFIED (first-hand validation error, ShotSumo build 164) |
| For pass-sumo, the primary category is almost certainly `public.app-category.utilities` (same as ShotSumo) or possibly `public.app-category.productivity` — this is a product decision, not yet made. Must be set in the Xcode/XcodeGen project config, not left to ASC alone | INFERRED |

## Entitlements and the sandbox

| Fact | Confidence |
|---|---|
| App Sandbox is **mandatory** for Mac App Store distribution — Guideline 2.4.5(i) | `[CONFIRMED]` |
| Hardened Runtime is required for notarization (Developer ID); whether it's enforced for plain MAS uploads is unclear — ShotSumo enabled it anyway since it "costs nothing" | `[UNVERIFIED whether Xcode's App Store upload flow enforces it]` |

**Strongest evidence in this document — ShotSumo's own Guideline 2.4.5(i) rejection**, first-hand,
not researched from a doc (submission `829ed126-e6a6-4080-81f3-98e9a20ec8e2`, 2026-08-28). App
Review rejected a build that (a) pre-set a save location (`~/Downloads`) before the user ever chose
one via a picker, and (b) shipped `com.apple.security.files.downloads.read-write`, an entitlement
with no functionality left to justify it once the pre-set default was removed. Confidence:
**VERIFIED (first-hand rejection)**.

Rule extracted, directly applicable to pass-sumo: **never ship an entitlement that isn't actively
exercised**, and **never default to a save/open location the app picked for the user** — always
route through a real `NSOpenPanel`/`NSSavePanel` first, then persist the choice as a security-scoped
bookmark. Concretely: opening a `.kdbx` file must go through a real file picker (never a hardcoded
default path such as `~/Documents/passwords.kdbx`), and only the two entitlements below should
ship — no broader file entitlement (Desktop/Downloads/Pictures) unless a real feature uses it.

Two entitlements are involved in "open a user-picked `.kdbx`, remember it across relaunches," and
they are not the same thing:

| Entitlement | Purpose | Confidence |
|---|---|---|
| `com.apple.security.files.user-selected.read-write` | Grants read-write to whatever the user picks via `NSOpenPanel`/`NSSavePanel` for the current session. This is what ShotSumo shipped and got specifically required by its own App Sandbox Information justification | VERIFIED (ShotSumo precedent) |
| `com.apple.security.files.bookmarks.app-scope` | Required in addition, specifically to let a resolved security-scoped bookmark survive across app relaunches (app-scope, as opposed to document-scope bookmarks used by document-based/NSDocument apps) | VERIFIED (entitlement name, via Apple's "Enabling App Sandbox" entitlement key reference page — title confirmed) / INFERRED (exact mechanics beyond the entitlement name; full page text could not be fetched in this session) |

Persistent access mechanics — resolve the bookmark on launch, call
`startAccessingSecurityScopedResource()` before touching the URL, `stopAccessingSecurityScopedResource()`
when done — corroborated across multiple independent sources (Apple Developer Forums threads) but
not read verbatim on an Apple page in this session. **VERIFIED (page identity)** / **treated as
high-confidence but not a verbatim Apple quote.**

Without the app-scope bookmark entitlement, a picker-only flow would force re-picking the `.kdbx`
file every launch — bad UX for a password manager users open constantly. Ship both from day one.

**App Store Connect's App Sandbox Information section** (distinct from the App Privacy
questionnaire) requires a **written justification per declared entitlement** — ShotSumo's
justification for `user-selected.read-write` was ~400 characters explaining exactly what triggers
the picker and what's persisted. Write an equivalent justification for pass-sumo's file-access and
(if used) Touch ID entitlements before submitting.

**iCloud Drive access to a user-picked file:** no special iCloud/ubiquity entitlement
(`com.apple.developer.icloud-container-identifiers` etc.) appears needed for the common case of
"user picks a `.kdbx` living inside `~/Library/Mobile Documents/...` via a standard Open panel" —
those files present as regular file-system paths to a security-scoped bookmark. The iCloud-specific
entitlements are for an app's *own* ubiquity container (e.g. an iCloud folder in the Finder
sidebar), not for reading a file the user picked that happens to be iCloud-synced. **INFERRED** —
corroborated by multiple forum/community sources, not confirmed on an Apple primary-source page.
Re-verify with a real test (pick a file physically only in iCloud Drive, not yet locally cached,
confirm the read succeeds/triggers download) before relying on it.

## Keychain, Touch ID & Local Authentication

| Fact | Confidence |
|---|---|
| `NSFaceIDUsageDescription` in Info.plist is required wherever an app uses Face ID via `LAContext` — the app crashes on first Face ID attempt without it, on both iOS and macOS | UNVERIFIED (search-engine-summarized secondary sources only; widely repeated but should be spot-checked against the live Xcode Info.plist key reference before shipping) |
| **Touch ID specifically (not Face ID) does not require a matching Info.plist usage-description key** — materially changes what plist work is needed for a Mac, which only has Touch ID, no Face ID, as biometric hardware | UNVERIFIED (same secondary sourcing; independently confirm) |
| Protecting a Keychain item behind biometrics uses `SecAccessControlCreateWithFlags` with a biometry flag (`kSecAccessControlBiometryAny` / `kSecAccessControlBiometryCurrentSet`, the latter invalidating the ACL if the enrolled fingerprint set changes) plus an `LAContext` passed into the `SecItem` call | UNVERIFIED (forum-sourced, not confirmed on a live Apple API reference page) |
| On macOS, biometric-gated Keychain access additionally needs real keychain-access-group entitlements — one forum report describes an error ("Client has neither com.apple.application-identifier, com.apple.security.application-groups nor keychain-access-groups entitlements") when those are missing | UNVERIFIED (single forum report, not cross-checked against Apple's own entitlement docs) — test directly against a real build rather than trust from research alone |

Design note, not a research finding: none of the above determines pass-sumo's actual
key-derivation design (Argon2 KDF from the KDBX spec). Touch ID/Keychain here is only ever a
*convenience unlock* layered on top of the master password, never a replacement for it, consistent
with how KeePass-family apps generally work. Keychain-stored biometric unlock typically means the
master key (or an equivalent) has to be held in Keychain, secured by the biometric ACL — this is
itself sensitive design that deserves its own dedicated security review when built, not something
to reverse-engineer from generic search results.

## Export compliance

This is the single biggest divergence from ShotSumo's precedent, and the item most likely to be
misjudged. ShotSumo set `ITSAppUsesNonExemptEncryption = false` because it has zero networking and
no custom crypto — **not directly transferable to pass-sumo**, which does implement its own
encryption (AES-256/ChaCha20 with an Argon2 KDF for the KDBX format).

- Apple's export-compliance questionnaire lists specific exemption categories, one of which is
  encryption "limited to authentication, digital signature, or the decryption of data or files"
  (plus carve-outs for medical use, IP/copyright protection, banking, fixed data compression).
  **UNVERIFIED as an exact Apple quote** — found via a secondary aggregator citing Apple's
  questionnaire wording, not fetched from developer.apple.com directly in this session (WebFetch
  retrieved only the page title, not the body). Re-read the live App Store Connect export-compliance
  questionnaire text directly at submission time.
- **The careful answer for pass-sumo:** the "limited to authentication" exemption applies to
  encryption whose *only* cryptographic function is authenticating a user or signing/verifying —
  not to encryption whose function is protecting the *confidentiality* of stored user data. A KDBX
  vault's AES-256/ChaCha20 encryption of entry contents (Argon2/AES-KDF deriving the key from the
  master password) is confidentiality encryption of user data — a different cryptographic function
  from "authentication." **INFERRED, but with reasonably high confidence** — this distinction
  (authentication/signing vs. confidentiality) is the actual dividing line under the US Export
  Administration Regulations' Category 5 Part 2 Note 4, corroborated by a BIS-focused source
  describing self-classification for products "limited to authentication and digital signature
  functions," explicitly contrasted with general confidentiality encryption.
- **Conclusion: pass-sumo almost certainly cannot claim the "limited to authentication" exemption**
  and should expect `ITSAppUsesNonExemptEncryption = true`, not `false`.

What `true` obligates the developer to do, layered:

1. The export-compliance questionnaire in App Store Connect asks follow-up questions at every
   submission — separate from, and in addition to, the Info.plist key.
2. A KDBX-format local password vault almost certainly qualifies as **"mass market"** under EAR
   Category 5 Part 2 (ECCN 5D992.c — retail-available software, user cannot modify the
   cryptographic functionality) — mass-market items can be **self-classified** (no CCATS required),
   but the exporter must file an **annual self-classification report** with BIS (due by February 1
   each year for the prior calendar year's exports) to specific BIS/NSA addresses (`crypt@bis.doc.gov`,
   `crypt-supp8@bis.doc.gov`, `enc@nsa.gov`, per secondary sourcing). **VERIFIED at the
   BIS-regulatory level** (bis.gov mass-market page confirms self-classification + annual reporting
   mechanism exists for 5A992.c/5D992.c) — **INFERRED that pass-sumo specifically qualifies**, since
   that determination requires reviewing the actual product against BIS's Note 3 criteria, which
   this research did not do in detail.
3. Apple's App Store Connect flow: if the developer says the app is not exempt and has (or needs)
   no CCATS, Apple in some cases asks for either a copy of a CCATS if one exists, or a short
   letter/attestation confirming the developer understands their obligation to file the annual BIS
   self-classification report themselves. **Apple does not do the BIS filing on the developer's
   behalf** — the annual report is the developer/legal-entity's own regulatory obligation.
   **UNVERIFIED as exact current wording** — corroborated by multiple developer-forum threads, not
   confirmed by fetching Apple's live "Export compliance documentation for encryption" help page
   body in this session (WebFetch retrieved only the title).
4. **France-specific:** France separately controls import of apps in specific categories including
   explicitly **"Secure Storage"** (alongside Secure Communications and Security Anti-Virus) — a
   KDBX password manager is squarely a "Secure Storage" app. If/when pass-sumo is distributed in
   the French App Store storefront, Apple requires an ANSSI encryption declaration, which can now
   be submitted through App Store Connect rather than directly to ANSSI. **VERIFIED that this
   category and requirement exist** (developer.apple.com's export-compliance-documentation-for-encryption
   help page is the authoritative source, confirmed via search-result synthesis of that page's
   content — the page body itself could not be fetched directly in this session; re-verify by
   reading it live before the first French submission).

**Bottom line:** pass-sumo should plan, from alpha onward, to set `ITSAppUsesNonExemptEncryption =
true`, expect to answer "yes, non-exempt, but mass-market self-classified, no CCATS" in App Store
Connect's questionnaire at every submission, expect an annual BIS self-classification report to
become a real recurring legal/compliance task once the app ships, and expect an additional French
ANSSI "Secure Storage" declaration step for French availability. None of this blocks alpha
development work — it is a submission-time / first-real-release concern — but it needs a
decision-owner and a plan before the first submission, not discovery at submission time. **This is
a legal declaration the developer/legal entity makes, not a build flag** — see OPEN QUESTIONS below.

## Privacy manifest & required-reason APIs

| Fact | Confidence |
|---|---|
| Privacy manifests, and declaring "Required Reason API" categories/reasons, have been enforced since **May 1, 2024** for new app/app-update submissions that use those APIs (directly or via a bundled third-party SDK/dependency) | VERIFIED that this enforcement date and mechanism exist (widely corroborated) / INFERRED that it still applies unchanged as of August 2026 (not re-confirmed against a live Apple page with a 2026 date) |
| Categories most likely relevant to pass-sumo: **UserDefaults** (app preferences), **File Timestamp** (checking a `.kdbx` file's modification date to detect external changes / conflict detection — plausible for an iCloud-Drive-synced file), **Disk Space** (if the app ever checks free space before writing a save), **System Boot Time** (less obviously applicable) | INFERRED |
| Each category has a fixed enumerated list of Apple-approved "reason codes" that must be cited exactly, not paraphrased (e.g. one File Timestamp reason code allows access to timestamps of files inside the app's own container, a different one for files the user picked) | UNVERIFIED verbatim reason-code text — direct fetch of Apple's canonical "Describing use of required reason API" page returned a 404 on the URL tried in this session; the correct current URL must be re-located and read directly before implementation, since citing the wrong reason code is an App Store Connect validation failure, not a style nit |
| This applies to pass-sumo's own code **and** any third-party dependency (e.g. KDBXKit, or a self-written KDBX library) — a missing privacy manifest in a bundled dependency is reported to cause rejection even if the app's own code is compliant | INFERRED as a consequence of the "third-party SDK" requirement, not independently confirmed |

Practical action for alpha: grep the codebase periodically for `UserDefaults`, `FileManager`
timestamp/attribute access, and disk-space APIs, and add the privacy manifest with the correct
reason codes before the first real submission. Unlike ShotSumo (which never had to deal with this
at all, per its docs — it uses none of these APIs), pass-sumo's very nature (touching file
timestamps on a user file to detect changes, likely `UserDefaults` for prefs) makes this near-certain
to be needed, not optional. This doesn't block alpha coding.

## App Review guidelines that apply

All fetched from developer.apple.com/app-store/review/guidelines/, 2026-08-29 — **VERIFIED** for
the quoted text in every row below unless otherwise noted.

| Guideline | What it says / requires | Relevance to pass-sumo |
|---|---|---|
| **2.4.5(i)** | Apps "must be appropriately sandboxed, and follow macOS File System Documentation," and should "only use the appropriate macOS APIs for modifying user data stored by other apps." | The same clause ShotSumo was rejected under (for a pre-set save path + orphaned entitlement, see above). No default/pre-set file paths, no unused entitlements. |
| **2.5.1 / 2.5.2** | Public-API-only, no dynamic code loading; app must be self-contained within its sandbox container and "may not read or write data outside the designated container area." | A user-picked `.kdbx` lives *outside* the container by definition — that's exactly what the user-selected file entitlement + security-scoped bookmark exists to legitimately permit. Nothing here forbids it; it's the reason the entitlement (not a container-relative path) is the correct mechanism. |
| **4.2 Minimum Functionality** | App must be more than "a repackaged website," must have "lasting entertainment value or adequate utility." | Low risk for a password manager, but keep the alpha build functionally real (actually open/edit/save a `.kdbx`) before any review submission. |
| **4.3(b)** | Apple won't accept submissions "indistinguishable from what's already widely available" in categories it names explicitly (dating, flashlight, sound effects, wallpaper, simple timers, fortune telling) unless "meaningfully different." | Password managers are **not** on that explicit list, so the named-category risk doesn't apply — but the general spirit is worth keeping ready in Notes for Review given how many KDBX-compatible apps exist (Strongbox, KeePassium, KeePassXC): pass-sumo's anti-bloat differentiator is the answer to have on hand. |
| **5.1.1(v)** | "If your app doesn't include significant account-based features, let people use it without a login." | pass-sumo has no account system (the `.kdbx` file is the identity) — trivially satisfied, state it plainly in Notes for Review, mirroring ShotSumo's "no account, no demo login possible" answer. **Except**: App Review still needs *some* way to exercise the core "open a vault" flow — see Review-logistics below, this is where "no login" framing alone doesn't fully solve the problem the way it did for ShotSumo. |
| **1.6 Data Security** | "Apps should implement appropriate security measures to ensure proper handling of user information... and prevent its unauthorized use, disclosure, or access by third parties." | Generic principle, not KDBX-specific. |

No explicit guideline clause was found in this research that names "credential storage" or
"password manager" as its own reviewed category. **UNVERIFIED / not found** — absence of evidence
in this search pass, not proof no such clause exists. Worth a second look focused specifically on
Apple's Human Interface Guidelines / security documentation for password-manager-category apps
(e.g. anything tied to the macOS/iOS Credential Provider Extension APIs) if/when v2's Credential
Provider work begins.

No specific, named, real-world rejection report for a password manager or KDBX-format app on the
Mac App Store was found in this research pass — only general "top rejection reasons" listicles and
one adjacent anecdote about a window-manager utility rejected for missing App Sandbox despite
similar unsandboxed apps having shipped (illustrative of inconsistent enforcement in general, not
password-manager-specific, not from an Apple primary source). **UNVERIFIED / not found** — do not
treat this absence as evidence password managers are low-risk.

## Subscriptions & free trial

Applies to a later release, not alpha, per this repo's own stated plan (subscription with free
trial is a later stage). All fetched from developer.apple.com/app-store/review/guidelines/,
2026-08-29.

| Fact | Confidence |
|---|---|
| **3.1.2(a)**: an auto-renewable subscription must provide "ongoing value," and the period must be at least **7 days**, available across all the user's devices | VERIFIED |
| **3.1.2(c)**: before asking a customer to subscribe, the app must clearly describe what they get (content/access/services) and communicate the Schedule 2 requirements (price, duration, auto-renewal terms) from the Apple Developer Program License Agreement | VERIFIED |
| **3.1.1**: a working **Restore Purchases** mechanism is required for restorable in-app purchases | VERIFIED (matches ShotSumo's own `apple-facts.md` entry independently) |
| Functional **Privacy Policy and Terms of Use (EULA)** links, live and reachable both in the app and in App Store Connect metadata, are required once any subscription exists — a fully-free app does not need this, a subscription app does | `[Carried over from ShotSumo's own CONFIRMED finding, not independently re-verified against a live Apple page in this pass — consistent with 5.1.1(i)'s general privacy-policy requirement]` |
| Introductory free trial: **one introductory offer per subscription group per Apple ID, ever** — recreating the group/product does not reset a consumed trial | `[Carried over from ShotSumo's own CONFIRMED finding — an ASC platform behavior, not guideline text]` |

None of this blocks pass-sumo's alpha work.

## Review-logistics (how a reviewer will actually open a vault)

ShotSumo's own review-notes history is the most directly reusable lesson here. It was first
rejected under **Guideline 2.1 — Information Needed** for not proactively supplying: a screen
recording, devices/OS tested, functions & audience, setup & access instructions (relevant since it
has no Dock icon/window — an `LSUIElement` app), external services used, regional differences, and
regulated-industry/protected-material answer. Apple's own guidance was to put items 2–7 permanently
in the Notes field for future submissions. **VERIFIED (rejection text, first-hand).**

pass-sumo has non-obvious UI too (a password manager opening to an empty/locked state) and no demo
account — there's no "account" concept at all, the file *is* the account. Notes for Review should
preemptively cover: what the reviewer sees on first launch, that there's no demo login, external
services (none, if alpha ships fully offline), devices/OS tested, and why any biometric/keychain
prompts appear.

**Open question specific to pass-sumo, not something ShotSumo had to solve:** App Review needs
*some* way to actually open/create a database to test the app's core function. ShotSumo's answer to
Sign-In Information was "no login needed"; that alone doesn't fully answer the question for a
password manager the way it did for a screenshot tool. Two candidate answers: ship a small sample
`.kdbx` file's password in the Review notes, or make the app able to create a brand-new empty
database on first launch so the reviewer isn't blocked needing a pre-existing file. **INFERRED —
not addressed in ShotSumo's docs, no Apple source checked for this specific scenario.** This is a
product-design decision — see OPEN QUESTIONS below.

Versioning/process conventions worth carrying over from ShotSumo (not Apple-mandated, just
practical): version/build number stamped from git (`git describe --tags`, `git rev-list --count
HEAD`) at build time via a pre-build script, never hand-edited in the checked-in `Info.plist`
template.

---

## OPEN QUESTIONS

Everything here must be resolved — or at minimum explicitly decided — before the first App Store
submission.

1. **`ITSAppUsesNonExemptEncryption` classification.** The current plan is `true`, because pass-sumo
   implements its own confidentiality encryption (KDBX AES-256/ChaCha20 with an Argon2 KDF), which
   is not the "limited to authentication" exemption. But the classification itself is INFERRED, the
   BIS annual self-classification report obligation is INFERRED, and the French ANSSI declaration
   requirement is INFERRED in its applicability details (though VERIFIED to exist as a category).
   **This is a legal declaration, not a build flag** — it needs a human/legal sign-off, not just a
   code change. What would settle it: read the live App Store Connect export-compliance
   questionnaire text directly at submission time, and get legal/compliance confirmation of the BIS
   self-classification and (if shipping to France) ANSSI declaration obligations.
2. **`NSFaceIDUsageDescription` / Touch ID Info.plist keys.** Currently UNVERIFIED, sourced only
   from secondary articles. What would settle it: check the live Xcode Info.plist key reference
   before writing any `LAContext`/biometric code.
3. **Keychain-access-group entitlement requirement for biometric-gated Keychain access on macOS.**
   Currently UNVERIFIED, sourced from a single forum report. What would settle it: test directly
   against a real signed build.
4. **Required Reason API verbatim reason codes** (UserDefaults, File Timestamp, Disk Space).
   Apple's canonical reference page 404'd in this research pass. What would settle it: re-locate and
   read the current page directly before implementing any of these APIs — citing the wrong code is
   a validation failure, not a style nit.
5. **Primary category: Utilities vs. Productivity.** Not yet decided. What would settle it: a
   product decision, not further research — pick one and set `LSApplicationCategoryType` in the
   build config early so it's never a last-minute surprise (cf. ShotSumo's error 90242).
6. **Review-logistics affordance for "open a vault."** Sample vault + password in Review Notes, vs.
   an in-app "create a new empty vault" flow available at first launch. What would settle it: a
   product-design decision, made now — it's cheaper to build the affordance in from the start than
   retrofit it under review-rejection pressure the way ShotSumo had to twice.
7. **Hardened Runtime for plain MAS uploads.** Whether Xcode's App Store upload flow actually
   enforces it is UNVERIFIED. What would settle it: attempt an upload without it and see if it's
   blocked — or just enable it regardless, since ShotSumo found it costs nothing.
8. **iCloud Drive file access without ubiquity entitlements.** Currently INFERRED from forum
   corroboration only. What would settle it: pick a file that lives only in iCloud Drive, not yet
   locally cached, and confirm the read succeeds and triggers a download under App Sandbox.
