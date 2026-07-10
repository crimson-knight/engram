---
id: 20260710230733
title: Baked the running binary's absolute path into installed git hooks
topics: [hooks, reliability, doctor]
supersedes: []
author: crimsonknight
---

**Decision:** A clean-room newcomer audit (fresh clone, sanitized env, no
engram on the noninteractive PATH) found that `engram hook install` wrote
`engram sync --quiet` — a bare command — into `post-checkout`/`post-merge`/
`post-rewrite`. Git runs hooks under its own minimal, noninteractive PATH,
which usually does *not* include wherever a developer built or `cp`'d the
binary, so the hook silently no-op'd (`command not found`, hook exits
nonzero) and the per-clone cache went stale — the tool's headline promise
("branch switch, and the cache doesn't lie about what's true here") quietly
failing on the most common newcomer setup, while `engram doctor` still
reported the hooks `[ok]`. Fixed by having `Hooks.install` bake the
**absolute path** of the engram binary that ran `hook install`
(`Process.executable_path`) directly into the hook body, wrapped in a
human-readable `# engram-bin: <path>` marker line so it can be read back
without reverse-parsing shell quoting. `engram doctor` now also confirms that
baked-in path still exists on disk and downgrades to `[warn]` (naming the
affected hooks) if it doesn't — e.g. the binary was later rebuilt or moved.
Re-running `engram hook install` from the binary's new location repairs an
existing hook in place (it rewrites a stale block rather than treating "marker
already present" as a permanent no-op), so recovering from a stale hook is
just re-running the same command, not uninstall-then-reinstall.

**Why:** A feature whose entire value proposition is "you never have to
think about it" is worse than useless if it fails exactly the way a
newcomer's environment is shaped to trigger, and does so *silently* — no
error a user sees, just quietly wrong search results after a branch switch.
Baking in the resolved path removes the PATH dependency entirely rather than
documenting around it; having `doctor` verify the baked path (not just "is
the marker present and the file executable") closes the exact blind spot
that let a broken hook keep reporting `[ok]`.

**Rejected:** Requiring users to permanently install engram to a fixed system
PATH location (e.g. `/usr/local/bin`) and leaving the hook as a bare command —
this only shifts the burden onto every user remembering an extra manual step
the tool could just do for them, and still breaks the moment the binary is
reinstalled somewhere else without the hook being told. Also rejected:
resolving the engram path lazily at hook-run time via `command -v engram`
inside the hook script itself — that's exactly the PATH-dependent lookup
being removed, just deferred from install-time to every single checkout.
