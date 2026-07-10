# engram — branch-scoped memory for coding agents

**Status:** v0.1.0 spec (2026-07-10). This document is the build contract; it ships in the repo as `docs/SPEC.md` (AED why-document ethos: the spec records decisions AND rejections).

## One-paragraph pitch

Decision context should travel with code the way schema travels with data. `engram` stores agent memories as **migration files committed to the repo** (`.agents/memories/*.md`) and materializes them into a **per-clone SQLite cache** (`.git/engram.db`, never committed). Switching branches applies the memories that exist on that branch and rolls back the ones that don't — the agent gets perfect recall on checkout and clean amnesia on switch. Zero config: no Postgres, no pgvector, no model download. One static Crystal binary.

## Non-goals (v0.1)

- No daemon, no server except the stdio MCP server.
- No git history mining. Source of truth is the working tree, full stop.
- No multi-repo federation, no sync to remote services.
- No LoRA/model training (that's llamero's job; engram stores and retrieves).

## Repository layout (the tool's own repo)

```
engram/
  shard.yml            # name: engram, version: 0.1.0, targets: engram
  src/engram.cr        # entry, CLI dispatch
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
  docs/SPEC.md               # this file
  README.md
  LICENSE                    # MIT
  .agents/memories/          # engram dogfoods itself: its own design decisions as memories
```

Dependencies: `db` (crystal-lang/crystal-db ~> 0.13.1), `sqlite3` (crystal-lang/crystal-sqlite3 ~> 0.21.0). NOTHING else. Crystal >= 1.11.2. The sqlite3 shard links `-lsqlite3`; system libsqlite3 on macOS has FTS5 compiled in (verified 3.51.0). `engram doctor` re-verifies FTS5 at runtime.

## Memory migration file format

Path: `.agents/memories/<ID>_<slug>.md` where `<ID>` is `YYYYMMDDHHMMSS` UTC. The filename is canonical; frontmatter `id` must match or `sync` reports an error (does not guess).

```markdown
---
id: 20260710153000
title: Chose SQLite over Postgres for the memory cache
topics: [storage, architecture]
supersedes: []            # optional: list of older memory IDs this replaces
author: seth              # optional, freeform
---

**Decision:** Use a per-clone SQLite file at .git/engram.db instead of a shared Postgres database.

**Why:** Zero configuration for every teammate; the DB is a disposable cache of the
migration files, so nothing is lost when it's deleted.

**Rejected:** Postgres + pgvector — the per-developer setup cost (install, extension,
embedding model) was the main thing killing adoption.
```

Rules:
- Frontmatter is a strict subset of YAML (flat keys, string/array values); hand-rolled parser is acceptable — do NOT add a YAML shard dependency.
- Body is freeform markdown. `Decision/Why/Rejected` bold-label sections are convention, not schema.
- `supersedes` entries demote (not delete) older memories: superseded memories are excluded from `search`/`recent` output by default, included with `--all`.
- Duplicate IDs across two files in the same tree → `sync` fails loudly listing both paths (this is the merge-conflict-surfaces-decision-conflict feature; document it).

## SQLite schema (`.git/engram.db`)

```sql
CREATE TABLE IF NOT EXISTS memories (
  id INTEGER PRIMARY KEY,          -- the 14-digit migration ID
  slug TEXT NOT NULL,
  title TEXT NOT NULL,
  topics TEXT NOT NULL DEFAULT '', -- comma-joined, lowercased
  author TEXT,
  body TEXT NOT NULL,
  supersedes TEXT NOT NULL DEFAULT '',   -- comma-joined IDs
  superseded_by INTEGER,                 -- maintained by sync from other rows' supersedes
  embedding BLOB,                        -- packed Float32, NULL when embedder off
  file_path TEXT NOT NULL,               -- repo-relative source path
  applied_at TEXT NOT NULL               -- ISO8601 UTC
);
CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
  title, topics, body, content='memories', content_rowid='id'
);
-- external-content sync via AFTER INSERT/DELETE/UPDATE triggers (the verified pattern)
CREATE TABLE IF NOT EXISTS engram_meta (key TEXT PRIMARY KEY, value TEXT);
```

The applied-set IS the `memories` table (row present = applied). No linear version ordering anywhere — branches may reorder freely (Rails `schema_migrations` semantics, not `schema_version`).

## Sync semantics (the heart of the tool)

`engram sync`:
1. Scan `.agents/memories/*.md` in the working tree → parse into a set keyed by ID.
2. Set-diff against `memories` rows:
   - file present, no row → **apply** (insert + FTS + embedding if embedder configured).
   - row present, no file → **rollback** (delete row; FTS trigger cleans up).
   - both present but file content hash ≠ stored content → **re-apply** (update in place).
3. Recompute `superseded_by` links.
4. Print a one-line summary: `engram: +2 applied, -3 rolled back, 1 updated (47 active)`.

Properties to preserve (spec-tested): idempotent; git-agnostic (works mid-rebase, detached HEAD, after stash); a corrupted/deleted `.git/engram.db` is fully rebuilt by the next `sync`.

## Search & ranking

