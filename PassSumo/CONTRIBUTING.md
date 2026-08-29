# Contributing to PassSumo

Thanks for your interest in PassSumo.

This project has no chosen license yet, so no contributor license terms are defined either —
that will be written up once the project's own license is settled. Until then, treat any pull
request as a proposal to discuss, not something that can be merged.

## Ground rules

- **No GPL/AGPL code, ever.** Any third-party dependency must be MIT/BSD/Apache-2.0/CC0-licensed
  and recorded in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). GPL is incompatible with App
  Store distribution, which rules it out unconditionally, not just as a preference.
- Interop with the wider KeePass ecosystem (KeePassXC, KeePassium, Strongbox) must not regress —
  a round trip through PassSumo must not lose entries, fields, attachments, history, custom data,
  or icons written by another client.
- Never write a plaintext secret (master password, entry password) to disk or to a log.

## Reporting issues

Bug reports and feature requests are welcome as GitHub issues.
