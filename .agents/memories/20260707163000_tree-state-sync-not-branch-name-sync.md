---
id: 20260707163000
title: Sync reconciles tree state, never branch names or git history
topics: [sync, git, architecture]
supersedes: []
author: seth
---

**Decision:** `engram sync` scans `.agents/memories/*.md` on disk right now
and set-diffs it against the rows already in `.git/engram.db`. It never
looks at the current branch name, `git log`, reflogs, or any other piece of
git history to decide what should be applied.

**Why:** Correctness for free in every weird tree state a developer or an
agent can end up in: mid-rebase, detached HEAD, right after `git stash pop`,
immediately after a merge with unresolved-but-present files. All of these
are just "some set of `.md` files exists in `.agents/memories/` right now,"
which is the only fact sync needs. A file present with no matching row gets
applied; a row present with no matching file gets rolled back; a file whose
content changed gets re-applied in place. That's the entire algorithm, and
it's idempotent by construction — running it twice with nothing changed is
a no-op.

**Rejected:** Tracking sync state by branch name or by diffing against a
"last synced commit." Branch names get renamed and reused; a commit-based
diff falls apart the moment someone rebases, squashes, or force-pushes.
Tying correctness to git history mining would also have meant engram needed
to shell out to `git` and reason about its output — fragile, and a
violation of the non-goal that source of truth is the working tree, full
stop.
