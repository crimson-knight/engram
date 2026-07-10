# Tested environment

This is the exact environment every claim in the README — the quickstart, the
git-hook PATH-independence, the embeddings graceful-degradation, "zero
config, one static binary" — was built and verified against. It is not a
theoretical support matrix; every line below was actually run. If you hit a
failure this README doesn't explain, **diff your environment against this
file first**: this is the gap-localization ledger — the baseline a reported
failure gets compared to, to see what's actually different.

Verification method: a fresh `mktemp` work directory and a fresh, empty
`$HOME`, a clone of the public repo, and every command run under a sanitized
environment —

```
env -i HOME=<temp home> PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  CRYSTAL_CACHE_DIR=<temp>/.crystal TERM=xterm
```

— so nothing in the surrounding shell (aliases, extra PATH entries, existing
`.gitconfig`, ambient env vars) could quietly stand in for something the
README should have stated explicitly. `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`
were left unset throughout; `LLAMERO_HOME` was absent throughout.

## Host

| | |
|---|---|
| OS | macOS, Darwin 25.5.0 |
| Architecture | arm64 (Apple Silicon) |
| C toolchain | Xcode Command Line Tools `cc` + `ld64.lld` (via `clang`) |

**Untested**: Linux (any distro), Intel Mac (x86_64), any BSD, Windows (not a
target — engram assumes a POSIX `sh` for its git hooks). Apple Silicon and
macOS are environment givens of the machine this was built on, not a
deliberate scoping decision — they are simply what has actually been run.

## Toolchain

| Tool | Version | Path | Notes |
|---|---|---|---|
| Crystal | 1.20.0 (2026-04-16) | `/opt/homebrew/bin/crystal` | LLVM 22.1.3, default target `aarch64-apple-darwin25.5.0`. `shard.yml` declares `crystal: ">= 1.11.2"`; only 1.20.0 has actually been run. |
| Shards (stock) | 0.20.0 (2025-12-19) | `/opt/homebrew/bin/shards` | This is what the whole build + test suite runs on. **`shards-alpha` is not required anywhere in this repo's own build/test/run path.** |
| Shards Alpha | 2025.11.25.4 [8bc0c29] (2026-04-23) | `/opt/homebrew/bin/shards-alpha` | Present on the build host as a separate tool, used only for this project's AI-docs/compliance tooling (see `docs/SPEC.md`'s shards-alpha scope note) — never invoked by `shard.yml`, `crystal build`, or `crystal spec`. A newcomer without `shards-alpha` installed is unaffected. |
| git | 2.50.1 (Apple Git-155) | `/usr/bin/git` (Xcode CLT) | **PATH-order caveat**: on this same machine, `/opt/homebrew/bin/git` is a stale symlink to a Homebrew Cellar git 2.41.0. Which `git` a shell actually runs depends on PATH order — everything in this repo was verified against 2.50.1. |

**Untested**: any Crystal version other than 1.20.0, `shards` versions other
than 0.20.0, git versions older than 2.50.1 (or any git for Windows/Linux
packaging).

## SQLite (the runtime dependency that matters most)

| | |
|---|---|
| Version | 3.51.0 (2025-06-12) |
| Source | macOS system `libsqlite3` (not vendored, not Homebrew — the `sqlite3` shard links `-lsqlite3` against whatever the linker resolves, which on a stock macOS install is the system library) |
| FTS5 | **Confirmed present and enabled.** |
| Confirmation method | Two independent checks, both passing: (1) `engram doctor`'s own runtime probe — `CREATE VIRTUAL TABLE probe USING fts5(x)` against a throwaway in-memory `sqlite3::memory:` connection, reported `[ok] sqlite FTS5 available`; (2) the CLI's `sqlite3 --version` reporting `3.51.0`, matching `docs/SPEC.md`'s own build-time note ("system libsqlite3 on macOS has FTS5 compiled in (verified 3.51.0)"). |

**Untested**: any `libsqlite3` build without FTS5 (engram's own exit-code
table documents this as a `2`/environment-error exit, but no CI or local run
has actually exercised that path — it cannot be manufactured without removing
or replacing the OS-provided library, which was out of scope to do on this
host); any sqlite version other than 3.51.0; Linux distributions that ship
`libsqlite3` built without FTS5 by default (this does happen on some distros
and is the single most likely real-world way this untested gap gets hit).

## Link-time libraries

From the actual `crystal build` link line on this host:

```
cc ... -o bin/engram -rdynamic -fuse-ld=lld \
  -L<crystal-cellar>/lib -lz -lsqlite3 \
  $(pkg-config --libs libssl || echo -lssl -lcrypto) \
  $(pkg-config --libs libcrypto || echo -lcrypto) \
  -L/opt/homebrew/Cellar/pcre2/10.47_1/lib -lpcre2-8 \
  -L/opt/homebrew/Cellar/bdw-gc/8.2.12/lib -lgc -liconv
```

