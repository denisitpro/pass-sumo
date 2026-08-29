# Publication identifiers — handover sheet

> Status: living · Last verified: 2026-08-29 · [AI - claude-sonnet-5]
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

## Not yet created — do not guess

| Item | Value |
|---|---|
| App Store Connect SKU | `TBD — not yet created` |
| App Store Connect App ID (numeric Apple ID) | `TBD — not yet created` |

These two are created inside App Store Connect, not derived from anything already decided — fill
them in here the same day they're created, reading the value back from the console rather than
from memory of having typed it.
