# Documentation map

> Status: living · Last verified: 2026-08-29 · [AI - claude-sonnet-5]

This file is the map of every long-lived document in this repo — read it first to find where
something is, or where something new should go.

## What's where

| Doc | What it's for / when to read it |
|---|---|
| [`../README.md`](../README.md) | Repo entry point: what pass-sumo is, current status. |
| [`../CLAUDE.md`](../CLAUDE.md) (symlinked as `../AGENTS.md`) | Working agreements for AI sessions in this repo — positioning, key decisions, repo structure, working rules. Read before doing any work here. |
| `publish/apple-facts.md` | Apple's Mac App Store requirements as verified facts, each with a confidence label (VERIFIED/INFERRED/UNVERIFIED). Includes what ShotSumo (same developer account) learned first-hand from its own rejections and validation errors. Ends with an OPEN QUESTIONS list to resolve before the first submission. |
| `publish/identifiers.md` | The handover sheet: every settled identifier (bundle id, test-bundle ids, Team ID, keychain group/service). Check here before ever typing an identifier from memory. |
| [`../thinks/market-research.md`](../thinks/market-research.md) | Positioning and competitor research — working material, not a public doc. |
| [`../thinks/prompts/`](../thinks/prompts/) | Prompts written for other AIs. |
| [`../claude-memory/`](../claude-memory/) | Claude's per-project memory — travels with the repo via a SessionStart-managed symlink. Not a doc to edit by hand. |

## Where a new doc goes

- **`docs/`** — anything that should still be true in months from now: reference material, settled
  decisions, checklists that get reused. Public-ish, English-only.
- **`thinks/`** — working material and planning that's only interesting while the work is in
  flight (audits, plans, one-off task notes). Private, never published.
- **`thinks/prompts/`** — prompts written for other AIs, named `<ai-name>-<topic>.md`.

## Freshness stamp

Every long-lived doc in `docs/` carries a freshness stamp as its first line:

```
> Status: <living|draft|frozen> · Last verified: YYYY-MM-DD · [AI - <model-id>]
```

Refreshed by whoever substantively edits the doc. Use absolute dates only — never "today" or
relative phrasing, since the doc outlives the session that wrote it.
