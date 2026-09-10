---
name: pass-sumo-parallel-sessions-share-a-checkout
description: Several Claude sessions work this repo at once through one git checkout; branch-switch and wholesale `git add` strand each other's work.
metadata:
  type: project
---

On 2026-09-10 four Claude sessions worked pass-sumo simultaneously (docs, ASC setup, design,
issue #65). They shared the single checkout at `~/git/personal/pass-sumo`, and two things went
wrong within minutes of each other:

- A session created a branch in the shared tree, which carried another session's **uncommitted**
  edits along, and a wholesale `git add CLAUDE.md` swept a foreign hunk into its commit and its
  PR. The commit message did not mention it, and the PR pointed at a file that existed only on
  the other branch.
- A later `git switch` in that tree would have stranded a third session's uncommitted
  `Sources/Model/Domain.swift` on a branch it never chose — silently, with no error.

**Why:** one working tree cannot serve several writers. `git add <explicit path>` is not enough
protection when the collision is *inside* one file, and a branch switch succeeds quietly no
matter whose work is dirty in the tree.

**How to apply:** give your branch its own `git worktree` and work there, leaving the shared
checkout to whoever is actually editing in it. Before assuming the tree is yours, check
`git branch --show-current` and `git status` — and re-check after any pause, because another
session may have moved it under you. When a peer reports merge state or a PR's contents, verify
it yourself (`git fetch`, `gh pr diff`) rather than repeating it; several claims traded between
sessions that day were stale reads stated as current, in both directions.

Whether "one worktree per session" becomes a repo rule is the owner's call — it was put to him as
a suggestion, not written into `CLAUDE.md`. See [[pass-sumo-memory-lives-in-repo]].
