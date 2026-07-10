---
id: 20260707141500
title: Chose SQLite over Postgres for the memory cache
topics: [storage, architecture]
supersedes: []
author: seth
---

**Decision:** Use a per-clone SQLite file at `.git/engram.db` instead of a
shared Postgres database.

**Why:** Zero configuration for every teammate; the DB is a disposable cache
of the migration files in `.agents/memories/*.md`, so nothing is lost when
it's deleted — the next `engram sync` rebuilds it byte-for-byte from the
working tree. A tool meant to lower the cost of recording a decision can't
itself impose a setup tax on every developer who clones the repo.

**Rejected:** Postgres + pgvector — the per-developer setup cost (install,
extension, running server, embedding model just to get *any* value out of
it) was the main thing killing adoption of earlier internal attempts at
this. A shared server also doesn't understand branches: it would need its
own reconciliation logic to know which memories are "active" for whatever
tree a given developer currently has checked out, which is exactly the
problem engram exists to solve at the filesystem layer instead.