`pcre2` 10.47_1 and `bdw-gc` (Boehm GC) 8.2.12 are pulled in via hardcoded
Homebrew Cellar paths that the Crystal compiler itself emits — not anything
engram's `shard.yml` controls. `openssl` is resolved via `pkg-config` (falling
back to bare `-lssl -lcrypto` if `pkg-config` isn't found), so it tracks
whatever OpenSSL `pkg-config` resolves to on the host.

**Untested / environment-specific**: any non-Homebrew Crystal install (a
from-source build, a Linux package, `asdf`/`mise`-managed Crystal) will emit a
different link line with different library paths. This is a property of the
Crystal compiler/toolchain, not of engram's own dependency list — engram
depends on exactly two shards (below) and the system's `sqlite3`/`ssl`/`crypto`.

## engram's own dependencies (`shard.lock`)

| Shard | Version | Source |
|---|---|---|
| `db` | 0.13.1 | `github: crystal-lang/crystal-db` |
| `sqlite3` | 0.21.0 | `github: crystal-lang/crystal-sqlite3` |

Fetched from GitHub by `shards install`; nothing else. `shards install` needs
network access to `github.com` the first time (or whenever `shard.lock`
changes) — this is a build-time requirement this README did not previously
state explicitly.

## Requirements vs. graceful degradation

| Concern | Required? | Verified behavior |
|---|---|---|
| `shards install` before `crystal build` | **Required, hard failure without it** | `crystal build` fails immediately with `Error: can't find file 'db'` if skipped — now stated in the README quickstart. |
| A pre-existing `bin/` directory for `-o bin/engram` | **Required, hard failure without it** | Link step fails with an `ld64.lld: ... No such file or directory` error that reads like a toolchain bug — now `mkdir -p bin` is in the quickstart. |
| `engram` on the *interactive* shell PATH | **Required for every command in this README except the git hooks** | Bare `engram` after building errors `command not found` until exported/copied onto PATH — now stated explicitly in the README's "A note on PATH". |
| `engram` on the noninteractive git-hook PATH | **No longer required, as of the PATH-independence hardening.** | `engram hook install` bakes the absolute path of the binary that ran it directly into the installed hook body (verified: `git checkout` under a `PATH` containing neither this repo's `bin/` nor Homebrew still correctly applies/rolls back memories — see `spec/cli_spec.cr`'s dedicated PATH-independence example). `engram doctor` additionally confirms that baked-in path still exists on disk and warns if it doesn't (e.g. the binary was later moved or rebuilt elsewhere) — re-running `hook install` from the new location repairs it in place. |
| Stock `shards` (vs. `shards-alpha`) | **`shards-alpha` not required anywhere** | The entire build + test suite runs on stock `shards` 0.20.0; `shards-alpha` is a separate tool used only for this repo's own AI-docs/compliance tooling, never by `crystal build`/`crystal spec` themselves. |
| System `libsqlite3` with FTS5 | **Required, hard failure without it** | All search depends on the FTS5 virtual table; a build without it fails `doctor`'s probe and exits `2` at runtime (documented; not independently exercised in this environment — see "Untested" above). |
| A C toolchain (Xcode CLT / equivalent) | **Required, hard failure without it** | `crystal build` shells out to `cc` to link; without it, the build fails at the link step. General Crystal requirement, not engram-specific. |
| Embeddings (`.agents/engram.yml` `embedder:` block) | **Optional, off by default** | With no config: FTS5-only, zero setup. With a configured-but-unreachable endpoint: `engram sync` warns once to stderr, continues without embeddings, exits `0`, and search falls back to bm25-only — confirmed by pointing the embedder at a closed TCP port and re-syncing. |
| A running local model server (Ollama, etc.) | **Not required at all** | Confirmed unnecessary for the entire documented newcomer journey — engram never assumes one is running, and gracefully degrades (see above) when it isn't. |
| `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | **Not required at all** | Left unset throughout verification; irrelevant unless you opt into an embedder config that names one via `api_key_env`. |
| `LLAMERO_HOME` / local HF models | **Not required, and not referenced by the runtime at all** | engram's runtime never touches `llamero` or `~/.llamero`; it appears only as a rejected alternative in this repo's own `.agents/memories/` and a scope note in `docs/SPEC.md`. |
| MCP client protocol negotiation | **Lenient by design, not strictly validated** | `engram mcp`'s hand-rolled JSON-RPC server accepts `tools/call` before `initialize`, defaults missing `initialize` params to the newest protocol version, and is generally more permissive than the spec requires (see the README's "Known limitations"). Verified against a well-formed `initialize` → `tools/list` → `tools/call` sequence piped directly into the process; not verified against every real MCP client implementation's exact handshake. |

## A note on sandbox artifacts

One environment property was a **session artifact of the build host, not a
clean-machine given**: something was listening on `localhost:11434` (Ollama's
default port) during verification. To faithfully reproduce "no embedding
server running," the embedder was pointed at a confirmed-closed port
(`localhost:59999`) instead of relying on 11434 actually being closed. This
is called out here so a future re-verification run doesn't mistake an
already-running Ollama for a clean baseline.
