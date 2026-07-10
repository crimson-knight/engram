---
id: 20260708101500
title: FTS5 is the default search; embeddings are opt-in, config-driven
topics: [search, embeddings, architecture]
supersedes: []
author: seth
---

**Decision:** `engram search` always ranks with SQLite FTS5's `bm25()`
blended with a recency boost. Semantic search over embeddings only turns on
if `.agents/engram.yml` names an `embedder:` endpoint, and even then it's
merged in via Reciprocal Rank Fusion rather than replacing bm25 outright.

**Why:** The zero-config first run has to actually be zero-config. FTS5
ships in the system sqlite3 already linked for the `sqlite3` shard, so
full-text + recency ranked search works the instant someone runs
`engram init` — no model download, no server to stand up, no API key.
When a team does want semantic recall, the embedder config points at any
OpenAI-compatible `/v1/embeddings` endpoint, which makes Ollama a fully
supported, fully local, zero-cloud-dependency upgrade path — not a
second-class one bolted on after the fact.

**Rejected:** Bundling a local embedding model (e.g. via llamero) directly
into engram so semantic search "just works" out of the box. That would
have made the binary far bigger, added a real first-run cost (downloading
a model), and blurred the line between "a memory store" and "an inference
engine" — two different jobs that should stay decoupled. engram stores and
retrieves; model inference is deliberately someone else's job to plug in.
