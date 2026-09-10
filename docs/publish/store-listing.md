# App Store listing copy — 1.0.0

> Status: living · Last verified: 2026-09-10 · [AI - claude-opus-5]
> The exact text entered into App Store Connect on 2026-09-10, kept here so it can be reviewed,
> diffed and re-localized without reading it back out of the console. Identifiers, prices and
> product IDs live in [`identifiers.md`](identifiers.md); Apple's platform rules live in
> [`apple-facts.md`](apple-facts.md).

Everything below is the `English (U.S.)` localization, which is also the app's primary language.
Localizing the listing is a **separate axis** from localizing the app: App Store Connect holds
listing metadata per language independently of `CFBundleLocalizations`, so shipping the app in five
languages (issue #46) does not localize this page, and localizing this page does not require
shipping the app in that language.

## Subtitle — 25 of 30 chars

```
Password manager for KDBX
```

It names the thing the app is. ShotSumo's issue #171 is the cautionary tale here: its subtitle was
slogans and never said the app took screenshots.

## Promotional Text — 165 of 170 chars

Editable at any time without shipping a new version, unlike the Description.

```
One .kdbx file you keep, in iCloud Drive or on local disk. No account, no sync service, no telemetry. Vaults from other KeePass apps open here, and yours open there.
```

## Keywords — 90 of 100 chars

```
keepass,vault,totp,2fa,offline,argon2,chacha20,generator,local,secure,encrypted,passphrase
```

Apple indexes the app name and subtitle together with the keywords, so `password`, `manager` and
`kdbx` are deliberately **absent** — they already appear in the name or subtitle, and repeating
them would waste the budget.

## Description — 2,945 of 4,000 chars

```
PassSumo is a native Mac password manager built on KDBX 4.x - the open format used by KeePass-compatible apps across desktop and mobile. Your vault is one file, and you decide where it lives.

THE FILE IS THE DATABASE
No account, no sign-up, and no cloud of ours. Put the .kdbx file in iCloud Drive and every Mac that can reach that folder can open it; keep it on local disk and it never leaves the machine. Sync is whatever already moves your file - PassSumo runs no sync service of its own.

BUILT FOR INTEROP
A vault created in another KDBX app opens in PassSumo, and a vault PassSumo saves opens in them. Reading and writing the same open format is a design requirement here, not an afterthought.

ENCRYPTION IS THE FORMAT'S
The vault payload is encrypted with AES-256 or ChaCha20 under a key derived with Argon2 - exactly what the KDBX format specifies, applied the way any compliant reader or writer applies it.

WHAT IT DOES
- Unlock with your master password, or enrol Touch ID as a shortcut afterwards
- Search across every field, including the password field
- A password generator with a live strength read-out
- TOTP codes for two-factor accounts
- File attachments on an entry
- A recycle bin inside the vault, the convention other KDBX clients already use
- An automatic backup kept before saving over your vault
- A clipboard that clears itself, and auto-lock on a timer

DECIDED, NOT MISSING
No AutoFill and no browser extension: filling a password into a running browser is attack surface this app deliberately does not have. No passkeys: those need a system credential provider, and there is no settled cross-client convention for storing one in a KDBX file. Both are stated here so they do not have to be discovered by their absence.

PRIVATE
No analytics, no telemetry, no usage statistics, and no account of any kind. Your vault and everything in it stay on your Mac - the developer never sees them.

FREE FOR A MONTH, THEN A SUBSCRIPTION
PassSumo is free to try for one month, with nothing held back. After that, editing your vault requires an active subscription: PassSumo Monthly at $2.49 per month, or PassSumo Yearly at $19.99 per year. The App Store shows the price in your local currency before you confirm. Payment is charged to your Apple ID account at confirmation of purchase. The subscription renews automatically unless auto-renew is turned off at least 24 hours before the end of the current period, and the renewal charge is made within 24 hours before that period ends. Manage or cancel any time in your Apple ID subscription settings.

YOUR VAULT NEVER STOPS OPENING
If a subscription lapses, PassSumo still opens your vault and still lets you read and copy every password in it. Only changing the vault needs an active subscription. Nobody should lose sight of their own passwords because a payment did.

Privacy Policy: https://heaven8.com/passsumo/privacy
Terms of Use: https://heaven8.com/passsumo/terms
```

### Why the last two paragraphs are worded the way they are

**"FREE FOR A MONTH, THEN A SUBSCRIPTION"** exists to satisfy guideline 3.1.2(c), which expects the
subscription's length, price, auto-renewal behaviour and cancellation route to be disclosed before
a customer subscribes. The App Store already shows each product's own price automatically, so
repeating "$2.49" and "$19.99" is not strictly required — it is included so a reviewer does not
have to open the purchase sheet to find the numbers. Note what this paragraph does **not** do: it
never says the app is "free" or "has no subscription", which is the claim the no-absolute-price-
claims rule bans. ShotSumo learned that the rule is about the promise made, not the words used —
its 1.x Description never wrote "free" but promised unrestricted use anyway, and that had to be
retracted (its issue #231).

**"YOUR VAULT NEVER STOPS OPENING"** is the owner's decision on lapse behaviour, stated as a
feature rather than buried. It also inoculates against the review risk under 3.1.2(a), whose
"ongoing value" examples do not cleanly cover a local utility with no server: the paragraph makes
clear the customer is buying editing, and that nothing they already own is held hostage.

## Support URL / Marketing URL / Copyright

| Field | Value |
|---|---|
| Support URL | `https://heaven8.com/passsumo/support` |
| Marketing URL | `https://heaven8.com/passsumo` |
| Copyright | `2026 Nico Jamieson` |
| Privacy Policy | `https://heaven8.com/passsumo/privacy` — also required as its own ASC field under 5.1.1(i) |
| Terms of Use (EULA) | `https://heaven8.com/passsumo/terms` — Apple's Standard EULA applies; this page supplements it |

All four URLs returned **200 with no redirect** when checked on 2026-09-10, and the live pages
matched `main` in the `heaven8-landing` repo. Finsumo has a whole issue (#90) about exactly this
check, so it is worth re-running immediately before submission rather than trusting this line.

## Archive when

The 1.0.0 listing has shipped and a later version's copy supersedes this text. Until then this is
the live record of what is in the console.
