---
name: pass-sumo-shared-checkout-git-state
description: Several sessions share one pass-sumo checkout, so HEAD moves under you — judge branch state with `git branch --contains`, never from a subagent's report.
metadata:
  type: feedback
---

Four-plus Claude sessions work in this repo at once, and they share **one** working checkout while
some also use worktrees (`.claude/worktrees/`). So the checked-out branch changes hands during a
session without anything telling you: within one morning this tree sat on `docs/4-export-compliance`,
then `docs/unpin-test-counts`, then a `feat/` branch. "What `HEAD` points at" and "what `main`
points at" come apart constantly, and a branch checked out in another worktree is not available to
check out here.

**Why:** I told a peer session it had committed directly to `main` — a hard repo violation — on a
claim that was false. My implementing subagent's report said "local `main` is one commit ahead at
`508eb2d`"; the only command I ran myself was `git log -1 --format=… 508eb2d`, which prints a
commit's author and subject and says **nothing** about which branch contains it. I then wrote to the
peer under the heading "what I observed, read-only" and listed the subagent's claim as my own
observation. The commit was on its own pushed branch the whole time, open as a PR.

**How to apply:**

- A subagent's factual claim is a lead, not an observation. Never relay one in your own voice, and
  never act on one, without running the command that answers the question yourself. This matters
  most when the claim accuses someone of breaking a rule.
- To ask which branch holds a commit: `git branch --contains <sha> --all`. It answers directly and
  its `+` marker also reveals a branch checked out in another worktree, which explains most
  confusion here in one line.
- To ask whether local and remote agree: `git rev-parse main origin/main` plus
  `git rev-list --left-right --count main...origin/main`. Both are independent of whichever branch
  happens to be checked out. `git log`/`git status` are not.
- Branch from `origin/main` explicitly (`git checkout -b <name> origin/main`), never from whatever
  `HEAD` happens to be. Expect files from another session's branch to vanish from the tree when you
  do — that is the checkout changing, not work being lost.
- Never `git reset --hard`, `git stash`, `git checkout --`, or `git add -A` here. Stage by explicit
  path. Uncommitted changes you did not make belong to another live session.

Related: [[pass-sumo-work-sequencing]], [[pass-sumo-memory-lives-in-repo]]
