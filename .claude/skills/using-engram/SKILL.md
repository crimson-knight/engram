---
name: using-engram
description: Store and retrieve branch-scoped agent memories with engram — search decision history, record new decisions as memory migrations, understand why code is the way it is. Use when asked why a decision was made, when recording a decision, or when reviewing a branch.
---

# Using engram

`engram` is branch-scoped memory for coding agents: decisions live as
migration files in `.agents/memories/*.md` (committed to git) and get
materialized into a local SQLite cache at `.git/engram.db` (never committed,
fully disposable — `engram sync` rebuilds it from the tree at any time).
Checking out a branch applies the memories that exist there and rolls back
the ones that don't, so search results are always scoped to what's actually
on the current branch.

## Search before changing load-bearing code

Before modifying anything that looks structural, load-bearing, or oddly
specific (a weird-looking condition, a dependency choice, a config value that
doesn't explain itself), search for prior context first:

```
engram search "sqlite vs postgres"
engram search "embedder dimension" --topic architecture
engram recent --limit 5
```

Or, via MCP, call `search_memories {query, topic?, limit?}` or
`recent_memories {topic?, limit?}`. A hit that **rejects** the approach
you're about to take is exactly the case this tool exists for — read it
before you re-propose the rejected approach. `engram show <id>` (or the MCP
`get_memory {id}`) gets the full body of a specific hit.

## Recording a decision

Once you (or the user) make a decision worth remembering — a technical
choice, a rejected alternative, a non-obvious tradeoff — record it as a new
memory:

```
engram new "Chose X over Y for Z" --topics <comma,separated,topics>
```

This scaffolds `.agents/memories/<id>_<slug>.md` with frontmatter filled in
and opens `$EDITOR` if you're at an interactive terminal. Write the body as
freeform markdown; `**Decision:** / **Why:** / **Rejected:**` sections are
the convention but not enforced. Then apply it to the local cache:

```
engram sync
```

Via MCP, the same flow is one call: `remember {title, body, topics?,
supersedes?}` writes the file **and** applies it in one step.

**Either way, the memory isn't real until it's committed.** `engram new` +
`engram sync`, and MCP `remember`, only touch the local working tree and the
local cache. Run `git add .agents/memories/` and commit — an uncommitted
memory file disappears on the next tree reset and never reaches any other
clone. Both the CLI and the MCP tool result say this explicitly; don't skip
it.

If a new memory replaces an older one, pass `--supersedes <id>` (CLI) or
`supersedes: [id]` (MCP) — this demotes the old memory (hides it from default
search/recent, keeps it retrievable with `--all` / `include_superseded`)
rather than deleting it.

## The reviewer flow

When checking out someone else's branch to review or try something:

1. `git checkout <branch>` — if the git hooks are installed
   (`engram hook install`, adding to `post-checkout`/`post-merge`/
   `post-rewrite`), this alone re-syncs the cache automatically.
2. If hooks aren't installed, or you want to force a re-sync mid-session
   (mid-rebase, after a stash pop, in detached HEAD — `engram sync` is
   git-agnostic and always correct), run `engram sync` yourself.
3. `engram recent` or `engram search <topic>` to surface what the branch's
   author already decided (and rejected) before you suggest something they
   already ruled out.
4. Switching back to `main` (or any other branch) and re-syncing makes those
   memories disappear from search again automatically — nothing to clean up.

`engram doctor` is the quick health check if search/recent ever look empty or
stale unexpectedly: it reports FTS5 availability, whether `.agents/memories`
exists, hook install state, embedder reachability, and DB integrity.
