# Market research: KDBX password managers on macOS (2026-08)

> Status: living · Last verified: 2026-08-29 · [AI - claude-sonnet-5]

## Strongbox

Acquired by Applause (which also acquired Bartender in 2024 and Voice Dream — both acquisitions
damaged user trust), announced 2025-03-13/14. Creator Mark McGuill stays on in an advisory role.

As of 2026-08 pricing is unchanged: $2.99/mo, $24.99/yr, $124.99 lifetime.

Community reaction was strongly negative — Privacy Guides removed its recommendation.

- HN thread: https://news.ycombinator.com/item?id=43356283
- https://strongboxsafe.com/strongbox-joins-applause/
- https://mjtsai.com/blog/2025/03/14/strongbox-acquired-by-applause-group/

User's own assessment: feature-bloated.

## KeePassium

GPLv3, actively developed. macOS Catalyst app since 2024-12 (v2.0). Not fully Mac-idiomatic — the
author admits Catalyst limits (e.g. keyboard navigation); no search over the password field.
Roughly 250k free downloads / ~8k Pro (third-party aggregator estimate, approximate).

https://keepassium.com/blog/2024/12/keepassium-2.0/

## MacPass

De facto abandoned (last release ≤2022, 283 open issues), not in the App Store. Built on the
GPLv3 KeePassKit ecosystem.

## KeePassXC

Alive (2.7.11, 2025-11), but Qt-based — does not feel native. Not in the App Store.

## KeeWeb

Dead (last release 2021-07).

## PanicVault — closest competitor

Mac App Store, id6759188575, developer Pierre Stanislas. $4.99 one-time, no subscription/account,
native SwiftUI (per user reviews), KDBX4 (Argon2/ChaCha20), passkeys, TOTP, iCloud Drive/Google
Drive sync, system AutoFill. Very new: v1.0.8, 2 ratings as of 2026-08.

Validates the niche; competes on the same "native + App Store" ground. Consequence: price-anchor
against Strongbox, differentiate from PanicVault by quality and velocity, not price.

## PearPass

Tether's P2P, cloud-free password manager. Own format (not KDBX), free/open-source. Relevant only
as inspiration for a future sync model, not for KDBX compatibility.

https://pass.pears.com/

## Libraries

- **KDBXKit** — github.com/shadone/KDBXKit, BSD-2-Clause, Swift/SPM. KDBX 4.0/4.1 write + 3.1
  read, Argon2d/id + ChaCha20/AES. Author-claimed keepassxc-cli round-trip tests. v1.0.0
  2026-05-19, ~0 stars — young, needs our own test coverage before trusting.
- **KeePassKit** — github.com/MacPass/KeePassKit, Obj-C, GPLv3 — unusable, App Store incompatible.
  Alive-ish, last commit 2025-11.
- **KeePassium engine** — GPLv3, not separable from the app — unusable.

## Passkeys in KDBX

KeePassXC stores passkeys as separate entries with `KPEX_PASSKEY_*` custom attributes (PKCS#8 PEM
private key, etc.); Strongbox stores them in-entry. The two are documented as mutually breaking.
No clean universal convention exists, hence passkeys are deferred beyond v1.

- https://github.com/keepassxreboot/keepassxc/issues/10414
- https://strongboxsafe.com/passkeys/
