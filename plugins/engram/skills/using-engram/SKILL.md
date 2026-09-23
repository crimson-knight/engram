---
name: using-engram
description: Search and record branch-scoped agent memories with engram.
---

# Using engram

engram stores decisions as migration files in .agents/memories and applies
them to a disposable SQLite cache in .git/engram.db. The files are the source
of truth. Checking out another branch changes the active memory set to match
that branch.

## Search before changing load-bearing code

Before modifying structural or surprising behavior, search for the decision
that explains it:

    engram search "sqlite vs postgres"
    engram search "embedder dimension" --topic architecture
    engram recent --limit 5

The MCP tools search_memories and recent_memories provide the same search.
Use get_memory to read a full result before proposing a choice it rejects.

## Record a decision

Create a migration with a short title and useful topic:

    engram new "Chose X over Y for Z" --topics architecture

Write a concise body with the decision, why it was made, and the rejected
alternative. Then run engram sync. The MCP remember tool writes and applies
the migration in one call.

A memory is not shared until its migration is committed with the code. Stage
and commit .agents/memories with the other changes. If the new memory replaces
an older one, use --supersedes <id> or the MCP supersedes field.

## Review another branch

After checking out a branch, run engram sync if its git hooks are not
installed. Search or list recent memories before suggesting a decision that
may already have been considered. Switching branches and syncing removes
memories that are absent from the new tree.
