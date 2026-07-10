---
id: 20260710083000
title: A duplicate memory id fails sync loudly instead of picking a winner
topics: [sync, conflict-resolution, architecture]
supersedes: []
author: seth
---

**Decision:** If two files under `.agents/memories/` declare the same
`id`, `engram sync` raises before touching the store at all, naming both
offending paths in the error. It does not guess, does not take the newer
file's mtime, and does not silently keep whichever one sorted first.

**Why:** A duplicate migration id almost always means two branches
independently recorded a decision in the same timestamp "slot" — which is
itself a signal that two people made a real decision without seeing each
other's reasoning. That's a decision conflict, not a data-format hiccup,
and it deserves the same treatment a real merge conflict gets: surfaced to
a human at merge/sync time, forcing an explicit choice (rename one memory's
id, or fold them into a single memory referencing both), rather than
resolved automatically in a way nobody actually reviewed. Failing loudly
here is what makes the migration-file model trustworthy — silent
last-write-wins would mean a memory could vanish from the record with no
trace that it ever existed.

**Rejected:** Last-write-wins by file mtime, or by whichever file sorts
first alphabetically. Both are silent, both are essentially random from
the perspective of "which decision does the team actually agree happened,"
and both would make `engram sync`'s output lie about how many memories are
actually active without anyone noticing.
