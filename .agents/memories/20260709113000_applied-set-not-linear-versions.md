---
id: 20260709113000
title: The applied set is unordered rows, not a linear version counter
topics: [sync, schema, architecture]
supersedes: []
author: seth
---

**Decision:** Whether a memory is "applied" is just whether its row exists
in the `memories` table — there's no `schema_version` integer, no linear
ordering, no concept of memory N+1 depending on memory N having run first.
This mirrors Rails' `schema_migrations` model (a set of applied IDs) rather
than a single incrementing version number.

**Why:** Branches reorder freely. Two branches can each add memories with
IDs that interleave in time relative to each other, and there is no
meaningful, universal answer to "which one comes first" once they're both
in play — the same problem that makes cross-branch commit ordering
unsolvable in git generally. Modeling the applied set as an unordered set
of present/absent rows sidesteps the whole question: sync doesn't need to
know or care what order memories were created in, only whether each one's
file currently exists in the tree.

**Rejected:** A single `schema_version` watermark (the classic "current
version number" migration model). That model assumes migrations form one
global, totally-ordered sequence — true for a database schema evolving on
a single mainline, false the moment two branches are independently
recording decisions that later merge. Forcing a linear order onto that
would have meant inventing some arbitrary tie-break rule for cross-branch
conflicts that doesn't actually reflect anything true about the decisions
themselves.
