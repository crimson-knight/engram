---
id: 20260708153000
title: Hand-rolled the MCP server and the YAML subset instead of adding shards
topics: [mcp, dependencies, architecture]
supersedes: []
author: seth
---

**Decision:** `engram mcp` is a from-scratch newline-delimited JSON-RPC 2.0
loop over stdio (no MCP SDK dependency), and both the memory-file
frontmatter and `.agents/engram.yml` are parsed by small, purpose-built
readers instead of pulling in a YAML shard.

**Why:** Dependency count is the product here. engram's entire pitch is
"one static binary, zero setup" — every added shard is another thing that
can drift, another supply-chain surface, another version to pin and
audit. The actual protocol surface engram needs (newline-delimited JSON-RPC
framing, five tool schemas, a strict flat-key/array YAML subset) is small
and stable enough that hand-rolling it is *less* total complexity than
vendoring and tracking a general-purpose library for it, and it keeps the
declared dependency list at exactly `db` + `sqlite3` — nothing else.

**Rejected:** Adding a YAML shard for frontmatter/config parsing, and an MCP
SDK shard for the server loop. Both would have pulled in far more surface
area (arbitrary YAML semantics, anchors, multi-document streams, full
protocol negotiation machinery) than engram's genuinely small, fixed
requirements call for, in exchange for one dependency each that this
project would then be responsible for keeping compatible forever.
