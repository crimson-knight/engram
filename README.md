# engram

**Branch-scoped memory for coding agents.**

Decision context should travel with code the way schema travels with data.
`engram` stores agent memories as **migration files committed to the repo**
(`.agents/memories/*.md`) and materializes them into a **per-clone SQLite
cache** (`.git/engram.db`, never committed). Switch branches, and the
memories that exist there get applied; the ones that don't get rolled back.

The agent gets perfect recall on checkout, and clean amnesia on switch.

Zero config: no Postgres, no pgvector, no model download to get started.
One static Crystal binary.

## Why this exists

Every agentic coding session re-derives decisions that were already made and
already rejected, because "why we picked X over Y" lives in someone's memory,
a Slack thread, or a stale wiki page — not in the branch the agent is
actually looking at right now. `engram` treats that context the same way
you'd treat schema: as versioned, branch-aware, and reconstructable from
scratch at any time.

- **Migration files, not a database, are the source of truth.** `.agents/memories/*.md`
  lives in git. `.git/engram.db` is a disposable cache anyone can delete —
  the next `engram sync` rebuilds it perfectly from the tree.
- **Tree-state sync, not branch-name sync.** `engram sync` only ever looks
  at what's on disk right now and what's in the cache. That means it's
  correct mid-rebase, in a detached HEAD, after a stash, after a merge —
  there's no history to mine and nothing to get out of sync with.
- **Duplicate memory IDs fail loudly.** If two branches independently
  record a decision under colliding IDs, that's a *decision conflict*, and
  it should surface at merge time exactly like a code conflict does — not
  get silently resolved last-write-wins.

## 90-second quickstart

```sh
# 1. Build (or grab a release binary) and put it on your PATH.
crystal build src/engram.cr -o bin/engram

# 2. Inside any git repo:
engram init
#   → creates .agents/memories/, a commented-out .agents/engram.yml stub,
#     a .gitignore note, and runs the (empty) first sync.

# 3. Record a decision.
engram new "Chose SQLite over Postgres for the memory cache" \
  --topics storage,architecture
#   → .agents/memories/20260710153000_chose-sqlite-over-postgres.md

# Edit the file — Decision / Why / Rejected is convention, not schema:
#   **Decision:** Use a per-clone SQLite file at .git/engram.db.
#   **Why:** Zero configuration for every teammate; disposable cache.
#   **Rejected:** Postgres + pgvector — setup cost killed adoption.

# 4. Apply it to the local cache.
engram sync
#   → engram: +1 applied, -0 rolled back, 0 updated (1 active)

# 5. Find it again, from any tool that can shell out or speak MCP.
engram search "postgres"
#   → #20260710153000  Chose SQLite over Postgres  [storage, architecture]  score=-1.4
#         **Decision:** Use a per-clone SQLite file at .git/engram.db. **Why:** ...

# 6. Commit the migration file like any other change.
git add .agents/memories/
git commit -m "memory: chose SQLite over Postgres"
```

That's the whole loop. No server, no daemon, no accounts.

## The reviewer's story