- `engram search <query> [--topic t] [--limit n] [--all] [--json]`
  - FTS5 `MATCH` with `bm25(memories_fts)` (lower = better; default ASC order — do not add DESC).
  - Recency: final score = `bm25_rank - recency_boost` where `recency_boost = w * (id_timestamp - oldest) / (newest - oldest)`, w = 1.0. Document the formula in --help; keep it this simple.
  - When embeddings exist for ≥ 1 memory AND the embedder is configured: also compute query embedding, cosine against all rows (brute force over Float32 slices — fine into the tens of thousands), and merge via Reciprocal Rank Fusion (RRF, k=60) of the two orderings. RRF avoids score-scale games.
  - Superseded memories excluded unless `--all`.
- `engram recent [--topic t] [--limit n] [--json]` — newest first.
- `engram show <id>` — full body.
- `--json` outputs are the machine interface; keep shapes stable and documented in README.

## Embedder (optional, config-driven)

Config file `.agents/engram.yml` (same hand-rolled flat YAML subset):

```yaml
embedder:
  url: http://localhost:11434/v1/embeddings   # any OpenAI-compatible endpoint (Ollama works)
  model: nomic-embed-text
  api_key_env: OPENAI_API_KEY                  # optional; name of env var, never the key itself
```

- No config → embeddings silently off, FTS5 only. This is the default and the adoption story.
- HTTP via stdlib `HTTP::Client`, 10s timeout; on failure, warn once per sync and continue without embeddings (never block sync on a dead endpoint).
- Embeddings computed at apply time; stored as packed Float32 BLOB (`Bytes` reinterpret, the verified pattern); dimension recorded in `engram_meta`; dimension change → re-embed all on next sync (warn).

## MCP server (`engram mcp`)

Hand-rolled newline-delimited JSON-RPC 2.0 over stdio (the compliance_server.cr pattern: `STDIN.gets` loop, `STDOUT.puts + flush`, sync=true, EOF = shutdown). Methods: `initialize` (protocol versions `["2025-11-25","2025-06-18","2025-03-26","2024-11-05"]`, negotiate newest ≤ client), `notifications/initialized` (no reply), `ping`, `tools/list`, `tools/call`; unknown method with id → `-32601`; parse error → `-32700` id null; internal → `-32603`. In-process tool execution (no subprocess shell-outs). Tools:

1. `search_memories {query, topic?, limit?, include_superseded?}` → ranked memories (id, title, topics, snippet, score).
2. `recent_memories {topic?, limit?}` → newest active memories.
3. `get_memory {id}` → full body + metadata.
4. `remember {title, body, topics?, supersedes?}` → writes a new migration file (ID = current UTC timestamp, slug from title) AND applies it; returns file path + id. THE tool result must remind the agent the file needs to be committed.
5. `memory_status {}` → active/superseded counts, embedder on/off, DB path, last sync.

All results: `content: [{type:"text", text: <human summary>}]` plus `structuredContent` with the JSON payload.

## CLI surface

```
engram init                # create .agents/memories/, .gitignore note, optional engram.yml stub, run first sync
engram new "<title>" [--topics a,b] [--supersedes id,...]   # scaffold migration file, open $EDITOR if tty
engram sync [--verbose]
engram search / recent / show   (above)
engram mcp                 # stdio MCP server
engram hook install|uninstall   # post-checkout, post-merge, post-rewrite → `engram sync --quiet`
engram doctor              # checks: sqlite FTS5, .agents/memories exists, hook state, embedder reachability, DB integrity
engram version
```

`hook install`: if a hook file exists and doesn't contain the engram marker line, append the guarded snippet; if absent, create with shebang. Marker comments (`# >>> engram >>>` / `# <<< engram <<<`) make uninstall exact.

## Error handling & conventions

- AED conventions: code reads like plain statements of intent; every public method has a one-line doc comment; errors are specific exception classes (`Engram::ParseError`, `Engram::DuplicateIdError`, ...) with actionable messages.
- Never print stack traces to users; `--verbose` shows detail.
- Exit codes: 0 ok, 1 user/data error (duplicate IDs, bad frontmatter), 2 environment error (no FTS5, unwritable .git).

## Spec (test) requirements

`crystal spec` must cover: frontmatter parse round-trip incl. malformed cases; sync apply/rollback/update/idempotence in a temp git repo; duplicate-ID failure; supersedes demotion; bm25+recency ordering with a fixed fixture set; RRF merge with a fake embedder; BLOB embedding round-trip; MCP initialize/tools-list/tools-call/error paths driven through an IO pair; hook install/uninstall marker behavior. Specs use temp dirs (`File.tempname`), never the real repo.

## Why-record (decisions already made — put these in the repo's own .agents/memories/)

1. SQLite-not-Postgres (adoption friction) — see pitch.
2. Tree-state sync, not branch-name sync (rebase/stash/detached-HEAD correctness for free).
3. FTS5-default, embeddings-optional (zero-config first run; semantic upgrade without new deps via OpenAI-compatible endpoint = Ollama-friendly).
4. Hand-rolled MCP + hand-rolled YAML subset (dependency count is the product).
5. Applied-set not linear versions (branches reorder; cross-branch timestamp ordering is unsolvable and unnecessary).
6. Duplicate ID = loud failure (decision conflicts should surface at merge, not silently last-write-win).
