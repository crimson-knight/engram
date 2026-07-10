---
id: 20260710182649
title: Documented v0.1 known limitations rather than gating on every adversarial edge
topics: [process, quality, mcp, search]
supersedes: []
author: seth
---

**Decision:** A round-1 adversarial (Codex) review surfaced a long tail of
real-but-low-reachability edges. We fixed the ones that could cause silent
data loss or wrong results on a compliant client, and *documented* the rest
as a "Known limitations (v0.1)" section in the README plus this memory —
rather than gating the release on hardening every edge.

**Fixed for v0.1 (verified):** atomic id-claim so two `remember`/`new` calls
in the same second never silently overwrite (id is the globally-unique key,
guarded by an id-prefix peek *and* an atomic `link(2)`); lossless
frontmatter serialize/parse round-trip (quoting for `#`, commas, colons,
quotes, backslashes; body indentation and blank lines preserved); a real
sync transaction on one connection plus `PRAGMA busy_timeout` so concurrent
syncs don't hit "database is locked" and an interrupted sync rolls back
cleanly; self-healing rebuild of a corrupted/truncated `.git/engram.db`;
percent-encoded sqlite connection URIs so a repo path with `+ ? # %` or a
space opens the right database; non-ASCII queries (e.g. all-CJK) that
tokenize to nothing return no-match instead of masquerading as recency
results; and hook installation that resolves the effective hooks dir via
`git` (honoring `core.hooksPath` and linked worktrees) and marks hooks
executable.

**Why:** engram v0.1 is a local, single-developer tool whose source of truth
is committed regular files. The documented edges either require hand-authored
adversarial input no normal workflow produces (memory symlinks, self/forward
supersession, cycles), only affect the opt-in embeddings cache (fully cured
by the disposable "delete `.git/engram.db` and re-sync"), or are excess
JSON-RPC leniency that never breaks a conforming MCP client. Honesty over
false coverage: the README states these plainly and `docs/SPEC.md`'s
"spec-tested" claims were kept to what the suite actually proves.

**Rejected:** Blocking release to build a strict MCP lifecycle state machine,
full JSON-RPC error-code layering, content-fingerprinted embedding
invalidation, supersession-graph validation, and lstat guards against
symlinked/special-file inputs. All are worthwhile future hardening; none is
release-gating for a single-user v0.1, and shipping them now would trade a
working, honestly-scoped tool for polish nobody is currently blocked on.