A reviewer checks out a coworker's branch to try something out, then
switches back to `main`. On the branch, `engram search` (or the MCP
`search_memories`/`recent_memories` tools, if they're using an agent)
surfaced the three decisions that branch's author had already recorded —
including one explicitly rejecting the approach the reviewer was about to
suggest. Switching back to `main`, those same memories quietly disappear
from every query: `main` never claimed them, so the cache doesn't lie about
what's actually true here. No stale context bleeding across branches in
either direction, and nothing to remember to clean up — `git checkout` (via
the installed hook) or the next `engram sync` handles it, always.

## The `.agents/` convention

`engram` puts its migration files at `.agents/memories/` and its optional
config at `.agents/engram.yml` — a nod to the emerging convention of
`.agents/` as the place a repo keeps material meant for coding agents
(as distinct from `.github/`, which is for the forge, or docs meant for
humans first). If your other tooling already reads `.agents/`, `engram`
slots in next to it; if it doesn't yet, this is a reasonable place to start.

## MCP setup (Claude Code)

`engram mcp` runs a stdio JSON-RPC MCP server in-process — no subprocess
shell-outs, no separate daemon to keep alive. Point Claude Code at the built
binary via `.mcp.json` in your repo root:

```json
{
  "mcpServers": {
    "engram": {
      "command": "/absolute/path/to/bin/engram",
      "args": ["mcp"]
    }
  }
}
```

That gives the agent five tools:

| Tool | Does |
|---|---|
| `search_memories` | Ranked search: `{query, topic?, limit?, include_superseded?}` |
| `recent_memories` | Newest active memories: `{topic?, limit?}` |
| `get_memory` | Full body + metadata for one id: `{id}` |
| `remember` | Writes a new migration file *and* applies it: `{title, body, topics?, supersedes?}` |
| `memory_status` | Active/superseded counts, embedder state, DB path, last sync |

`remember`'s result always reminds the agent that the file it just wrote
still needs `git add` + a commit — writing the migration file is not the
same as it being real for anyone else, and engram never commits on your
behalf.

Every tool result carries both a human-readable `content` summary and a
`structuredContent` JSON payload with the same shape as the CLI's `--json`
output, so the two interfaces stay interchangeable.

## Search ranking

`engram search <query>` combines two signals, in this order:

1. **FTS5 bm25**, over an external-content virtual table indexing
   `title`, `topics`, and `body`. Lower is better (sqlite's convention).
2. **A recency boost**, folded directly into the bm25 score:

   ```
   score = bm25(memories_fts) - recency_boost
   recency_boost = 1.0 * (id - oldest) / (newest - oldest)
   ```

   where `oldest`/`newest` are the id (timestamp) bounds of the candidates
   actually being ranked in this call — so a newer memory always edges out
   an older one when their keyword relevance is otherwise close, without a
   handful of ancient-but-perfect matches getting buried by pure recency.

3. **Optional semantic search.** If `.agents/engram.yml` configures an
   embedder and at least one memory has a stored embedding, `engram` also
   computes brute-force cosine similarity between the query and every
   embedded memory, then merges the two rankings via **Reciprocal Rank
   Fusion** (`k = 60`):

   ```
   rrf_score(id) = 1/(60 + bm25_rank(id)) + 1/(60 + cosine_rank(id))
   ```

   RRF sidesteps the usual pain of merging two differently-scaled scores —
   it only cares about each ranking's *ordering*. A memory with zero
   keyword overlap with the query can still surface (and win) purely on
   semantic similarity.

Superseded memories (anything named in another memory's `supersedes:`
list) are excluded from `search` and `recent` unless you pass `--all`.

## Embeddings are optional, always

With no `.agents/engram.yml`, engram is FTS5-only — this is the default
and the zero-friction adoption path. To turn semantic search on, point it
at any OpenAI-compatible `/v1/embeddings` endpoint (Ollama works great
locally):

```yaml
embedder:
  url: http://localhost:11434/v1/embeddings
  model: nomic-embed-text
  api_key_env: OPENAI_API_KEY   # optional; the *name* of an env var, never a key value
```

If that endpoint is ever unreachable, `engram sync` warns once to stderr
and continues without embeddings — a dead embedding server never blocks a
sync, and search silently falls back to bm25-only ranking.

## CLI reference

```
engram init                                   Create .agents/memories/, a config stub, run the first sync
engram new "<title>" [--topics a,b] [--supersedes id,...]
engram sync [--verbose] [--quiet]
engram search <query> [--topic t] [--limit n] [--all] [--json]
engram recent [--topic t] [--limit n] [--json]
engram show <id> [--json]
engram mcp                                    Run the stdio MCP server
engram hook install|uninstall                 post-checkout / post-merge / post-rewrite → `engram sync --quiet`
engram doctor                                 FTS5, memories dir, hook state, embedder reachability, DB integrity
engram version
```

Exit codes: `0` ok, `1` a user/data error (bad frontmatter, duplicate ids,
a bad config file, an unknown memory id), `2` an environment error (no
`.git` found, sqlite built without FTS5, a failed DB integrity check).

## FAQ

**Why not just use Postgres + pgvector?**
Because then every teammate needs a running Postgres, the pgvector
extension, and (for anything beyond keyword search) an embedding model —
before they've gotten any value out of the tool at all. That per-developer
setup cost was the actual thing killing adoption in earlier attempts.
`engram` ships as one static binary; the "database" is a disposable SQLite
file rebuilt from the repo any time it's missing.

**Why migration files instead of just... a database?**
Because a database is a single mutable blob that doesn't understand
branches. Migration files get the entire toolchain you already trust for
free: `git blame` on a decision, `git log -p` on how it evolved, `git diff`
between branches to see exactly which decisions are in play, and a merge
conflict when two branches genuinely disagree. `.git/engram.db` is just the
materialized view — delete it, run `engram sync`, and it's back, byte-for-
byte reconstructable from the tree.

**Don't merge conflicts on memory files get annoying?**
They're supposed to happen — rarely, and only when they mean something.
Two files legitimately colliding on the same 14-digit id is two people
recording *different* decisions under what your tooling treated as the same
slot. That's not busywork; that's exactly the moment you want a human to
look and decide which decision actually stands, instead of engram quietly
picking one for you.

**What happens if I delete `.git/engram.db`?**
Nothing bad. It's a cache. The next `engram sync` (or the git hooks, if
installed) rebuilds it from `.agents/memories/*.md` from scratch.

**Does engram mine git history for memories?**
No, deliberately. Source of truth is the working tree, full stop — no
history mining, no linear version ordering, no unsolvable "which commit's
memory wins across branches" problem. The applied set is just: does this
migration file currently exist? That's Rails' `schema_migrations` model,
not a `schema_version` counter, and it's why branches can reorder memories
freely without engram ever getting confused.

## Repository layout

```
engram/
  shard.yml
  src/engram.cr              # entry point / CLI dispatch
  src/engram/version.cr
  src/engram/store.cr        # SQLite open/schema/queries
  src/engram/memory_file.cr  # parse/serialize migration files
  src/engram/sync.cr         # tree↔db set-diff apply/rollback
  src/engram/search.cr       # fts5 bm25 + recency + optional cosine merge
  src/engram/embedder.cr     # OpenAI-compatible /v1/embeddings HTTP client (optional)
  src/engram/mcp_server.cr   # hand-rolled stdio JSON-RPC MCP server
  src/engram/hooks.cr        # git hook install/uninstall
  src/engram/cli.cr          # option parsing, subcommands, help text
  spec/                      # crystal spec; every module covered; temp-dir fixtures
  docs/SPEC.md                # the build contract this tool was built from
  .agents/memories/           # engram dogfoods itself — see its own design decisions below
```

See `docs/SPEC.md` for the full design contract, including the schema,
sync semantics, and every decision this tool made about itself (SQLite over
Postgres, hand-rolled MCP + YAML over new dependencies, why duplicate IDs
fail loudly, and more) — recorded, naturally, as `engram` memories in
`.agents/memories/`.

## License

MIT — see `LICENSE`.
