# engram — agent-facing usage

`engram` is branch-scoped memory for coding agents. It stores decisions as
**migration files committed to the repo** (`.agents/memories/*.md`) and
materializes them into a **per-clone SQLite cache** (`.git/engram.db`, never
committed). Checking out a branch applies the memories that exist there and
rolls back the ones that don't — perfect recall on checkout, clean amnesia on
switch. There's no server, no daemon, and no required embedding model: with
no config, search is FTS5-only.

The migration files are the source of truth. The SQLite cache is disposable —
delete `.git/engram.db` and the next `engram sync` rebuilds it byte-for-byte
from `.agents/memories/`.

## Commands

```
engram init                                   Create .agents/memories/, a config stub, run the first sync
engram new "<title>" [--topics a,b] [--supersedes id,...]
                                               Scaffold a new memory migration file
engram sync [--verbose] [--quiet]             Reconcile the DB cache against .agents/memories/
engram search <query> [--topic t] [--limit n] [--all] [--json]
                                               FTS5 bm25 + recency (+ optional embeddings) ranked search
engram recent [--topic t] [--limit n] [--json]
                                               Newest-first active memories
engram show <id> [--json]                     Full body and metadata for one memory
engram mcp                                    Run the stdio MCP server
engram hook install|uninstall                 Manage post-checkout/post-merge/post-rewrite git hooks
engram doctor                                 Check FTS5, memories dir, hook state, embedder reachability, DB integrity
engram version                                Print the engram version
```

Exit codes: `0` ok, `1` a user/data error (bad frontmatter, duplicate ids, a
bad config file, an unknown memory id), `2` an environment error (no `.git`
found, sqlite built without FTS5, a failed DB integrity check).

Superseded memories (named in another memory's `supersedes:` list) are
excluded from `search`/`recent` output unless you pass `--all`.

## Memory file format

Path: `.agents/memories/<ID>_<slug>.md`, where `<ID>` is a 14-digit
`YYYYMMDDHHMMSS` UTC timestamp. The filename is canonical — frontmatter `id`
must match it or `sync` reports an error. `engram new "<title>"` scaffolds
this for you.

```markdown
---
id: 20260710153000
title: Chose SQLite over Postgres for the memory cache
topics: [storage, architecture]
supersedes: []            # optional: ids of older memories this one replaces
author: seth              # optional, freeform
---

**Decision:** Use a per-clone SQLite file at .git/engram.db instead of a
shared Postgres database.

**Why:** Zero configuration for every teammate; the DB is a disposable cache
of the migration files, so nothing is lost when it's deleted.

**Rejected:** Postgres + pgvector — the per-developer setup cost (install,
extension, embedding model) was the main thing killing adoption.
```

Frontmatter is a strict flat-YAML subset (string/array values only). The
`Decision`/`Why`/`Rejected` bold-label body sections are convention, not
schema — write whatever markdown is useful. `supersedes` entries demote (not
delete) the memories they name: superseded memories are hidden from default
`search`/`recent` output, but still exist and show up with `--all`.

Duplicate ids across two files in the tree make `sync` fail loudly, naming
both paths — that's deliberate: a duplicate id is two decisions genuinely in
conflict, and it should surface like a merge conflict, not get silently
resolved.

**A memory file is inert until it's committed.** Writing it (by hand, via
`engram new`, or via the MCP `remember` tool) only updates the local working
tree and the local cache — nothing is real for any other clone until the file
is `git add`ed and committed like any other change.

## MCP tools (`engram mcp`)

Point an MCP-aware agent at the built binary (see `.mcp.json` in this repo)
to get five tools:

| Tool | Args | Does |
|---|---|---|
| `search_memories` | `{query, topic?, limit?, include_superseded?}` | Ranked search: FTS5 bm25 + recency, blended with cosine similarity via RRF if embeddings are configured. |
| `recent_memories` | `{topic?, limit?}` | Newest-first active memories. |
| `get_memory` | `{id}` | Full body + metadata for one memory id. |
| `remember` | `{title, body, topics?, supersedes?}` | Writes a new migration file under `.agents/memories/` and applies it to the local cache. |
| `memory_status` | `{}` | Active/superseded counts, embedder on/off, DB path, last sync time. |

**`remember` writes a file that must be committed.** Like `engram new`, the
tool result explicitly reminds you: the migration file it just wrote is only
on disk and in the local cache. Run `git add` and commit it — otherwise the
memory disappears the next time the tree is reset and never reaches anyone
else's clone.
